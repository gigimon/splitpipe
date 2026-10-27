import Foundation
import Network
import NetworkExtension

/// Перекачивает данные между перехваченным TCP flow и исходящим NWConnection, привязанным к интерфейсу.
final class TCPRelay: Relay {
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.splitpipe.tcp")
    private let onClose: () -> Void
    private var closed = false
    private var ready = false
    private var localEOF = false
    private var remoteEOF = false
    let stats = FlowStats()
    static let waitingTimeout: TimeInterval = 5
    /// Общий срок на установление соединения: в `.preparing` NWConnection может висеть сколько угодно, а приложение
    /// не получило бы ни ошибки, ни данных.
    static let connectTimeout: TimeInterval = 30

    init(flow: NEAppProxyTCPFlow, interface: NWInterface?, onClose: @escaping () -> Void) {
        self.flow = flow
        self.onClose = onClose
        // Keepalive, который приложение включало у своего сокета, к нашему не переходит: молчащие соединения
        // (IMAP IDLE, WebSocket) иначе умирают на NAT роутера или провайдера.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        let params = NWParameters(tls: nil, tcp: tcp)
        if let interface, !isDNS(flow.remoteFlowEndpoint) { params.requiredInterface = interface }
        params.preferNoProxies = true
        connection = NWConnection(to: flow.remoteFlowEndpoint, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                ready = true
                flow.open(withLocalFlowEndpoint: nil) { error in
                    self.queue.async {
                        if let error { self.close(error); return }
                        self.pumpFlowToRemote()
                        self.pumpRemoteToFlow()
                    }
                }
            case .waiting(let error):
                // Network.framework часто на мгновение сообщает «waiting» до того, как путь будет выбран,
                // и потом соединяется сам. Закрывать сразу нельзя — так ломалась половина соединений.
                queue.asyncAfter(deadline: .now() + Self.waitingTimeout) {
                    guard !self.closed, case .waiting = self.connection.state else { return }
                    logger.error("tcp \(self.connection.endpoint.debugDescription, privacy: .public) waiting too long: \(error.localizedDescription, privacy: .public)")
                    self.close(error)
                }
            case .failed(let error):
                logger.error("tcp \(self.connection.endpoint.debugDescription, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                close(error)
            case .cancelled:
                close(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) {
            guard !self.closed, !self.ready else { return }
            logger.error("tcp \(self.connection.endpoint.debugDescription, privacy: .public) connect timeout in \(String(describing: self.connection.state), privacy: .public)")
            self.close(NWError.posix(.ETIMEDOUT))
        }
    }

    private func pumpFlowToRemote() {
        flow.readData { data, error in
            self.queue.async {
                if let error { self.close(error); return }
                guard let data, !data.isEmpty else {
                    self.localEOF = true
                    self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { _ in })
                    self.finishIfDone()
                    return
                }
                self.stats.sent(data.count)
                self.connection.send(content: data, completion: .contentProcessed { error in
                    self.queue.async {
                        if let error { self.close(error) } else { self.pumpFlowToRemote() }
                    }
                })
            }
        }
    }

    private func pumpRemoteToFlow() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.stats.received(data.count)
                self.flow.write(data) { writeError in
                    self.queue.async {
                        if let writeError { self.close(writeError); return }
                        if isComplete { self.remoteDone() } else { self.pumpRemoteToFlow() }
                    }
                }
                return
            }
            if let error { self.close(error); return }
            if isComplete { self.remoteDone() } else { self.pumpRemoteToFlow() }
        }
    }

    private func remoteDone() {
        remoteEOF = true
        flow.closeWriteWithError(nil)
        finishIfDone()
    }

    private func finishIfDone() {
        if localEOF && remoteEOF { close(nil) }
    }

    func abort() {
        queue.async { self.close(NEAppProxyFlowError(.aborted)) }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        connection.cancel()
        onClose()
    }
}

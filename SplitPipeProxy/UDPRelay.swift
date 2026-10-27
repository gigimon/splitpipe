import Foundation
import Network
import NetworkExtension

/// UDP flow может слать датаграммы на разные адреса: на каждый remote endpoint своё NWConnection.
/// STUN, WebRTC и мессенджеры шлют с одного сокета на сотни адресов, поэтому соединения по endpoint ограничены
/// по числу и закрываются, когда простаивают.
final class UDPRelay: Relay {
    private struct Peer {
        var connection: NWConnection
        var lastActivity: Date
    }

    private let flow: NEAppProxyUDPFlow
    private let interface: NWInterface?
    private let lanViaSystem: Bool
    private let queue = DispatchQueue(label: "dev.splitpipe.udp")
    private let onClose: () -> Void
    private var peers: [Network.NWEndpoint: Peer] = [:]
    private var closed = false
    private var lastActivity = Date()
    /// Сокет приложения живёт долго и шлёт редко (игры, VoIP с редким keepalive): закрытый flow заменился бы новым,
    /// а у NAT — новым портом. Отдельные адреса закрываются раньше: их у STUN и WebRTC сотни.
    private let idleTimeout: TimeInterval = 300
    private let peerIdleTimeout: TimeInterval = 60
    private let maxPeers = 64
    let stats = FlowStats()

    init(flow: NEAppProxyUDPFlow, interface: NWInterface?, lanViaSystem: Bool, onClose: @escaping () -> Void) {
        self.flow = flow
        self.interface = interface
        self.lanViaSystem = lanViaSystem
        self.onClose = onClose
    }

    func start() {
        flow.open(withLocalFlowEndpoint: nil) { error in
            self.queue.async {
                if let error { self.close(error); return }
                self.readFromFlow()
                self.scheduleIdleCheck()
            }
        }
    }

    private func readFromFlow() {
        flow.readDatagrams { (datagrams: [(Data, Network.NWEndpoint)]?, error: Error?) in
            self.queue.async {
                if let error { self.close(error); return }
                guard let datagrams, !datagrams.isEmpty else { self.close(nil); return }
                self.lastActivity = Date()
                for (data, endpoint) in datagrams {
                    self.stats.sent(data.count)
                    self.stats.seen(remote: endpoint.display)
                    self.connection(for: endpoint).send(content: data, completion: .contentProcessed { _ in })
                }
                self.readFromFlow()
            }
        }
    }

    private func connection(for endpoint: Network.NWEndpoint) -> NWConnection {
        if peers[endpoint] != nil {
            peers[endpoint]!.lastActivity = Date()
            return peers[endpoint]!.connection
        }
        if peers.count >= maxPeers, let oldest = peers.min(by: { $0.value.lastActivity < $1.value.lastActivity }) {
            drop(oldest.key, oldest.value.connection)
        }
        let params = NWParameters.udp
        if let interface, !isDNS(endpoint), !(lanViaSystem && endpoint.isLocal) { params.requiredInterface = interface }
        params.preferNoProxies = true
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting:
                // Как и у TCP: «waiting» обычно временное, соединение установится само.
                self?.queue.asyncAfter(deadline: .now() + TCPRelay.waitingTimeout) {
                    guard case .waiting(let error) = c.state else { return }
                    logger.error("udp \(endpoint.debugDescription, privacy: .public) waiting too long: \(error.localizedDescription, privacy: .public)")
                    self?.drop(endpoint, c)
                }
            case .failed(let error):
                logger.error("udp \(endpoint.debugDescription, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self?.queue.async { self?.drop(endpoint, c) }
            default:
                break
            }
        }
        peers[endpoint] = Peer(connection: c, lastActivity: Date())
        c.start(queue: queue)
        receive(on: c, from: endpoint)
        return c
    }

    /// Вызывать на `queue`. Убирает соединение, только если по этому endpoint всё ещё оно, а не уже новое.
    private func drop(_ endpoint: Network.NWEndpoint, _ c: NWConnection) {
        c.cancel()
        if peers[endpoint]?.connection === c { peers[endpoint] = nil }
    }

    private func receive(on c: NWConnection, from endpoint: Network.NWEndpoint) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                if self.peers[endpoint]?.connection === c { self.peers[endpoint]?.lastActivity = self.lastActivity }
                self.stats.received(data.count)
                self.flow.writeDatagrams([(data, endpoint)]) { _ in }
            }
            if error == nil { self.receive(on: c, from: endpoint) }
        }
    }

    private func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastActivity) > self.idleTimeout {
                self.close(nil)
                return
            }
            for (endpoint, peer) in self.peers where now.timeIntervalSince(peer.lastActivity) > self.peerIdleTimeout {
                self.drop(endpoint, peer.connection)
            }
            self.scheduleIdleCheck()
        }
    }

    func abort() {
        queue.async { self.close(NEAppProxyFlowError(.aborted)) }
    }

    private func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        peers.values.forEach { $0.connection.cancel() }
        peers.removeAll()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        onClose()
    }
}

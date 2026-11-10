import Foundation
import Network
import NetworkExtension

/// Перекачивает датаграммы между перехваченным UDP flow и своими сокетами (`UDPSockets`): как и сокет приложения,
/// один сокет шлёт на все адреса с одного порта и принимает от любого.
final class UDPRelay: Relay {
    /// Адрес по имени (так шлёт Network.framework — QUIC у `URLSession`): резолвится системным резолвером, как и
    /// весь DNS.
    private enum Name {
        case resolving([Data])
        case resolved(UDPAddress)
        case failed(Date)
    }

    private let flow: NEAppProxyUDPFlow
    private let interface: NWInterface?
    private let lanViaSystem: Bool
    private let queue = DispatchQueue(label: "dev.splitpipe.udp")
    private let onClose: () -> Void
    private lazy var sockets = UDPSockets(interfaceIndex: interface.map { UInt32($0.index) }, queue: queue) { [weak self] in
        self?.received($0)
    }
    /// Адрес → endpoint, которым его назвало приложение (имя): ответ возвращается под ним же.
    private var origins: [UDPAddress: Network.NWEndpoint] = [:]
    private var names: [Network.NWEndpoint: Name] = [:]
    /// Ошибки отправки, уже попавшие в журнал: одна и та же на каждую датаграмму не нужна.
    private var reported: Set<Int32> = []
    private var sawRemote = false
    private var closed = false
    private var lastActivity = Date()
    /// Сокет приложения живёт долго и шлёт редко (игры, VoIP с редким keepalive): закрытый flow заменился бы новым,
    /// а у NAT — новым портом.
    private let idleTimeout: TimeInterval = 300
    private static let nameRetry: TimeInterval = 5
    private static let maxQueued = 32
    private static let maxNames = 256
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
                guard !self.closed else { return }
                if let error { self.close(error); return }
                guard let datagrams, !datagrams.isEmpty else { self.close(nil); return }
                self.lastActivity = Date()
                for (data, endpoint) in datagrams {
                    self.stats.sent(data.count)
                    if !self.sawRemote {
                        self.sawRemote = true
                        self.stats.seen(remote: endpoint.display)
                    }
                    self.send(data, to: endpoint)
                }
                self.readFromFlow()
            }
        }
    }

    private func send(_ data: Data, to endpoint: Network.NWEndpoint) {
        if let address = UDPAddress(endpoint) {
            transmit(data, to: address, port53: isDNS(endpoint))
            return
        }
        guard case .hostPort(.name(let host, _), let port) = endpoint else { return }
        switch names[endpoint] {
        case .resolved(let address):
            transmit(data, to: address, port53: isDNS(endpoint))
        case .resolving(let queued):
            if queued.count < Self.maxQueued { names[endpoint] = .resolving(queued + [data]) }
        case .failed(let at) where Date().timeIntervalSince(at) < Self.nameRetry:
            break
        default:
            if names.count >= Self.maxNames { names.removeAll() }
            names[endpoint] = .resolving([data])
            resolve(host, port: port.rawValue, for: endpoint)
        }
    }

    private func resolve(_ host: String, port: UInt16, for endpoint: Network.NWEndpoint) {
        DispatchQueue.global(qos: .userInitiated).async {
            let address = Self.lookup(host, port: port)
            self.queue.async {
                guard !self.closed, case .resolving(let queued)? = self.names[endpoint] else { return }
                guard let address else {
                    logger.error("udp \(host, privacy: .public): name not resolved")
                    self.names[endpoint] = .failed(Date())
                    return
                }
                self.names[endpoint] = .resolved(address)
                self.origins[address] = endpoint
                queued.forEach { self.transmit($0, to: address, port53: port == 53) }
            }
        }
    }

    /// Первый адрес IPv4, иначе IPv6: у привязанного интерфейса IPv6 обычно нет.
    private static func lookup(_ host: String, port: UInt16) -> UDPAddress? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        let all = sequence(first: first, next: { $0.pointee.ai_next }).compactMap { info in
            info.pointee.ai_addr.flatMap { UDPAddress($0, port: port) }
        }
        return all.first { !$0.isIPv6 } ?? all.first
    }

    /// DNS и, при «Локальная сеть — по системному маршруту», локальные адреса идут мимо интерфейса маршрута.
    private func transmit(_ data: Data, to address: UDPAddress, port53: Bool) {
        let bound = interface != nil && !port53 && !(lanViaSystem && address.endpoint.isLocal)
        guard let error = sockets.send(data, to: address, bound: bound), reported.insert(error).inserted else { return }
        logger.error("udp \(address.endpoint.display, privacy: .public) send failed: \(String(cString: strerror(error)), privacy: .public)")
    }

    private func received(_ datagrams: [(Data, UDPAddress)]) {
        guard !closed else { return }
        lastActivity = Date()
        let out = datagrams.map { data, from in
            stats.received(data.count)
            return (data, origins[from] ?? from.endpoint)
        }
        flow.writeDatagrams(out) { _ in }
    }

    private func scheduleIdleCheck() {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.idleTimeout {
                self.close(nil)
                return
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
        sockets.close()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        onClose()
    }
}

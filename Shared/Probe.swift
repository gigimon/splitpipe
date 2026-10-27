import Foundation
import Network

/// HTTP(S) GET через конкретный интерфейс. Нужен для проверки, куда реально уходит трафик.
enum Probe {
    static func run(url: String, interface: NWInterface?, interfaceName: String,
                    timeout: TimeInterval = 8, completion: @escaping (ProbeResult) -> Void) {
        guard let u = URL(string: url), let host = u.host else {
            completion(ProbeResult(interface: interfaceName, ok: false, body: "bad url", millis: 0))
            return
        }
        let queue = DispatchQueue(label: "dev.splitpipe.probe")
        queue.async {
            // Имя резолвим системным резолвером: у utun VPN без Network Extension нет своего DNS, и резолв
            // с привязкой к интерфейсу даёт «Network is down». Подключаемся по IP через нужный интерфейс.
            let target: NWEndpoint.Host
            if IPv4Address(host) != nil || IPv6Address(host) != nil {
                target = NWEndpoint.Host(host)
            } else if let ip = resolveIPv4(host) {
                target = .ipv4(ip)
            } else {
                completion(ProbeResult(interface: interfaceName, ok: false, body: "dns failed", millis: 0))
                return
            }
            get(u, host: host, target: target, interface: interface, interfaceName: interfaceName,
                queue: queue, timeout: timeout, completion: completion)
        }
    }

    private static func get(_ u: URL, host: String, target: NWEndpoint.Host, interface: NWInterface?, interfaceName: String,
                            queue: DispatchQueue, timeout: TimeInterval, completion: @escaping (ProbeResult) -> Void) {
        let tls = u.scheme == "https"
        let port = NWEndpoint.Port(integerLiteral: UInt16(u.port ?? (tls ? 443 : 80)))
        let params: NWParameters
        if tls {
            // По IP — имя сервера для SNI и проверки сертификата передаём сами.
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
            params = NWParameters(tls: options)
        } else {
            params = .tcp
        }
        if let interface { params.requiredInterface = interface }
        params.preferNoProxies = true

        let conn = NWConnection(host: target, port: port, using: params)
        let start = Date()
        var done = false
        var buffer = Data()

        func finish(_ ok: Bool, _ body: String) {
            guard !done else { return }
            done = true
            conn.cancel()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            completion(ProbeResult(interface: interfaceName, ok: ok, body: body, millis: ms))
        }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if isComplete || error != nil {
                    let text = String(decoding: buffer, as: UTF8.self)
                    let parts = text.components(separatedBy: "\r\n\r\n")
                    let status = parts.first?.components(separatedBy: "\r\n").first ?? ""
                    let body = parts.dropFirst().joined(separator: "\r\n\r\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if status.contains(" 200 ") {
                        finish(true, String(body.prefix(2000)))
                    } else if !buffer.isEmpty {
                        finish(false, status.isEmpty ? String(text.prefix(200)) : status)
                    } else {
                        finish(false, error.map { "\($0)" } ?? "empty response")
                    }
                    return
                }
                receive()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let path = u.path.isEmpty ? "/" : u.path
                let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: curl/8.7.1\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { error in
                    if let error { finish(false, "\(error)") } else { receive() }
                })
            case .waiting(let error):
                // Как в relay: «waiting» часто мгновенное, до выбора пути — ждём, прежде чем считать провалом.
                waitThenFail(conn, error, queue: queue, finish: finish)
            case .failed(let error):
                finish(false, "\(error)")
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false, "timeout \(Int(timeout))s") }
    }

    /// Соединение всё ещё ждёт через `waitingTimeout` — провал с ошибкой ожидания.
    private static func waitThenFail(_ conn: NWConnection, _ error: NWError, queue: DispatchQueue,
                                     finish: @escaping (Bool, String) -> Void) {
        queue.asyncAfter(deadline: .now() + waitingTimeout) {
            if case .waiting = conn.state { finish(false, "\(error)") }
        }
    }

    /// Как у relay в расширении (`TCPRelay.waitingTimeout`).
    static let waitingTimeout: TimeInterval = 5

    /// STUN Binding Request (RFC 5389) через интерфейс; в `body` — внешний IPv4 из XOR-MAPPED-ADDRESS.
    static func stun(server: String, interface: NWInterface?, interfaceName: String,
                     timeout: TimeInterval = 5, completion: @escaping (ProbeResult) -> Void) {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            completion(ProbeResult(interface: interfaceName, ok: false, body: "bad server", millis: 0))
            return
        }
        let queue = DispatchQueue(label: "dev.splitpipe.stun")
        queue.async {
            // Имя резолвим системным резолвером: у utun VPN без Network Extension нет своего DNS,
            // и резолв с привязкой к интерфейсу даёт «Network is down».
            guard let address = resolveIPv4(String(parts[0])) else {
                completion(ProbeResult(interface: interfaceName, ok: false, body: "dns failed", millis: 0))
                return
            }
            stun(address: address, port: port, interface: interface, interfaceName: interfaceName,
                 queue: queue, timeout: timeout, completion: completion)
        }
    }

    private static func resolveIPv4(_ host: String) -> IPv4Address? {
        if let literal = IPv4Address(host) { return literal }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            withUnsafeBytes(of: $0.pointee.sin_addr) { IPv4Address(Data($0)) }
        }
    }

    private static func stun(address: IPv4Address, port: NWEndpoint.Port, interface: NWInterface?, interfaceName: String,
                             queue: DispatchQueue, timeout: TimeInterval, completion: @escaping (ProbeResult) -> Void) {
        let params = NWParameters.udp
        if let interface { params.requiredInterface = interface }
        params.preferNoProxies = true
        let conn = NWConnection(host: .ipv4(address), port: port, using: params)
        var transaction = [UInt8](repeating: 0, count: 12)
        arc4random_buf(&transaction, transaction.count)
        let start = Date()
        var done = false

        func finish(_ ok: Bool, _ body: String) {
            guard !done else { return }
            done = true
            conn.cancel()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            completion(ProbeResult(interface: interfaceName, ok: ok, body: body, millis: ms))
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Binding Request, длина 0, magic cookie, transaction id.
                let request = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + transaction)
                conn.send(content: request, completion: .contentProcessed { error in
                    if let error { finish(false, "\(error)") }
                })
                conn.receiveMessage { data, _, _, error in
                    if let data, let ip = parseSTUN([UInt8](data), transaction: transaction) {
                        finish(true, ip)
                    } else {
                        finish(false, error.map { "\($0)" } ?? "bad stun response")
                    }
                }
            case .waiting(let error):
                waitThenFail(conn, error, queue: queue, finish: finish)
            case .failed(let error):
                finish(false, "\(error)")
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false, "timeout \(Int(timeout))s") }
    }

    static func parseSTUN(_ d: [UInt8], transaction: [UInt8]) -> String? {
        guard d.count >= 20, d[0] == 0x01, d[1] == 0x01, Array(d[8..<20]) == transaction else { return nil }
        let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
        var i = 20
        while i + 4 <= d.count {
            let type = UInt16(d[i]) << 8 | UInt16(d[i + 1])
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            let value = i + 4
            guard value + length <= d.count else { break }
            // XOR-MAPPED-ADDRESS (0x0020) или старый MAPPED-ADDRESS (0x0001), семейство IPv4.
            if type == 0x0020 || type == 0x0001, length >= 8, d[value + 1] == 0x01 {
                var a = Array(d[value + 4 ..< value + 8])
                if type == 0x0020 { a = zip(a, cookie).map { $0 ^ $1 } }
                return a.map(String.init).joined(separator: ".")
            }
            i = value + ((length + 3) & ~3)
        }
        return nil
    }
}

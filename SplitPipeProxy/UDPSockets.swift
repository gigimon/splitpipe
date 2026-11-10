import Darwin
import Foundation
import Network

/// Адрес UDP как `sockaddr_in` / `sockaddr_in6` — и для `sendto`, и ключом: от кого пришёл ответ.
struct UDPAddress: Hashable {
    private(set) var bytes: [UInt8]

    var isIPv6: Bool { bytes[1] == UInt8(AF_INET6) }

    init(v4 address: [UInt8], port: UInt16) {
        bytes = [UInt8(MemoryLayout<sockaddr_in>.size), UInt8(AF_INET), UInt8(port >> 8), UInt8(port & 0xff)]
            + address.prefix(4) + [UInt8](repeating: 0, count: 8)
    }

    init(v6 address: [UInt8], port: UInt16, scope: UInt32 = 0) {
        bytes = [UInt8(MemoryLayout<sockaddr_in6>.size), UInt8(AF_INET6), UInt8(port >> 8), UInt8(port & 0xff)]
            + [0, 0, 0, 0] + address.prefix(16) + withUnsafeBytes(of: scope) { Array($0) }
    }

    /// Адрес из endpoint; nil — имя (его сначала резолвят) или не `hostPort`.
    init?(_ endpoint: Network.NWEndpoint) {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): self.init(v4: [UInt8](a.rawValue), port: port.rawValue)
        case .ipv6(let a): self.init(v6: [UInt8](a.rawValue), port: port.rawValue, scope: UInt32(a.interface?.index ?? 0))
        default: return nil
        }
    }

    /// Из `recvfrom` / `getaddrinfo`: собирается заново, чтобы ключ не зависел от мусора в незначащих полях.
    init?(_ sa: UnsafePointer<sockaddr>, port override: UInt16? = nil) {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let sin = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in.self)
            self.init(v4: withUnsafeBytes(of: sin.sin_addr) { Array($0) }, port: override ?? UInt16(bigEndian: sin.sin_port))
        case AF_INET6:
            let sin6 = UnsafeRawPointer(sa).loadUnaligned(as: sockaddr_in6.self)
            self.init(v6: withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }, port: override ?? UInt16(bigEndian: sin6.sin6_port),
                      scope: sin6.sin6_scope_id)
        default:
            return nil
        }
    }

    var port: UInt16 { UInt16(bytes[2]) << 8 | UInt16(bytes[3]) }

    var endpoint: Network.NWEndpoint {
        let p = Network.NWEndpoint.Port(rawValue: port) ?? .any
        if isIPv6, let a = IPv6Address(Data(bytes[8..<24])) { return .hostPort(host: .ipv6(a), port: p) }
        if let a = IPv4Address(Data(bytes[4..<8])) { return .hostPort(host: .ipv4(a), port: p) }
        return .hostPort(host: .ipv4(.any), port: p)
    }
}

/// Сокеты UDP одного flow приложения. Сокет приложения один и шлёт на разные адреса с одного порта — так же должны
/// выглядеть и наши пакеты: по `NWConnection` на адрес давало каждому адресу свой порт (STUN видел один, собеседник —
/// другой: прямые соединения звонков, WebRTC и торрентов не устанавливались), а датаграммы от адреса, на который
/// ещё не слали, не принимались вовсе. Сокетов не больше четырёх: IPv4 и IPv6, с привязкой к интерфейсу и без неё
/// (DNS и локальные адреса идут по системному маршруту). Все вызовы — на `queue`.
final class UDPSockets {
    private struct Key: Hashable {
        var ipv6: Bool
        var bound: Bool
    }

    private struct Socket {
        var fd: Int32
        var source: DispatchSourceRead
    }

    /// Сколько датаграмм читать за одно пробуждение: остальные — на следующем, очередь relay не занята одним сокетом.
    private static let batch = 64

    private let interfaceIndex: UInt32?
    private let queue: DispatchQueue
    private let onReceive: ([(Data, UDPAddress)]) -> Void
    private var sockets: [Key: Socket] = [:]
    private var buffer = [UInt8](repeating: 0, count: 65535)
    private var closed = false

    /// `interfaceIndex` — интерфейс маршрута; nil — всё по системному маршруту.
    init(interfaceIndex: UInt32?, queue: DispatchQueue, onReceive: @escaping ([(Data, UDPAddress)]) -> Void) {
        self.interfaceIndex = interfaceIndex
        self.queue = queue
        self.onReceive = onReceive
    }

    /// Отправляет датаграмму; `bound: false` — мимо интерфейса маршрута. nil — ушла, иначе `errno`.
    func send(_ data: Data, to address: UDPAddress, bound: Bool) -> Int32? {
        guard !closed else { return ECANCELED }
        let key = Key(ipv6: address.isIPv6, bound: bound && interfaceIndex != nil)
        let fd: Int32
        if let s = sockets[key] {
            fd = s.fd
        } else {
            switch open(key) {
            case .success(let s): fd = s
            case .failure(let e): return e.code.rawValue
            }
        }
        let sent = data.withUnsafeBytes { payload in
            address.bytes.withUnsafeBytes { sa in
                sendto(fd, payload.baseAddress, payload.count, 0, sa.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                       socklen_t(sa.count))
            }
        }
        return sent >= 0 ? nil : errno
    }

    /// Локальный порт сокета — для тестов и диагностики.
    func localPort(ipv6: Bool, bound: Bool) -> UInt16? {
        guard let s = sockets[Key(ipv6: ipv6, bound: bound && interfaceIndex != nil)] else { return nil }
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s.fd, $0, &len) == 0 }
        }
        guard ok else { return nil }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UDPAddress($0)?.port } }
    }

    func close() {
        closed = true
        sockets.values.forEach { $0.source.cancel() }
        sockets.removeAll()
    }

    private func open(_ key: Key) -> Result<Int32, POSIXError> {
        let fd = socket(key.ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if key.bound, var index = interfaceIndex {
            let r = key.ipv6
                ? setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
                : setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            // Без привязки пакет ушёл бы по системному маршруту — мимо маршрута правила.
            guard r == 0 else {
                let e = errno
                Darwin.close(fd)
                return .failure(POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO))
            }
        }
        if key.ipv6 {
            var on: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        sockets[key] = Socket(fd: fd, source: source)
        return .success(fd)
    }

    private func drain(_ fd: Int32) {
        guard !closed else { return }
        var received: [(Data, UDPAddress)] = []
        for _ in 0..<Self.batch {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, 0, sa, &len) }
                }
            }
            // Ошибка сокета (ICMP unreachable от прошлой отправки) — не конец: читаем дальше на следующем пробуждении.
            guard n >= 0 else { break }
            let from = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { UDPAddress($0) } }
            if let from { received.append((Data(buffer[0..<n]), from)) }
        }
        if !received.isEmpty { onReceive(received) }
    }
}

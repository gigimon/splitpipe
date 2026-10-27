import Darwin
import Foundation

/// События таблицы маршрутов и адресов интерфейсов из routing socket (`PF_ROUTE`) — вместо частого опроса.
/// В песочнице сокет может быть недоступен: тогда `start` возвращает false и остаётся опрос.
final class RouteMonitor {
    /// Изменение маршрута, важного для SplitPipe и VPN: `default`, `0/1`, `128.0/1` и host-маршруты через шлюз
    /// (так VPN выводит свой сервер мимо туннеля).
    struct Change: CustomStringConvertible {
        var type: Int32
        /// Кто поменял маршрут: `route`, VPN-клиент, configd; 0 — ядро (сброс маршрутов интерфейса).
        var pid: pid_t
        var route: IPv4Route

        /// Маршрут на всё пространство: по нему решается, куда идёт трафик без привязки к интерфейсу.
        var isDefault: Bool { route.prefix <= 1 }

        var description: String {
            let action = switch type {
            case RTM_ADD: "add"
            case RTM_DELETE: "delete"
            case RTM_CHANGE: "change"
            default: "type \(type)"
            }
            return "\(action) \(route.cidr) via \(route.gateway ?? "link") \(route.interface)"
                + (route.scoped ? " ifscope" : "") + " pid=\(pid) (\(RouteMonitor.processName(pid)))"
        }
    }

    /// Состояние интерфейса из `RTM_IFINFO`.
    struct Link {
        var interface: String
        /// `IFF_UP | IFF_RUNNING`: линк есть. При роуминге Wi-Fi между точками линк на мгновение пропадает.
        var up: Bool
        /// Интерфейс удалён (VPN-клиент пересоздаёт utun при перезапуске): имя — последнее известное по индексу.
        var detached: Bool
    }

    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 8192)
    /// Имя по индексу из прошлых сообщений: у удалённого интерфейса `if_indextoname` уже ничего не вернёт.
    private var names: [UInt32: String] = [:]
    /// Вызывается на очереди монитора: `change` — важный маршрут, nil — поменялись адреса или состояние интерфейсов.
    var onEvent: ((Change?) -> Void)?
    /// Интерфейсу назначен IPv4-адрес (`RTM_NEWADDR`), в том числе прежний: после сна и при роуминге Wi-Fi DHCP
    /// ставит тот же адрес заново, а маршруты, созданные до этого, держат старый. Вызывается до `onEvent(nil)`.
    var onAddress: ((String) -> Void)?
    /// У интерфейса сменились флаги линка или он удалён (`RTM_IFINFO`), либо с него снят IPv4-адрес
    /// (`RTM_DELADDR`, `up == false`). Вызывается до `onEvent(nil)`.
    var onLink: ((Link) -> Void)?

    func start(queue: DispatchQueue) -> Bool {
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard fd >= 0 else { return false }
        // Имена всех интерфейсов заранее: об удалённом utun сообщение разбирается, когда его уже нет.
        if let list = if_nameindex() {
            var p = list
            while p.pointee.if_index != 0 {
                names[p.pointee.if_index] = String(cString: p.pointee.if_name)
                p += 1
            }
            if_freenameindex(list)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        // При роуминге Wi-Fi и переподключении VPN события идут пачками: буфер по умолчанию переполняется (`ENOBUFS`).
        var size: Int32 = 256 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain(_ fd: Int32) {
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == ENOBUFS {
                // Ядро выбросило часть событий: какие — не узнать, поэтому «что-то поменялось» — пусть сверятся сейчас,
                // а не по таймеру через 15–30 с.
                onEvent?(nil)
                continue
            }
            guard n > 4 else { return }
            switch buffer.withUnsafeBytes({ parse(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) {
            case .route(let change): onEvent?(change)
            case .address(let interface): onAddress?(interface); onEvent?(nil)
            case .link(let link): onLink?(link); onEvent?(nil)
            case .interfaces: onEvent?(nil)
            case .ignored: break
            }
        }
    }

    /// Разобранное сообщение; не `private` — для тестов (`RouteMonitorTests`).
    enum Parsed { case route(Change), address(String), link(Link), interfaces, ignored }

    /// Неважно: клонированные маршруты, ARP, ответы на `route get`, неудачные запросы.
    func parse(_ raw: UnsafeRawBufferPointer) -> Parsed {
        switch Int32(raw[3]) {
        case RTM_NEWADDR:
            return Self.ipv4Address(raw, names: names).map { remember($0.index, $0.name); return .address($0.name) } ?? .interfaces
        case RTM_DELADDR:
            guard let a = Self.ipv4Address(raw, names: names) else { return .interfaces }
            return .link(Link(interface: a.name, up: false, detached: false))
        case RTM_IFINFO:
            guard raw.count >= MemoryLayout<if_msghdr>.size else { return .interfaces }
            let h = raw.loadUnaligned(as: if_msghdr.self)
            let index = UInt32(h.ifm_index)
            var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(index, &buf) != nil {
                let name = String(cString: buf)
                remember(index, name)
                let up = h.ifm_flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
                return .link(Link(interface: name, up: up, detached: false))
            }
            guard let name = names.removeValue(forKey: index) else { return .interfaces }
            return .link(Link(interface: name, up: false, detached: true))
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            guard let m = RouteMessage(raw), m.rtmErrno == 0, let route = m.ipv4Route,
                  m.flags & (RTF_WASCLONED | RTF_LLINFO) == 0 else { return .ignored }
            let viaGateway = route.prefix == 32 && m.flags & RTF_GATEWAY != 0 && m.flags & RTF_STATIC != 0
            guard route.prefix <= 1 || viaGateway else { return .ignored }
            return .route(Change(type: m.type, pid: m.pid, route: route))
        default:
            return .ignored
        }
    }

    private func remember(_ index: UInt32, _ name: String) {
        names[index] = name
    }

    /// Интерфейс из `RTM_NEWADDR` / `RTM_DELADDR`, если адрес IPv4 (`RTA_IFA`); IPv6 (временные адреса) не нужен.
    /// Для уже удалённого интерфейса имя — из `names`.
    private static func ipv4Address(_ raw: UnsafeRawBufferPointer, names: [UInt32: String]) -> (index: UInt32, name: String)? {
        let header = MemoryLayout<ifa_msghdr>.size
        guard raw.count >= header else { return nil }
        let h = raw.loadUnaligned(as: ifa_msghdr.self)
        let size = min(Int(h.ifam_msglen), raw.count)
        var p = header
        for i in 0..<Int(RTAX_MAX) where h.ifam_addrs & (1 << i) != 0 {
            guard p + 2 <= size else { return nil }
            let saLen = Int(raw[p])
            if i == Int(RTAX_IFA) {
                guard raw[p + 1] == UInt8(AF_INET) else { return nil }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                let index = UInt32(h.ifam_index)
                if if_indextoname(index, &name) != nil { return (index, String(cString: name)) }
                return names[index].map { (index, $0) }
            }
            p += saLen > 0 ? 1 + ((saLen - 1) | 3) : 4
        }
        return nil
    }

    static func processName(_ pid: pid_t) -> String {
        guard pid > 0 else { return "kernel" }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : "?"
    }
}

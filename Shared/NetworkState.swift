import Darwin
import Foundation
import SystemConfiguration

/// Идентификаторы маршрутов в правилах. VPN хранится по ключу, а не по имени интерфейса: `utunN` меняется после переподключения.
enum RouteID {
    static let system = "default"
    static let direct = "direct"
    static let block = "block"
    static func vpn(_ key: String) -> String { "vpn:" + key }

    static func vpnKey(_ id: String) -> String? { id.hasPrefix("vpn:") ? String(id.dropFirst(4)) : nil }

    static func defaultName(forVPN key: String) -> String { VPNCatalog.name(forKey: key) }
}

/// Что делать, если выбранный маршрут недоступен: `block`, `default` или `alt:<route id>`.
enum Fallback {
    static let block = "block"
    static let system = "default"
    static func alt(_ route: String) -> String { "alt:" + route }

    static func altRoute(_ fallback: String) -> String? {
        fallback.hasPrefix("alt:") ? String(fallback.dropFirst(4)) : nil
    }
}

struct AppRule: Codable, Hashable {
    var route: String
    var fallback: String
}

/// Scoped-маршрут `0/1` или `128.0/1` через физический интерфейс. Вместе они дают привязке к интерфейсу то же,
/// что scoped `default`, но для мониторов «шлюза по умолчанию» (configd, VPN-клиенты) маршрутом по умолчанию не выглядят.
struct SplitRoute: Codable, Hashable {
    var interface: String
    /// `128.0/1`, иначе `0/1`.
    var upper: Bool
    /// Поставлен помощником (помечен `RTF_PROTO2`): только такие он и снимает.
    var ours: Bool
    /// Шлюз маршрута: сменился роутер при том же адресе — маршрут надо пересоздать (REVIEW3, 4.7).
    var gateway: String? = nil

    var destination: String { upper ? "128.0.0.0/1" : "0.0.0.0/1" }
}

/// Состояние сети, по которому роли маршрутов превращаются в интерфейсы. Его одинаково считают приложение
/// и расширение (в песочнице, поэтому без `route` и `ps`: таблица маршрутов и процессы читаются через sysctl).
struct NetworkState: Codable, Hashable {
    /// Поднятые интерфейсы с IPv4, кроме loopback → адрес.
    var addresses: [String: String] = [:]
    /// Основной физический интерфейс — «Напрямую».
    var physical: String?
    /// Шлюз маршрута по умолчанию физического интерфейса: через него помощник ставит scoped-маршруты.
    var physicalGateway: String?
    /// Интерфейс, через который система отправит трафик в интернет: utun, если VPN держит `0/1` + `128.0/1`.
    var defaultInterface: String?
    /// Есть ли у физического интерфейса scoped `default` (configd ставит его, когда интерфейс не основной).
    var scopedDefault = false
    /// Scoped `0/1` и `128.0/1` через физические интерфейсы.
    var splitRoutes: [SplitRoute] = []
    /// Интерфейсы, через которые IPv6 выходит в интернет: маршрут `::/0` (`::/1` + `8000::/1`, `2000::/3`) и глобальный адрес.
    /// Без него IPv6 не выйти — такие соединения расширение отклоняет сразу, и приложение уходит на IPv4, а не ждёт таймаута.
    var ipv6Interfaces: Set<String> = []
    /// utun → VPN-клиент (`VPNDetection`). utun без записи — неизвестный VPN, его ключ — имя интерфейса.
    var vpns: [String: VPNInfo] = [:]
    /// Виден ли список процессов: без него VPN без Network Extension не опознать.
    var processesVisible = true
    /// Индексы интерфейсов (`if_nametoindex`) на момент снимка: utun, пересозданный под тем же именем, — уже другой
    /// интерфейс, и привязка соединений к нему — по индексу (REVIEW3, 4.8). nil — снимок от расширения старой версии.
    var indexes: [String: UInt32]?
    /// Откуда взят `physical` (`primary`, `default`, `scoped default`) или почему его нет — для журнала (REVIEW3, 4.1).
    var physicalVia: String?

    var tunnels: [String] { addresses.keys.filter(Self.isTunnel).sorted() }

    static func isTunnel(_ name: String) -> Bool { name.hasPrefix("utun") }

    /// VPN держит маршрут по умолчанию: без scoped-маршрута привязка к физическому интерфейсу даёт `Network is down`.
    var vpnHoldsDefault: Bool { defaultInterface.map(Self.isTunnel) ?? false }

    /// Есть ли у физического интерфейса свой (scoped) маршрут в интернет: `default` или пара `0/1` + `128.0/1`.
    var physicalScoped: Bool {
        guard let physical else { return false }
        return scopedDefault || Set(splitRoutes.filter { $0.interface == physical }.map(\.upper)).count == 2
    }

    func vpnKey(forTunnel name: String) -> String { vpns[name]?.key ?? name }

    /// Индекс интерфейса из снимка; нет в снимке — из ядра сейчас.
    func index(of name: String) -> UInt32 { indexes?[name] ?? if_nametoindex(name) }

    /// Идентичность интерфейса для привязки соединений: `utun4#12`.
    func binding(_ name: String) -> String { "\(name)#\(index(of: name))" }

    /// Имя VPN: у подключённого — из обнаружения, у отключённого — по ключу.
    func vpnName(forKey key: String) -> String {
        vpns.values.first { $0.key == key }?.name ?? VPNCatalog.name(forKey: key)
    }

    /// Интерфейс маршрута (`direct`, `vpn:<key>`); nil — маршрут сейчас недоступен или это не маршрут через интерфейс.
    func interface(forRoute id: String) -> String? {
        if id == RouteID.direct { return physical }
        guard let key = RouteID.vpnKey(id) else { return nil }
        return tunnels.first { vpnKey(forTunnel: $0) == key }
    }

    /// Как сейчас работает «Напрямую»: через интерфейс, по системному маршруту (VPN не держит маршрут по умолчанию,
    /// а scoped-маршрута нет) или никак.
    enum DirectMode { case bound, system, unavailable }

    var directMode: DirectMode {
        guard let physical else { return .unavailable }
        if physicalScoped { return .bound }
        return defaultInterface == physical ? .system : .unavailable
    }

    /// Маршрут, через который идёт трафик без привязки к интерфейсу.
    var defaultRoute: String? {
        guard let d = defaultInterface else { return physical.map { _ in RouteID.direct } }
        if Self.isTunnel(d), addresses[d] != nil { return RouteID.vpn(vpnKey(forTunnel: d)) }
        return physical == nil ? nil : RouteID.direct
    }

    /// Для логов: `direct=en1 default=utun4 vpn=[utun4:amnezia(socket)]`.
    var summary: String {
        let list = tunnels.map { "\($0):\(vpnKey(forTunnel: $0))(\(vpns[$0]?.source.rawValue ?? "?"))" }.joined(separator: ",")
        let scoped = physicalScoped ? (scopedDefault ? "" : "(split)") : "(no-scoped)"
        return "direct=\(physical ?? "-")\(scoped)[\(physicalVia ?? "?")] ipv6=[\(ipv6Interfaces.sorted().joined(separator: ","))] default=\(defaultInterface ?? "-") vpn=[\(list)]" + (processesVisible ? "" : " no-processes")
    }

    static func current(detectVPNs: Bool = true) -> NetworkState {
        read(detectVPNs: detectVPNs) ?? build(routes: [], detectVPNs: detectVPNs)
    }

    /// Снимок сети; nil — таблицу маршрутов прочитать не удалось даже после повторов. Это не «сети нет»: такой
    /// снимок увёл бы VPN-правила в fallback и оборвал бы все VPN-соединения (REVIEW3, 4.6) — держим прежний.
    /// `detectVPNs: false` — без опознания VPN-клиентов (обход процессов): помощнику при выключенном SplitPipe
    /// нужны только маршруты.
    static func read(detectVPNs: Bool = true) -> NetworkState? {
        routeMessages(family: AF_INET).map { build(routes: $0.compactMap(\.ipv4Route), detectVPNs: detectVPNs) }
    }

    private static func build(routes: [IPv4Route], detectVPNs: Bool) -> NetworkState {
        var state = NetworkState()
        state.addresses = ipv4Addresses()
        state.indexes = Dictionary(state.addresses.keys.map { ($0, if_nametoindex($0)) }, uniquingKeysWith: { a, _ in a })
        let defaults = routes.filter { $0.prefix == 0 && !isTunnel($0.interface) && state.addresses[$0.interface] != nil }
        // Основной интерфейс из настроек сети (то же, что `scutil --nwi`). Если основной сейчас VPN-служба или
        // настройки не читаются — интерфейс с маршрутом по умолчанию: сначала обычным, потом scoped. Любой `enN`
        // с адресом не годится: во время переподключения Wi-Fi это может оказаться мост или USB-адаптер с 169.254.
        let primary = primaryIPv4()
        if let p = primary, !isTunnel(p.interface), state.addresses[p.interface] != nil {
            state.physical = p.interface
            state.physicalVia = "primary"
        } else if let d = defaults.first(where: { !$0.scoped }) ?? defaults.first {
            state.physical = d.interface
            state.physicalVia = d.scoped ? "scoped default" : "default"
        } else {
            // Почему «Напрямую» пропал: основной интерфейс — туннель или без адреса, маршрута по умолчанию нет.
            let p = primary.map { isTunnel($0.interface) ? "primary \($0.interface) is tunnel" : "primary \($0.interface) has no address" }
                ?? "no primary"
            state.physicalVia = "none: \(p), no default route"
        }
        let own = defaults.filter { $0.interface == state.physical }
        state.physicalGateway = (own.first { !$0.scoped } ?? own.first)?.gateway
            ?? (primary?.interface == state.physical ? primary?.router : nil)
        state.scopedDefault = own.contains { $0.scoped }
        state.splitRoutes = routes.compactMap { r in
            guard r.scoped, r.prefix == 1, !isTunnel(r.interface) else { return nil }
            return SplitRoute(interface: r.interface, upper: r.destination >> 31 == 1, ours: r.flags & RTF_PROTO2 != 0,
                              gateway: r.gateway)
        }
        state.ipv6Interfaces = ipv6InternetInterfaces()
        // Только маршруты на всё пространство (`default`, `0/1`, `128.0/1`): host-маршрут до 1.1.1.1 (allowNets
        // kill switch, чей-то обход) не должен менять ответ.
        state.defaultInterface = routes
            .filter { !$0.scoped && $0.prefix <= 1 && $0.contains(0x0101_0101) }
            .max { $0.prefix < $1.prefix }?.interface
        guard detectVPNs else { return state }
        let processes = VPNDetection.processes()
        state.processesVisible = processes != nil
        state.vpns = VPNDetection.detect(tunnels: state.tunnels, defaultInterface: state.defaultInterface,
                                         processes: processes)
        return state
    }

    /// `State:/Network/Global/IPv4`: основной интерфейс и его шлюз; nil — настройки сети недоступны.
    private static func primaryIPv4() -> (interface: String, router: String?)? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = global["PrimaryInterface"] as? String else { return nil }
        return (iface, global["Router"] as? String)
    }

    // MARK: - sysctl

    private static func ipv4Addresses() -> [String: String] {
        var out: [String: String] = [:]
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return out }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            // `RUNNING` — есть линк: у Wi-Fi без ассоциации адрес может ещё висеть (REVIEW3, 4.1).
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            out[String(cString: ifa.ifa_name)] = String(cString: host)
        }
        return out
    }

    /// Интерфейсы с глобальным IPv6-адресом (`2000::/3`). У системных `utun0–3` только `fe80::` — им IPv6 в интернет не выйти.
    private static func globalIPv6Interfaces() -> Set<String> {
        var out: Set<String> = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return out }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let byte = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0 }
            if byte & 0xe0 == 0x20 { out.insert(String(cString: ifa.ifa_name)) }
        }
        return out
    }

    /// Интерфейсы с маршрутом IPv6 в интернет и глобальным адресом: маршрут с префиксом не длиннее 3, покрывающий
    /// `2001::` — `::/0`, `::/1`, `2000::/3` (так часто пишут в конфигах WireGuard), scoped или нет.
    private static func ipv6InternetInterfaces() -> Set<String> {
        let routed = Set((routeMessages(family: AF_INET6) ?? []).compactMap { m -> String? in
            guard m.flags & RTF_HOST == 0, let iface = m.interface,
                  let dst = m.addrs[Int(RTAX_DST)], dst.count >= 24, dst[1] == UInt8(AF_INET6) else { return nil }
            let prefix = m.addrs[Int(RTAX_NETMASK)]
                .map { $0.count > 8 ? $0[8..<min($0.count, 24)].reduce(0) { $0 + $1.nonzeroBitCount } : 0 }
                ?? (dst[8..<24].allSatisfy { $0 == 0 } ? 0 : 128)
            return prefix <= 3 && Self.covers2001(firstByte: dst[8], prefix: prefix) ? iface : nil
        })
        return routed.intersection(globalIPv6Interfaces())
    }

    /// Первые `prefix` бит (не больше 8) адреса назначения совпадают с `2001::` (`0x20` в первом байте).
    static func covers2001(firstByte: UInt8, prefix: Int) -> Bool {
        prefix == 0 || (firstByte ^ 0x20) >> (8 - min(prefix, 8)) == 0
    }

    /// Сообщения таблицы маршрутов (`NET_RT_DUMP`); nil — `sysctl` не сработал. Таблица может вырасти между
    /// запросом размера и чтением (`ENOMEM`) — тогда повторяем с бóльшим запасом.
    private static func routeMessages(family: Int32) -> [RouteMessage]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0]
        for attempt in 1...3 {
            var len = 0
            guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return nil }
            guard len > 0 else { return [] }
            len += len / 4 * attempt
            var buf = [UInt8](repeating: 0, count: len)
            if sysctl(&mib, 6, &buf, &len, nil, 0) == 0 { return parseRouteMessages(buf, len) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    private static func parseRouteMessages(_ buf: [UInt8], _ len: Int) -> [RouteMessage] {
        var out: [RouteMessage] = []
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<rt_msghdr>.size <= len {
                let size = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                guard size > 0, off + size <= len else { break }
                defer { off += size }
                guard let m = RouteMessage(UnsafeRawBufferPointer(rebasing: raw[off..<off + size])),
                      m.flags & RTF_UP != 0, m.interface != nil else { continue }
                out.append(m)
            }
        }
        return out
    }
}

/// Маршрут IPv4 из таблицы или из события routing socket.
struct IPv4Route: Hashable {
    var destination: UInt32
    var prefix: Int
    var interface: String
    /// `rtm_index`: интерфейс, пересозданный под тем же именем, — другой маршрут.
    var index: UInt32 = 0
    var scoped: Bool
    var flags: Int32
    /// Адрес шлюза; nil — маршрут на интерфейс (`link#N`, utun).
    var gateway: String?

    func contains(_ address: UInt32) -> Bool {
        prefix == 0 || (address ^ destination) >> (32 - prefix) == 0
    }

    /// `default`, `0.0.0.0/1`, `198.51.100.20/32`.
    var cidr: String {
        if prefix == 0 && destination == 0 { return "default" }
        let b = [24, 16, 8, 0].map { String(destination >> UInt32($0) & 0xff) }
        return b.joined(separator: ".") + "/\(prefix)"
    }
}

/// Сообщение о маршруте (`rt_msghdr` и адреса `RTAX_*` за ним) — из дампа таблицы или из routing socket.
struct RouteMessage {
    var type: Int32
    var flags: Int32
    /// Процесс, который поменял маршрут (в событиях routing socket); 0 — ядро.
    var pid: pid_t
    var rtmErrno: Int32
    var interface: String?
    var index: UInt32
    var addrs: [Int: [UInt8]]

    init?(_ raw: UnsafeRawBufferPointer) {
        let header = MemoryLayout<rt_msghdr>.size
        guard raw.count >= header else { return nil }
        let h = raw.loadUnaligned(as: rt_msghdr.self)
        let size = min(Int(h.rtm_msglen), raw.count)
        type = Int32(h.rtm_type)
        flags = h.rtm_flags
        pid = h.rtm_pid
        rtmErrno = h.rtm_errno
        index = UInt32(h.rtm_index)
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        interface = if_indextoname(UInt32(h.rtm_index), &name) != nil ? String(cString: name) : nil
        addrs = [:]
        var p = header
        for i in 0..<Int(RTAX_MAX) where h.rtm_addrs & (1 << i) != 0 {
            guard p + 2 <= size else { break }
            let saLen = Int(raw[p])
            addrs[i] = Array(raw[p..<min(p + saLen, size)])
            p += saLen > 0 ? 1 + ((saLen - 1) | 3) : 4
        }
    }

    var ipv4Route: IPv4Route? {
        guard let interface, let dst = addrs[Int(RTAX_DST)], dst.count >= 8, dst[1] == UInt8(AF_INET) else { return nil }
        let destination = dst[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // Маска хранится усечённой: байты после sa_len — нули.
        let mask = addrs[Int(RTAX_NETMASK)].map { $0.count > 4 ? Array($0[4..<min($0.count, 8)]) : [] }
        let prefix = mask.map { $0.reduce(0) { $0 + $1.nonzeroBitCount } } ?? (flags & RTF_HOST != 0 ? 32 : 0)
        var gateway: String?
        if let gw = addrs[Int(RTAX_GATEWAY)], gw.count >= 8, gw[1] == UInt8(AF_INET) {
            gateway = gw[4..<8].map(String.init).joined(separator: ".")
        }
        return IPv4Route(destination: destination, prefix: prefix, interface: interface, index: index,
                         scoped: flags & RTF_IFSCOPE != 0, flags: flags, gateway: gateway)
    }
}

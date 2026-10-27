import Darwin
import Foundation
import SystemConfiguration

/// Кто держит utun. Ключ стабилен между переподключениями (в отличие от `utunN`) и хранится в правилах как `vpn:<key>`.
struct VPNInfo: Codable, Hashable {
    enum Source: String, Codable {
        /// VPN на Network Extension: служба в настройках сети (Outline, WireGuard из App Store).
        case service
        /// Процесс, открывший управляющий сокет utun (нужен root — работает в расширении).
        case socket
        /// Единственный запущенный известный VPN-процесс без своего utun (так приложение узнаёт Amnezia без root).
        case process
    }

    var key: String
    var name: String
    /// Процесс или bundle id клиента — для подписи в карточке маршрута.
    var client: String
    var source: Source

    /// Подпись клиента в карточке маршрута: «Outline», «AmneziaVPN», «wireguard-go».
    var clientTitle: String {
        if source == .service { return VPNCatalog.services[client] ?? client }
        return client == "amneziawg-go" ? "AmneziaVPN" : client
    }
}

/// Опознаём только распространённые клиенты: Amnezia, WireGuard, OpenVPN, Outline. Остальные utun — просто VPN по имени
/// интерфейса: провайдерских приложений-надстроек слишком много, чтобы вести их список.
enum VPNCatalog {
    /// Клиенты без Network Extension: имя процесса → ключ и имя маршрута.
    private static let daemons: [String: (key: String, name: String)] = [
        "amneziawg-go": ("amnezia", "Amnezia VPN"),
        "wireguard-go": ("wireguard", "WireGuard"),
        "openvpn": ("openvpn", "OpenVPN"),
    ]
    /// Клиенты на Network Extension: bundle id → имя клиента. Ключ маршрута — по службе, их может быть несколько.
    static let services: [String: String] = [
        "org.outline.macos.client": "Outline",
        "com.wireguard.macos": "WireGuard",
        "net.openvpn.connect.app": "OpenVPN Connect",
    ]

    static func isKnownDaemon(_ process: String) -> Bool { daemons[process] != nil }

    /// Процесс VPN-клиента: демон из каталога, приложение и служба Amnezia, клиент на Network Extension.
    static func isClient(path: String, signingID: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return isKnownDaemon(name) || name.hasPrefix("AmneziaVPN") || services[signingID] != nil
            || signingID.localizedCaseInsensitiveContains("amnezia")
    }

    static func info(forProcess process: String, source: VPNInfo.Source) -> VPNInfo? {
        daemons[process].map { VPNInfo(key: $0.key, name: $0.name, client: process, source: source) }
    }

    static let servicePrefix = "ne:"

    /// Имя VPN по ключу, даже если он сейчас отключён: службу Network Extension — из настроек сети.
    static func name(forKey key: String) -> String {
        if key.hasPrefix(servicePrefix) {
            return serviceName(String(key.dropFirst(servicePrefix.count))) ?? "VPN"
        }
        if let d = daemons.values.first(where: { $0.key == key }) { return d.name }
        return "VPN \(key)"
    }

    static func serviceName(_ serviceID: String) -> String? {
        SCDynamicStoreCopyValue(nil, "Setup:/Network/Service/\(serviceID)" as CFString)
            .flatMap { ($0 as? [String: Any])?["UserDefinedName"] as? String }
    }
}

enum VPNDetection {
    /// utun → VPN. Сначала службы Network Extension, потом владелец управляющего сокета (root),
    /// потом единственный известный VPN-процесс. Остальные utun остаются по имени `utunN`.
    static func detect(tunnels: [String], defaultInterface: String?,
                       processes: [Int32: String]?) -> [String: VPNInfo] {
        var result = services(tunnels: Set(tunnels))
        var rest = tunnels.filter { result[$0] == nil }
        guard !rest.isEmpty, let processes else { return result }

        for (tunnel, pid) in SocketOwners.shared.owners(of: rest, processes: processes) {
            guard let name = processes[pid] else { continue }
            result[tunnel] = VPNCatalog.info(forProcess: name, source: .socket)
        }
        rest = rest.filter { result[$0] == nil }

        let assigned = Set(result.values.map(\.client))
        let daemons = Set(processes.values.filter { VPNCatalog.isKnownDaemon($0) && !assigned.contains($0) })
        guard daemons.count == 1, let daemon = daemons.first else { return result }
        // Без root владельца utun не видно: единственный запущенный известный клиент — у utun с маршрутом по умолчанию
        // или у единственного неопознанного utun.
        if let d = defaultInterface, rest.contains(d) {
            result[d] = VPNCatalog.info(forProcess: daemon, source: .process)
        } else if rest.count == 1 {
            result[rest[0]] = VPNCatalog.info(forProcess: daemon, source: .process)
        }
        return result
    }

    /// Службы VPN на Network Extension: `State:/Network/Service/<id>/IPv4` → `InterfaceName`.
    private static func services(tunnels: Set<String>) -> [String: VPNInfo] {
        guard !tunnels.isEmpty,
              let keys = SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [:] }
        var out: [String: VPNInfo] = [:]
        for key in keys {
            guard let ipv4 = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any],
                  let iface = ipv4["InterfaceName"] as? String, tunnels.contains(iface) else { continue }
            let id = key.components(separatedBy: "/")[3]
            let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Service/\(id)/Interface" as CFString) as? [String: Any]
            guard let client = setup?["SubType"] as? String, VPNCatalog.services[client] != nil else { continue }
            out[iface] = VPNInfo(key: VPNCatalog.servicePrefix + id,
                                 name: VPNCatalog.serviceName(id) ?? VPNCatalog.services[client]!, client: client, source: .service)
        }
        return out
    }

    /// Процессы (`KERN_PROC_ALL`): pid → имя; nil — если песочница прячет чужие процессы (нет даже launchd).
    static func processes() -> [Int32: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var len = 0
        guard sysctl(&mib, 4, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        len += len / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: len / stride)
        guard sysctl(&mib, 4, &procs, &len, nil, 0) == 0 else { return nil }
        var out: [Int32: String] = [:]
        for var p in procs.prefix(len / stride) {
            out[p.kp_proc.p_pid] = withUnsafeBytes(of: &p.kp_proc.p_comm) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return out.values.contains("launchd") ? out : nil
    }
}

/// Владельцы utun по управляющим сокетам `com.apple.net.utun_control` (unit = N + 1 для utunN).
/// Чужие сокеты видны только root, поэтому у приложения результат пустой. Обход всех процессов дорогой —
/// найденный владелец кешируется, пока его процесс жив, а неопознанный utun ищется снова не чаще раза в минуту
/// (у utun Tailscale или Outline без Network Extension владельца из каталога нет, и обход шёл бы каждые несколько секунд).
/// Кэш — по имени и индексу (`utun4#12`): utun, пересозданный другим клиентом под тем же именем, ищется заново.
final class SocketOwners: @unchecked Sendable {
    static let shared = SocketOwners()
    private let lock = NSLock()
    private var cache: [String: Int32] = [:]
    /// Когда utun без найденного владельца искали в последний раз.
    private var searched: [String: Date] = [:]

    private static func key(_ tunnel: String) -> String { "\(tunnel)#\(if_nametoindex(tunnel))" }
    private let retryInterval: TimeInterval = 60
    /// Видны ли файлы чужих процессов: проверяем по launchd (root). Нет — не обходим процессы зря.
    private lazy var allowed = utunUnits(1) != nil

    /// utun → pid владельца.
    func owners(of tunnels: [String], processes: [Int32: String]) -> [String: Int32] {
        lock.lock(); defer { lock.unlock() }
        guard allowed else { return [:] }
        let keys = Dictionary(tunnels.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        cache = cache.filter { keys[$0.key] != nil && processes[$0.value] != nil }
        searched = searched.filter { keys[$0.key] != nil && cache[$0.key] == nil }
        let now = Date()
        let missing = Set(keys.keys.filter { cache[$0] == nil && searched[$0].map { now.timeIntervalSince($0) > retryInterval } ?? true })
        if !missing.isEmpty {
            let byName = Dictionary(missing.map { (keys[$0]!, $0) }, uniquingKeysWith: { a, _ in a })
            for pid in processes.keys where pid > 1 && pid != getpid() {
                for unit in utunUnits(pid) ?? [] {
                    if let key = byName["utun\(unit - 1)"] { cache[key] = pid }
                }
            }
            for key in missing where cache[key] == nil { searched[key] = now }
        }
        return Dictionary(cache.compactMap { k, pid in keys[k].map { ($0, pid) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Номера unit управляющих сокетов utun процесса; nil — нет доступа к его файлам.
    private func utunUnits(_ pid: Int32) -> [UInt32]? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard read > 0 else { return nil }
        var units: [UInt32] = []
        for fd in fds.prefix(Int(read) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                  info.psi.soi_kind == SOCKINFO_KERN_CTL else { continue }
            var ctl = info.psi.soi_proto.pri_kern_ctl
            let name = withUnsafeBytes(of: &ctl.kcsi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "com.apple.net.utun_control" { units.append(ctl.kcsi_unit) }
        }
        return units
    }
}

import Foundation
import SystemConfiguration

struct InterfaceInfo: Identifiable, Hashable {
    var name: String
    var address: String
    var label: String
    var id: String { name }
    var isTunnel: Bool { name.hasPrefix("utun") }
    var title: String { "\(name) — \(label) \(address)" }
}

enum SystemTools {
    /// Поднятые интерфейсы с IPv4, без loopback.
    static func interfaces() -> [InterfaceInfo] {
        var labels: [String: String] = [:]
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                labels[bsd] = name
            }
        }
        var result: [InterfaceInfo] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let label = labels[name] ?? (name.hasPrefix("utun") ? "VPN" : name)
            result.append(InterfaceInfo(name: name, address: String(cString: host), label: label))
        }
        return result.sorted { ($0.isTunnel ? 1 : 0, $0.name) < ($1.isTunnel ? 1 : 0, $1.name) }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "\(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func dnsServers() -> [String] {
        let out = run("/usr/sbin/scutil", ["--dns"])
        var seen = Set<String>()
        return out.components(separatedBy: "\n")
            .filter { $0.contains("nameserver[") }
            .compactMap { $0.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert($0).inserted }
    }

}

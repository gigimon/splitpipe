import Darwin
import Foundation

/// Снятие scoped-маршрута запросом в routing socket (`PF_ROUTE`), без запуска `/sbin/route`: fork и exec на
/// просыпающейся системе занимают сотни миллисекунд (2026-11-09 21:43:23 — 255 мс на два маршрута), а VPN-клиент
/// снимает и возвращает свои маршруты быстрее. Запись в сокет — это сам системный вызов: ошибка ядра (`ESRCH` —
/// маршрута нет, `EPERM`) возвращается из `write`.
enum RouteSocket {
    /// `rt_msghdr` и адреса: назначение и маска. Не `private` — для тестов и проверки запросом `RTM_GET`.
    static func message(type: Int32, destination: UInt32, prefix: Int, ifIndex: UInt32, seq: Int32 = 1) -> [UInt8] {
        func sockaddr(_ value: UInt32) -> [UInt8] {
            [UInt8(MemoryLayout<sockaddr_in>.size), UInt8(AF_INET), 0, 0,
             UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
                + [UInt8](repeating: 0, count: 8)
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        let body = sockaddr(destination) + sockaddr(mask)
        var h = rt_msghdr()
        h.rtm_version = UInt8(RTM_VERSION)
        h.rtm_type = UInt8(type)
        h.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE
        h.rtm_index = UInt16(ifIndex)
        h.rtm_addrs = RTA_DST | RTA_NETMASK
        h.rtm_seq = seq
        h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        return withUnsafeBytes(of: h) { Array($0) } + body
    }

    /// Снимает scoped-маршрут `destination/prefix` интерфейса. nil — снят; иначе `errno` (`ESRCH` — его и не было).
    static func deleteScoped(destination: UInt32, prefix: Int, interface: String) -> Int32? {
        let index = if_nametoindex(interface)
        guard index != 0 else { return ENXIO }
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_INET)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        let bytes = message(type: RTM_DELETE, destination: destination, prefix: prefix, ifIndex: index)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count ? nil : errno
    }
}

/// Счётчики пакетов интерфейса (`if_data` из `getifaddrs`): по ним видно, идёт ли трафик через туннель VPN.
struct InterfaceCounters: Equatable {
    /// Пакеты, пришедшие из туннеля (у WireGuard — расшифрованные ответы сервера), и ушедшие в него.
    var inPackets: UInt32
    var outPackets: UInt32

    static func read(_ interface: String) -> InterfaceCounters? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data,
                  String(cString: ifa.ifa_name) == interface else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return InterfaceCounters(inPackets: d.ifi_ipackets, outPackets: d.ifi_opackets)
        }
        return nil
    }
}

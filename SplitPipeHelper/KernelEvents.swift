import Darwin
import Foundation

/// События ядра о линке и Wi-Fi из kernel event socket (`PF_SYSTEM`/`SYSPROTO_EVENT`) — тот же источник, что у
/// configd («link status active») и airportd («BSSID_CHANGED»). Routing socket для этого не годится: при роуминге
/// между точками Wi-Fi драйвер шлёт только `LINK_ON` без `LINK_OFF`, флаги `IFF_UP|IFF_RUNNING` и
/// `State:/Network/Interface/en1/Link` не меняются (2026-10-22 18:10), а `RTM_IFINFO` об удалённом utun приходит,
/// когда имени по индексу уже нет.
final class KernelEventMonitor {
    enum Kind: CustomStringConvertible {
        case linkOff, linkOn, detaching, detached
        /// 802.11: смена точки доступа и смена состояния линка Wi-Fi.
        case bssidChanged, wifiLinkChanged

        var description: String {
            switch self {
            case .linkOff: "линк пропал"
            case .linkOn: "линк вернулся"
            case .detaching, .detached: "удалён"
            case .bssidChanged: "сменилась точка Wi-Fi"
            case .wifiLinkChanged: "линк Wi-Fi сменился"
            }
        }
    }

    struct Event {
        var kind: Kind
        var interface: String
    }

    private static let vendorApple: UInt32 = 1       // KEV_VENDOR_APPLE
    private static let networkClass: UInt32 = 1      // KEV_NETWORK_CLASS
    private static let dlSubclass: UInt32 = 2        // KEV_DL_SUBCLASS
    private static let ieee80211Class: UInt32 = 6    // KEV_IEEE80211_CLASS
    /// `_IOW('e', 2, struct kev_request)`: макрос в Swift не импортируется.
    private static let setFilter: UInt = 0x800C_6502

    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 4096)
    /// Вызывается на очереди монитора.
    var onEvent: ((Event) -> Void)?

    func start(queue: DispatchQueue) -> Bool {
        let fd = socket(PF_SYSTEM, SOCK_RAW, SYSPROTO_EVENT)
        guard fd >= 0 else { return false }
        // Фильтр у сокета один: берём все классы Apple и отбираем нужные сами — событий немного.
        var request = kev_request(vendor_code: Self.vendorApple, kev_class: 0, kev_subclass: 0)
        guard ioctl(fd, Self.setFilter, &request) == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
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
            guard n > 0 else { return }
            if let event = buffer.withUnsafeBytes({ Self.parse(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) {
                onEvent?(event)
            }
        }
    }

    /// `kern_event_msg`: 6 × u32 заголовка, затем `net_event_data` (family, unit, name[16]).
    private static func parse(_ raw: UnsafeRawBufferPointer) -> Event? {
        let header = 6 * MemoryLayout<UInt32>.size
        guard raw.count >= header + 8 + Int(IFNAMSIZ) else { return nil }
        let kevClass = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let subclass = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let code = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
        let kind: Kind
        switch (kevClass, subclass, code) {
        case (networkClass, dlSubclass, 10): kind = .detaching
        case (networkClass, dlSubclass, 11): kind = .detached
        case (networkClass, dlSubclass, 12): kind = .linkOff
        case (networkClass, dlSubclass, 13): kind = .linkOn
        case (ieee80211Class, _, 3): kind = .bssidChanged
        case (ieee80211Class, _, 4): kind = .wifiLinkChanged
        default: return nil
        }
        let unit = raw.loadUnaligned(fromByteOffset: header + 4, as: UInt32.self)
        let nameBytes = raw[(header + 8)..<(header + 8 + Int(IFNAMSIZ))].prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard !name.isEmpty else { return nil }
        return Event(kind: kind, interface: "\(name)\(unit)")
    }
}

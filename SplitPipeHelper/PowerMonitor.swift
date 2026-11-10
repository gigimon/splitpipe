import Foundation
import IOKit
import IOKit.pwr_mgt

/// Сон и пробуждение системы (`IORegisterForSystemPower`), в том числе фоновые пробуждения (DarkWake): VPN-клиент
/// переподключается на каждом, а события линка перед сном приходят не всегда.
final class PowerMonitor {
    /// `iokit_common_msg(…)` — макросы, в Swift не импортируются.
    private static let canSystemSleep: UInt32 = 0xe000_0270
    private static let systemWillSleep: UInt32 = 0xe000_0280
    private static let systemHasPoweredOn: UInt32 = 0xe000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    /// Вызываются на очереди монитора. `onSleep` — до засыпания: система ждёт, пока он вернётся.
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func start(queue: DispatchQueue) -> Bool {
        let callback: IOServiceInterestCallback = { refcon, _, type, argument in
            guard let refcon else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case PowerMonitor.canSystemSleep:
                // Не ответить — система ждёт 30 с.
                IOAllowPowerChange(me.rootPort, Int(bitPattern: argument))
            case PowerMonitor.systemWillSleep:
                me.onSleep?()
                IOAllowPowerChange(me.rootPort, Int(bitPattern: argument))
            case PowerMonitor.systemHasPoweredOn:
                me.onWake?()
            default:
                break
            }
        }
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, callback, &notifier)
        guard rootPort != 0, let port else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        return true
    }
}

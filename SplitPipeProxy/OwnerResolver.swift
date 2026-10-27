import Darwin
import Foundation
import Security

/// Кто открыл соединение — по audit token из метаданных flow.
struct FlowOwner {
    var pid: pid_t
    /// Путь к бинарнику: правила для консольных программ (curl, git, ssh) без bundle id.
    var path: String?
    /// Приложение, от имени которого работает процесс: у `com.apple.WebKit.Networking` это Safari или другое
    /// приложение с WebView, у XPC-служб — их приложение.
    var responsible: String?
    /// Путь ответственного процесса: WebKit у консольной программы с правилом по пути.
    var responsiblePath: String?
    /// Процесс работает от root (euid 0): системная служба или VPN-демон, не приложение пользователя.
    var root = false
}

/// Процессы живут долго и открывают много соединений, поэтому результат кешируется по pid и его версии.
final class OwnerResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [UInt64: FlowOwner] = [:]
    private var reported = false

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// Закрытая функция libsystem; если её нет, ответственное приложение не определяется.
    private static let responsibleFn: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    func owner(of token: Data?) -> FlowOwner? {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let t = token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        let pid = pid_t(bitPattern: t.val.5)
        let key = UInt64(UInt32(bitPattern: pid)) << 32 | UInt64(t.val.7)

        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        var owner = FlowOwner(pid: pid, path: Self.path(pid), root: t.val.1 == 0)
        if let fn = Self.responsibleFn {
            let r = fn(pid)
            if r > 0, r != pid {
                owner.responsiblePath = Self.path(r)
                // У приложения bundle id из Info.plist совпадает с signing id; проверка подписи с диска
                // (`SecCode*`) дорогая и держит `handleNewFlow` — только если пути внутри `.app` нет.
                owner.responsible = owner.responsiblePath.flatMap(Self.bundleID) ?? Self.signingID(r)
            }
        }

        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = owner
        let first = !reported
        reported = true
        lock.unlock()
        if first {
            logger.notice("owner resolver: pid=\(pid) path=\(owner.path ?? "nil", privacy: .public) responsible=\(owner.responsible ?? "nil", privacy: .public) fn=\(Self.responsibleFn != nil)")
        }
        return owner
    }

    private static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Signing id процесса — то же, что `sourceAppSigningIdentifier` и ключ правила приложения.
    private static func signingID(_ pid: pid_t) -> String? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
    }

    /// `/Applications/Safari.app/Contents/MacOS/Safari` → bundle id.
    private static func bundleID(_ executable: String) -> String? {
        guard let r = executable.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return Bundle(path: String(executable[..<r.lowerBound]) + ".app")?.bundleIdentifier
    }
}

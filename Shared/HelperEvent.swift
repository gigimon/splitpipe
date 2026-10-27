import Foundation

/// Что помощник сделал или почему не смог — кодом, а не текстом: у root своя локаль, а язык интерфейса знает только
/// приложение, оно и собирает текст. Помощник продолжает заполнять строки `HelperStatus` (`lastAction`, `lastError`,
/// `pfNote`) — для журнала и для приложения, которое ещё говорит со старым помощником.
enum HelperEvent: Codable, Hashable {
    case routesRestored(interface: String, gateway: String)
    case routesRemoved(interfaces: [String])
    case bypassEnabled(interfaces: [String])
    case bypassDisabled
    case noGateway(interface: String)
    /// `output` — что ответил `route`, как есть.
    case routesNotRestored(interface: String, output: String)
    case anchorNotLoaded(output: String)
    /// pf выключен — обход не нужен.
    case pfDisabled
    /// В общем наборе правил pf нет вызова `anchor "com.apple/*"`.
    case anchorNotCalled
    /// Раньше нашего якоря стоит чужой якорь или `block … quick`.
    case anchorShadowed(rule: String)
    /// SplitPipe включён, а прокси не работает (нет свежего heartbeat расширения): обход снят.
    case proxyNotRunning
}

/// События идут в том же JSON-объекте, что и `HelperStatus`, своими ключами: `HelperStatus` лежит в Shared, и его
/// правка заменила бы системное расширение. Лишние ключи и старое приложение, и `HelperStatus` пропускают.
struct HelperEvents: Codable, Equatable {
    var lastActionEvent: HelperEvent?
    var lastErrorEvent: HelperEvent?
    var pfNoteEvent: HelperEvent?

    static func encode(_ status: HelperStatus, _ events: HelperEvents) -> Data? {
        guard let s = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any],
              let e = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(events)) as? [String: Any]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: s.merging(e) { old, _ in old })
    }
}

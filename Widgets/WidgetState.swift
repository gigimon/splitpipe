import Foundation

/// Что показывают виджет и переключатель Control Center: приложение пишет в общий App Group, виджет читает.
/// Тексты — уже на языке интерфейса: их собирает приложение, виджету остаётся показать.
struct WidgetState: Codable, Equatable {
    enum Status: String, Codable { case off, starting, ok, warn }

    var status: Status
    /// «Работает», «Есть проблемы».
    var title: String
    /// «3 правила · VPN: 1».
    var subtitle: String
    var vpns: [String]
    var problems: [String]
    /// «Сегодня: 1,2 ГБ»; пусто — расширение не ответило.
    var traffic: String
    /// Включён пользователем (а не «работает прямо сейчас») — для переключателя.
    var wanted: Bool

    static let key = "widgetState"
    /// Ссылки из своего виджета подписаны этим секретом: так приложение отличает их от ссылки с сайта.
    static let tokenKey = "urlToken"

    /// `$(TeamIdentifierPrefix)dev.splitpipe` из Info.plist — как в entitlements.
    static var appGroup: String { Bundle.main.object(forInfoDictionaryKey: "SPAppGroup") as? String ?? "BL65NHTRYD.dev.splitpipe" }
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetState? {
        defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetState.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }

    static var placeholder: WidgetState {
        WidgetState(status: .ok, title: "SplitPipe", subtitle: "", vpns: ["Amnezia VPN"], problems: [], traffic: "", wanted: true)
    }
}

import Foundation

enum CommandError: LocalizedError {
    case appNotFound(String)
    case noFrontmostApp
    case routeNotFound(String)
    case badDuration(String)
    case notTemporary(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let s): String(localized: "Приложение не найдено: \(s)")
        case .noFrontmostApp: String(localized: "Нет активного приложения")
        case .routeNotFound(let s): String(localized: "Маршрут не найден: \(s)")
        case .badDuration(let s): String(localized: "Срок не понят: \(s) (15m, 1h, quit, vpn)")
        case .notTemporary(let s): String(localized: "У \(s) нет временного маршрута")
        case .unknownCommand(let s): String(localized: "Неизвестная команда: \(s)")
        }
    }
}

/// Разобранная ссылка `splitpipe://` — без выполнения: что сделать и чем подписана (`token` из своего виджета).
/// `app` nil — активное приложение; имена приложений и маршрутов разрешает `AppModel` (`Commands.swift`).
struct URLCommand: Equatable {
    enum Action: Equatable {
        /// nil — переключить.
        case setEnabled(Bool?)
        case route(app: String?, via: String, duration: TemporaryDuration?)
        case revert(app: String?)
    }

    var action: Action
    var token: String?

    /// `splitpipe://toggle`, `on`, `off`, `route?app=…&via=…&for=15m|1h|quit|vpn`, `revert?app=…`.
    static func parse(_ url: URL) throws -> URLCommand {
        guard url.scheme?.lowercased() == "splitpipe" else { throw CommandError.unknownCommand(url.absoluteString) }
        let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let app = items["app"].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let token = items["token"].flatMap { $0.isEmpty ? nil : $0 }
        let command = (url.host ?? url.path).lowercased()
        switch command {
        case "toggle": return URLCommand(action: .setEnabled(nil), token: token)
        case "on": return URLCommand(action: .setEnabled(true), token: token)
        case "off": return URLCommand(action: .setEnabled(false), token: token)
        case "route":
            guard let via = items["via"]?.trimmingCharacters(in: .whitespaces), !via.isEmpty else {
                throw CommandError.routeNotFound("")
            }
            return URLCommand(action: .route(app: app, via: via, duration: try TemporaryDuration.parse(items["for"])), token: token)
        case "revert": return URLCommand(action: .revert(app: app), token: token)
        default: throw CommandError.unknownCommand(command)
        }
    }
}

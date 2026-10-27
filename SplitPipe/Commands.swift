import AppKit
import Foundation

/// Команды для автоматизации — общие для URL-схемы `splitpipe://`, действий «Команд» и горячих клавиш:
/// включить/выключить SplitPipe, маршрут приложения (постоянно или на время), вернуть временный маршрут.
extension AppModel {
    /// Приложение по bundle id, ключу программы (`path:/usr/bin/curl`) или имени (без учёта регистра); nil — активное.
    func resolveApp(_ query: String?) throws -> String {
        guard let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty else {
            guard let id = foregroundApp else { throw CommandError.noFrontmostApp }
            return id
        }
        if appsByID[q] != nil || rules[q] != nil { return q }
        if let app = apps.first(where: { $0.name.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return app.bundleID
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) != nil { return q }
        throw CommandError.appNotFound(q)
    }

    /// Маршрут по идентификатору (`direct`, `default`, `block`, `vpn:amnezia`), имени или просто `vpn` — VPN,
    /// который держит маршрут по умолчанию (иначе первый подключённый).
    func resolveRoute(_ query: String) throws -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch q.lowercased() {
        case RouteID.direct, RouteID.block, RouteID.system: return q.lowercased()
        case "system": return RouteID.system
        case "vpn":
            if let r = vpnRoutes.first(where: { $0.up && $0.holdsDefault }) ?? vpnRoutes.first(where: \.up) { return r.id }
            throw CommandError.routeNotFound(q)
        default: break
        }
        if routes.contains(where: { $0.id == q }) { return q }
        if let r = routes.first(where: { $0.name.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return r.id
        }
        // Отключённый VPN из правил — по ключу.
        if q.hasPrefix("vpn:") { return q }
        throw CommandError.routeNotFound(q)
    }

    func commandSetRoute(app: String?, route: String, duration: TemporaryDuration?) throws {
        let id = try resolveApp(app)
        let r = try resolveRoute(route)
        if let duration {
            setTemporaryRoute(r, for: id, duration: duration)
        } else {
            setRoute(r, for: id)
        }
    }

    func commandRevert(app: String?) throws {
        let id = try resolveApp(app)
        guard temporaryRoutes[id] != nil else { throw CommandError.notTemporary(appName(id)) }
        endTemporaryRoute(for: id)
    }

    /// nil — переключить.
    func commandSetEnabled(_ on: Bool?) {
        let target = on ?? !enabled
        if target != enabled { setEnabled(target) }
    }

    /// Строка для «Команд» и ответов URL: маршрут приложения и что с ним сейчас.
    func routeSummary(for id: String) -> String {
        var text = "\(appName(id)): \(routeName(routeID(for: id)))"
        if let temp = temporaryRoutes[id] {
            text += " · " + String(localized: "временно, потом \(routeName(routeAfterTemporary(temp)))")
        }
        return text + " · " + describe(effective(for: id))
    }
}

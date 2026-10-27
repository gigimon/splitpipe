import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Правило для новых приложений: приложение без правила впервые вышло в сеть через SplitPipe — спросить, куда его
/// пускать, или сразу поставить маршрут. Новые находит расширение (`ProviderStatus.unruledApps`), так что работает
/// только при «Управлять всеми приложениями»: без него приложения без правила расширение не видит.
enum NewAppsMode: Hashable {
    case off, ask
    case route(String)

    /// В настройках: `off`, `ask` или идентификатор маршрута.
    init(_ raw: String) {
        switch raw {
        case "off": self = .off
        case "ask": self = .ask
        default: self = .route(raw)
        }
    }

    var raw: String {
        switch self {
        case .off: "off"
        case .ask: "ask"
        case .route(let r): r
        }
    }
}

extension Notifier {
    static let newAppCategoryPrefix = "new-app"
    static let defaultAction = "route:default"

    /// Категория уведомления о новом приложении с кнопками маршрутов: «По умолчанию», «Напрямую» и до двух VPN.
    /// Категории задаются заранее и целиком — регистрируем все, что понадобились.
    func newAppCategory(vpns: [(id: String, name: String)]) -> String {
        let id = ([Self.newAppCategoryPrefix] + vpns.map(\.id)).joined(separator: "|")
        guard newAppCategories[id] == nil else { return id }
        var actions = [UNNotificationAction(identifier: Self.defaultAction, title: String(localized: "По умолчанию")),
                       UNNotificationAction(identifier: "route:" + RouteID.direct, title: String(localized: "Напрямую"))]
        actions += vpns.map { UNNotificationAction(identifier: "route:" + $0.id, title: String(localized: "Через \($0.name)")) }
        newAppCategories[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories(Set(newAppCategories.values))
        return id
    }
}

extension AppModel {
    var newAppsMode: NewAppsMode { NewAppsMode(settings.newApps) }

    /// Раз в 10 с: какие приложения без правила видело расширение.
    func checkNewApps() async {
        guard newAppsMode != .off, manageAllApps, proxy.status == .connected,
              case .status(let s)? = await proxy.send(.statusParts(StatusParts(rules: false, network: false, flows: .none))),
              let seen = s.unruledApps else { return }
        // Только настоящие приложения из списка: helper-процессы относятся к своему приложению, службы — ни к чему.
        let ids = Set(seen.keys.compactMap { app(forSigningID: $0)?.bundleID })
        // Первое включение — всё, что уже ходит в сеть, «известно»: иначе пачка вопросов разом.
        if seedKnownApps {
            seedKnownApps = false
            knownApps.formUnion(ids)
            knownApps.formUnion(apps.filter(\.running).map(\.bundleID))
            return
        }
        for id in ids.sorted() where !knownApps.contains(id) && rules[id] == nil {
            knownApps.insert(id)
            switch newAppsMode {
            case .off: break
            case .route(let route):
                history.add(.newApp(app: id, route: route))
                setRoute(route, for: id)
            case .ask:
                history.add(.newApp(app: id, route: nil))
                askAboutNewApp(id)
            }
        }
    }

    /// Уведомление с кнопками: «По умолчанию» (правило не создаётся), «Напрямую», «Через <VPN>» — VPN, держащий маршрут
    /// по умолчанию, первым, не больше двух. Спрашиваем и при выключенных уведомлениях: режим «спрашивать» выбран явно.
    private func askAboutNewApp(_ id: String) {
        let vpns = vpnRoutes.filter(\.up).sorted { $0.holdsDefault && !$1.holdsDefault }.prefix(2).map { (id: $0.id, name: $0.name) }
        let category = notifier.newAppCategory(vpns: Array(vpns))
        notifier.post(id: "new-app:\(id)", title: String(localized: "Новое приложение: \(appName(id))"),
                      body: String(localized: "Пока идёт по маршруту для приложений без правила. Куда его направлять?"),
                      section: .apps, category: category, info: ["app": id])
    }

    /// Ответ из уведомления: `route:<id>` — правило, «По умолчанию» — только запомнить.
    func answerNewApp(_ id: String, action: String) {
        guard action.hasPrefix("route:") else { return }
        let route = String(action.dropFirst("route:".count))
        if action == Notifier.defaultAction {
            history.add(.newAppAnswered(app: id, route: nil))
        } else {
            history.add(.newAppAnswered(app: id, route: route))
            setRoute(route, for: id)
        }
    }

    /// Приложения, о которых уже не спрашиваем и у которых нет правила.
    var knownAppsWithoutRule: [String] {
        knownApps.filter { rules[$0] == nil }.sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    func forgetKnownApp(_ id: String) { knownApps.remove(id) }
}

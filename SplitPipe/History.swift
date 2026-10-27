import AppKit
import Foundation

extension EventSource {
    var title: String {
        switch self {
        case .app: String(localized: "Приложение")
        case .proxy: String(localized: "Расширение")
        case .helper: String(localized: "Помощник")
        }
    }
}

extension AppModel {
    /// Забирает новые события у расширения и помощника.
    func syncHistory() async {
        if proxy.status == .connected {
            let c = history.cursor(.proxy)
            if case .events(let batch)? = await proxy.send(.events(after: c?.seq ?? 0, journal: c?.journal)) {
                history.merge(batch, from: .proxy)
            }
        }
        if helper.running {
            let c = history.cursor(.helper)
            if let batch = await helper.events(after: c?.seq ?? 0, journal: c?.journal) {
                history.merge(batch, from: .helper)
            }
        }
    }

    /// Имя приложения или программы для истории.
    func appName(_ id: String) -> String {
        appsByID[id]?.name ?? ProgramRule.path(id).map { ($0 as NSString).lastPathComponent } ?? id
    }

    /// Текст события на языке интерфейса: строка и подробности.
    func describe(_ event: SPEvent) -> (title: String, detail: String?) {
        let none = String(localized: "нет")
        switch event.kind {
        case .proxyStarted(let rules, let manageAll):
            return (String(localized: "Прокси запущен"),
                    manageAll ? String(localized: "Правил: \(rules), под управлением все приложения")
                        : String(localized: "Правил: \(rules), только приложения с правилами"))
        case .proxyStopped(let reason):
            return (String(localized: "Прокси остановлен"), Self.stopReason(reason))
        case .defaultRouteChanged(let from, let to):
            return (String(localized: "Маршрут по умолчанию: \(from.map(routeName) ?? none) → \(to.map(routeName) ?? none)"), nil)
        case .vpnAppeared(let name, let iface):
            return (String(localized: "\(name) подключён"), iface)
        case .vpnDisappeared(let name, let iface):
            return (String(localized: "\(name) пропал"), iface)
        case .physicalLost(let reason):
            return (String(localized: "Сеть пропала — «Напрямую» недоступен"), reason.isEmpty ? nil : reason)
        case .physicalReturned(let iface):
            return (String(localized: "Сеть вернулась: \(iface)"), nil)
        case .flowsAborted(let count, let network):
            return (network ? String(localized: "Оборвано соединений из-за смены сети: \(count)")
                        : String(localized: "Оборвано соединений из-за смены правил: \(count)"), nil)
        case .configProblem(let problem):
            return (String(localized: "Расширение не прочитало конфигурацию"), problem)
        case .interfaceTimeout(let binding):
            return (String(localized: "Интерфейс \(binding) не появился за 2 с — соединения ушли на запасной вариант"), nil)
        case .helperStarted(let version):
            return (String(localized: "Помощник запущен"), String(localized: "Версия \(version)"))
        case .helperExiting(let reason):
            let why = switch reason {
            case "signal": String(localized: "остановлен системой")
            case "replaced": String(localized: "приложение обновлено или удалено")
            case "restart": String(localized: "перезапуск после обновления")
            default: reason
            }
            return (String(localized: "Помощник завершается — обход kill switch снят"), why)
        case .helper(let e):
            return (e.text.prefix(1).uppercased() + e.text.dropFirst(), nil)
        case .routesDropped(let reason):
            let title = switch reason {
            case .link(let iface, let up):
                up ? String(localized: "Линк \(iface) вернулся — маршруты сняты, вернутся свежими")
                    : String(localized: "Линк \(iface) пропал — маршруты сняты, вернутся свежими")
            case .tunnelGone(let iface):
                String(localized: "VPN \(iface) пропал — маршруты сняты до его переподключения")
            case .vpnDroppedDefault(let iface):
                String(localized: "VPN \(iface) снял маршрут по умолчанию — маршруты сняты до его переподключения")
            case .wifi(let iface, let what):
                String(localized: "Wi-Fi \(iface): \(what) — маршруты сняты, вернутся свежими")
            }
            return (title, nil)
        case .enabled(let on):
            return (on ? String(localized: "SplitPipe включён") : String(localized: "SplitPipe выключен"), nil)
        case .vpnDown(let name, let blocked, let moved):
            var lines: [String] = []
            if !blocked.isEmpty {
                lines.append(String(localized: "Заблокированы (\(blocked.count)): \(blocked.joined(separator: ", "))"))
            }
            if !moved.isEmpty { lines.append(moved.joined(separator: ", ")) }
            return (String(localized: "\(name) отключился"), lines.isEmpty ? nil : lines.joined(separator: "\n"))
        case .vpnUp(let name):
            return (String(localized: "\(name) снова подключён"), nil)
        case .killSwitchBlocking:
            return (String(localized: "Kill switch VPN блокирует «Напрямую»"), nil)
        case .proxyStoppedUnexpectedly:
            return (String(localized: "SplitPipe остановлен не переключателем"),
                    String(localized: "Правила не действуют — трафик идёт как обычно."))
        case .ruleChanged(let app, let route):
            return (route.map { String(localized: "\(appName(app)): \(routeName($0))") }
                        ?? String(localized: "\(appName(app)): правило удалено"), nil)
        case .temporaryRouteStarted(let app, let route):
            return (String(localized: "\(appName(app)): временно \(routeName(route))"), nil)
        case .newApp(let app, let route):
            return (route.map { String(localized: "Новое приложение \(appName(app)) — сразу \(routeName($0))") }
                        ?? String(localized: "Новое приложение \(appName(app)) — спрошено, куда направлять"), nil)
        case .newAppAnswered(let app, let route):
            return (route.map { String(localized: "\(appName(app)): выбрано \(routeName($0))") }
                        ?? String(localized: "\(appName(app)): оставлено по умолчанию"), nil)
        case .bypassDetected(let app, let count):
            return (String(localized: "\(appName(app)): соединений мимо SplitPipe — \(count)"),
                    String(localized: "Открыты до SplitPipe или до смены правила; «Оборвать соединения» переключит их."))
        case .temporaryRouteEnded(let app, let restored, let expired):
            return (expired ? String(localized: "\(appName(app)): временный маршрут закончился, снова \(routeName(restored))")
                        : String(localized: "\(appName(app)): возвращён маршрут \(routeName(restored))"), nil)
        }
    }

    /// `NEProviderStopReason`.
    private static func stopReason(_ raw: Int) -> String {
        switch raw {
        case 1: String(localized: "выключен пользователем")
        case 2: String(localized: "сбой расширения")
        case 3: String(localized: "нет сети")
        case 5, 9: String(localized: "отключён в настройках системы")
        case 10: String(localized: "конфигурация удалена")
        case 11: String(localized: "заменён другой конфигурацией")
        case 12: String(localized: "выход из системы")
        case 15: String(localized: "сон")
        case 16: String(localized: "обновление расширения")
        default: String(localized: "код \(raw)")
        }
    }

    /// Для экспорта диагностики: последние события текстом.
    func historyReport(last count: Int = 300) -> [String] {
        let format = Date.FormatStyle(date: .numeric, time: .standard).locale(.app)
        return history.events.suffix(count).map { e in
            let (title, detail) = describe(e)
            return "\(e.date.formatted(format)) [\(e.source.rawValue)] \(title)" + (detail.map { " — \($0.replacingOccurrences(of: "\n", with: "; "))" } ?? "")
        }
    }
}

import AppIntents
import Foundation

/// Действия SplitPipe для «Команд», Spotlight и Raycast. Выполняются в процессе приложения (запускают его, если
/// оно закрыто) и идут через те же команды, что ссылки `splitpipe://` (`Commands.swift`).
@MainActor
private func model() throws -> AppModel {
    guard let m = AppModel.shared else { throw CommandError.unknownCommand("SplitPipe") }
    return m
}

struct SplitPipeAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Приложение"
    static let defaultQuery = SplitPipeAppQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(id)") }
}

struct SplitPipeAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SplitPipeAppEntity] {
        let m = try model()
        return identifiers.map { SplitPipeAppEntity(id: $0, name: m.appName($0)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SplitPipeAppEntity] {
        try model().apps.filter { $0.name.localizedCaseInsensitiveContains(string) || $0.bundleID.localizedCaseInsensitiveContains(string) }
            .map { SplitPipeAppEntity(id: $0.bundleID, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SplitPipeAppEntity] {
        let m = try model()
        // Сначала с правилами и запущенные — их и переключают.
        return m.apps.sorted { (m.rules[$0.bundleID] == nil ? 1 : 0, $0.running ? 0 : 1, $0.name) < (m.rules[$1.bundleID] == nil ? 1 : 0, $1.running ? 0 : 1, $1.name) }
            .map { SplitPipeAppEntity(id: $0.bundleID, name: $0.name) }
    }
}

struct SplitPipeRouteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Маршрут"
    static let defaultQuery = SplitPipeRouteQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SplitPipeRouteQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SplitPipeRouteEntity] {
        let m = try model()
        return identifiers.map { SplitPipeRouteEntity(id: $0, name: m.routeName($0)) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SplitPipeRouteEntity] {
        let m = try model()
        let ids = [RouteID.system, RouteID.direct] + m.vpnRoutes.map(\.id) + [RouteID.block]
        return ids.map { SplitPipeRouteEntity(id: $0, name: m.routeName($0)) }
    }
}

enum SplitPipeDuration: String, AppEnum {
    case permanent, minutes15, hour, untilQuit, untilVPNDisconnect

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Срок"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .permanent: "Постоянно",
        .minutes15: "15 минут",
        .hour: "1 час",
        .untilQuit: "До выхода из приложения",
        .untilVPNDisconnect: "До отключения VPN",
    ]

    var temporary: TemporaryDuration? {
        switch self {
        case .permanent: nil
        case .minutes15: .minutes15
        case .hour: .hour
        case .untilQuit: .untilQuit
        case .untilVPNDisconnect: .untilVPNDisconnect
        }
    }
}

enum SplitPipeSwitch: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Действие"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .toggle: "Переключить", .on: "Включить", .off: "Выключить",
    ]
}

struct SetSplitPipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить или выключить SplitPipe"
    static let description = IntentDescription("Включает, выключает или переключает маршрутизацию SplitPipe.")

    @Parameter(title: "Действие", default: .toggle) var action: SplitPipeSwitch

    static var parameterSummary: some ParameterSummary { Summary("\(\.$action) SplitPipe") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let m = try model()
        m.commandSetEnabled(action == .toggle ? nil : action == .on)
        return .result(value: m.proxy.wantsRunning)
    }
}

struct SetAppRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Маршрут приложения"
    static let description = IntentDescription("Направляет приложение по маршруту — постоянно или на время. Без приложения — активное.")

    @Parameter(title: "Приложение") var app: SplitPipeAppEntity?
    @Parameter(title: "Маршрут") var route: SplitPipeRouteEntity
    @Parameter(title: "Срок", default: .permanent) var duration: SplitPipeDuration

    static var parameterSummary: some ParameterSummary { Summary("\(\.$app) → \(\.$route), \(\.$duration)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let m = try model()
        let id = try m.resolveApp(app?.id)
        try m.commandSetRoute(app: id, route: route.id, duration: duration.temporary)
        return .result(value: m.routeSummary(for: id))
    }
}

struct RevertTemporaryRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Вернуть временный маршрут"
    static let description = IntentDescription("Возвращает приложению прежний маршрут, не дожидаясь срока. Без приложения — активное.")

    @Parameter(title: "Приложение") var app: SplitPipeAppEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        try model().commandRevert(app: app?.id)
        return .result()
    }
}

struct GetAppRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Узнать маршрут приложения"
    static let description = IntentDescription("Маршрут приложения в SplitPipe и куда его трафик идёт сейчас.")

    @Parameter(title: "Приложение") var app: SplitPipeAppEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let m = try model()
        return .result(value: m.routeSummary(for: try m.resolveApp(app?.id)))
    }
}

struct GetSplitPipeStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Состояние SplitPipe"
    static let description = IntentDescription("Включён ли SplitPipe и какие VPN подключены.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let m = try model()
        let vpns = m.vpnRoutes.filter(\.up).map(\.name)
        let state = m.enabled ? String(localized: "SplitPipe включён") : String(localized: "SplitPipe выключен")
        let text = vpns.isEmpty ? state : state + " · VPN: " + vpns.joined(separator: ", ")
        return .result(value: vpns, dialog: "\(text)")
    }
}

struct SplitPipeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetSplitPipeIntent(), phrases: ["Переключить \(.applicationName)", "Toggle \(.applicationName)"],
                    shortTitle: "Вкл/выкл SplitPipe", systemImageName: "power")
        AppShortcut(intent: SetAppRouteIntent(), phrases: ["Маршрут приложения в \(.applicationName)", "Route app with \(.applicationName)"],
                    shortTitle: "Маршрут приложения", systemImageName: "arrow.triangle.branch")
        AppShortcut(intent: GetSplitPipeStatusIntent(), phrases: ["Состояние \(.applicationName)", "\(.applicationName) status"],
                    shortTitle: "Состояние", systemImageName: "info.circle")
    }
}

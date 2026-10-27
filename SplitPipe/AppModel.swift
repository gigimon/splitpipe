import AppKit
import Combine
import SwiftUI
import Foundation
import Network
import NetworkExtension

struct AppEntry: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var icon: NSImage?
    var running: Bool
    var id: String { bundleID }
    /// Консольная программа с правилом по пути (`path:/usr/bin/curl`).
    var isProgram: Bool { ProgramRule.path(bundleID) != nil }
}

/// Значения — те, что сохранены в `appsFilter`, подпись — `title`.
enum AppFilter: String, CaseIterable {
    case running = "Запущенные"
    case rules = "С правилами"
    case all = "Все"

    var title: String {
        switch self {
        case .running: String(localized: "Запущенные")
        case .rules: String(localized: "С правилами")
        case .all: String(localized: "Все")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var apps: [AppEntry] = [] {
        didSet { appsByID = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    private(set) var appsByID: [String: AppEntry] = [:]
    @Published var routes: [RouteInfo] = []
    @Published var rules: [String: AppRule] = [:]
    @Published var interfaces: [InterfaceInfo] = []
    @Published var diagnostics: [DiagItem] = []
    /// Раздел, на который нужно переключить окно (кнопки «Исправить» в диагностике).
    @Published var requestedSection: SidebarSection?
    @Published var diagnosticsRunning = false
    @Published var providerStatus: ProviderStatus?
    /// Запасные сервисы проверки по порядку, если Cloudflare trace по IP не ответил.
    @Published var echoURLs: [String]
    /// Держать у расширения соединения всех приложений, а не только с правилами: тогда любое приложение переключается сразу.
    @Published var manageAllApps: Bool {
        didSet { defaults.set(manageAllApps, forKey: "manageAllApps"); pushRules() }
    }
    @Published var settings: AppSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
            if settings.showInDock != oldValue.showInDock { applyDockPolicy() }
            if settings.notifications && !oldValue.notifications { notifier.requestAuthorization() }
            if NewAppsMode(oldValue.newApps) == .off && newAppsMode != .off {
                seedKnownApps = true
                notifier.requestAuthorization()
            }
            if settings.startProxyAtBoot != oldValue.startProxyAtBoot {
                proxy.startAtBoot = settings.startProxyAtBoot
                // Прокси включает приложение, поэтому после перезагрузки оно должно запуститься само.
                if settings.startProxyAtBoot && !launchAtLogin { launchAtLogin = true }
            }
            pushRules()
        }
    }
    /// Онбординг пройден (или всё уже было настроено) — показываем обычное окно.
    @Published var onboardingDone: Bool {
        didSet {
            defaults.set(onboardingDone, forKey: "onboardingDone")
            // В Login Items — только после онбординга: там пользователь видит «Запуск при старте» и может его выключить.
            if onboardingDone && settings.startProxyAtBoot && !launchAtLogin { launchAtLogin = true }
        }
    }
    /// Приложение на переднем плане, кроме самого SplitPipe, — для строки меню.
    @Published private(set) var foregroundApp: String?
    @Published var checks: [String: RouteCheck] = [:]
    /// Статистика выбранного периода (`loadStats`); `statsAvailable` — расширение ответило.
    @Published var statRows: [StatRow] = []
    /// nil — ещё не спрашивали (экран показывает загрузку).
    @Published var statsAvailable: Bool?
    @Published var killSwitch: KillSwitchState = .unknown {
        didSet { if killSwitch == .blocking && oldValue != .blocking { notifyKillSwitchBlocking() } }
    }
    /// Когда определили `killSwitch`; nil — ещё не проверяли.
    @Published var killSwitchCheckedAt: Date?
    /// Повторная проверка «Напрямую» перед тревогой «kill switch блокирует».
    var killSwitchConfirm: Task<Void, Never>?
    var confirmingKillSwitch = false
    /// Отложенная перепроверка «Напрямую» после пробуждения, включения, смены маршрута по умолчанию.
    var directCheckWork: Task<Void, Never>?
    /// У физического интерфейса нет scoped-маршрута: «Напрямую» не работает.
    @Published var scopedRouteMissing = false
    /// «Напрямую» работает (через интерфейс или по системному маршруту) — так же решает расширение (`directMode`).
    private(set) var directUsable = true
    /// Приложения без правила, о которых уже спросили или решили (`NewApps.swift`).
    var knownApps: Set<String> {
        didSet { defaults.set(Array(knownApps), forKey: "knownApps") }
    }
    /// Следующая проверка новых приложений только запоминает всё, что видно: первое включение режима.
    var seedKnownApps = false
    /// Трафик за сегодня для виджета (`WidgetPublisher.swift`); nil — ещё не спрашивали.
    var widgetTraffic: Int64?
    /// Сторож правил (`BypassWatcher.swift`): соединения приложений с правилом мимо расширения.
    @Published var bypassing: [String: [SocketConnection]] = [:]
    var bypassSince: [SocketConnection: Date] = [:]
    var bypassNotifiedAt: [String: Date] = [:]
    var bypassQuietUntil = Date.distantPast
    /// Списки IP-подсетей с правилами, по порядку (`IPListsModel.swift`).
    @Published var ipLists: [IPList] {
        didSet {
            if let data = try? JSONEncoder().encode(ipLists) { defaults.set(data, forKey: "ipLists") }
            pushRules()
        }
    }
    /// Разобранные подсети списков по id.
    var compiledLists: [String: CompiledIPList] = [:]
    var sendingLists = false
    var listWatchers: [String: DispatchSourceFileSystemObject] = [:]
    /// Временные маршруты приложений: правило само вернётся к прежнему (`TemporaryRoutes.swift`).
    @Published var temporaryRoutes: [String: TemporaryRoute] {
        didSet {
            if let data = try? JSONEncoder().encode(temporaryRoutes) { defaults.set(data, forKey: "temporaryRoutes") }
        }
    }

    let proxy = ProxyController()
    let helper = HelperController()
    let notifier = Notifier()
    /// История событий приложения, расширения и помощника (`History.swift`).
    let history = EventLog()
    /// Для действий «Команд»: они создаются системой, а не нами, и находят модель здесь.
    nonisolated(unsafe) static weak var shared: AppModel?
    /// Открыть главное окно — из места без SwiftUI-окружения (щелчок по уведомлению). Ставит `MainView`.
    var openMainWindow: (() -> Void)?
    /// Какие соединения нужны открытому экрану (`pollStatus`): ставят `MainView` и `AppsView`.
    var flowScope: StatusParts.Flows = .none
    /// Действует ли pf-правило помощника на прошлом опросе: изменилось — перепроверить kill switch.
    var lastAnchorEffective: Bool?
    private var helperChanges: AnyCancellable?
    private var proxyChanges: AnyCancellable?
    private var proxyConnected: AnyCancellable?
    private var proxyStopped: AnyCancellable?
    private let localInterfaces = InterfaceRegistry()
    private let defaults = UserDefaults.standard
    private var routeNames: [String: String]
    private var defaultInterface: String?
    private var refreshWork: DispatchWorkItem?
    /// Интерфейс и адрес каждого маршрута при прошлом обновлении — чтобы перепроверить те, что поменялись.
    var routeSignatures: [String: String] = [:]

    init() {
        echoURLs = defaults.stringArray(forKey: "echoURLs")
            // Свой запасной сервис из прошлых версий — первым, прежний по умолчанию (ipify) уже есть в списке.
            ?? defaults.string(forKey: "echoURL").map { old in
                Config.defaultEchoURLs.contains(old) ? Config.defaultEchoURLs : [old] + Config.defaultEchoURLs
            }
            ?? Config.defaultEchoURLs
        manageAllApps = defaults.object(forKey: "manageAllApps") as? Bool ?? true
        settings = defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        routeNames = defaults.dictionary(forKey: "routeNames") as? [String: String] ?? [:]
        rules = Self.loadRules(defaults)
        (ipLists, compiledLists) = Self.loadIPLists(defaults)
        knownApps = Set(defaults.stringArray(forKey: "knownApps") ?? [])
        seedKnownApps = defaults.object(forKey: "knownApps") == nil
        temporaryRoutes = defaults.data(forKey: "temporaryRoutes")
            .flatMap { try? JSONDecoder().decode([String: TemporaryRoute].self, from: $0) } ?? [:]
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        localInterfaces.onChange = { [weak self] in
            DispatchQueue.main.async { self?.scheduleRouteRefresh() }
        }
        localInterfaces.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            }
        }
        // После сна Wi-Fi переподключается не сразу: перепроверяем «Напрямую», когда сеть уже есть.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDirectCheck(after: 10) }
        }
        foregroundApp = Self.otherApp(NSWorkspace.shared.frontmostApplication)
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let id = Self.otherApp(app) { self?.foregroundApp = id }
            }
        }
        helperChanges = helper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Статус в строке меню зависит от состояния прокси.
        proxyChanges = proxy.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // Прокси могли включить без переключателя (запуск при старте, замена расширения) — помощнику сразу.
        proxyConnected = proxy.$status.removeDuplicates().filter { $0 == .connected }.sink { [weak self] _ in
            Task { await self?.helper.setEnabled(true) }
            // Kill switch проверяется только через расширение — заново, как только оно заработало.
            Task { @MainActor in self?.scheduleDirectCheck(after: 3) }
            // Расширение могло потерять списки (переустановка) или получить их раньше, чем мы их обновили.
            Task { await self?.pushIPLists() }
        }
        // Прокси остановился не по переключателю (система, сбой расширения) — уведомление, если не поднимется сам.
        proxyStopped = proxy.$status.removeDuplicates().scan((NEVPNStatus.invalid, NEVPNStatus.invalid)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                Task { @MainActor in self?.proxyStatusChanged(from: previous, to: current) }
            }
        AppModel.shared = self
        registerHotkeys()
        AppDelegate.urlHandler = { [weak self] url, sender in self?.handleURL(url, sender: sender) }
        notifier.onAction = { [weak self] action, info in
            if let app = info["app"] { self?.answerNewApp(app, action: action) }
        }
        notifier.onOpen = { [weak self] section in
            guard let self else { return }
            NSApp.activate()
            self.openMainWindow?()
            if let section { self.requestedSection = section }
        }
        // «Запуск при старте» без автозапуска приложения не работает: после перезагрузки включать прокси некому.
        // При первом запуске не молча: спрашивает онбординг (REVIEW2).
        if onboardingDone && settings.startProxyAtBoot && !launchAtLogin { launchAtLogin = true }
        proxy.onFirstActivation = { [weak self] in self?.setEnabled(true) }
        proxy.startAtBoot = settings.startProxyAtBoot
        applyDockPolicy()
        refresh()
        Task {
            await proxy.load()
            await helper.setEnabled(bypassWanted)
            await skipOnboardingIfReady()
            repushRules()
            await runLaunchActions()
        }
        Task { await runPeriodicChecks() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await checkNewApps()
            }
        }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                scanBypass()
            }
        }
        // Виджет и Control Center: состояние раз в 30 с и при смене статуса прокси, трафик — раз в минуту.
        Task {
            var tick = 0
            while !Task.isCancelled {
                if tick % 2 == 0 { await refreshWidgetTraffic() }
                publishWidgetState()
                tick += 1
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Списки по ссылке — раз в сутки (проверяем раз в час), файлы — по изменению.
        watchListFiles()
        Task {
            while !Task.isCancelled {
                await refreshStaleIPLists()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        // История расширения и помощника — и при закрытом окне: журналы источников короче нашего.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await syncHistory()
            }
        }
        // Сроки временных маршрутов и отключение их VPN; события запуска и выхода приложений — сразу (`refreshApps`).
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                checkTemporaryRoutes()
            }
        }
        if onboardingDone && settings.notifications { notifier.requestAuthorization() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await helper.refresh()
                // Помощника могли разрешить или перезапустить уже после запуска приложения — досылаем состояние.
                if let status = helper.status, status.enabled != bypassWanted { await helper.setEnabled(bypassWanted) }
                // Действует ли pf-правило — основной сигнал kill switch: изменилось — перепроверяем «Напрямую».
                let anchor = helper.status?.enabled == true ? helper.status?.anchorEffective : nil
                if anchor != lastAnchorEffective {
                    if lastAnchorEffective != nil || anchor == false { scheduleDirectCheck(after: 1) }
                    lastAnchorEffective = anchor
                }
            }
        }
    }

    private static func loadRules(_ defaults: UserDefaults) -> [String: AppRule] {
        if let data = defaults.data(forKey: "rules.v2"),
           let saved = try? JSONDecoder().decode([String: AppRule].self, from: data) {
            return saved
        }
        // Правила прототипа: bundle id → имя интерфейса.
        guard let data = defaults.data(forKey: "rules"),
              let old = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return old.mapValues { iface in
            if iface.hasPrefix("utun") { return AppRule(route: RouteID.vpn("amnezia"), fallback: Fallback.block) }
            if iface.hasPrefix("en") { return AppRule(route: RouteID.direct, fallback: Fallback.system) }
            return AppRule(route: RouteID.system, fallback: Fallback.system)
        }
    }

    // MARK: - Apps and routes

    func refresh() {
        refreshRoutes()
        refreshApps()
    }

    func refreshApps() {
        let me = Bundle.main.bundleIdentifier
        var list: [String: AppEntry] = [:]
        for app in NSWorkspace.shared.runningApplications where Self.isUserApp(app) {
            guard let id = app.bundleIdentifier, id != me else { continue }
            list[id] = AppEntry(bundleID: id, name: app.localizedName ?? id, icon: app.icon, running: true)
        }
        var installed = Self.installedApps()
        for id in rules.keys where installed[id] == nil && ProgramRule.path(id) == nil {
            installed[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
        for (id, url) in installed where list[id] == nil && id != me {
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            list[id] = AppEntry(bundleID: id, name: name,
                                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, running: false)
        }
        for id in rules.keys {
            guard let path = ProgramRule.path(id) else { continue }
            list[id] = AppEntry(bundleID: id, name: (path as NSString).lastPathComponent,
                                icon: NSWorkspace.shared.icon(forFile: path), running: false)
        }
        // VPN-клиентам маршрут не выбрать: расширение их правила всё равно не применяет (REVIEW3, 4.9).
        for (id, url) in installed where list[id] != nil {
            let executable = url.flatMap { Bundle(url: $0)?.executablePath } ?? ""
            if VPNCatalog.isClient(path: executable, signingID: id) { list[id] = nil }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, list[id] != nil else { continue }
            if VPNCatalog.isClient(path: app.executableURL?.path ?? "", signingID: id) { list[id] = nil }
        }
        apps = list.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        pushRules()
        checkTemporaryRoutes()
    }

    /// Обычные приложения и приложения строки меню (`LSUIElement`: Google Drive, Dropbox) из любой папки — так же, как
    /// их видит расширение (`ManagedApps`). Системные агенты строки меню (Control Center, Spotlight) лежат
    /// в `/System/Library` — их не показываем.
    private static func isUserApp(_ app: NSRunningApplication) -> Bool {
        switch app.activationPolicy {
        case .regular: return true
        case .accessory:
            // Вложенные хелперы (`Google Drive.app/Contents/Applications/FinderHelper.app`) идут под правилом родителя.
            guard let url = app.bundleURL, !url.deletingLastPathComponent().path.contains(".app") else { return false }
            return !ManagedApps.isSystem(url.path)
        default: return false
        }
    }

    private static func installedApps() -> [String: URL?] {
        var out: [String: URL?] = [:]
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                if let id = Bundle(url: url)?.bundleIdentifier { out[id] = url }
            }
        }
        return out
    }

    private func scheduleRouteRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshRoutes() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func refreshRoutes() {
        interfaces = SystemTools.interfaces()
        let known = Set(rules.values.flatMap { [$0.route, Fallback.altRoute($0.fallback) ?? ""] })
        let found = RouteDiscovery.discover(names: routeNames, known: known)
        routes = found.routes
        let previousDefault = defaultInterface
        defaultInterface = found.network.defaultInterface
        // VPN снял или вернул маршрут по умолчанию: адрес и интерфейс «Напрямую» те же, а kill switch — уже другой.
        if previousDefault != nil, previousDefault != defaultInterface, settings.checkOnNetworkChange {
            scheduleDirectCheck(after: 3)
        }
        // Scoped-маршрут нужен, только пока VPN держит маршрут по умолчанию: без VPN «Напрямую» идёт по системному.
        scopedRouteMissing = directRoute?.interface != nil && found.network.directMode == .unavailable
        directUsable = found.network.directMode != .unavailable
        pushRules()
        checkChangedRoutes()
        checkTemporaryRoutes()
        updateVPNNotifications()
    }

    func route(_ id: String) -> RouteInfo? { routes.first { $0.id == id } }
    var directRoute: RouteInfo? { route(RouteID.direct) }
    var vpnRoutes: [RouteInfo] { routes.filter { $0.kind == .vpn } }

    func rename(route id: String, to name: String) {
        guard id.hasPrefix("vpn:"), !name.isEmpty else { return }
        routeNames[String(id.dropFirst(4))] = name
        defaults.set(routeNames, forKey: "routeNames")
        refreshRoutes()
    }

    func filteredApps(_ filter: AppFilter, search: String) -> [AppEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { app in
            switch filter {
            case .running: if !app.running && !app.isProgram { return false }
            case .rules: if rules[app.bundleID] == nil { return false }
            case .all: break
            }
            return q.isEmpty || app.name.lowercased().contains(q) || app.bundleID.lowercased().contains(q)
        }
    }

    // MARK: - Rules

    func routeID(for bundleID: String) -> String { rules[bundleID]?.route ?? RouteID.system }

    /// Выбор маршрута пользователем — постоянный: временный маршрут, если был, больше сам не вернётся.
    func setRoute(_ route: String, for bundleID: String) {
        // Тот же пункт в меню выбора ещё раз — не отмена временного маршрута.
        if let temp = temporaryRoutes[bundleID] {
            guard temp.route != route else { return }
            temporaryRoutes[bundleID] = nil
        }
        if routeID(for: bundleID) != route || rules[bundleID] == nil { history.add(.ruleChanged(app: bundleID, route: route)) }
        applyRoute(route, for: bundleID)
    }

    /// Ставит маршрут правила, не трогая временные маршруты.
    func applyRoute(_ route: String, for bundleID: String) {
        let changed = routeID(for: bundleID) != route
        var rule = rules[bundleID] ?? AppRule(route: route, fallback: preferredFallback(for: route))
        if rule.route != route {
            // Выбор по умолчанию следует за типом маршрута, если пользователь его не менял.
            if rule.fallback == preferredFallback(for: rule.route) || Fallback.altRoute(rule.fallback) == route {
                rule.fallback = preferredFallback(for: route)
            }
            rule.route = route
        }
        rules[bundleID] = rule
        saveRulesAndPush()
        if changed { resetAfterRuleChange(bundleID) }
    }

    func setFallback(_ fallback: String, for bundleID: String) {
        guard var rule = rules[bundleID] else { return }
        rule.fallback = fallback
        rules[bundleID] = rule
        saveRulesAndPush()
        resetAfterRuleChange(bundleID)
    }

    func removeRule(for bundleID: String) {
        if rules[bundleID] != nil { history.add(.ruleChanged(app: bundleID, route: nil)) }
        temporaryRoutes[bundleID] = nil
        rules[bundleID] = nil
        saveRulesAndPush()
        resetAfterRuleChange(bundleID)
    }

    /// Расширение обрывает свои соединения приложения само, а открытые до SplitPipe идут мимо него —
    /// их сбрасывает помощник (если включён обрыв при смене правила).
    func resetAfterRuleChange(_ bundleID: String) {
        quietBypassWatch()
        guard settings.abortOnChange, enabled else { return }
        Task { await resetBypassingConnections(of: [bundleID]) }
    }

    /// Соединения приложений, идущие мимо расширения (открытые до SplitPipe), — через root-помощника.
    @discardableResult
    func resetBypassingConnections(of bundleIDs: [String]) async -> Int {
        let ids = Set(bundleIDs)
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(ids.contains) ?? false }
            .map(\.processIdentifier)
        return await helper.resetConnections(pids: pids)
    }

    func saveRulesAndPush() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "rules.v2") }
        refreshRoutes()
    }

    func routeName(_ id: String) -> String {
        switch id {
        case RouteID.system: String(localized: "По умолчанию")
        case RouteID.block: String(localized: "Блокировать")
        default: route(id)?.name ?? RouteDiscovery.defaultName(forVPN: String(id.dropFirst(4)))
        }
    }

    func routeSymbol(_ id: String) -> String {
        switch id {
        case RouteID.system: "arrow.triangle.branch"
        case RouteID.block: "nosign"
        default: route(id)?.symbol ?? "lock.shield"
        }
    }

    func routeTint(_ id: String) -> Color {
        switch id {
        case RouteID.system: .secondary
        case RouteID.block: .red
        default: route(id)?.tint ?? .secondary
        }
    }

    // MARK: - Effective route

    private func defaultTarget() -> EffectiveRoute {
        if let r = routes.first(where: { $0.up && $0.interface == defaultInterface }) {
            return EffectiveRoute(route: r.id, viaDefault: true)
        }
        if directRoute?.up == true { return EffectiveRoute(route: RouteID.direct, viaDefault: true) }
        return EffectiveRoute(block: .noNetwork, viaDefault: true)
    }

    /// Пока SplitPipe выключен, правила не действуют: всё идёт по системному маршруту, и «Напрямую» не нужен
    /// (маршрут через Wi-Fi/Ethernet помощник ставит только при включённом SplitPipe).
    func effective(for bundleID: String) -> EffectiveRoute {
        guard enabled else { return defaultTarget() }
        return effective(of: rules[bundleID] ?? unruledRule)
    }

    /// Правило для приложений без своего правила (настройка «маршрут для приложений без правила»).
    /// Действует, только если SplitPipe управляет всеми приложениями: иначе их соединения отдаются системе.
    var unruledRule: AppRule {
        let route = manageAllApps ? settings.defaultRoute : RouteID.system
        return AppRule(route: route, fallback: preferredFallback(for: route))
    }

    func preferredFallback(for route: String) -> String {
        route == RouteID.direct ? settings.fallbackDirect : settings.fallbackVPN
    }

    private func effective(of rule: AppRule) -> EffectiveRoute {
        resolve(rule.route, fallback: rule.fallback, depth: 0)
    }

    private func resolve(_ id: String, fallback: String, depth: Int) -> EffectiveRoute {
        if id == RouteID.block { return EffectiveRoute(block: .rule) }
        if id == RouteID.system { return defaultTarget() }
        if route(id)?.up == true, id != RouteID.direct || directUsable { return EffectiveRoute(route: id) }

        var out: EffectiveRoute
        if directRoute?.up != true {
            out = EffectiveRoute(block: .noNetwork)
        } else if fallback == Fallback.system {
            out = defaultTarget()
        } else if let alt = Fallback.altRoute(fallback), depth < 2 {
            out = resolve(alt, fallback: Fallback.block, depth: depth + 1)
            out.fallbackUnavailable = out.unavailable
        } else {
            out = EffectiveRoute(block: .unavailable)
        }
        out.unavailable = id
        return out
    }

    private func via(_ id: String) -> String {
        guard id == RouteID.direct else { return String(localized: "через \(routeName(id))") }
        let network = directRoute?.detail.components(separatedBy: " · ").first ?? String(localized: "сеть")
        return String(localized: "напрямую через \(network)")
    }

    func describe(_ e: EffectiveRoute) -> String {
        switch e.block {
        case .rule: return String(localized: "Заблокировано правилом")
        case .noNetwork: return String(localized: "Нет сети")
        case .unavailable:
            if let u = e.unavailable, let f = e.fallbackUnavailable {
                return String(localized: "\(routeName(u)) и запасной \(routeName(f)) недоступны → заблокировано")
            }
            return String(localized: "\(routeName(e.unavailable ?? "")) недоступен → заблокировано")
        case nil:
            guard let r = e.route else { return "" }
            if let u = e.unavailable { return String(localized: "\(routeName(u)) недоступен → \(via(r))") }
            return e.viaDefault ? String(localized: "сейчас \(via(r))") : via(r)
        }
    }

    /// Есть ли у приложения проблема, которую стоит показать в списке.
    func hasProblem(_ e: EffectiveRoute) -> Bool { e.block != nil && e.block != .rule || e.unavailable != nil }

    // MARK: - Extension

    func providerConfig() -> ProviderConfig {
        // Правила уходят с ролями маршрутов: какой интерфейс за ролью, расширение решает само и при смене сети,
        // поэтому конфиг не зависит от того, открыто ли приложение. Какие процессы — приложения (без системных служб
        // и VPN-клиентов), расширение тоже решает само: конфиг не меняется при запуске и выходе приложений.
        var config = ProviderConfig(rules: Self.withResolvedPaths(rules), manageAllApps: manageAllApps)
        config.unmanagedRule = unruledRule
        config.routeNames = routeNames
        config.abortOnChange = settings.abortOnChange
        config.lanViaSystem = settings.lanViaSystem
        config.rejectIPv6 = settings.rejectIPv6
        config.blockQUIC = settings.blockQUIC
        config.lists = ipListRules
        return config
    }

    /// Правило программы действует и по настоящему пути: `/opt/homebrew/bin/git` — ссылка в `Cellar/git/<версия>/bin`,
    /// а процесс расширение видит по настоящему пути. Пересчитывается при каждой отправке (после `brew upgrade` тоже).
    private static func withResolvedPaths(_ rules: [String: AppRule]) -> [String: AppRule] {
        var out = rules
        for (key, rule) in rules {
            guard let path = ProgramRule.path(key) else { continue }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if real != path, out[ProgramRule.key(real)] == nil { out[ProgramRule.key(real)] = rule }
        }
        return out
    }

    /// Выбор консольной программы: правило по пути к бинарнику. Возвращает ключ правила.
    func addProgram() -> String? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Программа для правила")
        panel.message = String(localized: "Выберите исполняемый файл (curl, git, ssh). Скрытые папки: ⇧⌘G и путь, например /usr/bin.")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            proxy.lastError = String(localized: "\(url.lastPathComponent) — не исполняемый файл")
            return nil
        }
        let key = ProgramRule.key(url.path)
        if rules[key] == nil { setRoute(RouteID.direct, for: key) }
        refreshApps()
        return key
    }

    /// Отправить правила, даже если они не менялись: расширение их потеряло или не прочитало.
    func repushRules() {
        proxy.push(config: providerConfig(), force: true)
    }

    /// Не изменилась — ничего не отправляется (сравнивает `ProxyController`).
    func pushRules() {
        proxy.push(config: providerConfig())
    }

    /// Приложение по signing id процесса: helper-процессы (`<bundle id>.helper`) относятся к своему приложению.
    func app(forSigningID id: String) -> AppEntry? { appsByID.match(signingID: id) }

    @discardableResult
    func abortConnections(of bundleID: String) async -> Int {
        var total = await resetBypassingConnections(of: [bundleID])
        if case .aborted(let n)? = await proxy.send(.abort(app: bundleID)) {
            total += n
            await pollStatus(flows: flowScope)
        }
        return total
    }

    /// Закрывает приложение обычным способом (оно может спросить про несохранённое) и запускает снова.
    func relaunch(_ bundleID: String) {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard let url = running.first?.bundleURL else { return }
        running.forEach { $0.terminate() }
        Task {
            for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard running.allSatisfy(\.isTerminated) else { return }
            try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func saveEchoURLs() { defaults.set(echoURLs, forKey: "echoURLs") }

    var enabled: Bool { proxy.status == .connected || proxy.status == .connecting }
    /// Помощнику — намерение пользователя, а не мгновенный статус сессии: при `.reasserting` обход не снимается,
    /// а работает ли прокси на самом деле, помощник видит сам по heartbeat расширения (REVIEW3, 4.4).
    var bypassWanted: Bool { proxy.wantsRunning }

    func setEnabled(_ on: Bool) {
        history.add(.enabled(on))
        quietBypassWatch()
        if on {
            Task {
                await proxy.start(config: providerConfig())
                // Соединения, открытые до включения, идут мимо расширения: сбрасываем их у приложений с правилами,
                // когда прокси уже принимает новые.
                for _ in 0..<40 where proxy.status != .connected { try? await Task.sleep(for: .milliseconds(250)) }
                guard proxy.status == .connected else { return }
                await resetBypassingConnections(of: Array(rules.keys))
            }
        } else {
            proxy.stop()
            // Kill switch определяется только при включённом SplitPipe: старый результат больше не верен.
            killSwitchConfirm?.cancel()
            directCheckWork?.cancel()
            confirmingKillSwitch = false
            killSwitch = .unknown
            killSwitchCheckedAt = nil
        }
        // Без SplitPipe обход kill switch не нужен: помощник убирает pf-правило.
        Task { await helper.setEnabled(on) }
    }


    /// «Исправить» в баннерах и диагностике: обход kill switch держит root-помощник — установить его
    /// или попросить сразу сверить pf-правило и маршрут.
    func fixBypass() {
        Task {
            if helper.registration != .enabled { helper.install() }
            await helper.setEnabled(bypassWanted)
            refreshRoutes()
        }
    }

    /// Опрос расширения для открытого экрана: соединения — только для «Соединений» (все) и панели деталей
    /// приложения (его последние), правила — никогда (их сверяет диагностика полным статусом).
    func pollStatus(flows: StatusParts.Flows = .all) async {
        var reply = await proxy.send(.statusParts(StatusParts(rules: false, network: true, flows: flows)))
        // Расширение старой версии (до замены) `statusParts` не знает.
        if case .error? = reply { reply = await proxy.send(.status) }
        guard case .status(var s)? = reply else { return }
        // Расширение не прочитало конфигурацию при запуске — досылаем свою, один раз на появление проблемы.
        if s.configProblem != nil, providerStatus?.configProblem == nil { repushRules() }
        // Правила без них в ответе — прежние: пустые значили бы «в расширении правил нет».
        if s.rulesIncluded == false { s.rules = providerStatus?.rules ?? [:] }
        let listsDiffer = s.listHashes.map { have in ipListRules.contains { compiledLists[$0.id]?.hash != have[$0.id] } } ?? false
        providerStatus = s
        if listsDiffer { Task { await pushIPLists() } }
    }

    func localInterface(_ name: String) -> NWInterface? { localInterfaces.interface(named: name) }

    func probeLocal(_ name: String, url: String) async -> ProbeResult {
        let iface = localInterfaces.interface(named: name)
        if iface == nil { return ProbeResult(interface: name, ok: false, body: "not in NWPathMonitor", millis: 0) }
        return await withCheckedContinuation { cont in
            Probe.run(url: url, interface: iface, interfaceName: name) { cont.resume(returning: $0) }
        }
    }
}

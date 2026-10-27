import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct AppSettings: Codable, Equatable {
    /// Маршрут для приложений без своего правила (работает при «Управлять всеми приложениями»).
    var defaultRoute = RouteID.system
    /// Что делать по умолчанию, если маршрут недоступен.
    var fallbackVPN = Fallback.block
    var fallbackDirect = Fallback.system
    var abortOnChange = true
    var lanViaSystem = true
    var rejectIPv6 = false
    var blockQUIC = false
    /// Проверка маршрутов раз в N минут; 0 — только вручную.
    var checkInterval = 5
    /// Перепроверять маршрут, когда у него поменялся интерфейс или адрес (переподключение VPN, другая сеть).
    var checkOnNetworkChange = true
    /// Приложение при запуске само включает SplitPipe, если он был включён (вместе с запуском при входе в систему —
    /// и после перезагрузки). Не через запуск по требованию (`onDemandRules`): он делает прокси обязательным для
    /// всей системы, и при замене или сбое расширения сеть пропадала до перезагрузки.
    var startProxyAtBoot = true
    /// Значок в строке меню с быстрым переключением маршрутов.
    var showMenuBar = true
    /// Значок в Dock. Хотя бы одно из двух включено, иначе к приложению не добраться.
    var showInDock = true
    /// Уведомления: VPN отключился и приложения заблокированы, kill switch блокирует «Напрямую», прокси остановлен,
    /// временный маршрут закончился.
    var notifications = true
    /// Новые приложения: `off`, `ask` или маршрут, который ставить сразу (`NewAppsMode`).
    var newApps = "off"
    /// Программы, которым можно открывать ссылки `splitpipe://` без подтверждения (bundle id).
    var trustedURLSenders: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultRoute = try c.decodeIfPresent(String.self, forKey: .defaultRoute) ?? d.defaultRoute
        fallbackVPN = try c.decodeIfPresent(String.self, forKey: .fallbackVPN) ?? d.fallbackVPN
        fallbackDirect = try c.decodeIfPresent(String.self, forKey: .fallbackDirect) ?? d.fallbackDirect
        abortOnChange = try c.decodeIfPresent(Bool.self, forKey: .abortOnChange) ?? d.abortOnChange
        lanViaSystem = try c.decodeIfPresent(Bool.self, forKey: .lanViaSystem) ?? d.lanViaSystem
        rejectIPv6 = try c.decodeIfPresent(Bool.self, forKey: .rejectIPv6) ?? d.rejectIPv6
        blockQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockQUIC) ?? d.blockQUIC
        checkInterval = try c.decodeIfPresent(Int.self, forKey: .checkInterval) ?? d.checkInterval
        checkOnNetworkChange = try c.decodeIfPresent(Bool.self, forKey: .checkOnNetworkChange) ?? d.checkOnNetworkChange
        startProxyAtBoot = try c.decodeIfPresent(Bool.self, forKey: .startProxyAtBoot) ?? d.startProxyAtBoot
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? d.showMenuBar
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        newApps = try c.decodeIfPresent(String.self, forKey: .newApps) ?? d.newApps
        trustedURLSenders = try c.decodeIfPresent([String].self, forKey: .trustedURLSenders) ?? d.trustedURLSenders
    }
}

extension AppModel {
    // MARK: Автозапуск

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                proxy.lastError = String(localized: "автозапуск: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    // MARK: Проверки

    /// Раз в `checkInterval` минут проверяет маршруты, пока SplitPipe включён.
    func runPeriodicChecks() async {
        while !Task.isCancelled {
            let minutes = max(settings.checkInterval, 1)
            try? await Task.sleep(for: .seconds(minutes * 60))
            if settings.checkInterval > 0 && enabled { checkAll() }
        }
    }

    // MARK: Правила

    func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "splitpipe-rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(rules).write(to: url) } catch { proxy.lastError = String(localized: "экспорт: \(error.localizedDescription)") }
    }

    func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode([String: AppRule].self, from: Data(contentsOf: url))
            for (id, rule) in imported {
                temporaryRoutes[id] = nil
                rules[id] = rule
            }
            saveRulesAndPush()
        } catch {
            proxy.lastError = String(localized: "импорт: \(error.localizedDescription)")
        }
    }

    func resetRules() {
        temporaryRoutes = [:]
        rules = [:]
        saveRulesAndPush()
    }

    /// Диагностика и текущее состояние в текстовый файл — чтобы приложить к сообщению об ошибке.
    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "splitpipe-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
    }

    func diagnosticsReport() -> String {
        // Отчёт — на языке интерфейса, как и всё, что видит пользователь.
        var lines = ["SplitPipe \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")", String(localized: "Дата: \(Date().description)"), ""]
        lines.append(String(localized: "Расширение: \(proxy.extensionState.title), прокси: \(proxy.status.title)"))
        if let error = proxy.lastError { lines.append(String(localized: "Ошибка прокси: \(error)")) }
        lines.append(String(localized: "Сеть (приложение): \(NetworkState.current().summary)"))
        lines.append(String(localized: "Сеть (расширение): \(providerStatus?.network?.summary ?? "—")"))
        lines.append("")
        lines.append(String(localized: "Маршруты:"))
        for r in routes {
            let c = checks[r.id]
            let iface = r.interface ?? String(localized: "отключён")
            lines.append("  \(r.name) [\(r.id)] \(iface) \(r.address ?? "") "
                + String(localized: "внешний IP: \(c?.ip ?? "—") \(c?.country ?? "")") + " UDP: \(c?.udpSummary ?? "—")")
        }
        lines.append("")
        lines.append(String(localized: "Правила:"))
        for (id, rule) in rules.sorted(by: { $0.key < $1.key }) {
            lines.append("  " + String(localized: "\(id): \(rule.route), если недоступен: \(rule.fallback) → \(describe(effective(for: id)))"))
        }
        lines.append("")
        lines.append(String(localized: "Диагностика:"))
        for d in diagnostics { lines.append("  [\(d.level)] \(d.title): \(d.detail)") }
        lines.append("")
        lines.append(String(localized: "История (последние события):"))
        lines += historyReport().map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    /// Удаляет расширение, конфигурацию прокси и pf-правило, сбрасывает настройки и закрывает приложение.
    func uninstallEverything() {
        Task {
            await proxy.uninstall()
            // Помощник перед удалением убирает pf-правило.
            await helper.uninstall()
            launchAtLogin = false
            NSApp.terminate(nil)
        }
    }
}

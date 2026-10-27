import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }.tag("general")
            RoutingSettings()
                .tabItem { Label("Маршрутизация", systemImage: "arrow.left.arrow.right") }.tag("routing")
            ListsSettings()
                .tabItem { Label("Списки", systemImage: "list.bullet.rectangle") }.tag("lists")
            HelperSettings()
                .tabItem { Label("Помощник", systemImage: "lock.shield") }.tag("helper")
            ChecksSettings()
                .tabItem { Label("Проверки", systemImage: "gauge.with.dots.needle.67percent") }.tag("checks")
            AdvancedSettings()
                .tabItem { Label("Дополнительно", systemImage: "ellipsis.circle") }.tag("advanced")
            AboutSettings()
                .tabItem { Label("О программе", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 600)
        // Вкладки прошлых версий (Kill switch, DNS) убраны, пока их функций нет.
        .onAppear { if !["general", "routing", "lists", "helper", "checks", "advanced", "about"].contains(tab) { tab = "general" } }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })) {
                    Text("Запускать при входе в систему")
                    if model.settings.startProxyAtBoot {
                        Text("Нужно для запуска при старте")
                    }
                }
                .disabled(model.settings.startProxyAtBoot)
                Toggle(isOn: $model.settings.startProxyAtBoot) {
                    Text("Запуск при старте")
                    Text("После входа в систему SplitPipe запускается сам, без окна, и включает маршрутизацию, если она была включена")
                }
            }
            Section {
                Toggle(isOn: $model.settings.showMenuBar) {
                    Text("Показывать в строке меню")
                    Text("Статус и быстрое переключение маршрута активного приложения")
                }
                .disabled(!model.settings.showInDock)
                Toggle(isOn: $model.settings.showInDock) {
                    Text("Показывать в Dock")
                    Text("Без значка в Dock SplitPipe открывается из строки меню")
                }
                .disabled(!model.settings.showMenuBar)
            } footer: {
                Text("Хотя бы один из значков остаётся включённым, иначе до приложения не добраться.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                KeyboardShortcuts.Recorder(String(localized: "Включить или выключить SplitPipe"), name: .toggleSplitPipe)
                KeyboardShortcuts.Recorder(String(localized: "Маршрут активного приложения"), name: .routeMenu)
            } header: {
                Text("Сочетания клавиш")
            } footer: {
                Text("Работают в любом приложении. Меню маршрута открывается у указателя мыши. Ещё SplitPipe управляется из «Команд» и ссылками splitpipe://.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.settings.trustedURLSenders.isEmpty {
                Section("Ссылки splitpipe:// без подтверждения") {
                    ForEach(model.settings.trustedURLSenders, id: \.self) { id in
                        HStack {
                            Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                                .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                            Spacer()
                            Button("Убрать") { model.settings.trustedURLSenders.removeAll { $0 == id } }.buttonStyle(.link)
                        }
                    }
                }
            }
            Section {
                Toggle(isOn: $model.settings.notifications) {
                    Text("Уведомления")
                    Text("VPN отключился и приложения заблокированы, kill switch блокирует «Напрямую», SplitPipe остановлен, временный маршрут закончился")
                }
                if model.settings.notifications && notificationsDenied {
                    LabeledContent {
                        Button("Открыть настройки…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!)
                        }
                    } label: {
                        Text("Уведомления запрещены в System Settings → Notifications").foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.settings.notifications) {
            // Разрешение спрашивается при включении — ответ приходит не сразу.
            try? await Task.sleep(for: .seconds(1))
            notificationsDenied = await model.notifier.authorizationStatus() == .denied
        }
    }
}

/// Root-помощник: обход kill switch VPN (pf-правило и маршрут через Wi-Fi/Ethernet) и сброс старых соединений.
private struct HelperSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let helper = model.helper
        Form {
            Section {
                LabeledContent("Состояние") {
                    Text(helper.title.prefix(1).uppercased() + helper.title.dropFirst())
                        .foregroundStyle(helper.running ? Color.green : .orange)
                }
                if let st = helper.status {
                    LabeledContent("Обход kill switch") {
                        Text(!st.enabled ? String(localized: "выключен вместе со SplitPipe")
                             : st.anchorInterfaces.isEmpty ? String(localized: "pf-правила нет")
                             : String(localized: "pf-правило для \(st.anchorInterfaces.joined(separator: ", "))"))
                            .foregroundStyle(.secondary)
                    }
                    if st.enabled, st.anchorEffective == false {
                        LabeledContent("pf-правило") {
                            Text("не действует: \(helper.pfNoteText ?? String(localized: "kill switch VPN перекрывает его"))")
                                .foregroundStyle(.red).multilineTextAlignment(.trailing)
                        }
                    }
                    if st.enabled, let iface = st.physical {
                        LabeledContent("Маршрут через \(iface)") {
                            Text(st.directUsable ? String(localized: "есть") : String(localized: "нет"))
                                .foregroundStyle(st.directUsable ? Color.secondary : .red)
                        }
                    }
                    if let action = helper.lastActionText, let at = st.lastActionAt {
                        LabeledContent("Последнее действие") {
                            Text(verbatim: "\(action), \(at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(.app)))")
                                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                    }
                    if let error = helper.lastErrorText {
                        LabeledContent("Ошибка") { Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing) }
                    }
                }
            } footer: {
                Text("Помощник работает от root. Пока SplitPipe включён, он держит правило pf, пропускающее SplitPipe мимо kill switch VPN, и маршрут через Wi-Fi/Ethernet — и восстанавливает их после сна и переподключения VPN. Он же сбрасывает соединения, открытые до SplitPipe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                switch model.killSwitch {
                case .bypassed: LabeledContent("Kill switch VPN") { Text("включён, SplitPipe его обходит") }
                case .blocking: LabeledContent("Kill switch VPN") { Text("блокирует «Напрямую»").foregroundStyle(.red) }
                case .none: LabeledContent("Kill switch VPN") { Text("не обнаружен") }
                case .unknown: LabeledContent("Kill switch VPN") {
                    Text(model.enabled ? String(localized: "ещё не проверялся — «Проверить связь» на «Маршрутах»")
                         : String(localized: "проверяется, когда SplitPipe включён"))
                }
                }
            }
            Section {
                HStack {
                    if helper.registration == .enabled {
                        Button("Проверить обход kill switch") { model.fixBypass() }
                        Spacer()
                        Button("Удалить помощника", role: .destructive) { Task { await helper.uninstall() } }
                    } else if helper.registration == .requiresApproval {
                        Button("Открыть Login Items…") { helper.install() }
                    } else {
                        Button("Установить помощника") { helper.install() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await helper.refresh() }
    }
}

struct RoutingSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.manageAllApps) {
                    Text("Управлять всеми приложениями")
                    Text("Соединения приложений без правила тоже идут через SplitPipe, поэтому маршрут любого запущенного приложения переключается сразу. Системные службы и VPN-клиенты не затрагиваются.")
                }
                Picker(selection: $model.settings.defaultRoute) {
                    Label("По умолчанию", systemImage: "arrow.triangle.branch").tag(RouteID.system)
                    Section("Напрямую") {
                        Label("Напрямую", systemImage: model.routeSymbol(RouteID.direct)).tag(RouteID.direct)
                    }
                    Section("VPN") {
                        ForEach(model.vpnRoutes) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                    }
                    Divider()
                    Label("Блокировать", systemImage: "nosign").tag(RouteID.block)
                } label: {
                    Text("Маршрут для приложений без правила")
                    Text(model.manageAllApps ? String(localized: "Например, «Блокировать» — разрешать сеть только приложениям с правилом")
                         : String(localized: "Работает, только когда SplitPipe управляет всеми приложениями"))
                }
                .disabled(!model.manageAllApps)
            }
            Section {
                Picker(selection: $model.settings.newApps) {
                    Text("Ничего не делать").tag("off")
                    Text("Спрашивать").tag("ask")
                    Section("Сразу направлять") {
                        Label("По умолчанию", systemImage: "arrow.triangle.branch").tag(RouteID.system)
                        Label("Напрямую", systemImage: model.routeSymbol(RouteID.direct)).tag(RouteID.direct)
                        ForEach(model.vpnRoutes) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                        Label("Блокировать", systemImage: "nosign").tag(RouteID.block)
                    }
                } label: {
                    Text("Новые приложения")
                    Text(model.manageAllApps ? String(localized: "Приложение без правила впервые вышло в сеть: спросить уведомлением или сразу поставить маршрут")
                         : String(localized: "Работает, только когда SplitPipe управляет всеми приложениями"))
                }
                .disabled(!model.manageAllApps)
                let known = model.knownAppsWithoutRule
                if model.newAppsMode != .off, !known.isEmpty {
                    DisclosureGroup(String(localized: "Уже известные без правила: \(known.count)")) {
                        ForEach(known, id: \.self) { id in
                            HStack {
                                Text(model.appName(id))
                                Spacer()
                                Button("Спросить снова") { model.forgetKnownApp(id) }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Section("Если маршрут недоступен — по умолчанию") {
                Picker("Для VPN-маршрутов", selection: $model.settings.fallbackVPN) { fallbackOptions }
                Picker("Для «Напрямую»", selection: $model.settings.fallbackDirect) { fallbackOptions }
            }
            Section {
                Toggle(isOn: $model.settings.abortOnChange) {
                    Text("Обрывать соединения при смене правила")
                    Text("Браузеры держат соединения открытыми — без этого новое правило применится не сразу")
                }
                Toggle(isOn: $model.settings.lanViaSystem) {
                    Text("Локальные адреса — по системному маршруту")
                    Text("Локальная сеть и внутренние сети VPN (10.x, 172.16–31.x, 192.168.x) доступны и у приложений «Напрямую»")
                }
                Toggle(isOn: $model.settings.rejectIPv6) {
                    Text("Всегда отклонять IPv6")
                    Text("Если у интерфейса нет маршрута IPv6, IPv6 отклоняется и так — приложение сразу переходит на IPv4. Включите, чтобы отклонять IPv6, даже когда маршрут есть")
                }
                Toggle(isOn: $model.settings.blockQUIC) {
                    Text("Отключить QUIC для перенаправленных приложений")
                    Text("Блокирует UDP 443, браузер переходит на TCP")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var fallbackOptions: some View {
        Text("Блокировать").tag(Fallback.block)
        Text("Маршрут по умолчанию").tag(Fallback.system)
    }
}

private struct ChecksSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var echoText = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Основной сервис") {
                    Text("Cloudflare (1.1.1.1) — IP и страна").foregroundStyle(.secondary)
                }
                TextField(text: $echoText, axis: .vertical) {
                    Text("Запасные сервисы")
                    Text("По одному на строку, по порядку. Ответ — только IP или формат Cloudflare trace")
                }
                .lineLimit(3...6)
                .onSubmit(save)
                Button("Сбросить список") {
                    echoText = Config.defaultEchoURLs.joined(separator: "\n")
                    save()
                }
                LabeledContent("UDP") {
                    Text("STUN: \(Config.stunServers.joined(separator: ", "))").foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Проверять маршруты", selection: $model.settings.checkInterval) {
                    Text("каждую минуту").tag(1)
                    Text("каждые 5 минут").tag(5)
                    Text("каждые 15 минут").tag(15)
                    Text("только вручную").tag(0)
                }
                Toggle(isOn: $model.settings.checkOnNetworkChange) {
                    Text("Проверять при смене сети")
                    Text("Когда у маршрута меняется интерфейс или адрес: VPN переподключился, другая сеть Wi-Fi")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { echoText = model.echoURLs.joined(separator: "\n") }
        .onDisappear(perform: save)
    }

    private func save() {
        let list = echoText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.echoURLs = list
        model.saveEchoURLs()
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false
    @State private var confirmResetStats = false
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Диагностика") {
                    Button("Экспорт…") { model.exportDiagnostics() }
                }
            }
            Section {
                LabeledContent("Правила") {
                    HStack {
                        Button("Импорт…") { model.importRules() }
                        Button("Экспорт…") { model.exportRules() }
                    }
                }
                LabeledContent("Сбросить все правила") {
                    Button("Сбросить", role: .destructive) { confirmReset = true }
                }
            }
            Section {
                LabeledContent {
                    Button("Сбросить", role: .destructive) { confirmResetStats = true }
                } label: {
                    Text("Статистика трафика")
                    Text("Хранится 30 дней в расширении")
                }
            }
            Section {
                LabeledContent {
                    Button("Начать…") { model.onboardingDone = false }
                } label: {
                    Text("Пройти настройку заново")
                    Text("Показать шаги первого запуска: расширение, прокси, помощник")
                }
            }
            Section {
                LabeledContent {
                    Button("Удалить…", role: .destructive) { confirmUninstall = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } label: {
                    Text("Удалить SplitPipe полностью")
                    Text("Сетевое расширение, конфигурация прокси, помощник и его правила pf")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Сбросить статистику трафика?", isPresented: $confirmResetStats) {
            Button("Сбросить", role: .destructive) { model.resetStats() }
        } message: {
            Text("Счёт трафика по приложениям и маршрутам начнётся заново.")
        }
        .confirmationDialog("Сбросить все правила?", isPresented: $confirmReset) {
            Button("Сбросить", role: .destructive) { model.resetRules() }
        } message: {
            Text("Все приложения пойдут по маршруту для приложений без правила.")
        }
        .confirmationDialog("Удалить SplitPipe полностью?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { model.uninstallEverything() }
        } message: {
            Text("Будут удалены сетевое расширение, конфигурация прокси, помощник и его правила pf. Трафик пойдёт как обычно. Приложение закроется; сам файл SplitPipe.app перенесите в корзину вручную.")
        }
    }
}

private struct AboutSettings: View {
    /// Версия из git (scripts/resolve_version.sh): `X.Y.Z` у релиза, иначе `X.Y.Z-N-g<hash>` или хэш коммита.
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("SplitPipe").font(.title.bold())
            Text("Маршрут для каждого приложения на Mac").foregroundStyle(.secondary)
            Text("Версия \(version) (\(build))")
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
                .padding(.top, 4)
            Link("Исходный код на GitHub", destination: URL(string: "https://github.com/gigimon/splitpipe")!)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

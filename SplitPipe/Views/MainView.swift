import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case apps, routes, connections, stats, history, diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .apps: String(localized: "Приложения")
        case .routes: String(localized: "Маршруты")
        case .connections: String(localized: "Соединения")
        case .stats: String(localized: "Статистика")
        case .history: String(localized: "История")
        case .diagnostics: String(localized: "Диагностика")
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .routes: "arrow.left.arrow.right"
        case .connections: "list.bullet"
        case .stats: "chart.bar"
        case .history: "clock.arrow.circlepath"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var proxy: ProxyController
    @AppStorage("sidebarSection") private var section: SidebarSection = .apps
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if model.onboardingDone {
                main
            } else if proxy.loaded {
                OnboardingView(proxy: proxy) {
                    model.onboardingDone = true
                    section = .apps
                }
                .frame(minWidth: 720, minHeight: 600)
            } else {
                ProgressView().frame(minWidth: 720, minHeight: 600)
            }
        }
        .onAppear {
            model.applyDockPolicy()
            model.openMainWindow = { [openWindow] in openWindow(id: "main") }
            // При входе в систему окно не нужно — SplitPipe включает маршрутизацию сам и живёт в строке меню.
            if AppDelegate.launchedAsLoginItem && model.settings.showMenuBar && model.onboardingDone {
                AppDelegate.launchedAsLoginItem = false
                dismissWindow(id: "main")
            }
        }
    }

    private var main: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SidebarSection.allCases) { s in
                    Label(s.title, systemImage: s.symbol)
                        .tag(s)
                        .badge(badge(s))
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { StatusCard(proxy: proxy) }
        } detail: {
            switch section {
            case .apps: AppsView()
            case .routes: RoutesView()
            case .connections: ConnectionsView()
            case .stats: StatsView()
            case .history: HistoryView(history: model.history)
            case .diagnostics: DiagnosticsView()
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .onChange(of: model.requestedSection) { _, s in
            if let s { section = s; model.requestedSection = nil }
        }
        // Соединения нужного экрана — сразу, а не через 2 с опроса.
        .onChange(of: section) { Task { await model.pollStatus(flows: flowScope) } }
        .task {
            // `open SplitPipe.app --args -SPOpenSettings YES` — сразу открыть настройки (для проверки вёрстки).
            if UserDefaults.standard.bool(forKey: "SPOpenSettings") { openSettings() }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "SPMenuPreview") { openWindow(id: "menu-preview") }
            #endif
            while !Task.isCancelled {
                await model.pollStatus(flows: flowScope)
                try? await Task.sleep(for: .seconds(section == .connections ? 1 : 2))
            }
        }
    }

    /// Соединения, которые нужны открытому разделу: все — «Соединениям», последние выбранного приложения — «Приложениям».
    private var flowScope: StatusParts.Flows {
        switch section {
        case .connections: .all
        case .apps: model.flowScope
        default: .none
        }
    }

    private func badge(_ s: SidebarSection) -> Int {
        switch s {
        case .apps: model.rules.count
        case .routes: model.vpnRoutes.filter { !$0.up }.count
        case .connections: model.providerStatus?.activeFlows ?? 0
        case .stats, .history: 0
        case .diagnostics: model.diagnostics.filter { $0.level == .fail || $0.level == .warn }.count
        }
    }
}

enum OverallStatus {
    case off, starting, ok, warn

    var title: String {
        switch self {
        case .off: String(localized: "Выключен")
        case .starting: String(localized: "Включается…")
        case .ok: String(localized: "Работает")
        case .warn: String(localized: "Есть проблемы")
        }
    }

    var symbol: String {
        switch self {
        case .off: "power"
        case .starting: "ellipsis"
        case .ok: "checkmark"
        case .warn: "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .off: .gray
        case .starting: .blue
        case .ok: .green
        case .warn: .orange
        }
    }
}

extension AppModel {
    var status: OverallStatus {
        switch proxy.status {
        case .connected:
            let problem = apps.contains { $0.running && rules[$0.bundleID] != nil && hasProblem(effective(for: $0.bundleID)) }
            return problem ? .warn : .ok
        case .connecting, .reasserting: return .starting
        default: return .off
        }
    }

    var statusSubtitle: String {
        switch status {
        case .off: String(localized: "Трафик идёт как обычно")
        case .starting: String(localized: "Подключаю расширение")
        case .warn: String(localized: "Маршрут недоступен")
        case .ok: String(localized: "\(rules.count) правил") + " · VPN: \(vpnRoutes.filter(\.up).count)"
        }
    }
}

struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var proxy: ProxyController

    var body: some View {
        let st = model.status
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: st.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(st.color.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(st.title).font(.headline)
                    Text(model.statusSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Toggle("SplitPipe", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            if proxy.extensionState == .notInstalled {
                Button("Установить расширение") { proxy.activateExtension() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.horizontal, 12)
            }
            if let e = proxy.lastError ?? model.helper.lastError {
                Text(e).font(.caption2).foregroundStyle(.red).lineLimit(3).padding(.horizontal, 12)
            }
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Расширение: \(proxy.extensionState.title)")
                    Text("Помощник: \(model.helper.title)")
                        .help("Root-помощник держит обход kill switch VPN: pf-правило и маршрут через Wi-Fi/Ethernet")
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Menu {
                    Button(proxy.extensionState == .active ? String(localized: "Переустановить расширение")
                           : String(localized: "Установить расширение")) { proxy.activateExtension() }
                    Divider()
                    if model.helper.registration == .enabled {
                        Button("Проверить обход kill switch") { model.fixBypass() }
                        Button("Удалить помощника") { Task { await model.helper.uninstall() } }
                    } else {
                        Button("Установить помощника…") { model.helper.install() }
                    }
                    Divider()
                    Button("Обновить приложения и маршруты") { model.refresh() }
                    SettingsLink { Text("Настройки…") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

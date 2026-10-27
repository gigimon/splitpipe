import SwiftUI

/// Поповер в строке меню: статус, переключатель, маршрут активного приложения и приложений с правилами.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var proxy: ProxyController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let st = model.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SplitPipe").fontWeight(.semibold)
                    (Text(verbatim: "● \(st.title)").foregroundStyle(st == .off ? Color.secondary : st.color)
                        + Text(verbatim: " · \(model.statusSubtitle)").foregroundStyle(.secondary))
                        .font(.caption).lineLimit(1)
                }
                Spacer(minLength: 6)
                Toggle("SplitPipe", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .disabled(!model.onboardingDone)
            }
            .padding(.horizontal, 6).padding(.bottom, 8)

            chips.padding(.horizontal, 6).padding(.bottom, 4)
            ForEach(banners, id: \.self) { MenuBanner(text: $0) }

            if let id = model.foregroundApp, let app = model.apps.first(where: { $0.bundleID == id }) {
                MenuSection("Активное приложение")
                AppRouteRow(app: app, prominent: true)
            }
            let ruled = model.apps
                .filter { model.rules[$0.bundleID] != nil && $0.bundleID != model.foregroundApp }
                .sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
                .prefix(6)
            if !ruled.isEmpty {
                MenuSection("Правила")
                ForEach(ruled) { AppRouteRow(app: $0) }
            }

            Divider().padding(.vertical, 6)
            MenuItem("Открыть SplitPipe", shortcut: "⌘O") {
                NSApp.activate()
                openWindow(id: "main")
            }
            MenuItem("Настройки…", shortcut: "⌘,") {
                NSApp.activate()
                openSettings()
            }
            Divider().padding(.vertical, 6)
            MenuItem("Выйти из SplitPipe", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(8)
        .frame(width: 340)
    }

    /// Помощник, kill switch и подключённые VPN — коротко, одной строкой.
    private var chips: some View {
        HStack(spacing: 6) {
            switch model.killSwitch {
            case .bypassed: Chip("Kill switch обходится", symbol: "lock.shield", color: .green)
            case .blocking: Chip("Kill switch блокирует", symbol: "lock.shield", color: .red)
            default: EmptyView()
            }
            if model.enabled, model.helper.status?.enabled == true, model.helper.status?.anchorEffective == false {
                Chip("Обход kill switch не действует", symbol: "lock.shield", color: .red)
            }
            if model.onboardingDone && !model.helper.running {
                Chip("Помощник: \(model.helper.title)", symbol: "wrench.and.screwdriver", color: .orange)
            }
            ForEach(model.vpnRoutes.filter(\.up)) { Chip(verbatim: $0.name, symbol: "lock.shield", color: $0.tint) }
        }
        .lineLimit(1)
    }

    private var banners: [String] {
        var out: [String] = []
        if !model.onboardingDone { out.append(String(localized: "Завершите настройку, чтобы SplitPipe начал работать.")) }
        if model.enabled { out += model.routeProblems.map(\.title) }
        return out
    }
}

private struct AppRouteRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry
    var prominent = false

    var body: some View {
        let e = model.effective(for: app.bundleID)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AppIcon(app: app, size: prominent ? 22 : 18)
                Text(app.name).fontWeight(prominent ? .semibold : .regular).lineLimit(1)
                if model.rules[app.bundleID] != nil && model.hasProblem(e) {
                    Circle().fill(e.route == nil ? Color.red : .orange).frame(width: 6, height: 6)
                }
                Spacer(minLength: 6)
                TemporaryRouteMenu(app: app).controlSize(.small)
                RouteControl(route: model.routeID(for: app.bundleID)) { model.setRoute($0, for: app.bundleID) }
                    .frame(width: 150)
                    .controlSize(.small)
            }
            if let temp = model.temporaryRoutes[app.bundleID] {
                TemporaryRouteLabel(temp: temp)
                    .font(.caption)
                    .padding(.leading, prominent ? 30 : 26)
            }
            if prominent {
                Text(model.describe(e))
                    .font(.caption)
                    .foregroundStyle(model.hasProblem(e) ? (e.route == nil ? Color.red : .orange) : .secondary)
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
}

private struct MenuSection: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
    }
}

private struct Chip: View {
    let text: Text
    let symbol: String
    let color: Color
    init(_ text: LocalizedStringKey, symbol: String, color: Color) {
        self.text = Text(text)
        self.symbol = symbol
        self.color = color
    }

    /// Имя VPN — как есть, без перевода.
    init(verbatim text: String, symbol: String, color: Color) {
        self.text = Text(verbatim: text)
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

private struct MenuBanner: View {
    let text: String

    var body: some View {
        Label {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 2).padding(.vertical, 3)
    }
}

/// Пункт меню: подсвечивается при наведении, как системный.
private struct MenuItem: View {
    let title: LocalizedStringKey
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: LocalizedStringKey, shortcut: String, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(hover ? Color.white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(hover ? Color.white : .primary)
            .background(hover ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension AppModel {
    /// Значок в строке меню по состоянию.
    var menuBarSymbol: String {
        switch status {
        case .off: "pause.circle"
        case .starting: "ellipsis.circle"
        case .warn: "exclamationmark.triangle"
        case .ok: "arrow.triangle.branch"
        }
    }
}

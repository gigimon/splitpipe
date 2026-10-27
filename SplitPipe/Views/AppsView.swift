import SwiftUI

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("appsFilter") private var filter: AppFilter = .running
    @State private var search = ""
    @State private var selection: String?

    var body: some View {
        let list = model.filteredApps(filter, search: search)
        let programs = list.filter(\.isProgram)
        let running = list.filter { $0.running && !$0.isProgram }
        let other = list.filter { !$0.running && !$0.isProgram }
        // Как в дизайне: сверху строка заголовка на всю ширину, под ней две колонки — список и детали.
        HStack(spacing: 0) {
            List(selection: $selection) {
                // Заголовки — обычные строки: системные заголовки секций прилипают к верху и получают свой фон,
                // из-за чего первый выглядит иначе остальных.
                if !running.isEmpty {
                    ListHeader("Запущенные")
                    ForEach(running) { AppRow(app: $0) }
                }
                if !other.isEmpty {
                    ListHeader("Не запущены")
                    ForEach(other) { AppRow(app: $0) }
                }
                if !programs.isEmpty {
                    ListHeader("Программы")
                    ForEach(programs) { AppRow(app: $0) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Иначе macOS затемняет тулбар только над списком, и детали снова выглядят отдельной колонкой.
            .scrollEdgeEffectHidden(true, for: .top)
            .frame(minWidth: 380)
            .overlay {
                if list.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("Нет приложений", systemImage: "app.dashed",
                                               description: Text("Попробуйте фильтр «Все»."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            Divider()
            Group {
                if let id = selection, let app = model.apps.first(where: { $0.bundleID == id }) {
                    AppInspector(app: app)
                } else {
                    ContentUnavailableView("Выберите приложение", systemImage: "app.dashed",
                                           description: Text("Здесь настраивается маршрут и что делать, если он недоступен."))
                }
            }
            .frame(width: 300)
            .frame(maxHeight: .infinity)
        }
        .onChange(of: selection, initial: true) { _, id in
            model.flowScope = id.map { .app($0, limit: 8) } ?? .none
            Task { await model.pollStatus(flows: model.flowScope) }
        }
        .screen(title: "Приложения",
                subtitle: String(localized: "\(model.rules.count) правил") + " · "
                    + String(localized: "\(model.apps.filter(\.running).count) запущено")) {
            FilterSegments(selection: $filter)
            SearchField(text: $search)
            Button {
                if let key = model.addProgram() { selection = key }
            } label: {
                Image(systemName: "terminal")
            }
            .help("Добавить правило для консольной программы (curl, git, ssh) по пути к файлу")
        }
    }
}

/// Сегменты как в дизайне: системный segmented в тулбаре macOS 26 либо в стеклянной капсуле, либо без дорожки.
struct FilterSegments: View {
    @Binding var selection: AppFilter

    var body: some View {
        Segments(selection: $selection, options: AppFilter.allCases.map { ($0, $0.title) })
    }
}

struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { f, title in
                Button { selection = f } label: {
                    Text(title)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background {
                            if selection == f {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlColor))
                                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

/// Системный NSSearchField фиксированной ширины: `.searchable` в тулбаре растягивается на всю ширину.
struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Поиск")
        field.delegate = context.coordinator
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        // AppKit отдаёт поиску фокус при открытии окна — не нужно, список важнее.
        DispatchQueue.main.async { if field.window?.firstResponder == field.currentEditor() { field.window?.makeFirstResponder(nil) } }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}

struct AppIcon: View {
    let app: AppEntry
    var size: CGFloat = 28

    var body: some View {
        if let icon = app.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app").resizable().foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry

    var body: some View {
        let id = app.bundleID
        let e = model.effective(for: id)
        HStack(spacing: 10) {
            AppIcon(app: app)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).fontWeight(.medium)
                    if app.running {
                        Circle().fill(.green).frame(width: 6, height: 6).help("Запущено")
                    }
                }
                Text(id + (model.rules[id] == nil ? " · " + String(localized: "без правила") : ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let temp = model.temporaryRoutes[id] {
                    TemporaryRouteLabel(temp: temp).font(.caption)
                }
                if model.rules[id] != nil && model.hasProblem(e) {
                    EffectiveLabel(effective: e).font(.caption)
                }
                if let n = model.bypassing[id]?.count, n > 0 {
                    BypassLabel(count: n).font(.caption)
                }
            }
            Spacer(minLength: 8)
            TemporaryRouteMenu(app: app)
            RouteControl(route: model.routeID(for: id)) { model.setRoute($0, for: id) }
                .frame(width: 230)
        }
        .padding(.vertical, 3)
        .tableRow()
        .tag(id)
    }
}

/// «3 соединения мимо SplitPipe».
struct BypassLabel: View {
    let count: Int

    var body: some View {
        Label(String(localized: "Соединений мимо SplitPipe: \(count)"), systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("Открыты до SplitPipe или до смены правила — идут мимо него. «Оборвать соединения» переключит их на правило.")
    }
}

struct EffectiveLabel: View {
    @EnvironmentObject var model: AppModel
    let effective: EffectiveRoute

    var body: some View {
        let blocked = effective.route == nil
        Label(model.describe(effective), systemImage: blocked ? "nosign" : "exclamationmark.triangle.fill")
            .foregroundStyle(blocked ? .red : .orange)
    }
}

/// Системный pop-up со списком маршрутов, сгруппированным по типам.
struct RouteControl: View {
    @EnvironmentObject var model: AppModel
    let route: String
    var includeSpecial = true
    var exclude: String?
    let onChange: (String) -> Void

    var body: some View {
        Picker("Маршрут", selection: Binding(get: { route }, set: onChange)) {
            if includeSpecial { item(RouteID.system) }
            Section("Напрямую") {
                if exclude != RouteID.direct { item(RouteID.direct) }
            }
            Section("VPN") {
                ForEach(model.vpnRoutes.filter { $0.id != exclude }) { item($0.id) }
            }
            if includeSpecial {
                Divider()
                item(RouteID.block)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func item(_ id: String) -> some View {
        let r = model.route(id)
        let title = r.map { $0.up || $0.kind == .direct ? $0.name : String(localized: "\($0.name) — отключён") } ?? model.routeName(id)
        return Label(title, systemImage: model.routeSymbol(id)).tag(id)
    }
}

struct AppInspector: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry

    private var id: String { app.bundleID }
    private var rule: AppRule? { model.rules[id] }

    var body: some View {
        let route = model.routeID(for: id)
        let e = model.effective(for: id)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    AppIcon(app: app, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(app.isProgram ? String(localized: "программа · правило по пути к файлу")
                             : app.running ? String(localized: "запущено") : String(localized: "не запущено"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                Divider()

                InspectorSection("Маршрут") {
                    RouteControl(route: route) { model.setRoute($0, for: id) }
                    if let temp = model.temporaryRoutes[id] {
                        TemporaryRouteLabel(temp: temp).font(.caption)
                        Button("Вернуть сейчас") { model.endTemporaryRoute(for: id) }
                            .buttonStyle(.link)
                    }
                    TemporaryRouteMenu(app: app, titled: true)
                    if rule != nil {
                        Button("Удалить правило") { model.removeRule(for: id) }
                            .buttonStyle(.link)
                    } else {
                        Text("Правила нет — приложение идёт по системному маршруту.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                InspectorSection("Если маршрут недоступен") { fallbackEditor(route: route) }

                InspectorSection("Сейчас") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.route.map(model.routeSymbol) ?? "nosign")
                            .foregroundStyle(e.route.map(model.routeTint) ?? .red)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.route.map(model.routeName) ?? String(localized: "Заблокировано"))
                                .fontWeight(.semibold)
                                .foregroundStyle(e.route == nil ? .red : e.unavailable != nil ? .orange : .primary)
                            Text(model.describe(e)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                InspectorSection("Соединения", last: true) {
                    if let bypass = model.bypassing[id], !bypass.isEmpty {
                        BypassLabel(count: bypass.count).font(.caption)
                        Text(bypass.prefix(5).map(\.display).joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    connections
                    Button {
                        Task { await model.abortConnections(of: id) }
                    } label: {
                        Label("Оборвать соединения", systemImage: "scissors")
                    }
                    .disabled(!model.enabled)
                    .help("Приложение переподключится — например, чтобы сразу применить новый маршрут")
                }
            }
        }
    }

    @ViewBuilder
    private func fallbackEditor(route: String) -> some View {
        let applies = rule != nil && route != RouteID.system && route != RouteID.block
        let fallback = rule?.fallback ?? model.preferredFallback(for: route)
        let alt = Fallback.altRoute(fallback)
        if !applies {
            Text(rule == nil ? String(localized: "Сначала выберите маршрут.")
                 : String(localized: "Не применяется: «\(model.routeName(route))» всегда доступен."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Если маршрут недоступен", selection: Binding(
            get: { alt == nil ? fallback : "alt" },
            set: { kind in
                if kind == "alt" {
                    let candidates = [RouteID.direct] + model.vpnRoutes.map(\.id)
                    let pick = candidates.first { $0 != route && model.route($0)?.up == true } ?? RouteID.direct
                    model.setFallback(Fallback.alt(alt ?? pick), for: id)
                } else {
                    model.setFallback(kind, for: id)
                }
            })) {
            Text("Блокировать").tag(Fallback.block)
            Text("Использовать маршрут по умолчанию").tag(Fallback.system)
            Text("Запасной маршрут").tag("alt")
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(!applies)

        if applies {
            if let alt {
                RouteControl(route: alt, includeSpecial: false, exclude: route) { model.setFallback(Fallback.alt($0), for: id) }
                    .padding(.leading, 20)
            }
            Text(fallbackHint(fallback))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fallbackHint(_ fallback: String) -> String {
        if fallback == Fallback.block { return String(localized: "Без утечек: трафик не уходит мимо выбранного маршрута.") }
        if fallback == Fallback.system {
            return String(localized: "Трафик пойдёт так, как решит система. Если в VPN включён kill switch, это фактически «через VPN или заблокировано».")
        }
        return String(localized: "Если запасной маршрут тоже недоступен, трафик блокируется.")
    }

    @ViewBuilder
    private var connections: some View {
        let flows = (model.providerStatus?.recentFlows ?? [])
            .filter { $0.app == id || $0.app.hasPrefix(id + ".") }
            .suffix(8)
            .reversed()
        if flows.isEmpty {
            if model.enabled && app.running {
                Text(model.helper.running
                     ? String(localized: "Новых соединений нет. Открытые до SplitPipe соединения «Оборвать соединения» сбрасывает тоже — приложение переподключится уже по правилу.")
                     : String(localized: "Новых соединений нет. Открытые раньше соединения идут мимо SplitPipe и не переключаются — перезапустите приложение или установите помощника, чтобы правило применилось ко всему трафику."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Перезапустить \(app.name)") { model.relaunch(app.bundleID) }
            } else {
                Text(!model.enabled ? String(localized: "SplitPipe выключен")
                     : app.isProgram ? String(localized: "Соединений пока нет") : String(localized: "Приложение не запущено"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            ForEach(Array(flows.enumerated()), id: \.offset) { _, f in
                HStack {
                    Text(f.remote).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(f.routeLabel)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

/// «На время…»: переключить маршрут приложения на 15 минут, час, до выхода из приложения или до отключения VPN —
/// потом правило вернётся само.
struct TemporaryRouteMenu: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry
    /// С подписью — в панели деталей; без — значок рядом с выбором маршрута.
    var titled = false

    var body: some View {
        let id = app.bundleID
        let temp = model.temporaryRoutes[id]
        Menu {
            if let temp {
                Button("Вернуть сейчас — \(model.routeName(model.routeAfterTemporary(temp)))") {
                    model.endTemporaryRoute(for: id)
                }
                Divider()
            }
            Section("На время") {
                ForEach(model.temporaryCandidates(for: id), id: \.self) { route in
                    Menu {
                        ForEach(model.temporaryDurations(for: app, route: route)) { d in
                            Button(d.title) { model.setTemporaryRoute(route, for: id, duration: d) }
                        }
                    } label: {
                        Label(model.routeName(route), systemImage: model.routeSymbol(route))
                    }
                }
            }
        } label: {
            if titled {
                Label("На время…", systemImage: "timer")
            } else {
                Image(systemName: temp == nil ? "timer" : "timer.circle.fill")
                    .foregroundStyle(temp == nil ? Color.secondary : .accentColor)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(titled ? .visible : .hidden)
        .fixedSize()
        .help("Переключить маршрут на время — потом он вернётся сам")
    }
}

/// «Временно, ещё 14:59 · потом Amnezia VPN».
struct TemporaryRouteLabel: View {
    @EnvironmentObject var model: AppModel
    let temp: TemporaryRoute

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
            switch temp.end {
            case .at(let date):
                Text("временно, ещё")
                Text(date, style: .timer).monospacedDigit()
            case .appQuit: Text("временно, до выхода из приложения")
            case .vpnDisconnect: Text("временно, до отключения VPN")
            }
            Text("· потом \(model.routeName(model.routeAfterTemporary(temp)))")
        }
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
    }
}

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    var last = false
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, last: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.last = last
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textCase(.uppercase)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        if !last { Divider() }
    }
}

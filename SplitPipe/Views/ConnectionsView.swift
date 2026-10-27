import SwiftUI

/// Ширины колонок ленты: шапка и строки должны совпадать.
private enum Col {
    static let time: CGFloat = 72
    static let app: CGFloat = 150
    static let proto: CGFloat = 48
    static let route: CGFloat = 150
    static let traffic: CGFloat = 90
    static let spacing: CGFloat = 12
    /// Отступ строк и шапки от краёв, чтобы колонки совпадали.
    static let inset: CGFloat = 18
    /// Простой список добавляет к отступу строки ещё ~8 pt своих.
    static let rowInsets = EdgeInsets(top: 4, leading: inset - 8, bottom: 4, trailing: inset - 8)
}

/// Лента соединений. Не системная Table: в ней нельзя подсветить строку целиком при наведении,
/// а разделители не идут через всю строку.
struct ConnectionsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("connGrouped") private var grouped = false
    @State private var filter = "all"
    @State private var paused: [FlowRecord]?
    @State private var collapsed: Set<String> = []
    @State private var selection: Set<String> = []

    var body: some View {
        let flows = visibleFlows
        let active = (model.providerStatus?.recentFlows ?? []).filter { $0.state == .active }.count
        VStack(spacing: 0) {
            columnsHeader
            Divider()
            List(selection: $selection) {
                if grouped {
                    ForEach(groups(flows), id: \.app) { g in
                        GroupRow(app: g.app, flows: g.flows, expanded: !collapsed.contains(g.app),
                                 toggle: { toggle(g.app) },
                                 abort: { Task { await model.abortConnections(of: g.app) } })
                            .tag("group:" + g.app)
                        if !collapsed.contains(g.app) {
                            ForEach(g.flows) { FlowRow(flow: $0).tag("\($0.id)") }
                        }
                    }
                } else {
                    ForEach(flows) { FlowRow(flow: $0).tag("\($0.id)") }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    let flow = flows.first { "\($0.id)" == id }
                    let app = flow.map { appID($0.app) } ?? String(id.dropFirst("group:".count))
                    Button("Оборвать соединения приложения") { Task { await model.abortConnections(of: app) } }
                    if let flow {
                        Button("Скопировать адрес") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(flow.remote, forType: .string)
                        }
                    }
                }
            }
            .overlay {
                if flows.isEmpty {
                    if model.providerStatus == nil {
                        ContentUnavailableView("SplitPipe выключен", systemImage: "list.bullet",
                                               description: Text("Включите SplitPipe, чтобы видеть соединения."))
                    } else {
                        ContentUnavailableView("Нет соединений", systemImage: "list.bullet",
                                               description: Text("Под фильтр ничего не попало."))
                    }
                }
            }
        }
        .screen(title: "Соединения", subtitle: paused == nil ? String(localized: "\(active) активных") : String(localized: "пауза")) {
            Picker("Маршрут", selection: $filter) {
                Text("Все маршруты").tag("all")
                Divider()
                ForEach(model.routes) { Text($0.name).tag($0.id) }
                Text("По умолчанию").tag(RouteID.system)
                Divider()
                Text("Заблокированные").tag(RouteID.block)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $grouped) { Label("Группировать по приложению", systemImage: "square.grid.2x2") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Группировать по приложению")
            Button {
                paused = paused == nil ? model.providerStatus?.recentFlows ?? [] : nil
            } label: {
                Label(paused == nil ? String(localized: "Пауза") : String(localized: "Продолжить ленту"),
                      systemImage: paused == nil ? "pause" : "play")
            }
            .labelStyle(.iconOnly)
            .help(paused == nil ? String(localized: "Остановить ленту") : String(localized: "Продолжить ленту"))
        }
    }

    private var columnsHeader: some View {
        HStack(spacing: Col.spacing) {
            Text("Время").frame(width: Col.time, alignment: .leading)
            Text("Приложение").frame(width: Col.app, alignment: .leading)
            Text("Адрес").frame(maxWidth: .infinity, alignment: .leading)
            Text("Прот.").frame(width: Col.proto, alignment: .leading)
            Text("Маршрут").frame(width: Col.route, alignment: .leading)
            Text("Трафик").frame(width: Col.traffic, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Col.inset)
        .padding(.vertical, 7)
        // Как и строка заголовка экрана: не увеличивать минимальную ширину колонки окна.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Новые сверху; с паузой лента замирает на снимке.
    private var visibleFlows: [FlowRecord] {
        // Соединения мимо SplitPipe — в общей ленте, по времени, когда их заметили.
        let all = ((paused ?? model.providerStatus?.recentFlows ?? []) + (paused == nil ? model.bypassRecords : []))
            .sorted { $0.date < $1.date }.reversed()
        switch filter {
        case "all": return Array(all)
        case RouteID.block: return all.filter { $0.state == .blocked }
        // «По умолчанию» — по правилу (фактический маршрут у таких соединений — VPN или «Напрямую»), остальные — по тому,
        // куда соединение ушло. Записи старого расширения — по имени маршрута, как раньше.
        case RouteID.system:
            let name = model.routeName(RouteID.system)
            return all.filter { $0.ruleRoute.map { $0 == RouteID.system } ?? ($0.routeLabel == name) }
        default:
            let name = model.routeName(filter)
            return all.filter { $0.state != .blocked && ($0.actualRoute.map { $0 == filter } ?? ($0.routeLabel == name)) }
        }
    }

    private func groups(_ flows: [FlowRecord]) -> [(app: String, flows: [FlowRecord])] {
        var order: [String] = []
        var byApp: [String: [FlowRecord]] = [:]
        for f in flows {
            let key = appID(f.app)
            if byApp[key] == nil { order.append(key) }
            byApp[key, default: []].append(f)
        }
        return order.map { ($0, byApp[$0] ?? []) }
    }

    /// Helper-процессы группируются под своим приложением.
    private func appID(_ signingID: String) -> String {
        model.app(forSigningID: signingID)?.bundleID ?? signingID
    }

    private func toggle(_ app: String) {
        if collapsed.contains(app) { collapsed.remove(app) } else { collapsed.insert(app) }
    }
}

private struct FlowRow: View {
    @EnvironmentObject var model: AppModel
    let flow: FlowRecord

    var body: some View {
        HStack(spacing: Col.spacing) {
            Text(flow.date, format: .dateTime.hour().minute().second())
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: Col.time, alignment: .leading)
            AppLabel(signingID: flow.app)
                .frame(width: Col.app, alignment: .leading)
            HStack(spacing: 6) {
                Text(flow.remote.isEmpty ? "—" : flow.remote)
                    .font(.callout.monospaced())
                    .strikethrough(flow.state == .aborted)
                if let host = flow.host { Text(host).font(.caption).foregroundStyle(.tertiary) }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(flow.proto.uppercased()).foregroundStyle(.secondary)
                .frame(width: Col.proto, alignment: .leading)
            RouteTag(flow: flow, tint: model.routes.first { $0.name == flow.routeLabel }?.tint)
                .frame(width: Col.route, alignment: .leading)
            Traffic(bytes: flow.bytesIn + flow.bytesOut, active: flow.state == .active)
                .frame(width: Col.traffic, alignment: .trailing)
        }
        .opacity(flow.state == .aborted ? 0.45 : flow.state == .closed ? 0.7 : 1)
        .tableRow(insets: Col.rowInsets)
    }
}

private struct GroupRow: View {
    let app: String
    let flows: [FlowRecord]
    let expanded: Bool
    let toggle: () -> Void
    let abort: () -> Void

    var body: some View {
        let active = flows.filter { $0.state == .active }.count
        HStack(spacing: Col.spacing) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: Col.time, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            AppLabel(signingID: app).fontWeight(.semibold)
                .frame(width: Col.app, alignment: .leading)
            Text(verbatim: String(localized: "\(flows.count) соединений") + " · " + String(localized: "активных \(active)"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Col.proto, height: 1)
            Button("Оборвать", action: abort)
                .controlSize(.small)
                .disabled(active == 0)
                .frame(width: Col.route, alignment: .leading)
            Traffic(bytes: flows.reduce(0) { $0 + $1.bytesIn + $1.bytesOut }, active: false)
                .frame(width: Col.traffic, alignment: .trailing)
        }
        .tableRow(insets: Col.rowInsets)
        .onTapGesture(count: 2, perform: toggle)
    }
}

private struct AppLabel: View {
    @EnvironmentObject var model: AppModel
    let signingID: String

    var body: some View {
        HStack(spacing: 6) {
            if let app = model.app(forSigningID: signingID) {
                AppIcon(app: app, size: 16)
                Text(app.name)
            } else if signingID == Bundle.main.bundleIdentifier {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tint).frame(width: 16)
                Text("SplitPipe (проверки)")
            } else {
                Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                Text(signingID.components(separatedBy: ".").last ?? signingID)
            }
        }
        .lineLimit(1)
        .help(signingID)
    }
}

private struct Traffic: View {
    let bytes: Int64
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(bytes > 0 ? bytes.formatted(.byteCount(style: .file).locale(.app)) : "—")
                .monospacedDigit().foregroundStyle(.secondary)
            if active { Circle().fill(.green).frame(width: 6, height: 6) }
        }
    }
}

struct RouteTag: View {
    let flow: FlowRecord
    let tint: Color?

    var body: some View {
        let (text, color, symbol) = style
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    private var style: (String, Color, String?) {
        switch flow.state {
        case .aborted: return (String(localized: "оборвано"), .secondary, nil)
        case .blocked: return (String(localized: "Заблокировано"), .red, "nosign")
        case .passed: return (String(localized: "По умолчанию"), .secondary, nil)
        case .bypass: return (String(localized: "мимо SplitPipe"), .orange, "exclamationmark.triangle.fill")
        default: return (flow.routeLabel, tint ?? .secondary, nil)
        }
    }
}

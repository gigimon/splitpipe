import Charts
import SwiftUI

/// Трафик через SplitPipe по маршрутам и приложениям. Считает расширение, приложение только показывает.
struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("statsPeriod") private var period: StatsPeriod = .today

    var body: some View {
        let data = StatsSummary(rows: model.statRows, period: period, model: model)
        Group {
            switch model.statsAvailable {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case false? where model.statRows.isEmpty:
                ContentUnavailableView("Статистика недоступна", systemImage: "chart.bar",
                                       description: Text("Статистику хранит расширение — включите SplitPipe."))
            default:
                content(data)
            }
        }
        .screen(title: "Статистика", subtitle: String(localized: "Трафик через SplitPipe \(period.subtitle)")) {
            Segments(selection: $period, options: StatsPeriod.allCases.map { ($0, $0.title) })
        }
        .task(id: period) {
            while !Task.isCancelled {
                await model.loadStats(period)
                // Пока прокси поднимается, ответа нет — переспрашиваем чаще.
                try? await Task.sleep(for: .seconds(model.statsAvailable == true ? 10 : 2))
            }
        }
    }

    private func content(_ data: StatsSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tiles(data)
                StatCard(title: "Трафик по маршрутам") {
                    TrafficChart(data: data, period: period)
                }
                if !data.routes.isEmpty {
                    StatCard(title: "Маршруты") {
                        ForEach(data.routes, id: \.self) { RouteStatRow(route: $0, data: data) }
                    }
                }
                if !data.apps.isEmpty {
                    StatCard(title: "Приложения", note: String(localized: "по трафику \(period.subtitle)")) {
                        AppStatHeader()
                        ForEach(data.apps, id: \.id) { AppStatRow(item: $0, data: data) }
                    }
                }
                Text("Считает расширение: учитываются соединения, которые идут через SplitPipe. «По умолчанию» — по фактическому маршруту. Хранится 30 дней; сбросить — в Настройках → Дополнительно.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    private func tiles(_ d: StatsSummary) -> some View {
        HStack(spacing: 12) {
            StatTile(symbol: "arrow.up.arrow.down", title: "Весь трафик", value: formatBytes(d.total.bytes),
                     sub: "↓ \(formatBytes(d.total.down)) · ↑ \(formatBytes(d.total.up))")
            StatTile(symbol: model.routeSymbol(RouteID.direct), title: "Напрямую", value: d.percent(d.directBytes),
                     sub: formatBytes(d.directBytes), tint: d.tint(RouteID.direct))
            StatTile(symbol: "lock.shield", title: "Через VPN", value: d.percent(d.vpnBytes),
                     sub: formatBytes(d.vpnBytes), tint: d.vpnTint)
            StatTile(symbol: "list.bullet", title: "Соединений", value: d.total.flows.formatted(.number.locale(.app)),
                     sub: d.total.blocked > 0 ? String(localized: "заблокировано \(d.total.blocked)") : String(localized: "без блокировок"),
                     subTint: d.total.blocked > 0 ? .red : nil)
        }
    }
}

/// Сводка по строкам статистики: итоги, порядок маршрутов, приложения по трафику.
struct StatsSummary {
    struct AppItem {
        var id: String
        var entry: AppEntry
        var totals: StatTotals
        /// Маршрут → трафик, по убыванию.
        var routes: [(String, Int64)]
    }

    let rows: [StatRow]
    let total: StatTotals
    let byRoute: [String: StatTotals]
    /// Маршруты с трафиком: «Напрямую», потом VPN по трафику.
    let routes: [String]
    let apps: [AppItem]
    private let model: AppModel

    @MainActor
    init(rows: [StatRow], period: StatsPeriod, model: AppModel) {
        self.rows = rows
        self.model = model
        var total = StatTotals()
        var byRoute: [String: StatTotals] = [:]
        var byApp: [String: StatTotals] = [:]
        var appRoutes: [String: [String: Int64]] = [:]
        for r in rows {
            total.add(r)
            byRoute[r.route, default: StatTotals()].add(r)
            byApp[r.app, default: StatTotals()].add(r)
            if r.down + r.up > 0 { appRoutes[r.app, default: [:]][r.route, default: 0] += r.down + r.up }
        }
        self.total = total
        self.byRoute = byRoute
        routes = byRoute.filter { $0.value.bytes > 0 }.keys.sorted {
            ($0 == RouteID.direct ? 0 : 1, -byRoute[$0]!.bytes) < ($1 == RouteID.direct ? 0 : 1, -byRoute[$1]!.bytes)
        }
        apps = byApp.map { id, totals in
            let entry = model.app(forSigningID: id) ?? model.apps.first { $0.bundleID == id }
                ?? AppEntry(bundleID: id, name: ProgramRule.path(id).map { ($0 as NSString).lastPathComponent } ?? id,
                            icon: nil, running: false)
            return AppItem(id: id, entry: entry, totals: totals,
                           routes: (appRoutes[id] ?? [:]).sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
        }
        .sorted { ($0.totals.bytes, $0.totals.blocked) > ($1.totals.bytes, $1.totals.blocked) }
    }

    var directBytes: Int64 { byRoute[RouteID.direct]?.bytes ?? 0 }
    var vpnBytes: Int64 { byRoute.filter { RouteID.vpnKey($0.key) != nil }.values.reduce(0) { $0 + $1.bytes } }
    var maxAppBytes: Int64 { apps.first?.totals.bytes ?? 1 }

    func percent(_ b: Int64) -> String {
        total.bytes > 0 ? "\(Int((Double(b) / Double(total.bytes) * 100).rounded()))%" : "—"
    }

    @MainActor
    func name(_ route: String) -> String {
        if route == RouteID.direct { return String(localized: "Напрямую") }
        if route == RouteID.block { return String(localized: "Блокировать") }
        return model.routeName(route)
    }

    /// Цвет маршрута, в том числе отключённого сейчас VPN (по ключу, как в карточках маршрутов).
    @MainActor
    func tint(_ route: String) -> Color {
        if let key = RouteID.vpnKey(route) { return model.route(route)?.tint ?? RouteDiscovery.tint(forVPN: key) }
        return model.routeTint(route)
    }

    @MainActor
    var vpnTint: Color {
        routes.first { RouteID.vpnKey($0) != nil }.map(tint) ?? RouteDiscovery.amneziaTint
    }
}

private struct TrafficChart: View {
    @EnvironmentObject var model: AppModel
    let data: StatsSummary
    let period: StatsPeriod

    private struct Point: Identifiable {
        var id: String { "\(label)|\(route)" }
        var label: String
        var route: String
        var bytes: Int64
    }

    var body: some View {
        let buckets = period.buckets()
        let labels = buckets.map(label)
        let points = self.points(buckets)
        let routes = data.routes
        VStack(alignment: .leading, spacing: 8) {
            Chart(points) { p in
                BarMark(x: .value(String(localized: "Время"), p.label), y: .value(String(localized: "Трафик"), p.bytes))
                    .foregroundStyle(by: .value(String(localized: "Маршрут"), data.name(p.route)))
                    .cornerRadius(2)
            }
            .chartXScale(domain: labels)
            .chartForegroundStyleScale(domain: routes.map(data.name), range: routes.map(data.tint))
            .chartLegend(position: .top, alignment: .trailing)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, to: labels.count, by: max(1, labels.count / 8)).map { labels[$0] }) { _ in
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int64.self) { Text(v == 0 ? "0" : formatBytes(v)) } }
                }
            }
            .frame(height: 180)
            if points.isEmpty {
                Text("Трафика через SplitPipe \(period.subtitle) не было").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ d: Date) -> String {
        let style: Date.FormatStyle = switch period {
        case .hour: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        case .today: .dateTime.hour(.defaultDigits(amPM: .omitted))
        case .week, .month: .dateTime.day().month(.twoDigits)
        }
        return d.formatted(style.locale(.app))
    }

    private func points(_ buckets: [Date]) -> [Point] {
        var bytes: [String: [String: Int64]] = [:]
        for r in data.rows where r.down + r.up > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(r.bucket))
            bytes[label(date), default: [:]][r.route, default: 0] += r.down + r.up
        }
        return buckets.map(label).flatMap { l in
            (bytes[l] ?? [:]).map { Point(label: l, route: $0.key, bytes: $0.value) }
        }
    }
}

private struct StatTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let sub: String
    var tint: Color? = nil
    var subTint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel(tint: tint))
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(sub).font(.caption).foregroundStyle(subTint ?? .secondary).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private struct TintedIconLabel: LabelStyle {
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint ?? .secondary)
            configuration.title
        }
    }
}

private struct StatCard<Content: View>: View {
    let title: LocalizedStringKey
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Полоса доли: один цвет или несколько сегментов (трафик приложения по маршрутам).
private struct ShareBar: View {
    let segments: [(Color, Double)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.0).frame(width: geo.size.width * min(max(s.1, 0), 1))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

private struct RouteStatRow: View {
    @EnvironmentObject var model: AppModel
    let route: String
    let data: StatsSummary

    var body: some View {
        let t = data.byRoute[route] ?? StatTotals()
        HStack(spacing: 10) {
            Image(systemName: model.routeSymbol(route)).foregroundStyle(data.tint(route)).frame(width: 18)
            Text(data.name(route)).frame(width: 150, alignment: .leading).lineLimit(1)
            ShareBar(segments: [(data.tint(route), data.total.bytes > 0 ? Double(t.bytes) / Double(data.total.bytes) : 0)])
            Text(formatBytes(t.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(data.percent(t.bytes)).foregroundStyle(.tertiary).monospacedDigit().frame(width: 40, alignment: .trailing)
            Text("\(t.flows) соед.").foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

private struct AppStatHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Приложение").frame(maxWidth: .infinity, alignment: .leading)
            Text("Маршруты").frame(width: 130, alignment: .leading)
            Text("Трафик").frame(width: 190, alignment: .leading)
            Text("↓ / ↑").frame(width: 64, alignment: .trailing)
            Text("Соед.").frame(width: 56, alignment: .trailing)
            Text("Заблок.").frame(width: 62, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}

private struct AppStatRow: View {
    let item: StatsSummary.AppItem
    let data: StatsSummary

    var body: some View {
        let t = item.totals
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                AppIcon(app: item.entry, size: 18)
                Text(item.entry.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if item.routes.isEmpty {
                    StatRouteTag(name: String(localized: "Блокировать"), tint: .red)
                } else {
                    ForEach(item.routes.prefix(1), id: \.0) { StatRouteTag(name: data.name($0.0), tint: data.tint($0.0)) }
                    // Часть трафика ушла по другому маршруту (запасному, пока основной был недоступен).
                    if item.routes.count > 1 {
                        Text("+\(item.routes.count - 1)").font(.caption2).foregroundStyle(.secondary)
                            .help(item.routes.dropFirst().map { data.name($0.0) }.joined(separator: ", "))
                    }
                }
            }
            .frame(width: 130, alignment: .leading)
            HStack(spacing: 8) {
                ShareBar(segments: item.routes.map { (data.tint($0.0), Double($0.1) / Double(max(data.maxAppBytes, 1))) })
                Text(formatBytes(t.bytes)).monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            .frame(width: 190)
            Text(t.bytes > 0 ? "\(Int(Double(t.down) / Double(t.bytes) * 100))/\(Int(Double(t.up) / Double(t.bytes) * 100))%" : "—")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(t.flows > 0 ? "\(t.flows)" : "—").monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(t.blocked > 0 ? "\(t.blocked)" : "—").monospacedDigit()
                .foregroundStyle(t.blocked > 0 ? Color.red : .secondary).frame(width: 62, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

private struct StatRouteTag: View {
    let name: String
    let tint: Color

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

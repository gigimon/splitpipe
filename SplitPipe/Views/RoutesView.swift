import SwiftUI

struct RoutesView: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.routeProblems) { p in
                    Banner(style: p.severity == .error ? .error : .warning, title: p.title, detail: p.detail) {
                        if p.fix == .bypass { Button("Исправить") { model.fixBypass() } }
                    }
                }
                if model.killSwitch == .bypassed {
                    Banner(style: .ok, title: String(localized: "Kill switch VPN обнаружен — обход для SplitPipe настроен"),
                           detail: String(localized: "Приложения «Напрямую» выходят через \(physicalLabel), остальной трафик VPN по-прежнему защищает.")) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    }
                }
                if !model.enabled {
                    Banner(style: .info, title: String(localized: "SplitPipe выключен"),
                           detail: String(localized: "Проверка идёт от имени приложения: «Напрямую» может не пройти из-за kill switch VPN.")) { EmptyView() }
                }

                SectionHeader("Напрямую")
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(model.routes.filter { $0.kind == .direct }) { RouteCard(route: $0) }
                }
                SectionHeader("VPN")
                if model.vpnRoutes.isEmpty {
                    Text("VPN не найден: нет интерфейсов utun с IPv4.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.vpnRoutes) { RouteCard(route: $0) }
                    }
                }
                Text("«Проверить связь» отправляет запрос к Cloudflare (1.1.1.1) через интерфейс маршрута и показывает внешний IP, страну и задержку. VPN определяются по интерфейсам utun; дважды щёлкните по названию, чтобы переименовать.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .screen(title: "Маршруты", subtitle: String(localized: "Куда может идти трафик приложений")) {
            Button { model.refreshRoutes(); model.checkAll() } label: {
                Label("Проверить все маршруты", systemImage: "arrow.clockwise")
            }
            .help("Проверить связь через каждый маршрут")
        }
        .task {
            model.refreshRoutes()
            model.checkStale()
        }
    }

    private var physicalLabel: String {
        model.directRoute?.detail.components(separatedBy: " · ").first ?? String(localized: "сеть")
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
    }
}

struct Banner<Accessory: View>: View {
    enum Style { case ok, warning, error, info }

    let style: Style
    let title: String
    let detail: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.3), lineWidth: 0.5))
    }

    private var color: Color {
        switch style {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .info: .secondary
        }
    }

    private var symbol: String {
        switch style {
        case .ok: "lock.shield"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .info: "power"
        }
    }
}

struct RouteCard: View {
    @EnvironmentObject var model: AppModel
    let route: RouteInfo
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let check = model.checks[route.id]
        let users = model.apps.filter { model.rules[$0.bundleID]?.route == route.id }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: route.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background((route.up ? route.tint : Color.gray).gradient, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    title
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                StatusPill(up: route.up, direct: route.kind == .direct)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Интерфейс", route.interface ?? "—", mono: true)
                row("Локальный IP", route.address ?? "—", mono: true)
                GridRow {
                    Text("Внешний IP").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(check?.ip ?? "—").font(.callout.monospaced())
                            .foregroundStyle(check?.state == .ok ? .green : .primary)
                            .textSelection(.enabled)
                        if let c = check?.country { Text(verbatim: "· \(c)").foregroundStyle(.secondary) }
                    }
                }
                GridRow {
                    Text("Проверка").foregroundStyle(.secondary)
                    CheckStatus(check: check, interface: route.interface)
                }
                if let udp = check?.udpSummary, check?.state != .running {
                    GridRow {
                        Text("UDP").foregroundStyle(.secondary)
                        Text(udp).foregroundStyle(check?.udpState == .ok ? Color.primary : check?.udpState == .otherIP ? .orange : .red)
                            .help("STUN-запрос через тот же интерфейс: UDP (звонки, QUIC) должен выходить с того же IP")
                    }
                }
            }
            .font(.callout)

            Divider()
            HStack(spacing: 8) {
                Text(footer(users: users)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(spacing: -4) {
                    ForEach(users.prefix(5)) { AppIcon(app: $0, size: 18).help($0.name) }
                }
                Button {
                    Task { await model.check(route: route.id) }
                } label: {
                    if check?.state == .running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Проверить связь")
                }
                .disabled(!route.up || check?.state == .running)
                .help("Отправить запрос через этот маршрут: узнать внешний IP и задержку")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    @ViewBuilder
    private var title: some View {
        if editing {
            TextField("Название", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.rename(route: route.id, to: draft); editing = false }
                .onExitCommand { editing = false }
        } else {
            Text(route.name)
                .font(.headline)
                .onTapGesture(count: 2) {
                    guard route.kind == .vpn else { return }
                    draft = route.name
                    editing = true
                }
                .help(route.kind == .vpn ? String(localized: "Дважды щёлкните, чтобы переименовать") : "")
        }
    }

    private var subtitle: String {
        var s = route.detail
        if route.kind == .direct { s += " · " + String(localized: "основное подключение") }
        if route.holdsDefault && route.up { s += " · " + String(localized: "держит маршрут по умолчанию") }
        return s
    }

    private func row(_ k: LocalizedStringKey, _ v: String, mono: Bool) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
        }
    }

    private func footer(users: [AppEntry]) -> String {
        let n = users.count
        guard !route.up, n > 0 else { return String(localized: "\(n) приложений") }
        let blocked = users.filter { model.effective(for: $0.bundleID).route == nil }.count
        var s = String(localized: "\(blocked) приложений заблокировано")
        if n - blocked > 0 { s += ", " + String(localized: "\(n - blocked) на запасном маршруте") }
        return s
    }
}

struct StatusPill: View {
    let up: Bool
    let direct: Bool

    var body: some View {
        let text = up ? (direct ? String(localized: "подключено") : String(localized: "подключён"))
            : (direct ? String(localized: "нет сети") : String(localized: "отключён"))
        HStack(spacing: 4) {
            Circle().frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(up ? .green : .secondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((up ? Color.green : Color.secondary).opacity(0.13), in: Capsule())
    }
}

struct CheckStatus: View {
    let check: RouteCheck?
    let interface: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            HStack(spacing: 5) {
                switch check?.state {
                case .running:
                    ProgressView().controlSize(.mini)
                    Text("запрос через \(interface ?? "—")…").foregroundStyle(.secondary)
                case .ok:
                    Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.bold)
                    Text("работает · \(check?.millis ?? 0) мс")
                    Text(verbatim: "· \(ago(check?.at))").foregroundStyle(.tertiary)
                case .failed:
                    Image(systemName: "nosign").foregroundStyle(.red)
                    Text(check?.error ?? String(localized: "нет ответа")).foregroundStyle(.red)
                    Text(verbatim: "· \(ago(check?.at))").foregroundStyle(.tertiary)
                case .skipped:
                    Text(check?.error ?? "").foregroundStyle(.secondary)
                case nil:
                    Text("не проверялось").foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 10 { return String(localized: "только что") }
        if s < 60 { return String(localized: "\(s) с назад") }
        return String(localized: "\(s / 60) мин назад")
    }
}

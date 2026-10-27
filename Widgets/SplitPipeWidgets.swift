import AppIntents
import SwiftUI
import WidgetKit

@main
struct SplitPipeWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        SplitPipeControl()
    }
}

// MARK: - Виджет состояния

struct StatusEntry: TimelineEntry {
    var date: Date
    var state: WidgetState?
}

/// Состояние пишет приложение и само просит WidgetKit обновить виджет; расписание — только страховка.
struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), state: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), state: context.isPreview ? .placeholder : WidgetState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let entry = StatusEntry(date: Date(), state: WidgetState.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.splitpipe.status", provider: StatusProvider()) { entry in
            StatusWidgetView(state: entry.state)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SplitPipe")
        .description("Состояние SplitPipe, подключённые VPN, проблемы и трафик за сегодня.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let state: WidgetState?

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(state.status))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(color(state.status).gradient, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: state.title).font(.headline).lineLimit(1)
                        Text(verbatim: state.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(state.vpns.prefix(family == .systemSmall ? 2 : 3), id: \.self) { vpn in
                    Label { Text(verbatim: vpn).lineLimit(1) } icon: { Image(systemName: "lock.shield") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.problems.prefix(family == .systemSmall ? 1 : 2), id: \.self) { problem in
                    Label { Text(verbatim: problem).lineLimit(2) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if !state.traffic.isEmpty {
                    Text(verbatim: state.traffic).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.title2)
                Text("Откройте SplitPipe").font(.caption).multilineTextAlignment(.center)
            }
        }
    }

    private func symbol(_ s: WidgetState.Status) -> String {
        switch s {
        case .off: "power"
        case .starting: "ellipsis"
        case .ok: "checkmark"
        case .warn: "exclamationmark"
        }
    }

    private func color(_ s: WidgetState.Status) -> Color {
        switch s {
        case .off: .gray
        case .starting: .blue
        case .ok: .green
        case .warn: .orange
        }
    }
}

// MARK: - Control Center

/// Переключатель SplitPipe в Control Center. Прокси включает приложение, а не расширение виджета: действие открывает
/// `splitpipe://on|off` с секретом из App Group — по нему приложение отличает свой виджет от ссылки с сайта
/// и не спрашивает подтверждения. Если приложение закрыто, ссылка его запустит.
struct SplitPipeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.splitpipe.toggle", provider: ControlStateProvider()) { on in
            ControlWidgetToggle("SplitPipe", isOn: on, action: SetSplitPipeFromControl()) { isOn in
                Label(isOn ? "Включён" : "Выключен", systemImage: "arrow.triangle.branch")
            }
        }
        .displayName("SplitPipe")
        .description("Включить или выключить маршрутизацию SplitPipe.")
    }
}

struct ControlStateProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool { WidgetState.load()?.wanted ?? false }
}

struct SetSplitPipeFromControl: SetValueIntent {
    static let title: LocalizedStringResource = "Включить или выключить SplitPipe"

    @Parameter(title: "Включён") var value: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        var components = URLComponents()
        components.scheme = "splitpipe"
        components.host = value ? "on" : "off"
        components.queryItems = [URLQueryItem(name: "token", value: WidgetState.defaults?.string(forKey: WidgetState.tokenKey) ?? "")]
        return .result(opensIntent: OpenURLIntent(components.url!))
    }
}

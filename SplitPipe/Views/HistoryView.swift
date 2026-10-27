import SwiftUI
import UniformTypeIdentifiers

/// История событий приложения, расширения и помощника — новые сверху.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var history: EventLog
    @AppStorage("historySource") private var source = "all"
    @AppStorage("historyProblems") private var problemsOnly = false
    @State private var search = ""

    var body: some View {
        let list = visible
        List {
            ForEach(list) { EventRow(event: $0) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if list.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Событий нет", systemImage: "clock.arrow.circlepath",
                                           description: Text("Здесь появятся смена сети, VPN, действия помощника и правила."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .screen(title: "История", subtitle: String(localized: "\(list.count) событий")) {
            Picker("Источник", selection: $source) {
                Text("Все источники").tag("all")
                Divider()
                ForEach(EventSource.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $problemsOnly) { Label("Только проблемы", systemImage: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Только предупреждения и ошибки")
            SearchField(text: $search)
            Button { export() } label: { Label("Экспорт…", systemImage: "square.and.arrow.up") }
                .labelStyle(.iconOnly)
                .help("Сохранить историю в текстовый файл")
        }
        // Пока история открыта — свежие события расширения и помощника каждые 5 с.
        .task {
            while !Task.isCancelled {
                await model.syncHistory()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var visible: [SPEvent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return history.events.reversed().filter { e in
            if source != "all", e.source.rawValue != source { return false }
            if problemsOnly, e.severity == .info { return false }
            guard !q.isEmpty else { return true }
            let (title, detail) = model.describe(e)
            return title.lowercased().contains(q) || (detail?.lowercased().contains(q) ?? false)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "splitpipe-history.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.historyReport(last: history.events.count).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let event: SPEvent

    var body: some View {
        let (title, detail) = model.describe(event)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(.app)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.source.title)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 3)
        .tableRow()
    }

    private var symbol: String {
        switch event.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    private var color: Color {
        switch event.severity {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

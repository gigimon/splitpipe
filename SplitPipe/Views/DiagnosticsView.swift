import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.diagnostics
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !model.diagnosticsRunning {
                            summary(items).padding(.bottom, 8)
                        }
                        ForEach(items) { item in
                            DiagRow(item: item)
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .screen(title: "Диагностика", subtitle: String(localized: "Расширение, маршруты, kill switch и DNS")) {
            if model.diagnosticsRunning {
                ProgressView().controlSize(.small)
            }
            if !items.isEmpty {
                Button { model.runDiagnostics() } label: {
                    Label("Проверить снова", systemImage: "arrow.clockwise")
                }
                .help("Проверить расширение, маршруты, kill switch и DNS")
                .disabled(model.diagnosticsRunning)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Диагностика").font(.title2.weight(.semibold))
            Text("Проверим сетевое расширение, каждый маршрут и его внешний IP, kill switch VPN и DNS. Займёт несколько секунд.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button { model.runDiagnostics() } label: {
                Text("Запустить проверки").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func summary(_ items: [DiagItem]) -> some View {
        let fails = items.filter { $0.level == .fail }.count
        let warns = items.filter { $0.level == .warn }.count
        if fails + warns == 0 {
            Banner(style: .ok, title: String(localized: "Всё в порядке"), detail: String(localized: "Проверок: \(items.count)")) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            }
        } else {
            let title = fails == 0 ? String(localized: "Предупреждений: \(warns)")
                : warns == 0 ? String(localized: "Проблем: \(fails)")
                : String(localized: "Проблем: \(fails), предупреждений: \(warns)")
            Banner(style: fails > 0 ? .error : .warning, title: title,
                   detail: String(localized: "Нажмите «Исправить» рядом с проблемой.")) { EmptyView() }
        }
    }
}

struct DiagRow: View {
    @EnvironmentObject var model: AppModel
    let item: DiagItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = item.fix {
                Button(item.fixTitle) { model.apply(fix) }
            }
        }
        .padding(.vertical, 10)
        .animation(.default, value: item.level)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.level {
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary).font(.title3)
        }
    }
}

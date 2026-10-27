import SwiftUI

extension View {
    /// Экран со строкой заголовка как в дизайне: название, подзаголовок и элементы управления справа, под ней содержимое.
    /// Системный тулбар macOS 26 прозрачный и рисует поверх содержимого — поэтому заголовок свой, а тулбар пустой
    /// (остаётся только ради кнопок окна и кнопки боковой панели).
    func screen<Controls: View>(title: LocalizedStringKey, subtitle: String,
                                @ViewBuilder controls: () -> Controls) -> some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, subtitle: subtitle, controls: controls)
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

struct ListHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        // Как в дизайне: мелкие заглавные, приглушённые, с разрядкой.
        Text(title)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }
}

/// Строка заголовка экрана: название, подзаголовок и элементы управления справа, линия снизу на всю ширину.
struct ScreenHeader<Controls: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder let controls: Controls

    init(title: LocalizedStringKey, subtitle: String, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.controls = controls()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                controls
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            // Не увеличивать минимальную ширину колонки: иначе раскладка окна зацикливается и AppKit роняет приложение.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            Divider()
        }
        .background(.bar)
    }
}


/// Строка списка как строка таблицы: подсветка при наведении и разделитель через всю строку.
struct TableRowStyle: ViewModifier {
    /// Свои отступы строки, если нужно выровнять её по шапке колонок.
    var insets: EdgeInsets?
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .listRowInsets(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .listRowBackground(hovered ? Color.primary.opacity(0.06) : Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { _ in -40 }
            .alignmentGuide(.listRowSeparatorTrailing) { d in d.width + 40 }
    }
}

extension View {
    func tableRow(insets: EdgeInsets? = nil) -> some View { modifier(TableRowStyle(insets: insets)) }
}

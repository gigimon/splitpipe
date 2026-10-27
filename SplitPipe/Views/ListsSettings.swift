import SwiftUI

/// Списки IP-подсетей: «адреса из списка — по такому-то маршруту» для приложений без своего правила.
struct ListsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var addingURL = false

    var body: some View {
        Form {
            if !model.manageAllApps {
                Section {
                    Label("Списки действуют только на приложения без правила — включите «Управлять всеми приложениями» в «Маршрутизации»",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                if model.ipLists.isEmpty {
                    Text("Списков пока нет").foregroundStyle(.secondary)
                }
                ForEach(model.ipLists) { ListRow(list: $0) }
                    .onMove { model.moveIPLists(from: $0, to: $1) }
            } header: {
                Text("Списки по порядку — срабатывает первый подходящий")
            } footer: {
                Text("Правило приложения важнее списка, список важнее маршрута для приложений без правила. Формат: по одной подсети или адресу на строку (1.2.3.0/24, 2a00::/32), комментарии — # или ;. Ссылки обновляются раз в сутки, файлы — при изменении.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Добавить по ссылке…") { addingURL = true }
                    Button("Добавить файл…") { model.addIPListFile() }
                    Spacer()
                    Button("Обновить все") {
                        Task { for l in model.ipLists where l.enabled { await model.refreshIPList(l.id) } }
                    }
                    .disabled(model.ipLists.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $addingURL) { AddListSheet() }
    }
}

private struct ListRow: View {
    @EnvironmentObject var model: AppModel
    let list: IPList

    var body: some View {
        HStack(spacing: 10) {
            Toggle(list.name, isOn: Binding(get: { list.enabled }, set: { on in
                model.updateIPList(list.id) { $0.enabled = on }
                model.watchListFiles()
            }))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(list.name).fontWeight(.medium).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(list.error == nil ? Color.secondary : .red).lineLimit(2)
            }
            Spacer(minLength: 8)
            RouteControl(route: list.rule.route) { model.setIPListRoute($0, for: list.id) }
                .frame(width: 170)
            Menu {
                Picker("Если маршрут недоступен", selection: Binding(get: { list.rule.fallback },
                                                                     set: { f in model.updateIPList(list.id) { $0.rule.fallback = f } })) {
                    Text("Блокировать").tag(Fallback.block)
                    Text("Маршрут по умолчанию").tag(Fallback.system)
                }
                Divider()
                Button("Обновить") { Task { await model.refreshIPList(list.id) } }
                Button("Выше") { model.moveIPList(list.id, by: -1) }
                    .disabled(model.ipLists.first?.id == list.id)
                Button("Ниже") { model.moveIPList(list.id, by: 1) }
                    .disabled(model.ipLists.last?.id == list.id)
                switch list.source {
                case .file(let path):
                    Button("Показать файл в Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                case .url(let s):
                    Button("Скопировать ссылку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                }
                Divider()
                Button("Удалить", role: .destructive) { model.removeIPList(list.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var status: String {
        let source: String = switch list.source {
        case .url(let s): URL(string: s)?.host ?? s
        case .file(let p): (p as NSString).lastPathComponent
        }
        if let error = list.error { return source + " · " + String(localized: "ошибка: \(error)") }
        guard let at = list.updatedAt else { return source + " · " + String(localized: "загружается…") }
        var parts = [source, String(localized: "подсетей: \(list.entries)"),
                     String(localized: "обновлён \(at.formatted(.relative(presentation: .named).locale(.app)))")]
        if list.invalid > 0 { parts.append(String(localized: "не разобрано строк: \(list.invalid)")) }
        return parts.joined(separator: " · ")
    }
}

private struct AddListSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        let valid = URL(string: url.trimmingCharacters(in: .whitespaces)).map { ["http", "https"].contains($0.scheme ?? "") } ?? false
        Form {
            TextField("Название", text: $name, prompt: Text("Например, RU"))
            TextField("Ссылка", text: $url, prompt: Text(verbatim: "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"))
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                Button("Добавить") {
                    let link = url.trimmingCharacters(in: .whitespaces)
                    let title = name.trimmingCharacters(in: .whitespaces)
                    model.addIPList(name: title.isEmpty ? (URL(string: link)?.lastPathComponent ?? link) : title, source: .url(link))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding()
        }
    }
}

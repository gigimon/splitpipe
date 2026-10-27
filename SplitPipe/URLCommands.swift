import AppKit
import Foundation

/// `splitpipe://toggle`, `on`, `off`, `route?app=<bundle id или имя>&via=<маршрут>&for=15m|1h|quit|vpn`,
/// `revert?app=…`. Без `app` — активное приложение. Ссылку может открыть любая программа и любой сайт, поэтому
/// без подтверждения выполняются только вызовы от «Команд», самого SplitPipe (виджет) и программ, которым
/// пользователь разрешил это раз и навсегда.
extension AppModel {
    static let trustedURLSenderPrefixes = ["com.apple.shortcuts", "dev.splitpipe"]

    func handleURL(_ url: URL, sender: String?) {
        guard url.scheme == "splitpipe" else { return }
        do {
            let command = try URLCommand.parse(url)
            let action: () throws -> Void
            let summary: String
            switch command.action {
            case .setEnabled(let on):
                action = { self.commandSetEnabled(on) }
                let target = on ?? !enabled
                summary = target ? String(localized: "включить SplitPipe") : String(localized: "выключить SplitPipe")
            case .route(let query, let via, let duration):
                let app = try resolveApp(query)
                let route = try resolveRoute(via)
                action = { try self.commandSetRoute(app: app, route: route, duration: duration) }
                summary = "\(appName(app)) → \(routeName(route))" + (duration.map { " (\($0.title.lowercased()))" } ?? "")
            case .revert(let query):
                let app = try resolveApp(query)
                action = { try self.commandRevert(app: app) }
                summary = String(localized: "вернуть маршрут \(appName(app))")
            }
            // Свой виджет (Control Center) подписывает ссылку секретом из App Group.
            let fromWidget = command.token == widgetToken
            guard fromWidget || confirmURL(summary, sender: sender) else { return }
            try action()
        } catch {
            notifier.post(id: "url-error", title: String(localized: "SplitPipe не выполнил ссылку"),
                          body: "\(url.absoluteString)\n\(error.localizedDescription)")
        }
    }

    /// Вызов от доверенной программы — сразу; иначе диалог с «Всегда разрешать».
    private func confirmURL(_ summary: String, sender: String?) -> Bool {
        if let sender, Self.trustedURLSenderPrefixes.contains(where: sender.hasPrefix) || settings.trustedURLSenders.contains(sender) {
            return true
        }
        let name = sender.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? sender ?? String(localized: "Неизвестная программа")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "«\(name)» просит SplitPipe: \(summary)")
        alert.informativeText = String(localized: "Ссылку splitpipe:// может открыть любая программа или сайт. Выполнить?")
        alert.addButton(withTitle: String(localized: "Выполнить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        if sender != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Всегда разрешать «\(name)»")
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let sender, alert.suppressionButton?.state == .on { settings.trustedURLSenders.append(sender) }
        return true
    }
}

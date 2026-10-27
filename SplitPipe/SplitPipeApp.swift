import SwiftUI

/// Запуск как объект входа (Login Items): главное окно не открываем, SplitPipe работает из строки меню.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedAsLoginItem = false
    /// Ссылки `splitpipe://` (URL, bundle id программы, которая её открыла). Пришли раньше модели — ждут её.
    static var urlHandler: ((URL, String?) -> Void)? {
        didSet {
            guard let urlHandler else { return }
            pendingURLs.forEach { urlHandler($0.0, $0.1) }
            pendingURLs = []
        }
    }
    private static var pendingURLs: [(URL, String?)] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        // Кто открыл ссылку — по pid отправителя Apple Event: от этого зависит, спрашивать ли подтверждение.
        let pid = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let sender = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        for url in urls {
            if let handler = Self.urlHandler { handler(url, sender) } else { Self.pendingURLs.append((url, sender)) }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

@main
struct SplitPipeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Одно главное окно: `openWindow(id: "main")` выводит вперёд уже открытое, а не создаёт новое.
        Window("SplitPipe", id: "main") {
            MainView(proxy: model.proxy)
                .environmentObject(model)
                .environment(\.locale, .app)
        }
        .windowToolbarStyle(.unified)
        // Ссылки `splitpipe://` обрабатывает AppDelegate, окно для них не открываем.
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.locale, .app)
        }

        // MenuBarExtra пишет в привязку при каждом обновлении: присваивание того же значения меняло бы settings
        // и снова перерисовывало сцену — бесконечный цикл.
        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBar },
                                         set: { if model.settings.showMenuBar != $0 { model.settings.showMenuBar = $0 } })) {
            MenuBarView(proxy: model.proxy)
                .environmentObject(model)
                .environment(\.locale, .app)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        // `-SPMenuPreview YES`: содержимое поповера строки меню в обычном окне — для снимков вёрстки.
        Window("Строка меню", id: "menu-preview") {
            MenuBarView(proxy: model.proxy)
                .environmentObject(model)
                .environment(\.locale, .app)
        }
        .windowResizability(.contentSize)
        #endif
    }
}

import AppKit
import KeyboardShortcuts

/// Глобальные сочетания клавиш (по умолчанию не назначены, задаются в настройках): включить/выключить SplitPipe
/// и меню маршрута активного приложения у указателя мыши.
extension KeyboardShortcuts.Name {
    static let toggleSplitPipe = Self("toggleSplitPipe")
    static let routeMenu = Self("routeMenu")
}

/// Пункт меню с замыканием вместо target/action.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, image: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension AppModel {
    func registerHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .toggleSplitPipe) { [weak self] in self?.commandSetEnabled(nil) }
        KeyboardShortcuts.onKeyUp(for: .routeMenu) { [weak self] in self?.showRouteMenu() }
    }

    /// Меню маршрутов активного приложения у указателя: маршрут, «на время…», «вернуть сейчас».
    func showRouteMenu() {
        guard let id = foregroundApp else { NSSound.beep(); return }
        let front = NSWorkspace.shared.frontmostApplication
        let menu = NSMenu()
        let header = NSMenuItem(title: appName(id), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let temp = temporaryRoutes[id] {
            menu.addItem(ClosureMenuItem(String(localized: "Вернуть сейчас — \(routeName(routeAfterTemporary(temp)))"),
                                         image: "arrow.uturn.backward") { [weak self] in self?.endTemporaryRoute(for: id) })
        }
        menu.addItem(.separator())
        let current = routeID(for: id)
        let routeIDs = [RouteID.system, RouteID.direct] + vpnRoutes.filter(\.up).map(\.id) + [RouteID.block]
        for r in routeIDs {
            menu.addItem(ClosureMenuItem(routeName(r), checked: r == current, image: routeSymbol(r)) { [weak self] in
                self?.setRoute(r, for: id)
            })
        }
        menu.addItem(.separator())
        let temporary = NSMenuItem(title: String(localized: "На время"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for r in temporaryCandidates(for: id) {
            let item = NSMenuItem(title: routeName(r), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: routeSymbol(r), accessibilityDescription: nil)
            let durations = NSMenu()
            for d in temporaryDurations(for: appsByID[id] ?? AppEntry(bundleID: id, name: appName(id), running: true), route: r) {
                durations.addItem(ClosureMenuItem(d.title) { [weak self] in self?.setTemporaryRoute(r, for: id, duration: d) })
            }
            item.submenu = durations
            sub.addItem(item)
        }
        temporary.submenu = sub
        menu.addItem(temporary)
        // Меню у указателя показывает только активное приложение — после выбора возвращаем фокус тому, что был.
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        front?.activate()
    }
}

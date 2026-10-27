import AppKit
import Foundation
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications

/// Системные уведомления: о том, что SplitPipe перестал делать то, что обещал, пока окно закрыто.
/// Повторы одного события заменяют прежнее уведомление (тот же идентификатор), а исправившееся — убирается.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    /// Щелчок по уведомлению: раздел, который открыть.
    var onOpen: ((SidebarSection?) -> Void)?

    /// VPN, которые на прошлой проверке были подключены (ключ — маршрут).
    var vpnUp: [String: Bool] = [:]
    /// Отложенные уведомления об отключении: VPN при переподключении пропадает на секунды.
    var vpnPending: [String: Task<Void, Never>] = [:]
    /// Об отключении уже сообщили — о возвращении тоже стоит.
    var vpnNotified: Set<String> = []
    var proxyStopPending: Task<Void, Never>?
    /// Категории уведомлений о новых приложениях по набору VPN (`newAppCategory`).
    var newAppCategories: [String: UNNotificationCategory] = [:]
    /// Кнопка уведомления (не щелчок по нему): идентификатор действия и `userInfo`.
    var onAction: ((String, [String: String]) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func post(id: String, title: String, body: String, section: SidebarSection? = nil, category: String? = nil,
              info: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var userInfo = info
        if let section { userInfo["section"] = section.rawValue }
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = self.center
        center.getNotificationSettings { settings in
            // Разрешения ещё не спрашивали (выключили и снова включили уведомления до запроса) — спросим сейчас.
            guard settings.authorizationStatus != .denied else { return }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            } else {
                center.add(request)
            }
        }
    }

    func remove(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // Показывать и поверх открытого окна: строка меню — не «на переднем плане» в смысле пользователя.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo.reduce(into: [String: String]()) { out, kv in
            if let k = kv.key as? String, let v = kv.value as? String { out[k] = v }
        }
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                self.onOpen?(info["section"].flatMap(SidebarSection.init))
            } else if action != UNNotificationDismissActionIdentifier {
                self.onAction?(action, info)
            }
            completionHandler()
        }
    }
}

extension AppModel {
    private var notify: Bool { settings.notifications }

    /// VPN отключился, а через него идут приложения с правилами: какие заблокированы, какие ушли на запасной маршрут.
    /// Ждём 10 с — переподключение VPN (роуминг Wi-Fi, сон) не отключение.
    func updateVPNNotifications() {
        for r in vpnRoutes {
            let was = notifier.vpnUp[r.id]
            notifier.vpnUp[r.id] = r.up
            guard let was, was != r.up else { continue }
            let id = r.id
            notifier.vpnPending[id]?.cancel()
            if r.up {
                notifier.vpnPending[id] = nil
                notifier.remove(id: "vpn-down:\(id)")
                if notifier.vpnNotified.remove(id) != nil, enabled {
                    history.add(.vpnUp(name: r.name))
                    if notify {
                        notifier.post(id: "vpn-up:\(id)", title: String(localized: "\(r.name) снова подключён"),
                                      body: String(localized: "Приложения снова идут через него."), section: .routes)
                    }
                }
            } else {
                notifier.vpnPending[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, let self, self.route(id)?.up != true else { return }
                    self.notifyVPNDown(id)
                }
            }
        }
    }

    private func notifyVPNDown(_ id: String) {
        guard enabled, let r = route(id) else { return }
        let users = apps.filter { $0.running && rules[$0.bundleID]?.route == id }
        guard !users.isEmpty else { return }
        let blocked = users.filter { effective(for: $0.bundleID).route == nil }.map(\.name)
        let moved = users.compactMap { app in
            effective(for: app.bundleID).route.map { "\(app.name) → \(routeName($0))" }
        }
        var lines: [String] = []
        if !blocked.isEmpty {
            lines.append(String(localized: "Заблокированы (\(blocked.count)): \(blocked.joined(separator: ", "))"))
        }
        if !moved.isEmpty { lines.append(moved.joined(separator: ", ")) }
        notifier.vpnNotified.insert(id)
        history.add(.vpnDown(name: r.name, blocked: blocked, moved: moved))
        guard notify else { return }
        notifier.remove(id: "vpn-up:\(id)")
        notifier.post(id: "vpn-down:\(id)", title: String(localized: "\(r.name) отключился"),
                      body: lines.joined(separator: "\n"), section: .routes)
    }

    func notifyKillSwitchBlocking() {
        guard enabled else { return }
        history.add(.killSwitchBlocking)
        guard notify else { return }
        notifier.post(id: "kill-switch", title: String(localized: "Kill switch VPN блокирует «Напрямую»"),
                      body: String(localized: "Приложения «Напрямую» без сети. Проверьте помощника SplitPipe."),
                      section: .routes)
    }

    func notifyTemporaryRouteEnded(_ id: String, restored: String) {
        guard notify else { return }
        let name = appsByID[id]?.name ?? ProgramRule.path(id).map { ($0 as NSString).lastPathComponent } ?? id
        notifier.post(id: "temporary:\(id)", title: String(localized: "Временный маршрут \(name) закончился"),
                      body: String(localized: "Снова: \(routeName(restored))."), section: .apps)
    }

    /// Прокси остановился, хотя SplitPipe включён: система остановила расширение или оно упало. Замена расширения
    /// при обновлении тоже останавливает его — на неё и на повторный старт даём 15 с.
    func proxyStatusChanged(from previous: NEVPNStatus, to current: NEVPNStatus) {
        publishWidgetState()
        if current == .connected {
            notifier.proxyStopPending?.cancel()
            notifier.remove(id: "proxy-stopped")
            return
        }
        guard previous == .connected, current == .disconnected || current == .invalid else { return }
        notifier.proxyStopPending?.cancel()
        notifier.proxyStopPending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.proxy.wantsRunning,
                  self.proxy.status != .connected, self.proxy.status != .connecting else { return }
            self.history.add(.proxyStoppedUnexpectedly)
            guard self.notify else { return }
            self.notifier.post(id: "proxy-stopped", title: String(localized: "SplitPipe остановлен"),
                               body: String(localized: "Правила не действуют — трафик идёт как обычно. Включите SplitPipe снова."))
        }
    }
}

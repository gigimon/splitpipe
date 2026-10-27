import AppKit
import Foundation

extension AppModel {
    /// Переключает приложение на `route` на время. Временный поверх временного возвращается к исходному правилу.
    func setTemporaryRoute(_ route: String, for id: String, duration: TemporaryDuration) {
        let previous = temporaryRoutes[id].map(\.previous) ?? rules[id]
        applyRoute(route, for: id)
        temporaryRoutes[id] = TemporaryRoute(route: route, end: duration.end, previous: previous)
        history.add(.temporaryRouteStarted(app: id, route: route))
    }

    /// Варианты срока для приложения и маршрута: «до выхода» — только у запущенного приложения, «до отключения VPN» —
    /// только у маршрута через VPN.
    func temporaryDurations(for app: AppEntry, route: String) -> [TemporaryDuration] {
        TemporaryDuration.allCases.filter { d in
            switch d {
            case .untilQuit: app.running && !app.isProgram
            case .untilVPNDisconnect: RouteID.vpnKey(route) != nil
            default: true
            }
        }
    }

    /// Маршруты, на которые можно переключить приложение на время: кроме текущего и отключённых VPN.
    func temporaryCandidates(for id: String) -> [String] {
        let current = routeID(for: id)
        let all = [RouteID.system, RouteID.direct] + vpnRoutes.filter(\.up).map(\.id) + [RouteID.block]
        return all.filter { $0 != current }
    }

    /// Маршрут, к которому вернётся приложение.
    func routeAfterTemporary(_ temp: TemporaryRoute) -> String { temp.previous?.route ?? RouteID.system }

    /// Возвращает прежнее правило. `expired` — срок вышел сам (а не «Вернуть сейчас»): об этом — уведомление.
    func endTemporaryRoute(for id: String, expired: Bool = false) {
        guard let temp = temporaryRoutes.removeValue(forKey: id) else { return }
        // Правило поменяли мимо меню выбора (импорт): возвращать уже нечего.
        guard rules[id]?.route == temp.route else { return }
        rules[id] = temp.previous
        saveRulesAndPush()
        resetAfterRuleChange(id)
        history.add(.temporaryRouteEnded(app: id, restored: routeAfterTemporary(temp), expired: expired))
        if expired { notifyTemporaryRouteEnded(id, restored: routeAfterTemporary(temp)) }
    }

    /// Снимает временные маршруты, чей срок вышел. Вызывается по таймеру, при смене маршрутов и запуске/выходе приложений.
    func checkTemporaryRoutes() {
        guard !temporaryRoutes.isEmpty else { return }
        let now = Date()
        // Снятие меняет `temporaryRoutes` и через `saveRulesAndPush` снова вызывает эту проверку — идём по копии.
        for (id, temp) in temporaryRoutes {
            switch temp.end {
            case .at(let date):
                if date <= now { endTemporaryRoute(for: id, expired: true) }
            case .appQuit:
                if !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
                    endTemporaryRoute(for: id)
                }
            case .vpnDisconnect:
                if route(temp.route)?.up == true {
                    if temp.vpnDownSince != nil { temporaryRoutes[id]?.vpnDownSince = nil }
                } else if let since = temp.vpnDownSince {
                    if now.timeIntervalSince(since) >= TemporaryRoute.vpnGrace { endTemporaryRoute(for: id, expired: true) }
                } else {
                    temporaryRoutes[id]?.vpnDownSince = now
                }
            }
        }
    }
}

import Foundation
import WidgetKit

/// Публикует состояние для виджета и переключателя Control Center (`WidgetState` в App Group) и просит WidgetKit
/// их обновить — только когда что-то поменялось: перерисовка виджетов не бесплатна.
extension AppModel {
    /// Секрет для ссылок из своего виджета (`splitpipe://on?token=…`).
    var widgetToken: String {
        if let t = WidgetState.defaults?.string(forKey: WidgetState.tokenKey), !t.isEmpty { return t }
        let t = UUID().uuidString
        WidgetState.defaults?.set(t, forKey: WidgetState.tokenKey)
        return t
    }

    func publishWidgetState() {
        let st = status
        let code: WidgetState.Status = switch st {
        case .off: .off
        case .starting: .starting
        case .ok: .ok
        case .warn: .warn
        }
        let state = WidgetState(
            status: code,
            title: st.title, subtitle: statusSubtitle,
            vpns: vpnRoutes.filter(\.up).map(\.name),
            problems: enabled ? routeProblems.map(\.title) : [],
            traffic: widgetTraffic.map { String(localized: "Сегодня: \(formatBytes($0))") } ?? "",
            wanted: proxy.wantsRunning)
        guard state != WidgetState.load() else { return }
        state.save()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// Трафик через SplitPipe за сегодня — раз в минуту, из часовых интервалов расширения.
    func refreshWidgetTraffic() async {
        guard proxy.status == .connected,
              case .stats(let rows)? = await proxy.send(.stats(from: Calendar.current.startOfDay(for: Date()), bucket: 3600))
        else { return }
        widgetTraffic = rows.reduce(0) { $0 + $1.down + $1.up }
    }
}

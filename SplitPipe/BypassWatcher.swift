import AppKit
import Foundation

/// Сторож правил: соединения приложений с правилом, которые идут мимо расширения (открыты до SplitPipe, до смены
/// правила или сокетом, который расширение не перехватывает). Только показывает: строка в «Соединениях», отметка
/// у приложения, уведомление и событие истории; оборвать их — «Оборвать соединения».
///
/// Перехваченный TCP-сокет в процессе приложения — `CLOSED` (соединение держит расширение), так что мимо — это
/// `ESTABLISHED` в интернет. UDP не смотрим: отличить перехваченный UDP-сокет от прямого не удалось проверить.
extension AppModel {
    /// Раз в 15 с, пока SplitPipe включён.
    func scanBypass() {
        guard enabled, proxy.status == .connected, Date() >= bypassQuietUntil else {
            if !enabled, !bypassing.isEmpty { bypassing = [:] }
            return
        }
        // «По умолчанию» мимо расширения — то же, что через него: смотреть незачем.
        let watched = NSWorkspace.shared.runningApplications.compactMap { app -> (String, pid_t)? in
            guard let id = app.bundleIdentifier, let rule = rules[id], rule.route != RouteID.system else { return nil }
            return (id, app.processIdentifier)
        }
        guard !watched.isEmpty else {
            if !bypassing.isEmpty { bypassing = [:] }
            return
        }
        let roots = Dictionary(watched.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .utility) {
            var found: [String: Set<SocketConnection>] = [:]
            for pid in SocketScanner.allPids() {
                let root = roots[pid] != nil ? pid : SocketScanner.responsible(for: pid)
                guard let root, let app = roots[root] else { continue }
                let conns = SocketScanner.connections(of: pid, udp: false)
                if !conns.isEmpty { found[app, default: []].formUnion(conns) }
            }
            let result = found.mapValues { Array($0).sorted { $0.display < $1.display } }
            await MainActor.run { self.applyBypass(result) }
        }
    }

    private func applyBypass(_ found: [String: [SocketConnection]]) {
        let now = Date()
        for (app, conns) in found {
            let before = Set(bypassing[app] ?? [])
            let fresh = conns.filter { !before.contains($0) }
            for c in fresh where bypassSince[c] == nil { bypassSince[c] = now }
            guard !fresh.isEmpty else { continue }
            history.add(.bypassDetected(app: app, count: conns.count))
            // Не чаще раза в час на приложение: соединение, открытое до SplitPipe, может жить часами.
            if settings.notifications, now.timeIntervalSince(bypassNotifiedAt[app] ?? .distantPast) > 3600 {
                bypassNotifiedAt[app] = now
                notifier.post(id: "bypass:\(app)", title: String(localized: "\(appName(app)): соединения мимо SplitPipe"),
                              body: String(localized: "Соединений мимо правила «\(routeName(routeID(for: app)))»: \(conns.count). «Оборвать соединения» переключит их на правило."),
                              section: .apps)
            }
        }
        let alive = Set(found.values.joined())
        bypassSince = bypassSince.filter { alive.contains($0.key) }
        bypassing = found
    }

    /// После включения и смены правила помощник как раз сбрасывает старые соединения — не тревожим зря.
    func quietBypassWatch(for seconds: TimeInterval = 30) {
        bypassQuietUntil = Date().addingTimeInterval(seconds)
        bypassing = [:]
    }

    /// Строки «мимо SplitPipe» для ленты соединений.
    var bypassRecords: [FlowRecord] {
        bypassing.flatMap { app, conns in
            conns.map { c in
                FlowRecord(id: UInt64(truncatingIfNeeded: c.hashValue) | 1 << 63, date: bypassSince[c] ?? Date(), app: app,
                           process: nil, remote: c.display, host: nil, proto: "tcp", route: "", state: .bypass,
                           ruleRoute: rules[app]?.route, actualRoute: nil)
            }
        }
        .sorted { $0.date < $1.date }
    }
}

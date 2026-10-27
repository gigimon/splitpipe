import Foundation

struct RouteCheck {
    /// `skipped` — проверять сейчас нечего: «Напрямую» при выключенном SplitPipe (маршрут через интерфейс ставит
    /// помощник только при включённом).
    enum State { case running, ok, failed, skipped }

    var state: State
    var ip: String?
    var country: String?
    var millis: Int?
    var error: String?
    var at = Date()
    /// Проверка UDP (STUN); nil — ещё не проверяли.
    var udp: UDPCheck?
}

struct UDPCheck {
    var ip: String?
    var millis: Int?
    var error: String?
}

extension RouteCheck {
    enum UDPState { case ok, otherIP, failed }

    /// UDP работает, идёт другим путём (внешний IP не тот, что у TCP) или не отвечает.
    var udpState: UDPState? {
        guard let udp else { return nil }
        guard let udpIP = udp.ip else { return .failed }
        return ip == nil || ip == udpIP ? .ok : .otherIP
    }

    var udpSummary: String? {
        switch udpState {
        case .ok: String(localized: "работает · \(udp?.millis ?? 0) мс")
        case .otherIP: String(localized: "другой внешний IP: \(udp?.ip ?? "")")
        case .failed: udp?.error ?? String(localized: "нет ответа")
        case nil: nil
        }
    }
}

/// Kill switch VPN определяем по факту: приложение (обычный пользователь) через физический интерфейс не выходит.
enum KillSwitchState {
    case unknown
    case none
    /// Kill switch есть, расширение (root) выходит мимо него.
    case bypassed
    /// Kill switch есть, и расширение тоже не выходит: нужно pf-правило.
    case blocking
}

extension AppModel {
    func checkAll() {
        for r in routes where r.up { Task { await check(route: r.id) } }
    }

    /// Проверка, если маршрут ещё не проверяли или с прошлой проверки прошло больше 5 минут.
    func checkStale() {
        for r in routes where r.up {
            if let c = checks[r.id], c.state == .running || Date().timeIntervalSince(c.at) < 300 { continue }
            Task { await check(route: r.id) }
        }
    }

    /// Перепроверка «Напрямую» (и kill switch) через `seconds`: после пробуждения, включения SplitPipe, смены
    /// маршрута по умолчанию. Повторный вызов откладывает её: при переподключении Wi-Fi событий много.
    func scheduleDirectCheck(after seconds: Double) {
        directCheckWork?.cancel()
        directCheckWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.enabled, self.checks[RouteID.direct]?.state != .running else { return }
            await self.check(route: RouteID.direct)
        }
    }

    /// После смены сети перепроверяет маршруты, у которых поменялся интерфейс или адрес. При запуске — не нужно:
    /// это делает экран «Маршруты».
    func checkChangedRoutes() {
        var next: [String: String] = [:]
        for r in routes where r.up { next[r.id] = "\(r.interface ?? "")|\(r.address ?? "")" }
        let changed = next.keys.filter { routeSignatures[$0] != next[$0] }
        let first = routeSignatures.isEmpty
        routeSignatures = next
        guard !first, settings.checkOnNetworkChange, !changed.isEmpty else { return }
        Task {
            // VPN после подключения ещё пару секунд настраивает маршруты.
            try? await Task.sleep(for: .seconds(2))
            for id in changed where checks[id]?.state != .running { await check(route: id) }
        }
    }

    func check(route id: String) async {
        guard let iface = route(id)?.interface else {
            checks[id] = RouteCheck(state: .failed, error: String(localized: "маршрут недоступен"))
            return
        }
        if id == RouteID.direct, !enabled, !directUsable {
            checks[id] = RouteCheck(state: .skipped, error: String(localized: "проверяется при включённом SplitPipe"))
            return
        }
        checks[id] = RouteCheck(state: .running)
        // Из расширения (root) запрос идёт тем же путём, что и перенаправленный трафик, и проходит мимо kill switch.
        let viaExtension = proxy.status == .connected
        var result = ProbeResult(interface: iface, ok: false, body: "", millis: 0)
        var parsed: (ip: String, country: String?)?
        // Если не ответил никто, показываем ошибку основного сервиса: у запасных она обычно вторичная (DNS).
        var firstFailure: ProbeResult?
        var workedURL: String?
        for url in [Config.traceURL] + echoURLs where !url.isEmpty {
            result = await probe(iface, url: url, viaExtension: viaExtension)
            parsed = result.ok ? Self.parseIP(result.body) : nil
            if parsed != nil { workedURL = url; break }
            if firstFailure == nil { firstFailure = result }
        }
        if parsed == nil, let firstFailure { result = firstFailure }
        var check = parsed.map { RouteCheck(state: .ok, ip: $0.ip, country: $0.country, millis: result.millis) }
            ?? RouteCheck(state: .failed, error: Self.shortError(result.body))
        check.udp = await checkUDP(iface, viaExtension: viaExtension)
        checks[id] = check

        if id == RouteID.direct && viaExtension {
            // Тем же адресом, что ответил через расширение: `1.1.1.1` провайдер может блокировать, и провал
            // локального запроса к нему выглядел бы как kill switch (REVIEW3, 4.2).
            let local = await probeLocal(iface, url: workedURL ?? Config.traceURL)
            // Kill switch бывает только у подключённого VPN: без него провал — это сеть, а не kill switch.
            // Без scoped-маршрута через интерфейс не выходит никто — по провалу тоже нельзя судить.
            let vpnHoldsDefault = vpnRoutes.contains { $0.holdsDefault && $0.up }
            // Основной сигнал — помощник: действует ли его pf-правило (наш якорь вызывается раньше правил VPN-клиента).
            // Провал и через расширение при действующем правиле — это сеть, а не kill switch (REVIEW3, 4.2).
            let anchor = helper.status?.enabled == true ? helper.status?.anchorEffective : nil
            let state: KillSwitchState = local.ok ? .none
                : !vpnHoldsDefault || scopedRouteMissing ? .unknown
                : parsed != nil ? .bypassed
                : anchor == true ? .unknown : .blocking
            // Один провал — не тревога: сразу после сна и при переподключении Wi-Fi сети нет ни у кого.
            // Перепроверяем через 20 с и показываем «блокирует», только если провал повторился. Если помощник сам
            // говорит, что его правило не действует, — сразу.
            if state == .blocking, anchor != false, killSwitch != .blocking, !confirmingKillSwitch {
                confirmingKillSwitch = true
                killSwitchConfirm = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, let self, self.enabled else { return }
                    await self.check(route: RouteID.direct)
                }
            } else {
                killSwitchConfirm?.cancel()
                confirmingKillSwitch = false
                killSwitch = state
                killSwitchCheckedAt = Date()
            }
        }
    }

    /// Внешний IP по UDP (STUN) через тот же интерфейс: первый ответивший сервер.
    private func checkUDP(_ iface: String, viaExtension: Bool) async -> UDPCheck {
        var last = ProbeResult(interface: iface, ok: false, body: "", millis: 0)
        for server in Config.stunServers {
            if viaExtension {
                // Не отвечает — так и показываем: локальная проверка идёт другим путём и показала бы другую картину.
                if case .probe(let r)? = await proxy.send(.stun(interface: iface, server: server)) { last = r } else { last = Self.noExtension(iface) }
            } else {
                let local = localInterface(iface)
                last = await withCheckedContinuation { cont in
                    Probe.stun(server: server, interface: local, interfaceName: iface) { cont.resume(returning: $0) }
                }
            }
            if last.ok { return UDPCheck(ip: last.body, millis: last.millis) }
        }
        return UDPCheck(error: Self.shortError(last.body))
    }

    private func probe(_ iface: String, url: String, viaExtension: Bool) async -> ProbeResult {
        if viaExtension {
            if case .probe(let r)? = await proxy.send(.probe(interface: iface, url: url)) { return r }
            return Self.noExtension(iface)
        }
        return await probeLocal(iface, url: url)
    }

    private static func noExtension(_ iface: String) -> ProbeResult {
        ProbeResult(interface: iface, ok: false, body: "extension not responding", millis: 0)
    }

    /// Ответ Cloudflare trace (`ip=…`, `loc=NL`) или просто IP от echo-сервиса.
    static func parseIP(_ body: String) -> (ip: String, country: String?)? {
        if body.contains("ip=") {
            var ip: String?
            var loc: String?
            for line in body.split(separator: "\n") {
                if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
                if line.hasPrefix("loc=") { loc = String(line.dropFirst(4)) }
            }
            return ip.map { ($0, loc.flatMap { Locale.app.localizedString(forRegionCode: $0) }) }
        }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 45 || text.contains(" ") ? nil : (text, nil)
    }

    private static func shortError(_ body: String) -> String {
        if body.contains("timeout") { return String(localized: "нет ответа") }
        if body.contains("Network is down") || body.contains("unreachable") { return String(localized: "нет маршрута") }
        if body.contains("interface not found") { return String(localized: "интерфейс пропал") }
        if body.contains("extension not responding") { return String(localized: "расширение не ответило") }
        return String(localized: "ошибка")
    }

    /// Баннеры о том, что сейчас мешает маршрутизации.
    var routeProblems: [RouteProblem] {
        var out: [RouteProblem] = []
        // Маршрут ставит помощник, и только пока SplitPipe включён.
        if scopedRouteMissing, enabled, let iface = directRoute?.interface {
            out.append(RouteProblem(severity: .error, title: String(localized: "Нет маршрута через \(iface) — «Напрямую» не работает"),
                                    detail: helper.running ? String(localized: "Помощник ещё не восстановил маршрут.")
                                        : String(localized: "Маршрут ставит помощник — он не установлен или не отвечает."),
                                    fix: .bypass))
        }
        if killSwitch == .blocking, enabled {
            var detail = String(localized: "Нужно правило pf, которое пропускает SplitPipe мимо kill switch.")
            if let at = killSwitchCheckedAt {
                detail += " " + String(localized: "Проверено в \(at.formatted(date: .omitted, time: .shortened)).")
            }
            out.append(RouteProblem(severity: .error, title: String(localized: "Kill switch VPN блокирует «Напрямую»"),
                                    detail: detail, fix: .bypass))
        }
        for r in vpnRoutes where !r.up {
            let users = apps.filter { $0.running && rules[$0.bundleID]?.route == r.id }
            guard !users.isEmpty else { continue }
            let blocked = users.filter { effective(for: $0.bundleID).route == nil }.map(\.name)
            let moved = users.filter { effective(for: $0.bundleID).route != nil }
                .map { "\($0.name) → \(routeName(effective(for: $0.bundleID).route ?? ""))" }
            var parts: [String] = []
            if !blocked.isEmpty {
                let names = blocked.joined(separator: ", ")
                parts.append(blocked.count > 1 ? String(localized: "\(names) заблокированы") : String(localized: "\(names) заблокирован"))
            }
            if !moved.isEmpty { parts.append(moved.joined(separator: ", ")) }
            out.append(RouteProblem(severity: blocked.isEmpty ? .warning : .error,
                                    title: String(localized: "\(r.name) отключён — \(parts.joined(separator: "; "))"), detail: nil, fix: nil))
        }
        return out
    }
}

struct RouteProblem: Identifiable {
    enum Severity { case error, warning }
    enum Fix { case bypass }

    var severity: Severity
    var title: String
    var detail: String?
    var fix: Fix?
    var id: String { title }
}

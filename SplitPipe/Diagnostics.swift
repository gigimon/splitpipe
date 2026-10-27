import AppKit

struct DiagItem: Identifiable {
    enum Level { case running, ok, warn, fail, info }
    enum Fix { case installExtension, openExtensionSettings, enable, bypass, routes, helper }

    let id: String
    var level: Level
    var title: String
    var detail: String
    var fix: Fix?

    var fixTitle: String {
        switch fix {
        case .installExtension: String(localized: "Установить")
        case .openExtensionSettings: String(localized: "Открыть настройки")
        case .enable: String(localized: "Включить")
        case .bypass: String(localized: "Исправить")
        case .routes: String(localized: "Маршруты")
        case .helper: String(localized: "Установить")
        case nil: ""
        }
    }
}

extension AppModel {
    func runDiagnostics() {
        guard !diagnosticsRunning else { return }
        diagnosticsRunning = true
        diagnostics = []
        Task {
            await diagnose()
            diagnosticsRunning = false
        }
    }

    func apply(_ fix: DiagItem.Fix) {
        switch fix {
        case .installExtension: proxy.activateExtension()
        case .openExtensionSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        case .enable: setEnabled(true)
        case .bypass: fixBypass()
        case .routes: requestedSection = .routes
        case .helper: helper.install()
        }
    }

    /// Для проверок без интерфейса: `open SplitPipe.app --args -SPEnable YES -SPDiagnosticsOut /tmp/sp.txt`
    /// включает SplitPipe и записывает отчёт диагностики в файл; `-SPInstallHelper YES` регистрирует помощника, `-SPReset <bundle id>` сбрасывает соединения приложения мимо расширения.
    func runLaunchActions() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "SPEnable"), !enabled { setEnabled(true) }
        if defaults.bool(forKey: "SPInstallHelper"), helper.registration != .enabled { helper.install() }
        if let id = defaults.string(forKey: "SPReset") {
            for _ in 0..<20 where !helper.running { await helper.refresh(); try? await Task.sleep(for: .milliseconds(500)) }
            await resetBypassingConnections(of: [id])
        }
        guard let path = defaults.string(forKey: "SPDiagnosticsOut") else { return }
        // Сначала ждём проверку и обновление расширения: на время замены система останавливает прокси.
        for _ in 0..<120 where [.checking, .updating, .activating].contains(proxy.extensionState) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        for _ in 0..<120 where proxy.status != .connected { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(2))
        diagnosticsRunning = true
        diagnostics = []
        await diagnose()
        diagnosticsRunning = false
        try? diagnosticsReport().write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Проверка появляется со спиннером, потом заменяется результатом — так видно, что идёт работа.
    private func step(_ id: String, _ title: String, _ body: () async -> DiagItem) async {
        diagnostics.append(DiagItem(id: id, level: .running, title: title, detail: String(localized: "проверяю…")))
        let result = await body()
        if let i = diagnostics.firstIndex(where: { $0.id == id }) { diagnostics[i] = result }
    }

    private func diagnose() async {
        refresh()

        await step("ext", String(localized: "Сетевое расширение")) {
            switch proxy.extensionState {
            case .active:
                return DiagItem(id: "ext", level: .ok, title: String(localized: "Сетевое расширение"), detail: String(localized: "Установлено и разрешено"))
            case .awaitingApproval:
                return DiagItem(id: "ext", level: .fail, title: String(localized: "Сетевое расширение"),
                                detail: String(localized: "Ждёт разрешения в System Settings → Login Items & Extensions"), fix: .openExtensionSettings)
            case .notInstalled, .failed:
                return DiagItem(id: "ext", level: .fail, title: String(localized: "Сетевое расширение"),
                                detail: proxy.extensionState.title.capitalizedFirst, fix: .installExtension)
            default:
                return DiagItem(id: "ext", level: .info, title: String(localized: "Сетевое расширение"), detail: proxy.extensionState.title.capitalizedFirst)
            }
        }

        await step("proxy", "SplitPipe") {
            guard proxy.status == .connected else {
                return DiagItem(id: "proxy", level: .warn, title: "SplitPipe", detail: String(localized: "Выключен — правила не применяются"), fix: .enable)
            }
            guard case .status(let s)? = await proxy.send(.status) else {
                return DiagItem(id: "proxy", level: .fail, title: "SplitPipe", detail: String(localized: "Расширение не отвечает"))
            }
            providerStatus = s
            if s.uid != 0 {
                return DiagItem(id: "proxy", level: .fail, title: "SplitPipe",
                                detail: String(localized: "Расширение работает не от root — обход kill switch не сработает"))
            }
            return DiagItem(id: "proxy", level: .ok, title: "SplitPipe",
                            detail: manageAllApps ? String(localized: "Работает: правил \(rules.count), под управлением все приложения")
                                : String(localized: "Работает: правил \(rules.count), только приложения с правилами"))
        }

        await step("helper", String(localized: "Помощник")) {
            await helper.refresh()
            guard helper.running, let st = helper.status else {
                return DiagItem(id: "helper", level: .warn, title: String(localized: "Помощник"),
                                detail: String(localized: "\(helper.title.capitalizedFirst) — обход kill switch и маршрут через Wi-Fi/Ethernet не восстанавливаются сами"),
                                fix: helper.registration == .requiresApproval ? .openExtensionSettings : .helper)
            }
            let physical = st.physical ?? "—"
            let anchor = st.anchorInterfaces.isEmpty ? String(localized: "pf-правила нет")
                : String(localized: "pf-правило для \(st.anchorInterfaces.joined(separator: ", "))")
            var detail = !st.enabled ? String(localized: "Работает, обход kill switch выключен вместе со SplitPipe")
                : st.directUsable ? String(localized: "Держит обход kill switch: \(anchor), «Напрямую» через \(physical) работает")
                : String(localized: "Держит обход kill switch: \(anchor), маршрута через \(physical) нет")
            if let action = helper.lastActionText, let at = st.lastActionAt {
                let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.app))
                detail += "\n" + String(localized: "Последнее: \(action), \(time)")
            }
            if let error = helper.lastErrorText { detail += "\n" + String(localized: "Ошибка: \(error)") }
            if st.enabled, st.anchorEffective == false {
                let note = helper.pfNoteText ?? String(localized: "kill switch VPN перекрывает его")
                detail += "\n" + String(localized: "pf-правило не действует: \(note) — «Напрямую» заблокирован")
            }
            let ok = !st.enabled || (!st.anchorInterfaces.isEmpty && st.directUsable && st.lastError == nil && st.anchorEffective != false)
            return DiagItem(id: "helper", level: ok ? .ok : .warn, title: String(localized: "Помощник"), detail: detail)
        }

        if let net = providerStatus?.network, proxy.status == .connected {
            await step("ext-routes", String(localized: "Маршруты в расширении")) {
                let mismatched = routes.filter { net.interface(forRoute: $0.id) != $0.interface }
                // Интерфейс в таблице маршрутов есть, а в реестре `NWInterface` расширения — нет или с другим индексом:
                // соединения ждут его, потом уходят на запасной маршрут (REVIEW3, 4.8). Старое расширение пишет только имена.
                let known = providerStatus?.interfaces ?? []
                let unseen = known.contains { $0.contains("#") } ? routes.compactMap { r -> String? in
                    guard let name = net.interface(forRoute: r.id), r.kind == .vpn || net.directMode == .bound else { return nil }
                    return known.contains(net.binding(name)) ? nil : "\(r.name) (\(net.binding(name)))"
                } : []
                if mismatched.isEmpty, !unseen.isEmpty {
                    return DiagItem(id: "ext-routes", level: .warn, title: String(localized: "Маршруты в расширении"),
                                    detail: String(localized: "Расширение ещё не получило интерфейс от системы: \(unseen.joined(separator: ", ")) — новые соединения ждут его до 2 с, потом идут по запасному варианту"))
                }
                if mismatched.isEmpty {
                    return DiagItem(id: "ext-routes", level: .ok, title: String(localized: "Маршруты в расширении"),
                                    detail: String(localized: "Расширение само находит интерфейсы маршрутов и пересчитывает их при смене сети"))
                }
                let none = String(localized: "нет интерфейса")
                let list = mismatched.map {
                    String(localized: "\($0.name): \(net.interface(forRoute: $0.id) ?? none) вместо \($0.interface ?? none)")
                }
                return DiagItem(id: "ext-routes", level: .warn, title: String(localized: "Маршруты в расширении"),
                                detail: String(localized: "Расширение видит сеть иначе — \(list.joined(separator: ", "))")
                                    + (net.processesVisible ? "" : String(localized: ". Расширению недоступен список процессов.")))
            }
        }

        if let ps = providerStatus, proxy.status == .connected {
            await step("ext-rules", String(localized: "Правила в расширении")) {
                let expected = providerConfig().rules
                if ps.rules == expected && ps.configProblem == nil {
                    return DiagItem(id: "ext-rules", level: .ok, title: String(localized: "Правила в расширении"),
                                    detail: String(localized: "Совпадают с приложением"))
                }
                repushRules()
                let reason = ps.configProblem.map { String(localized: "Расширение не прочитало свою конфигурацию (\($0)).") }
                    ?? String(localized: "Расширение работает с другими правилами (\(ps.rules.count) вместо \(expected.count)).")
                return DiagItem(id: "ext-rules", level: .warn, title: String(localized: "Правила в расширении"),
                                detail: reason + " " + String(localized: "Правила отправлены заново."))
            }
        }

        let vpn = routes.first { $0.kind == .vpn && $0.holdsDefault && $0.up }
        await step("default", String(localized: "Маршрут по умолчанию")) {
            if let vpn {
                return DiagItem(id: "default", level: .ok, title: String(localized: "Маршрут по умолчанию"),
                                detail: String(localized: "Через \(vpn.name) (\(vpn.interface ?? "")) — «По умолчанию» значит через VPN"))
            }
            return DiagItem(id: "default", level: .info, title: String(localized: "Маршрут по умолчанию"),
                            detail: String(localized: "Напрямую — ни один VPN не держит маршрут по умолчанию"))
        }

        if let iface = directRoute?.interface {
            // Та же проверка, что у расширения и помощника (`NetworkState.directMode`), а не `route get -ifscope`:
            // без VPN тот успешен и без scoped-маршрута.
            await step("scoped", String(localized: "Маршрут через \(iface)")) {
                switch NetworkState.current().directMode {
                case .bound:
                    DiagItem(id: "scoped", level: .ok, title: String(localized: "Маршрут через \(iface)"),
                             detail: String(localized: "Есть — приложения «Напрямую» могут выходить через этот интерфейс"))
                case .system:
                    DiagItem(id: "scoped", level: .ok, title: String(localized: "Маршрут через \(iface)"),
                             detail: String(localized: "Не нужен — VPN не держит маршрут по умолчанию, «Напрямую» идёт по системному маршруту"))
                case .unavailable where !enabled:
                    DiagItem(id: "scoped", level: .info, title: String(localized: "Маршрут через \(iface)"),
                             detail: String(localized: "Нет — помощник ставит его, когда SplitPipe включён"))
                case .unavailable:
                    DiagItem(id: "scoped", level: .fail, title: String(localized: "Маршрут через \(iface)"),
                             detail: String(localized: "Нет собственного маршрута интерфейса — «Напрямую» не работает"), fix: .bypass)
                }
            }
        } else {
            diagnostics.append(DiagItem(id: "scoped", level: .fail, title: String(localized: "Сеть"), detail: String(localized: "Нет физического подключения")))
        }

        for r in routes {
            await step("route:\(r.id)", r.name) {
                guard r.up else {
                    let used = rules.values.contains { $0.route == r.id }
                    return DiagItem(id: "route:\(r.id)", level: used ? .fail : .info, title: r.name,
                                    detail: used ? String(localized: "Отключён — приложения с этим маршрутом не работают или ушли на запасной")
                                        : String(localized: "Отключён"),
                                    fix: used ? .routes : nil)
                }
                await check(route: r.id)
                let c = checks[r.id]
                if c?.state == .skipped {
                    return DiagItem(id: "route:\(r.id)", level: .info, title: r.name, detail: (c?.error ?? "").capitalizedFirst)
                }
                if c?.state == .ok {
                    let country = c?.country.map { " · \($0)" } ?? ""
                    let udp = c?.udpSummary.map { "\nUDP: \($0)" } ?? ""
                    return DiagItem(id: "route:\(r.id)", level: c?.udpState == .ok ? .ok : .warn, title: r.name,
                                    detail: String(localized: "Внешний IP \(c?.ip ?? "")\(country) · \(c?.millis ?? 0) мс") + udp)
                }
                return DiagItem(id: "route:\(r.id)", level: .fail, title: r.name,
                                detail: String(localized: "Проверка не прошла: \(c?.error ?? String(localized: "нет ответа"))"),
                                fix: r.kind == .direct ? .bypass : .routes)
            }
        }

        await step("killswitch", String(localized: "Kill switch VPN")) {
            switch killSwitch {
            case .bypassed:
                DiagItem(id: "killswitch", level: .ok, title: String(localized: "Kill switch VPN"),
                         detail: String(localized: "Включён в VPN-клиенте, обход для SplitPipe работает"))
            case .blocking:
                DiagItem(id: "killswitch", level: .fail, title: String(localized: "Kill switch VPN"),
                         detail: String(localized: "Включён и блокирует приложения «Напрямую» — нужно правило pf"), fix: .bypass)
            case .none:
                DiagItem(id: "killswitch", level: .info, title: String(localized: "Kill switch VPN"), detail: String(localized: "Не обнаружен"))
            case .unknown:
                DiagItem(id: "killswitch", level: .info, title: String(localized: "Kill switch VPN"),
                         detail: proxy.status != .connected
                            ? String(localized: "Неизвестно — проверка возможна, только когда SplitPipe включён")
                            : String(localized: "Неизвестно — сначала нужен маршрут через интерфейс"))
            }
        }

        if let vpn, let direct = checks[RouteID.direct], let viaVPN = checks[vpn.id],
           direct.state == .ok, viaVPN.state == .ok {
            await step("split", String(localized: "Разделение трафика")) {
                direct.ip != viaVPN.ip
                    ? DiagItem(id: "split", level: .ok, title: String(localized: "Разделение трафика"),
                               detail: String(localized: "Напрямую \(direct.ip ?? ""), через VPN \(viaVPN.ip ?? "") — адреса различаются"))
                    : DiagItem(id: "split", level: .warn, title: String(localized: "Разделение трафика"),
                               detail: String(localized: "Внешний IP одинаковый (\(direct.ip ?? "")) — «Напрямую» идёт через тот же выход, что и VPN"))
            }
        }

        let broken = apps.filter { $0.running && rules[$0.bundleID] != nil && hasProblem(effective(for: $0.bundleID)) }
        await step("rules", String(localized: "Правила")) {
            broken.isEmpty
                ? DiagItem(id: "rules", level: .ok, title: String(localized: "Правила"),
                           detail: rules.isEmpty ? String(localized: "Правил пока нет")
                            : String(localized: "Все запущенные приложения идут по своим маршрутам"))
                : DiagItem(id: "rules", level: .warn, title: String(localized: "Правила"),
                           detail: broken.map { "\($0.name): \(describe(effective(for: $0.bundleID)))" }.joined(separator: "\n"),
                           fix: .routes)
        }

        await step("dns", "DNS") {
            let servers = SystemTools.dnsServers()
            let viaVPN = vpn != nil
            return DiagItem(id: "dns", level: viaVPN ? .warn : .ok, title: "DNS",
                            detail: (servers.isEmpty ? String(localized: "Нет DNS-серверов") : servers.joined(separator: ", "))
                                + (viaVPN ? String(localized: " — приложения «Напрямую» тоже резолвят адреса через VPN. Отдельный DNS будет позже.") : ""))
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

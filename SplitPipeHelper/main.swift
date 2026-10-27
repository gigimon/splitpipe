import Foundation
import os
import SystemConfiguration

let log = Logger(subsystem: Config.logSubsystem, category: "helper")

/// Держит обход kill switch, пока SplitPipe включён: pf-правило, которое пропускает root (расширение) через
/// физический интерфейс, и scoped-маршруты этого интерфейса — только пока VPN держит маршрут по умолчанию.
/// Реагирует на события таблицы маршрутов (и сверяется по таймеру) — сам чинит то, что пропало после сна,
/// перезагрузки или переподключения VPN, и снимает свои маршруты, когда они больше не нужны.
final class Guardian: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.splitpipe.helper")
    private let stateURL = URL(fileURLWithPath: "/Library/Application Support/SplitPipe/helper.json")
    private var timer: DispatchSourceTimer?
    private let monitor = RouteMonitor()
    private let kernelEvents = KernelEventMonitor()
    private var tickWork: DispatchWorkItem?
    private var enabled = false
    private var anchorInterfaces: [String] = []
    private var lastAction: HelperEvent?
    private var lastActionAt: Date?
    private var lastError: HelperEvent?
    private var network = NetworkState()
    /// Физический интерфейс пропадал (сон, переподключение Wi-Fi) — свои маршруты пересоздать, когда он вернётся.
    /// Ядро их при этом не снимает, а host-маршрут, клонированный от них, пока линка не было, остаётся нерабочим
    /// и перехватывает адрес: 2026-10-19 так пропадал сервер Amnezia — handshake не уходил на en1, пока маршруты
    /// не сняли, и VPN висел в «reconnecting». Удаление маршрута удаляет и его клоны. Значение — причина для журнала.
    private var routesStale: String?
    /// Линк физического интерфейса моргнул или utun VPN пропал: свои маршруты сняты сразу, и до возврата host-маршрута
    /// VPN к серверу (или `vpnRouteWait`) заново не ставятся. Иначе первый handshake перезапущенного `amneziawg-go`
    /// уходит через наш маршрут с устаревшим адресом и теряется, а пересоздание по host-маршруту опаздывает на ~0,7 с:
    /// 2026-10-22 12:36 Amnezia после этого 86 минут висела в «reconnecting» (PLANS, «Разобрано»).
    private var waitingForVPNRoute: Date?
    private let vpnRouteWait: TimeInterval = 15
    /// Флаги линка по интерфейсам из `RTM_IFINFO` и `Active` из `State:/Network/Interface/<if>/Link` — реагируем на смену.
    private var linkUp: [String: Bool] = [:]
    private var linkActive: [String: Bool] = [:]
    private var store: SCDynamicStore?
    /// Держал ли VPN маршрут по умолчанию на прошлой сверке: на смене пишем состояние pf в журнал.
    private var vpnHeldDefault: Bool?
    private var anchorEffective: Bool?
    private var pfNote: HelperEvent?
    /// Проверка якоря — два запуска `pfctl`; при роуминге Wi-Fi сверки идут пачками, а pf так часто не меняется.
    private var anchorCheckedAt: Date?
    private let anchorCheckInterval: TimeInterval = 5
    /// Последнее состояние для XPC: ответ не ждёт, пока `tick()` запускает `pfctl` и `route`.
    private let statusLock = NSLock()
    private var published: Data?

    private struct Saved: Codable { var enabled: Bool }

    /// История для приложения: что помощник сделал и почему — в том числе ночью и при закрытом приложении.
    let events = EventJournal(source: .helper, url: URL(fileURLWithPath: "/Library/Application Support/SplitPipe/events.json"))

    /// `enabled` — намерение пользователя; обход держится, только пока прокси действительно работает. Расширение
    /// (root) раз в 10 с обновляет `heartbeat` в своём контейнере и удаляет его при остановке прокси. Иначе обход
    /// оставался бы и после смерти расширения, и сразу после загрузки — до запуска приложения (REVIEW3, 4.3).
    private static let extensionContainer = "/private/var/root/Library/Containers/\(Config.extensionBundleID)"
    private static let heartbeatPath = extensionContainer + "/Data/Library/Application Support/heartbeat"
    private let heartbeatMaxAge: TimeInterval = 60
    /// Как прокси выглядел на прошлой сверке — для журнала на смене.
    private var proxyState: String?
    private var proxyRecheck: DispatchWorkItem?

    func start() {
        queue.sync {
            enabled = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }?.enabled ?? false
            anchorInterfaces = loadedAnchorInterfaces()
            log.notice("helper started, enabled=\(self.enabled), anchor=\(self.anchorInterfaces, privacy: .public)")
            events.add(.helperStarted(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
            tick()
        }
        monitor.onEvent = { [weak self] change in
            guard let self else { return }
            // Журнал «кто и когда поменял маршрут»: pid отправителя, 0 — ядро.
            if let change { log.notice("route \(change.description, privacy: .public)") }
            // configd снимает обычный `default` через физический интерфейс, когда линк пропадает: tick может
            // не застать момент без сети, поэтому помечаем по событию.
            if let change, change.type == RTM_DELETE, change.route.prefix == 0, !change.route.scoped,
               !NetworkState.isTunnel(change.route.interface) {
                self.routesStale = "сеть пропадала"
            }
            // VPN-клиент снял свой маршрут по умолчанию: переподключение или перезапуск демона (Amnezia при роуминге
            // Wi-Fi перезапускает `amneziawg-go` через 50 мс после этого, handshake — через 200 мс). Снимаем свои
            // маршруты сейчас же, иначе handshake уйдёт через них — с устаревшим адресом после роуминга.
            if let change, change.type == RTM_DELETE, change.isDefault, !change.route.scoped,
               NetworkState.isTunnel(change.route.interface) {
                self.dropRoutes("VPN \(change.route.interface) снял маршрут по умолчанию",
                                .vpnDroppedDefault(interface: change.route.interface), awaitVPN: true)
            }
            // VPN-клиент вернул маршрут к своему серверу через физический интерфейс (переподключение): пока его не было,
            // ядро могло клонировать от нашего `128.0/1` host-маршрут к серверу — он перехватит адрес у маршрута VPN.
            // Так бывает и без пропажи `default`: при роуминге между точками mesh-сети линк моргает, DHCP заново
            // ставит тот же адрес, и наши маршруты держат старый (`Can't assign requested address`).
            if let change, change.type == RTM_ADD, change.route.prefix == 32, !change.route.scoped,
               !NetworkState.isTunnel(change.route.interface) {
                self.routesStale = "VPN вернул маршрут к серверу"
                self.waitingForVPNRoute = nil
                // Маршруты VPN по умолчанию идут следом за host-маршрутом в те же миллисекунды.
                self.scheduleTick(after: 0.2)
            }
            if change?.isDefault ?? true { self.scheduleTick() }
        }
        // Линк моргнул (роуминг Wi-Fi между точками, сон) или VPN-клиент удалил свой utun (перезапуск): снимаем свои
        // маршруты сразу, не дожидаясь сверки, — VPN-клиент перезапускает демон в ту же секунду.
        monitor.onLink = { [weak self] link in self?.linkChanged(link) }
        // DHCP заново поставил адрес физическому интерфейсу (после сна, при роуминге Wi-Fi): маршруты, созданные
        // до этого, держат старый адрес. Пересоздаём сразу — до переподключения VPN-клиента: его первый handshake
        // через устаревший маршрут теряется, повтор WireGuard через 5 с, а Amnezia ждёт меньше и бросает попытку.
        monitor.onAddress = { [weak self] iface in
            guard let self, !NetworkState.isTunnel(iface), iface == (self.network.physical ?? iface) else { return }
            self.routesStale = "адрес \(iface) назначен заново"
        }
        let routeEvents = monitor.start(queue: queue)
        if !routeEvents { log.error("routing socket unavailable, polling every 5 s") }
        startLinkWatch()
        kernelEvents.onEvent = { [weak self] event in self?.kernelEvent(event) }
        if !kernelEvents.start(queue: queue) {
            log.error("kernel event socket unavailable: \(String(cString: strerror(errno)), privacy: .public)")
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = routeEvents ? 30 : 5
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func setEnabled(_ on: Bool, reply: @escaping (Data?) -> Void) {
        queue.async {
            if self.enabled != on {
                self.enabled = on
                try? FileManager.default.createDirectory(at: self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(Saved(enabled: on)).write(to: self.stateURL)
                log.notice("bypass \(on ? "enabled" : "disabled", privacy: .public)")
            }
            self.tick()
            reply(self.report)
        }
    }

    /// `HelperStatus` и события для приложения (`HelperEvents`) в JSON.
    func currentStatus() -> Data? {
        statusLock.lock()
        let cached = published
        statusLock.unlock()
        return cached ?? queue.sync { report }
    }

    private var report: Data? {
        let status = HelperStatus(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                                  enabled: enabled, anchorInterfaces: anchorInterfaces, physical: network.physical,
                                  directUsable: network.directMode != .unavailable, lastAction: lastAction?.description,
                                  lastActionAt: lastActionAt, lastError: lastError?.description,
                                  anchorEffective: anchorEffective, pfNote: pfNote?.description)
        return HelperEvents.encode(status, HelperEvents(lastActionEvent: lastAction, lastErrorEvent: lastError,
                                                        pfNoteEvent: pfNote))
    }

    /// Несколько событий маршрутов подряд (VPN ставит `0/1`, `128.0/1` и host-маршрут) — одна сверка.
    private func scheduleTick(after delay: TimeInterval = 0.5) {
        tickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        tickWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Линк и utun

    /// `State:/Network/Interface/<if>/Link` → `Active`: configd публикует его по тому же событию ядра, что и
    /// `RTM_IFINFO`, — второй источник на случай, если флаги интерфейса не поменялись. Уведомления приходят на `queue`.
    private func startLinkWatch() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { store, keys, info in
            guard let info else { return }
            Unmanaged<Guardian>.fromOpaque(info).takeUnretainedValue().linkKeysChanged(store, keys as? [String] ?? [])
        }
        guard let store = SCDynamicStoreCreate(nil, "dev.splitpipe.helper" as CFString, callback, &context),
              SCDynamicStoreSetNotificationKeys(store, nil, ["State:/Network/Interface/[^/]+/Link"] as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            log.error("link watch unavailable: \(String(cString: SCErrorString(SCError())), privacy: .public)")
            return
        }
        self.store = store
    }

    private func linkKeysChanged(_ store: SCDynamicStore, _ keys: [String]) {
        for key in keys {
            let parts = key.split(separator: "/")
            guard parts.count == 5 else { continue }
            let iface = String(parts[3])
            let active = (SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any])?["Active"] as? Bool
            // configd уведомляет только о смене, так что и первое уведомление — смена линка.
            guard linkActive[iface] != active else { continue }
            linkActive[iface] = active
            linkChanged(RouteMonitor.Link(interface: iface, up: active == true, detached: false))
        }
    }

    /// Вызывать на `queue`.
    private func linkChanged(_ link: RouteMonitor.Link) {
        if NetworkState.isTunnel(link.interface) {
            // utun VPN удалён или лишился адреса: клиент перезапускает демон, его первый handshake — в ближайшие
            // доли секунды. Пропажа чужих utun (системные utun0–3 адресов не имеют и сюда не попадают) не важна.
            guard !link.up, isVPNTunnel(link.interface) else { return }
            dropRoutes("VPN \(link.interface) \(link.detached ? "удалён" : "потерял адрес")", .tunnelGone(interface: link.interface),
                       awaitVPN: true)
            return
        }
        guard isPhysical(link.interface) else { return }
        let was = linkUp[link.interface]
        linkUp[link.interface] = link.up
        // Первое наблюдение — только запоминаем; `RTM_IFINFO` приходит и без смены линка.
        guard was != nil, was != link.up else { return }
        dropRoutes("линк \(link.interface) \(link.up ? "вернулся" : "пропал")", .link(interface: link.interface, up: link.up),
                   awaitVPN: false)
    }

    /// События ядра о линке и Wi-Fi (`KernelEventMonitor`): при роуминге это единственный ранний сигнал.
    private func kernelEvent(_ event: KernelEventMonitor.Event) {
        switch event.kind {
        case .detaching, .detached:
            guard isVPNTunnel(event.interface) else { return }
            dropRoutes("VPN \(event.interface) удалён", .tunnelGone(interface: event.interface), awaitVPN: true)
        case .linkOff, .linkOn, .bssidChanged, .wifiLinkChanged:
            guard isPhysical(event.interface) else { return }
            dropRoutes("\(event.interface): \(event.kind)", .wifi(interface: event.interface, event: "\(event.kind)"),
                       awaitVPN: false)
        }
    }

    private func isVPNTunnel(_ iface: String) -> Bool {
        network.vpns[iface] != nil || network.defaultInterface == iface
    }

    private func isPhysical(_ iface: String) -> Bool {
        iface == network.physical || network.splitRoutes.contains(where: { $0.ours && $0.interface == iface })
    }

    /// Снимает свои маршруты сейчас. `awaitVPN` — VPN-клиент перезапускается: вернуть после его host-маршрута
    /// к серверу (`waitingForVPNRoute`); иначе (линк моргнул, VPN на месте) — на ближайшей сверке, уже свежими.
    private func dropRoutes(_ reason: String, _ code: RouteDropReason, awaitVPN: Bool) {
        if awaitVPN { waitingForVPNRoute = Date() }
        guard enabled else { return }
        network = NetworkState.current()
        guard network.splitRoutes.contains(where: \.ours) else { return }
        log.notice("\(reason, privacy: .public) — снимаю маршруты, верну \(awaitVPN ? "после host-маршрута VPN" : "свежими", privacy: .public)")
        removeRoutes(except: nil, journal: false)
        events.add(.routesDropped(code))
        publish()
        if !awaitVPN { scheduleTick(after: 1) }
    }

    /// Вызывать на `queue`.
    private func tick() {
        defer { publish() }
        // Таблица маршрутов не прочиталась — это не «сети нет»: ничего не снимаем до следующей сверки.
        // VPN-клиентов опознаём (обход всех процессов), только пока SplitPipe включён: выключенному нужны лишь
        // свои маршруты, чтобы их снять.
        guard let state = NetworkState.read(detectVPNs: enabled) else {
            log.error("routing table unreadable, skipping")
            return
        }
        // Откуда взят физический интерфейс и почему пропал (REVIEW3, 4.1): окно без него бывает при сне и роуминге.
        if state.physical != network.physical || (state.physical == nil && state.physicalVia != network.physicalVia) {
            log.notice("physical: \(self.network.physical ?? "-", privacy: .public) → \(state.physical ?? "-", privacy: .public) (\(state.physicalVia ?? "?", privacy: .public))")
        }
        network = state
        logPFOnVPNChange()
        guard enabled else {
            disarm()
            return
        }
        guard proxyRunning() else {
            if !anchorInterfaces.isEmpty || network.splitRoutes.contains(where: \.ours) { fail(.proxyNotRunning) }
            disarm()
            // Прокси запускается после помощника (загрузка, включение): не ждём таймера в 30 с.
            let work = DispatchWorkItem { [weak self] in self?.tick() }
            proxyRecheck?.cancel()
            proxyRecheck = work
            queue.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        // Правило могли сбросить снаружи (VPN-клиент перезагружает свой файрвол) — сверяемся с pf каждый раз.
        anchorInterfaces = loadedAnchorInterfaces()
        // Без сети (переподключение Wi-Fi) ничего не трогаем, только помечаем свои маршруты к пересозданию.
        guard let physical = network.physical else {
            routesStale = "сеть пропадала"
            return
        }
        reconcileRoutes(physical)
        let reloaded = anchorInterfaces != [physical]
        if reloaded { loadAnchor([physical]) }
        checkAnchorEffective(force: reloaded)
    }

    private func disarm() {
        if !anchorInterfaces.isEmpty { flushAnchor() }
        removeRoutes(except: nil)
        anchorEffective = nil
        anchorCheckedAt = nil
        pfNote = nil
    }

    /// Перед завершением процесса (SIGTERM, перезапуск, замена бинаря): pf-правило и маршруты живут в ядре и после
    /// смерти помощника. Новый помощник взведёт их заново, если прокси работает.
    /// `reason` — для истории: `signal`, `replaced`, `restart`.
    func shutdown(_ reason: String) {
        queue.sync {
            network = NetworkState.current()
            anchorInterfaces = loadedAnchorInterfaces()
            disarm()
            log.notice("helper exiting: bypass removed")
            events.add(.helperExiting(reason: reason))
            events.flush()
        }
    }

    /// Работает ли прокси: по свежести heartbeat. Если контейнер расширения не найден или не читается (защита данных
    /// приложений), — хотя бы по процессу расширения; это слабее: процесс живёт и после остановки прокси.
    private func proxyRunning() -> Bool {
        var st = stat()
        let state: String
        let running: Bool
        if stat(Self.heartbeatPath, &st) == 0 {
            let age = Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec)
            running = age < heartbeatMaxAge
            state = running ? "heartbeat" : "heartbeat stale"
        } else if errno == ENOENT, stat(Self.extensionContainer, &st) == 0 {
            running = false
            state = "no heartbeat"
        } else {
            running = Self.extensionProcessRunning()
            state = "process \(running ? "running" : "not found") (heartbeat unreadable: \(String(cString: strerror(errno))))"
        }
        if state != proxyState {
            log.notice("proxy: \(state, privacy: .public)")
            proxyState = state
        }
        return running
    }

    private static func extensionProcessRunning() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(max(n, 0))).contains { pid in
            pid > 0 && proc_pidpath(pid, &buf, UInt32(buf.count)) > 0
                && String(cString: buf).hasSuffix(".systemextension/Contents/MacOS/\(Config.extensionBundleID)")
        }
    }

    // MARK: - Журнал pf

    /// VPN потерял или вернул маршрут по умолчанию — пишем состояние pf: что VPN-клиент делает со своим kill switch
    /// и почему наше правило перестаёт действовать. Клиент перезагружает pf не сразу — вторая запись через 3 с.
    private func logPFOnVPNChange() {
        let holds = network.vpnHoldsDefault
        defer { vpnHeldDefault = holds }
        guard let was = vpnHeldDefault, was != holds else { return }
        let reason = holds ? "VPN вернул маршрут по умолчанию" : "VPN потерял маршрут по умолчанию"
        logPF(reason)
        if !holds {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.logPF("\(reason), через 3 с")
                if self.enabled { self.checkAnchorEffective(force: true); self.publish() }
            }
        }
    }

    private func logPF(_ reason: String) {
        let info = Self.run("/sbin/pfctl", ["-s", "info"]).split(separator: "\n").prefix(1).joined()
        let main = Self.run("/sbin/pfctl", ["-sr"])
        let anchors = Self.run("/sbin/pfctl", ["-sA"])
        let amn = Self.run("/sbin/pfctl", ["-a", "amn", "-sA"])
        let ours = Self.run("/sbin/pfctl", ["-a", HelperConfig.pfAnchor, "-sr"])
        log.notice("pf: \(reason, privacy: .public)\n\(info, privacy: .public)\nmain:\n\(Self.pfErrors(main), privacy: .public)\nanchors:\n\(Self.pfErrors(anchors), privacy: .public)\namn:\n\(Self.pfErrors(amn), privacy: .public)\nours:\n\(Self.pfErrors(ours), privacy: .public)")
    }

    // MARK: - Действует ли якорь

    /// Наш якорь вызывается из общего набора правил (`anchor "com.apple/*"`), и перед ним нет чужих якорей и правил
    /// `block … quick`: иначе kill switch VPN-клиента отбрасывает пакеты раньше, чем дойдёт до нашего `pass … quick`.
    /// Не чаще раза в `anchorCheckInterval`, если правило только что не перезагружали (`force`).
    private func checkAnchorEffective(force: Bool = false) {
        if !force, let at = anchorCheckedAt, Date().timeIntervalSince(at) < anchorCheckInterval { return }
        anchorCheckedAt = Date()
        let (effective, note) = Self.anchorEffect(info: Self.run("/sbin/pfctl", ["-s", "info"]),
                                                  main: Self.run("/sbin/pfctl", ["-sr"]))
        if effective != anchorEffective || note != pfNote {
            if effective {
                log.notice("pf anchor effective\(note.map { ": \($0)" } ?? "", privacy: .public)")
            } else {
                log.error("pf anchor not effective: \(note?.description ?? "", privacy: .public)")
            }
        }
        anchorEffective = effective
        pfNote = note
    }

    static func anchorEffect(info: String, main: String) -> (Bool, HelperEvent?) {
        if info.contains("Status: Disabled") { return (true, .pfDisabled) }
        let rules = main.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("scrub") && !noise.contains(where: $0.contains) }
        let ours = rules.firstIndex { $0.hasPrefix("anchor \"com.apple/*\"") || $0.hasPrefix("anchor \"com.apple/splitpipe\"") }
        guard let ours else { return (false, .anchorNotCalled) }
        if let blocker = rules.prefix(ours).first(where: { r in
            (r.hasPrefix("anchor") && !r.hasPrefix("anchor \"com.apple")) || (r.hasPrefix("block") && r.contains(" quick"))
        }) {
            return (false, .anchorShadowed(rule: blocker))
        }
        return (true, nil)
    }

    private static let noise = ["Use of -f option", "present in the main ruleset", "See /etc/pf.conf", "ALTQ"]

    private func publish() {
        let s = report
        statusLock.lock()
        published = s
        statusLock.unlock()
    }

    // MARK: - Scoped-маршруты

    /// Без scoped-маршрута привязка к интерфейсу при VPN, держащем `0/1` + `128.0/1`, даёт `Network is down` —
    /// «Напрямую» не работает. Без VPN поиск в области интерфейса и так находит обычный `default`, маршрут не нужен.
    /// Ставим пару `0/1` + `128.0/1`, а не второй `default`: появление и пропажа маршрута по умолчанию для мониторов
    /// VPN-клиентов выглядит как смена шлюза и запускает переподключение.
    private func reconcileRoutes(_ physical: String) {
        // Роутер сменился при том же адресе (или DHCP выдал другой шлюз): маршруты со старым шлюзом не работают.
        if let gateway = network.physicalGateway,
           network.splitRoutes.contains(where: { $0.ours && $0.interface == physical && $0.gateway != nil && $0.gateway != gateway }) {
            routesStale = "шлюз \(physical) сменился на \(gateway)"
        }
        if let reason = routesStale {
            routesStale = nil
            if network.splitRoutes.contains(where: \.ours) {
                log.notice("\(reason, privacy: .public) — пересоздаю маршруты через \(physical, privacy: .public)")
                removeRoutes(except: nil)
            }
        }
        // Ставятся, когда VPN держит маршрут по умолчанию, а снимаются только вместе со SplitPipe, сменой
        // физического интерфейса или морганием линка: без VPN они безвредны (ведут на тот же шлюз, что и `default`),
        // а снятие по уходу VPN меняло привязку «Напрямую» дважды — два обрыва на каждое переподключение VPN (REVIEW2, P1).
        // configd ставит свой scoped `default`, если интерфейс не основной: тогда свои маршруты не нужны.
        let needed = !network.scopedDefault
        removeRoutes(except: needed ? physical : nil)
        guard network.vpnHoldsDefault && !network.physicalScoped else { return }
        // После моргания линка или перезапуска VPN ждём host-маршрут к серверу: VPN без него (Network Extension)
        // в наших маршрутах не нуждается, но на всякий случай — не дольше `vpnRouteWait`.
        if let since = waitingForVPNRoute {
            guard Date().timeIntervalSince(since) >= vpnRouteWait else {
                scheduleTick(after: vpnRouteWait - Date().timeIntervalSince(since) + 0.1)
                return
            }
            log.notice("VPN не вернул host-маршрут за \(Int(self.vpnRouteWait)) с — ставлю маршруты без него")
            waitingForVPNRoute = nil
        }
        addRoutes(physical)
    }

    private func addRoutes(_ iface: String) {
        guard let gateway = network.physicalGateway else {
            fail(.noGateway(interface: iface))
            return
        }
        let present = Set(network.splitRoutes.filter { $0.interface == iface }.map(\.upper))
        var errors: [String] = []
        for upper in [false, true] where !present.contains(upper) {
            let route = SplitRoute(interface: iface, upper: upper, ours: true)
            // По коду возврата: «File exists» тоже начинается с `add net`.
            let (out, status) = Self.execute("/sbin/route", ["-n", "add", "-ifscope", iface, "-net", route.destination, gateway, "-proto2"])
            if status != 0 { errors.append(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        network = NetworkState.current()
        if network.physicalScoped {
            did(.routesRestored(interface: iface, gateway: gateway))
        } else {
            fail(.routesNotRestored(interface: iface, output: errors.joined(separator: "; ")))
        }
    }

    /// Снимает свои маршруты (помеченные `RTF_PROTO2`) на всех интерфейсах, кроме `keep`.
    /// `journal: false` — причину в историю пишет вызывающий (`routesDropped`).
    private func removeRoutes(except keep: String?, journal: Bool = true) {
        let stale = network.splitRoutes.filter { $0.ours && $0.interface != keep }
        guard !stale.isEmpty else { return }
        for route in stale {
            Self.run("/sbin/route", ["-n", "delete", "-ifscope", route.interface, "-net", route.destination])
        }
        network = NetworkState.current()
        did(.routesRemoved(interfaces: Set(stale.map(\.interface)).sorted()), journal: journal)
    }

    // MARK: - pf

    private func loadAnchor(_ ifs: [String]) {
        // Без состояний, как у Amnezia: у `keep state` по умолчанию `flags S/SA` — правило совпадает только с SYN,
        // остальные пакеты идут по таблице состояний. Пока VPN-клиент держит pf выключенным (переподключение) или
        // сбрасывает состояния, у открытых соединений записей нет, и они упираются в его `block out all`.
        // `flags any` обязателен: без него и `no state` получает `flags S/SA`.
        let rules = ifs.map { "pass out quick on \($0) user root flags any no state\n" }.joined()
        let out = Self.run("/sbin/pfctl", ["-a", HelperConfig.pfAnchor, "-f", "-"], input: rules)
        anchorInterfaces = loadedAnchorInterfaces()
        if anchorInterfaces == ifs {
            did(.bypassEnabled(interfaces: ifs))
        } else {
            fail(.anchorNotLoaded(output: Self.pfErrors(out)))
        }
    }

    private func flushAnchor() {
        _ = Self.run("/sbin/pfctl", ["-a", HelperConfig.pfAnchor, "-F", "rules"])
        anchorInterfaces = loadedAnchorInterfaces()
        if anchorInterfaces.isEmpty { did(.bypassDisabled) }
    }

    /// Интерфейсы из загруженного правила: `pass out quick on en1 all user = 0 flags any no state`. Правило старой
    /// версии помощника (`keep state`) помечается — не совпадёт с нужным и перезагрузится, а при выключении снимется.
    private func loadedAnchorInterfaces() -> [String] {
        Self.run("/sbin/pfctl", ["-a", HelperConfig.pfAnchor, "-sr"]).split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ")
            guard words.starts(with: ["pass", "out", "quick", "on"]), words.count > 4 else { return nil }
            return line.contains("no state") ? String(words[4]) : "\(words[4]) keep state"
        }
    }

    /// Предупреждения, которые pfctl пишет всегда, — не ошибки.
    private static func pfErrors(_ out: String) -> String {
        let noise = ["Use of -f option", "present in the main ruleset", "See /etc/pf.conf", "ALTQ"]
        return out.split(separator: "\n").filter { line in !noise.contains { line.contains($0) } }.joined(separator: "; ")
    }

    // MARK: -

    private func did(_ action: HelperEvent, journal: Bool = true) {
        lastAction = action
        lastActionAt = Date()
        lastError = nil
        log.notice("\(action.description, privacy: .public)")
        if journal { events.add(.helper(action)) }
    }

    private func fail(_ error: HelperEvent) {
        // Одна и та же ошибка на каждой сверке не нужна ни в логе, ни в истории.
        if lastError != error {
            log.error("\(error.description, privacy: .public)")
            events.add(.helper(error))
        }
        lastError = error
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil) -> String {
        execute(path, args, input: input).output
    }

    /// Сколько ждать `pfctl` и `route`: зависший процесс иначе встал бы очередь помощника навсегда (REVIEW3, 5).
    static let commandTimeout: TimeInterval = 15

    /// Вывод (stdout и stderr вместе) и код возврата; -1 — не запустился, SIGTERM (15) — не уложился в `commandTimeout`.
    static func execute(_ path: String, _ args: [String], input: String? = nil) -> (output: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { return ("\(error)", -1) }
        if let input {
            // Пишем в фоне: иначе при большом выводе процесс и мы ждали бы друг друга на заполненных pipe.
            let handle = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                handle.write(Data(input.utf8))
                try? handle.close()
            }
        }
        let timer = DispatchWorkItem {
            guard p.isRunning else { return }
            log.error("\(path, privacy: .public) \(args.joined(separator: " "), privacy: .public) timed out after \(Int(commandTimeout)) s")
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
}

/// Текст для журнала и строк `HelperStatus` — прежний, на русском: журнал не переводится, на языке пользователя
/// текст собирает приложение.
extension HelperEvent: CustomStringConvertible {
    var description: String {
        switch self {
        case .routesRestored(let iface, let gateway): "восстановлен маршрут через \(iface) (\(gateway))"
        case .routesRemoved(let ifs): "сняты маршруты через \(ifs.joined(separator: ", "))"
        case .bypassEnabled(let ifs): "обход kill switch через \(ifs.joined(separator: ", "))"
        case .bypassDisabled: "обход kill switch выключен"
        case .noGateway(let iface): "нет шлюза у \(iface)"
        case .routesNotRestored(let iface, let output): "маршрут через \(iface) не восстановлен: \(output)"
        case .anchorNotLoaded(let output): "pf-правило не загрузилось: \(output)"
        case .pfDisabled: "pf выключен — обход не нужен"
        case .anchorNotCalled: "в общем наборе правил pf нет вызова anchor \"com.apple/*\""
        case .anchorShadowed(let rule): "раньше нашего якоря в pf стоит: \(rule)"
        case .proxyNotRunning: "прокси SplitPipe не работает — обход kill switch снят"
        }
    }
}

final class HelperService: NSObject, HelperProtocol {
    private let guardian: Guardian
    private let resetter: ConnectionResetter
    init(_ guardian: Guardian, _ resetter: ConnectionResetter) {
        self.guardian = guardian
        self.resetter = resetter
    }

    func resetConnections(_ pids: Data, reply: @escaping (Int) -> Void) {
        let list = (try? JSONDecoder().decode([Int32].self, from: pids)) ?? []
        DispatchQueue.global().async { reply(self.resetter.reset(pids: list)) }
    }

    func setEnabled(_ enabled: Bool, reply: @escaping (Data?) -> Void) {
        guardian.setEnabled(enabled, reply: reply)
    }

    func status(reply: @escaping (Data?) -> Void) {
        reply(guardian.currentStatus())
    }

    func restart(reply: @escaping () -> Void) {
        log.notice("restart requested")
        reply()
        // KeepAlive: launchd сразу запустит бинарь из обновлённого приложения.
        let guardian = self.guardian, resetter = self.resetter
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            guardian.shutdown("restart")
            resetter.shutdown()
            exit(0)
        }
    }

    func events(after: UInt64, journal: String?, reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(guardian.events.batch(after: after, journal: journal)))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let guardian: Guardian
    let resetter: ConnectionResetter
    init(_ guardian: Guardian, _ resetter: ConnectionResetter) {
        self.guardian = guardian
        self.resetter = resetter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService(guardian, resetter)
        connection.resume()
        return true
    }
}

/// Приложение обновили (бинарь помощника удалён или заменён): код процесса больше не совпадает с подписью на диске,
/// и приложение отклоняет подключение к нему — попросить о перезапуске по XPC уже нельзя. Завершаемся сами,
/// launchd (`KeepAlive`) запустит новую версию.
func exitWhenReplaced(cleanup: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
    guard let path = Bundle.main.executablePath else { return nil }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .write],
                                                           queue: .global())
    source.setEventHandler {
        log.notice("helper binary replaced, exiting for relaunch")
        // Новая копия приложения ещё может дописываться — даём ей пару секунд.
        // Приложение могли и удалить: тогда нового помощника не будет, а правила остались бы в ядре.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { cleanup(); exit(0) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    return source
}

let guardian = Guardian()
guardian.start()
let resetter = ConnectionResetter()
resetter.start()
let binaryWatch = exitWhenReplaced { guardian.shutdown("replaced"); resetter.shutdown() }
// launchd останавливает помощника SIGTERM (bootout, удаление из Login Items): снимаем обход перед выходом.
let signalSources = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        log.notice("signal \(sig), exiting")
        guardian.shutdown("signal")
        resetter.shutdown()
        exit(0)
    }
    source.resume()
    return source
}
let delegate = ListenerDelegate(guardian, resetter)
let listener = NSXPCListener(machServiceName: HelperConfig.machService)
// Подключения только от SplitPipe, подписанного нашей командой: помощник работает от root.
listener.setConnectionCodeSigningRequirement(HelperConfig.appRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()

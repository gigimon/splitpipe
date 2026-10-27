import Foundation
import Network
import NetworkExtension
import os

let logger = Logger(subsystem: Config.logSubsystem, category: "proxy")

/// DNS всегда идёт по системному маршруту: системный резолвер обычно живёт внутри VPN (у Amnezia это 172.29.172.254)
/// и через физический интерфейс недоступен. Отдельный DNS для «Напрямую» — этап 4.
func isDNS(_ endpoint: Network.NWEndpoint) -> Bool {
    if case .hostPort(_, let port) = endpoint { return port.rawValue == 53 }
    return false
}

extension Network.NWEndpoint {
    /// `1.2.3.4:443`, `[2001:db8::1]:443` — системное описание пишет порт IPv6 через точку.
    var display: String {
        guard case .hostPort(let host, let port) = self else { return debugDescription }
        switch host {
        case .ipv6(let a): return "[\(a.debugDescription.components(separatedBy: "%").first ?? "")]:\(port.rawValue)"
        case .ipv4(let a): return "\(a.debugDescription.components(separatedBy: "%").first ?? ""):\(port.rawValue)"
        case .name(let n, _): return "\(n):\(port.rawValue)"
        @unknown default: return debugDescription
        }
    }
}

extension Network.NWEndpoint {
    var isIPv6: Bool {
        if case .hostPort(.ipv6, _) = self { return true }
        return false
    }

    var portNumber: UInt16? {
        if case .hostPort(_, let port) = self { return port.rawValue }
        return nil
    }

    /// Частные, link-local, loopback, multicast и broadcast, CGNAT (`100.64/10`: Tailscale, сети провайдера) —
    /// локальная сеть или внутренние сети VPN, в интернет через привязанный интерфейс им не надо (REVIEW2/3).
    var isLocal: Bool {
        guard case .hostPort(let host, _) = self else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254) || b[0] == 127 || (224...239).contains(b[0])
                || b.allSatisfy { $0 == 255 } || (b[0] == 100 && b[1] & 0xc0 == 64)
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            return (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] & 0xfe == 0xfc || b[0] == 0xff
                || (b.dropLast().allSatisfy { $0 == 0 } && b.last == 1)
        default:
            return false
        }
    }
}

protocol Relay: AnyObject {
    var stats: FlowStats { get }
    /// Обрывает соединение, чтобы приложение переподключилось по новому маршруту.
    func abort()
}

private enum Decision {
    /// Перекачивать через интерфейс; nil — по системному маршруту. `label` — имя маршрута для ленты,
    /// `route` — фактический маршрут для статистики («По умолчанию» — тот, что сейчас держит маршрут по умолчанию).
    /// `defaultVia` — интерфейс маршрута по умолчанию у соединения по системному маршруту.
    case relay(NWInterface?, label: String, route: String, defaultVia: String? = nil)
    /// Ядро интерфейс маршрута уже знает, а `NWPathMonitor` — ещё нет (VPN только что поднял utun): `requiredInterface`
    /// поставить не на что. Это не «маршрут недоступен»: новое соединение подождёт, открытое не обрывается (REVIEW3, 4.8).
    case pending(interface: String, binding: String)
    case block

    /// Куда фактически привязано соединение: если это меняется, соединение надо оборвать. По индексу, а не только
    /// по имени: VPN, пересоздавший `utun4` под тем же именем, — это уже другой интерфейс. У соединения по системному
    /// маршруту — интерфейс маршрута по умолчанию: открытое через en1, пока VPN переподключался, иначе так и живёт
    /// мимо его kill switch (расширение — root, обход pf) после возвращения VPN.
    var binding: String {
        switch self {
        case .relay(let iface?, _, _, _): Self.binding(iface)
        case .relay(nil, _, _, let via): via.map { "system:\($0)" } ?? "system"
        case .pending(_, let binding): binding
        case .block: "block"
        }
    }

    static func binding(_ iface: NWInterface) -> String { "\(iface.name)#\(iface.index)" }

    /// Привязка к интерфейсу, а не системный маршрут или блок: её короткую пропажу можно переждать.
    static func isInterface(_ binding: String) -> Bool { binding != "block" && !binding.hasPrefix("system") }
}

private struct ActiveRelay {
    var app: String
    var rule: AppRule
    /// Правило для приложений без правила.
    var managed: Bool
    var binding: String
    var relay: Relay
    var recordID: UInt64
    /// Фактический маршрут и сколько байт уже учтено в статистике.
    var route: String
    var countedOut: Int64 = 0
    var countedIn: Int64 = 0
    /// Привязка к интерфейсу пропала: с какого момента. Вернётся за `flapGrace` — соединение не обрываем.
    var staleSince: Date?
    /// Адрес назначения: по нему правило списка IP пересчитывается при смене списков и правил.
    var endpoint: Network.NWEndpoint?
}

final class TransparentProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling {
    private let lock = NSLock()
    private var config = ProviderConfig()
    private var relays: [ObjectIdentifier: ActiveRelay] = [:]
    /// Последние соединения для ленты в приложении, по порядку появления.
    private var records: [UInt64: FlowRecord] = [:]
    private var order: [UInt64] = []
    /// Сколько последних соединений видит лента.
    private static let recordLimit = 400
    private var nextID: UInt64 = 1
    private let interfaces = InterfaceRegistry()
    /// Привязки к интерфейсам, которых реестр `NWInterface` не дождался: новые соединения к ним уже не ждут.
    /// Сбрасывается, когда реестр меняется.
    private var unready: Set<String> = []
    private let waitQueue = DispatchQueue(label: "dev.splitpipe.wait")
    /// Подсети списков IP (под `lock`); на диске — `lists.json` в контейнере, переживают перезапуск.
    private var ipLists = IPListSet()
    /// Приложения без своего правила, чьи соединения видели (под `lock`), — для поиска новых приложений.
    private var unruledSeen: [String: Date] = [:]
    /// Те же списки в упакованном виде — для `lists.json`.
    private var compiledLists: [String: CompiledIPList] = [:]
    private let listsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("lists.json")
    private let owners = OwnerResolver()
    /// Сеть, по которой роли маршрутов превращаются в интерфейсы. Обновляется само, даже если приложение закрыто.
    private var network = NetworkState()
    private let networkQueue = DispatchQueue(label: "dev.splitpipe.network")
    private var networkTimer: DispatchSourceTimer?
    private var networkWork: DispatchWorkItem?
    private let routeMonitor = RouteMonitor()
    private let stats = TrafficStats()
    private var statsTimer: DispatchSourceTimer?
    /// Знак жизни для помощника: пока прокси работает, файл обновляется раз в 10 с; при остановке удаляется.
    /// Без него помощник держал бы обход kill switch и после смерти расширения (REVIEW3, 4.3).
    private let heartbeatURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("heartbeat")
    private let lastGoodConfigURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("config.json")
    /// Конфигурация не прочиталась при запуске; nil — всё в порядке или приложение уже прислало свою.
    private var configProblem: String?
    /// История: запуск и остановка прокси, смена сети, обрывы — забирает приложение (`.events`), в том числе то,
    /// что было, пока оно было закрыто.
    private let events = EventJournal(source: .proxy, url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("events.json"))

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        loadConfig()
        if let url = listsURL, let saved = try? JSONDecoder().decode([CompiledIPList].self, from: Data(contentsOf: url)) {
            storeLists(saved, keep: Set(config.lists.map(\.id)))
        }
        network = NetworkState.current()
        interfaces.onChange = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.unready.removeAll()
            self.lock.unlock()
            self.scheduleNetworkRefresh()
        }
        interfaces.start()
        routeMonitor.onEvent = { [weak self] change in
            if change?.isDefault ?? true { self?.scheduleNetworkRefresh() }
        }
        startNetworkTimer(events: routeMonitor.start(queue: networkQueue))
        startStatsTimer()
        touchHeartbeat()
        logger.notice("heartbeat: \(self.heartbeatURL?.path ?? "nil", privacy: .public)")
        logger.notice("network: \(self.network.summary, privacy: .public)")
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroup)
        logger.notice("app group container: \(group?.path ?? "nil", privacy: .public)")
        logger.notice("start proxy uid=\(getuid()) rules=\(self.config.rules.count) manageAll=\(self.config.manageAllApps)")
        events.add(.proxyStarted(rules: config.rules.count, manageAll: config.manageAllApps))
        if let configProblem { events.add(.configProblem(configProblem)) }

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0, localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .UDP, direction: .outbound),
        ]
        // Loopback не перехватываем вовсе: у приложения «Напрямую» `requiredInterface = en1` не дал бы подключиться
        // к локальному dev-серверу, `ssh -D` или локальному прокси (REVIEW2, P1).
        settings.excludedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: .hostPort(host: "127.0.0.0", port: 0), remotePrefix: 8,
                          localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: .hostPort(host: "::1", port: 0), remotePrefix: 128,
                          localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
        ]
        setTunnelNetworkSettings(settings) { error in
            if let error { logger.error("settings failed: \(error.localizedDescription, privacy: .public)") }
            completionHandler(error)
        }
    }

    /// Конфигурация из настроек прокси; не прочиталась — последняя рабочая (`config.json`, её пишет `setConfig`).
    /// Нет и её — пустая, но с `configProblem`: приложение увидит это в статусе и пришлёт свою.
    private func loadConfig() {
        let data = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["config"] as? Data
        if let data, let saved = try? JSONDecoder().decode(ProviderConfig.self, from: data), !saved.rulesUnreadable {
            config = saved
            return
        }
        if let url = lastGoodConfigURL, let saved = try? JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url)),
           !saved.rulesUnreadable {
            config = saved
            configProblem = "configuration unreadable, using last good (\(saved.rules.count) rules)"
        } else {
            configProblem = data == nil ? "no configuration" : "configuration unreadable, no last good copy"
        }
        logger.error("\(self.configProblem ?? "", privacy: .public)")
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        networkTimer?.cancel()
        networkTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
        routeMonitor.stop()
        // Процесс расширения живёт и после остановки прокси: без этого relay'и и их NWConnection висели часами.
        lock.lock()
        let active = Array(relays.values)
        relays.removeAll()
        active.forEach { finish($0, as: .aborted) }
        lock.unlock()
        active.forEach { $0.relay.abort() }
        stats.save()
        if let heartbeatURL { try? FileManager.default.removeItem(at: heartbeatURL) }
        logger.notice("stop proxy reason=\(reason.rawValue), closed \(active.count) flows")
        events.add(.proxyStopped(reason: reason.rawValue))
        events.flush()
        interfaces.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        handle(flow, endpoint: (flow as? NEAppProxyTCPFlow)?.remoteFlowEndpoint)
    }

    /// UDP-flow не знает адрес назначения (он у каждой датаграммы свой); система передаёт первый отдельно.
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        handle(flow, endpoint: remoteEndpoint)
    }

    private func handle(_ flow: NEAppProxyFlow, endpoint: Network.NWEndpoint?) -> Bool {
        let signingID = flow.metaData.sourceAppSigningIdentifier
        let proto = flow is NEAppProxyUDPFlow ? "udp" : "tcp"
        let remote = endpoint?.display ?? ""
        let host = flow.remoteHostname

        lock.lock()
        let options = config
        let net = network
        lock.unlock()
        // Ни правил, ни управления всеми приложениями: узнавать процесс незачем. В ленту не пишем: это каждое
        // соединение системы (DNS, `mDNSResponder`, `apsd`), а запись берёт `lock` на горячем пути (REVIEW2).
        if options.rules.isEmpty && !options.manageAllApps { return false }
        // Своё правило — сразу; иначе узнаём процесс: путь к бинарнику и приложение, от имени которого он работает.
        let owner = owners.owner(of: flow.metaData.sourceAppAuditToken)
        var match = options.rules.match(signingID: signingID).map { (rule: $0, app: signingID, managed: false) }
        if match == nil {
            match = options.match(signingID: signingID, path: owner?.path, responsible: owner?.responsible,
                                  responsiblePath: owner?.responsiblePath, root: owner?.root ?? false)
        } else if VPNCatalog.isClient(path: owner?.path ?? "", signingID: signingID) {
            // Своё правило на VPN-клиент не применяем: его соединение с сервером через другой интерфейс — петля
            // или обрыв туннеля (REVIEW3, 4.9). Исключение `ManagedApps` сюда не доходит: оно только для приложений
            // без правила.
            match = nil
        }
        let app = match?.app ?? signingID
        var flowInfo = FlowInfo(app: app, process: app == signingID ? nil : signingID, remote: remote, host: host,
                                proto: proto, endpoint: endpoint)
        guard let match else {
            // Отданные системе — только у приложений: службы и демоны системы в ленте не нужны.
            if owner?.path?.contains(".app/Contents/MacOS/") == true {
                record(flowInfo, "По умолчанию", .passed, rule: RouteID.system)
            }
            return false
        }
        // Приложение без своего правила: адрес из списка IP — правило списка (первого по порядку).
        lock.lock()
        let lists = ipLists
        if match.managed {
            if unruledSeen.count > 1000 { unruledSeen.removeAll() }
            unruledSeen[match.app] = Date()
        }
        lock.unlock()
        let list = match.managed ? Self.listRule(for: endpoint, rules: options.lists, in: lists) : nil
        let rule = list?.rule ?? match.rule
        flowInfo.list = list?.name
        // Без `lock`: пока решение думает, новые соединения других процессов ждать не должны.
        let decision = decide(rule, config: options, network: net, allowPending: true)
        guard case .pending(let name, let binding) = decision else {
            return open(flow, flowInfo, rule: rule, managed: match.managed, decision: decision,
                        config: options, network: net)
        }
        // Интерфейс маршрута уже в таблице маршрутов, а `NWPathMonitor` о нём ещё не знает (VPN только что поднял
        // utun): ждём его, а не уводим соединение на запасной маршрут (REVIEW3, 4.8).
        logger.info("\(app, privacy: .public) \(proto, privacy: .public) \(remote, privacy: .public) waits for \(name, privacy: .public)")
        waitForInterface(binding, rule: rule, deadline: Date().addingTimeInterval(Self.interfaceWait)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cfg = self.config
            let net = self.network
            self.lock.unlock()
            let decision = self.decide(rule, config: cfg, network: net, allowPending: false)
            if !self.open(flow, flowInfo, rule: rule, managed: match.managed, decision: decision, config: cfg, network: net) {
                self.reject(flow)
            }
        }
        return true
    }

    /// Что известно о соединении до решения: для ленты, журнала и отказов.
    private struct FlowInfo {
        var app: String
        var process: String?
        var remote: String
        var host: String?
        var proto: String
        var endpoint: Network.NWEndpoint?
        /// Список IP, чьё правило сработало, — в ленту рядом с маршрутом.
        var list: String?
    }

    /// Правило первого списка, содержащего адрес назначения; по имени (адреса ещё нет) — никакого.
    private static func listRule(for endpoint: Network.NWEndpoint?, rules: [IPListRule], in lists: IPListSet) -> IPListRule? {
        guard !rules.isEmpty, !lists.isEmpty, case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a):
            return lists.firstMatch(rules, v4: a.rawValue.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case .ipv6(let a):
            return lists.firstMatch(rules, v6: a.rawValue.reduce(UInt128(0)) { $0 << 8 | UInt128($1) })
        default:
            return nil
        }
    }

    /// Текущее правило соединения: своё, правило списка IP (для приложений без правила) или правило для приложений
    /// без правила; nil — правила больше нет.
    private func currentRule(_ active: ActiveRelay, config: ProviderConfig, lists: IPListSet) -> AppRule? {
        guard let base = config.rule(forApp: active.app, managed: active.managed) else { return nil }
        guard active.managed else { return base }
        return Self.listRule(for: active.endpoint, rules: config.lists, in: lists)?.rule ?? base
    }

    /// Сколько новое соединение ждёт `NWInterface` интерфейса, который ядро уже знает.
    private static let interfaceWait: TimeInterval = 2

    /// Повторяет решение раз в 100 мс, пока интерфейс не появится в реестре или не выйдет срок. Не дождались —
    /// привязку запоминаем (`unready`): следующие соединения к ней не ждут, а сразу идут по запасному варианту.
    private func waitForInterface(_ binding: String, rule: AppRule, deadline: Date, then done: @escaping () -> Void) {
        waitQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cfg = self.config
            let net = self.network
            self.lock.unlock()
            guard case .pending = self.decide(rule, config: cfg, network: net, allowPending: true) else { return done() }
            guard Date() < deadline else {
                self.lock.lock()
                self.unready.insert(binding)
                self.lock.unlock()
                logger.error("interface \(binding, privacy: .public) not in NWPathMonitor after \(Self.interfaceWait) s, using fallback")
                self.events.add(.interfaceTimeout(binding: binding))
                return done()
            }
            self.waitForInterface(binding, rule: rule, deadline: deadline, then: done)
        }
    }

    /// Применяет решение: отказ, блок или relay. false — flow не TCP и не UDP.
    private func open(_ flow: NEAppProxyFlow, _ info: FlowInfo, rule: AppRule, managed: Bool, decision: Decision,
                      config options: ProviderConfig, network net: NetworkState) -> Bool {
        let (app, proto, remote) = (info.app, info.proto, info.remote)
        let udp = flow is NEAppProxyUDPFlow
        let blocked = { (reason: String) in
            self.reject(flow)
            logger.info("\(app, privacy: .public) \(proto, privacy: .public) \(remote, privacy: .public) \(reason, privacy: .public)")
            self.record(info, "Заблокировано", .blocked, rule: rule.route, actual: RouteID.block)
        }
        // `.pending` сюда не доходит (`allowPending: false`), но если бы дошёл — блок: мимо маршрута трафик не уходит.
        guard case .relay(var interface, let label, let route, _) = decision else {
            blocked("blocked")
            stats.add(app: app, route: RouteID.block, blocked: 1)
            return true
        }
        if interface == nil, net.ipv6Interfaces.isEmpty, let endpoint = info.endpoint, endpoint.isIPv6, !endpoint.isLocal {
            // По системному маршруту тоже: без relay приложение сразу получило бы `ENETUNREACH` и ушло на IPv4,
            // а NWConnection без маршрута ждёт, и каждое IPv6-соединение стоило бы таймаута.
            blocked("rejected (ipv6, no route)")
            return true
        }
        if interface != nil, let endpoint = info.endpoint {
            // Отклоняем сразу, чтобы приложение не ждало таймаута и ушло на IPv4 / TCP: IPv6 — если у интерфейса нет
            // маршрута IPv6 (у Wi-Fi за kill switch и у Amnezia его нет) или по настройке, QUIC — по настройке.
            let noIPv6 = endpoint.isIPv6 && !endpoint.isLocal && !net.ipv6Interfaces.contains(interface?.name ?? "")
            if (endpoint.isIPv6 && (options.rejectIPv6 || noIPv6)) || (options.blockQUIC && udp && endpoint.portNumber == 443) {
                blocked("rejected (\(endpoint.isIPv6 ? "ipv6" : "quic"))")
                return true
            }
            if options.lanViaSystem && endpoint.isLocal { interface = nil }
        }

        let id = ObjectIdentifier(flow)
        let onClose = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let active = self.relays.removeValue(forKey: id) { self.finish(active, as: .closed) }
            self.lock.unlock()
        }
        let relay: Relay
        if let tcp = flow as? NEAppProxyTCPFlow {
            relay = TCPRelay(flow: tcp, interface: interface, onClose: onClose)
        } else if let udp = flow as? NEAppProxyUDPFlow {
            relay = UDPRelay(flow: udp, interface: interface, lanViaSystem: options.lanViaSystem, onClose: onClose)
        } else {
            return false
        }
        let recordID = record(info, info.list.map { "\(label) · \($0)" } ?? label, .active, rule: rule.route, actual: route)
        stats.add(app: app, route: route, flows: 1)
        lock.lock()
        relays[id] = ActiveRelay(app: app, rule: rule, managed: managed, binding: decision.binding,
                                 relay: relay, recordID: recordID, route: route, endpoint: info.endpoint)
        lock.unlock()
        (relay as? TCPRelay)?.start()
        (relay as? UDPRelay)?.start()
        logger.info("\(app, privacy: .public)\(info.process.map { " (\($0))" } ?? "", privacy: .public) \(proto, privacy: .public) \(remote, privacy: .public) → \(label, privacy: .public)")
        return true
    }

    /// Роль маршрута → интерфейс по текущей сети. Если маршрут недоступен — запасной вариант правила,
    /// если и он недоступен — блок: мимо выбранного маршрута трафик не уходит. `allowPending` — интерфейс, который
    /// ядро знает, а реестр `NWInterface` ещё нет, — `.pending`, а не повод для запасного варианта.
    private func decide(_ rule: AppRule, config: ProviderConfig, network: NetworkState, allowPending: Bool) -> Decision {
        var route = rule.route
        // Индекс — из снимка ядра, а не из реестра `NWInterface`: реестр мог ещё не узнать интерфейс, и привязка
        // `system:utun4` сменилась бы на `system:utun4#12`, оборвав все соединения «По умолчанию» (REVIEW3, 4.8).
        let defaultVia = network.defaultInterface.map(network.binding)
        for attempt in 0..<2 {
            switch route {
            case RouteID.block:
                return .block
            case RouteID.system:
                let actual = network.defaultRoute ?? RouteID.system
                return .relay(nil, label: config.routeName(actual), route: actual, defaultVia: defaultVia)
            case RouteID.direct where network.directMode == .system:
                return .relay(nil, label: config.routeName(RouteID.direct), route: RouteID.direct, defaultVia: defaultVia)
            case RouteID.direct where network.directMode == .unavailable:
                break
            default:
                // Реестр мог отстать: utun пересоздан под тем же именем, а `NWInterface` — от прежнего; привязка к нему
                // вела бы на мёртвый интерфейс.
                guard let name = network.interface(forRoute: route) else { break }
                if let iface = interfaces.interface(named: name), iface.index == Int(network.index(of: name)) {
                    return .relay(iface, label: config.routeName(route), route: route)
                }
                let binding = network.binding(name)
                lock.lock()
                let waited = unready.contains(binding)
                lock.unlock()
                if allowPending && !waited { return .pending(interface: name, binding: binding) }
            }
            guard attempt == 0 else { break }
            route = rule.fallback == Fallback.system ? RouteID.system : Fallback.altRoute(rule.fallback) ?? RouteID.block
        }
        return .block
    }

    // MARK: - Статистика

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.splitpipe.stats"))
        var ticks = 0
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.accountTraffic()
            self.touchHeartbeat()
            ticks += 1
            if ticks % 6 == 0 { self.stats.save() }
        }
        timer.resume()
        statsTimer = timer
    }

    /// Добавляет или заменяет списки, оставляет только `keep` и пишет на диск, если что-то поменялось.
    private func storeLists(_ new: [CompiledIPList], keep: Set<String>) {
        lock.lock()
        let before = compiledLists
        for l in new where compiledLists[l.id]?.hash != l.hash {
            compiledLists[l.id] = l
            ipLists.upsert(l)
        }
        compiledLists = compiledLists.filter { keep.contains($0.key) }
        ipLists.keepOnly(keep)
        let changed = compiledLists != before
        let all = Array(compiledLists.values)
        lock.unlock()
        guard changed, let url = listsURL, let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func touchHeartbeat() {
        guard let heartbeatURL else { return }
        try? FileManager.default.createDirectory(at: heartbeatURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(Date().timeIntervalSince1970).utf8).write(to: heartbeatURL)
    }

    /// Трафик активных соединений с прошлого раза — в статистику; долгие соединения попадают в свои интервалы.
    private func accountTraffic() {
        lock.lock()
        for (id, var active) in relays {
            let s = active.relay.stats.snapshot
            let down = s.inbound - active.countedIn, up = s.out - active.countedOut
            guard down != 0 || up != 0 else { continue }
            stats.add(app: active.app, route: active.route, down: down, up: up)
            active.countedIn = s.inbound
            active.countedOut = s.out
            relays[id] = active
        }
        lock.unlock()
    }

    // MARK: - Network

    /// `events` — работает routing socket: изменения маршрутов приходят событиями, таймер — только страховка.
    private func startNetworkTimer(events: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        // Маршруты VPN (`0/1`, `128.0/1`) меняются без событий NWPathMonitor: без routing socket сверяемся по таймеру.
        let interval: Double = events ? 15 : 3
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refreshNetwork(force: false) }
        timer.resume()
        networkTimer = timer
    }

    /// Интерфейсы поменялись: даём системе досоздать маршруты и пересчитываем.
    private func scheduleNetworkRefresh() {
        networkQueue.async { [self] in
            networkWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshNetwork(force: true) }
            networkWork = work
            networkQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// `force` — пересчитать соединения, даже если таблица маршрутов та же (появился NWInterface для нового utun).
    private func refreshNetwork(force: Bool) {
        guard var state = NetworkState.read() else {
            logger.error("network: routing table unreadable, keeping previous state")
            return
        }
        lock.lock()
        // Список процессов на мгновение не виден — VPN без Network Extension не опознать: прежнее опознание
        // туннеля, который никуда не делся, лучше, чем увести его правила в fallback (REVIEW3, 4.6).
        if !state.processesVisible {
            for tunnel in state.tunnels where state.vpns[tunnel] == nil { state.vpns[tunnel] = network.vpns[tunnel] }
        }
        let changed = state != network
        let old = network
        let cfg = config
        network = state
        lock.unlock()
        guard changed || force else { return }
        if changed {
            logger.notice("network changed: \(state.summary, privacy: .public)")
            journalNetworkChange(from: old, to: state, config: cfg)
        }
        let aborted = reevaluate()
        if aborted > 0 {
            logger.notice("network change: aborted \(aborted) flows")
            events.add(.flowsAborted(count: aborted, network: true))
        }
    }

    /// В историю — то, что видно пользователю: маршрут по умолчанию, VPN, физическая сеть.
    private func journalNetworkChange(from old: NetworkState, to new: NetworkState, config: ProviderConfig) {
        if old.defaultRoute != new.defaultRoute {
            events.add(.defaultRouteChanged(from: old.defaultRoute, to: new.defaultRoute))
        }
        let before = Set(old.tunnels), after = Set(new.tunnels)
        for t in before.subtracting(after).sorted() {
            events.add(.vpnDisappeared(name: config.routeName(RouteID.vpn(old.vpnKey(forTunnel: t))), interface: t))
        }
        for t in after.subtracting(before).sorted() {
            events.add(.vpnAppeared(name: config.routeName(RouteID.vpn(new.vpnKey(forTunnel: t))), interface: t))
        }
        if old.physical != nil, new.physical == nil { events.add(.physicalLost(reason: new.physicalVia ?? "")) }
        if old.physical == nil, let p = new.physical { events.add(.physicalReturned(interface: p)) }
    }

    /// Сколько ждать, не вернётся ли привязка к интерфейсу: помощник пересоздаёт scoped-маршруты при моргании линка
    /// примерно за секунду, и «Напрямую» на это время становится недоступен.
    private static let flapGrace: TimeInterval = 2

    /// Обрывает соединения, у которых поменялось правило или интерфейс маршрута: приложение переподключится по новому.
    /// Решения считаются без `lock`: при сотнях соединений и смене сети это заняло бы `handleNewFlow`.
    /// Пропажу привязки к интерфейсу пережидаем `flapGrace` (REVIEW3, 5): вернулась прежней — соединение живёт.
    /// Соединения по системному маршруту обрываются сразу: иначе открытые через en1, пока VPN переподключался,
    /// дольше жили бы мимо его kill switch.
    @discardableResult
    private func reevaluate() -> Int {
        lock.lock()
        let cfg = config
        let net = network
        let lists = ipLists
        let snapshot = cfg.abortOnChange ? relays : [:]
        lock.unlock()
        let now = Date()
        var staleIDs: [ObjectIdentifier] = []
        /// Новое `staleSince`: дата — привязка пропала, nil — вернулась.
        var marks: [ObjectIdentifier: Date?] = [:]
        for (id, active) in snapshot {
            guard let rule = currentRule(active, config: cfg, lists: lists), rule == active.rule else {
                staleIDs.append(id)
                continue
            }
            if decide(rule, config: cfg, network: net, allowPending: true).binding == active.binding {
                if active.staleSince != nil { marks[id] = .some(nil) }
            } else if !Decision.isInterface(active.binding) {
                staleIDs.append(id)
            } else if let since = active.staleSince {
                if now.timeIntervalSince(since) >= Self.flapGrace { staleIDs.append(id) }
            } else {
                marks[id] = .some(now)
            }
        }
        lock.lock()
        // Пока считали, соединение могло закрыться, а его ObjectIdentifier — достаться новому.
        for (id, since) in marks where relays[id]?.recordID == snapshot[id]?.recordID { relays[id]?.staleSince = since }
        var stale: [ActiveRelay] = []
        for id in staleIDs where relays[id]?.recordID == snapshot[id]?.recordID {
            if let active = relays.removeValue(forKey: id) { stale.append(active) }
        }
        stale.forEach { finish($0, as: .aborted) }
        lock.unlock()
        stale.forEach { $0.relay.abort() }
        if marks.values.contains(where: { $0 != nil }) {
            networkQueue.asyncAfter(deadline: .now() + Self.flapGrace + 0.1) { [weak self] in
                guard let self else { return }
                let aborted = self.reevaluate()
                if aborted > 0 {
                    logger.notice("interface did not come back in \(Self.flapGrace) s: aborted \(aborted) flows")
                    self.events.add(.flowsAborted(count: aborted, network: true))
                }
            }
        }
        return stale.count
    }

    private func reject(_ flow: NEAppProxyFlow) {
        let error = NEAppProxyFlowError(.refused)
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let reply: (ProviderReply) -> Void = { completionHandler?(try? JSONEncoder().encode($0)) }
        guard let request = try? JSONDecoder().decode(ProviderRequest.self, from: messageData) else {
            reply(.error("bad request"))
            return
        }
        switch request {
        case .setConfig(let newConfig):
            lock.lock()
            config = newConfig
            configProblem = nil
            lock.unlock()
            // Подсети списков, которых больше нет в правилах, не нужны.
            storeLists([], keep: Set(newConfig.lists.map(\.id)))
            if let url = lastGoodConfigURL, let data = try? JSONEncoder().encode(newConfig) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            let aborted = reevaluate()
            let summary = newConfig.rules.map { "\($0.key)=\($0.value.route)/\($0.value.fallback)" }.sorted().joined(separator: ", ")
            logger.notice("rules updated: \(summary, privacy: .public), manageAll \(newConfig.manageAllApps), aborted \(aborted) flows")
            if aborted > 0 { events.add(.flowsAborted(count: aborted, network: false)) }
            reply(.ok)
        case .status:
            reply(.status(status(StatusParts(rules: true, network: true, flows: .all))))
        case .statusParts(let parts):
            reply(.status(status(parts)))
        case .stats(let from, let bucket):
            accountTraffic()
            reply(.stats(stats.query(from: from, bucket: bucket)))
        case .setLists(let lists):
            lock.lock()
            let keep = Set(config.lists.map(\.id)).union(lists.map(\.id))
            lock.unlock()
            storeLists(lists, keep: keep)
            let aborted = reevaluate()
            logger.notice("ip lists updated: \(lists.map(\.id).joined(separator: ","), privacy: .public), aborted \(aborted) flows")
            if aborted > 0 { events.add(.flowsAborted(count: aborted, network: false)) }
            reply(.ok)
        case .events(let after, let journal):
            reply(.events(events.batch(after: after, journal: journal)))
        case .resetStats:
            accountTraffic()
            stats.reset()
            reply(.ok)
        case .abort(let app):
            lock.lock()
            let matching = relays.filter { $0.value.app == app || $0.value.app.hasPrefix(app + ".") }
            matching.keys.forEach { relays[$0] = nil }
            matching.values.forEach { finish($0, as: .aborted) }
            lock.unlock()
            matching.values.forEach { $0.relay.abort() }
            logger.info("abort \(app, privacy: .public): \(matching.count) flows")
            reply(.aborted(matching.count))
        case .probe(let name, let url):
            guard let iface = interfaces.interface(named: name) else {
                reply(.probe(ProbeResult(interface: name, ok: false, body: "interface not found", millis: 0)))
                return
            }
            Probe.run(url: url, interface: iface, interfaceName: name) { reply(.probe($0)) }
        case .stun(let name, let server):
            guard let iface = interfaces.interface(named: name) else {
                reply(.probe(ProbeResult(interface: name, ok: false, body: "interface not found", millis: 0)))
                return
            }
            Probe.stun(server: server, interface: iface, interfaceName: name) { reply(.probe($0)) }
        }
    }

    /// Статус с нужными частями. Счётчики трафика — только у отдаваемых записей, а не копия всей ленты.
    private func status(_ parts: StatusParts) -> ProviderStatus {
        lock.lock(); defer { lock.unlock() }
        let recent = order.suffix(Self.recordLimit)
        let ids: [UInt64]
        switch parts.flows {
        case .none: ids = []
        case .all: ids = Array(recent)
        case .app(let app, let limit):
            ids = Array(recent.filter { records[$0].map { $0.app == app || $0.app.hasPrefix(app + ".") } ?? false }.suffix(limit))
        }
        let live = Dictionary(relays.values.map { ($0.recordID, $0.relay.stats) }, uniquingKeysWith: { a, _ in a })
        let flows = ids.compactMap { id in records[id].map { r in live[id].map { withStats(r, $0) } ?? r } }
        // Имя и индекс: в диагностике видно, знает ли реестр `NWInterface` интерфейс, который видит ядро (REVIEW3, 4.8).
        return ProviderStatus(uid: getuid(), rules: parts.rules ? config.rules : [:],
                              interfaces: interfaces.all.map(Decision.binding), network: parts.network ? network : nil,
                              activeFlows: relays.count, recentFlows: flows, configProblem: configProblem,
                              rulesIncluded: parts.rules, listHashes: ipLists.hashes, unruledApps: unruledSeen)
    }

    @discardableResult
    private func record(_ info: FlowInfo, _ route: String, _ state: FlowState, rule: String? = nil,
                        actual: String? = nil) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        records[id] = FlowRecord(id: id, date: Date(), app: info.app.isEmpty ? "<unsigned>" : info.app, process: info.process,
                                 remote: info.remote, host: info.host, proto: info.proto, route: route, state: state,
                                 ruleRoute: rule, actualRoute: actual)
        order.append(id)
        // Старые записи — пачкой: `removeFirst()` на каждое соединение сдвигал бы весь массив.
        if order.count > Self.recordLimit * 2 {
            let old = order.count - Self.recordLimit
            order.prefix(old).forEach { records[$0] = nil }
            order.removeFirst(old)
        }
        return id
    }

    /// Вызывать под `lock`. Первое итоговое состояние побеждает: оборванное соединение потом закрывается, но остаётся «оборванным».
    private func finish(_ active: ActiveRelay, as state: FlowState) {
        // Хвост трафика, который ещё не попал в статистику.
        let s = active.relay.stats.snapshot
        stats.add(app: active.app, route: active.route, down: s.inbound - active.countedIn, up: s.out - active.countedOut)
        guard var r = records[active.recordID], r.state == .active else { return }
        r = withStats(r, active.relay.stats)
        r.state = state
        records[active.recordID] = r
    }

    private func withStats(_ record: FlowRecord, _ stats: FlowStats) -> FlowRecord {
        var r = record
        let s = stats.snapshot
        r.bytesOut = s.out
        r.bytesIn = s.inbound
        if r.remote.isEmpty, let remote = s.remote { r.remote = remote }
        return r
    }
}

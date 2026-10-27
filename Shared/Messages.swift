import Foundation

enum Config {
    /// Интерфейс на русском независимо от языка системы: страны, размеры, время.
    static let locale = Locale(identifier: "ru_RU")
    static let extensionBundleID = "dev.splitpipe.app.proxy"
    /// Из Info.plist (`$(TeamIdentifierPrefix)dev.splitpipe`, как в entitlements), а не с зашитым team id.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "SPAppGroup") as? String ?? "BL65NHTRYD.dev.splitpipe"
    static let logSubsystem = "dev.splitpipe"
    /// Внешний IP и страна выхода. По IP-адресу, без DNS: проверка «Напрямую» не зависит от DNS внутри VPN.
    static let traceURL = "https://1.1.1.1/cdn-cgi/trace"
    /// Запасные сервисы по порядку: Cloudflare trace по имени (другие адреса, тоже даёт страну), потом сервисы, отдающие только IP.
    static let defaultEchoURLs = ["https://www.cloudflare.com/cdn-cgi/trace", "https://api.ipify.org", "https://icanhazip.com"]
    /// STUN-серверы для проверки UDP: внешний IP по UDP должен совпасть с TCP.
    static let stunServers = ["stun.l.google.com:19302", "stun.cloudflare.com:3478"]
}

/// bundle id приложения → правило с ролями маршрутов. Интерфейсы по ролям расширение находит само (`NetworkState`).
typealias RoutingRules = [String: AppRule]

struct ProviderConfig: Codable, Hashable {
    var rules: RoutingRules = [:]
    /// Держать у себя соединения и приложений без правила, чтобы их можно было переключить мгновенно.
    /// Какой процесс — приложение, расширение решает само по пути (`ManagedApps`): список приложений в конфигурации
    /// менялся бы при каждом запуске и выходе любого приложения, а с ним — настройки системы.
    var manageAllApps = false
    /// Правило для управляемых приложений без своего правила («маршрут для приложений без правила»).
    var unmanagedRule = AppRule(route: RouteID.system, fallback: Fallback.system)
    /// Имена VPN, переименованных пользователем (ключ VPN → имя), для ленты соединений.
    var routeNames: [String: String] = [:]
    /// Обрывать перенаправленные соединения приложения, когда его правило меняется.
    var abortOnChange = true
    /// Локальные адреса (10/8, 172.16/12, 192.168/16, link-local) — по системному маршруту, даже у перенаправленных приложений.
    var lanViaSystem = true
    /// Сразу отклонять IPv6 у приложений, привязанных к интерфейсу: приложение не ждёт таймаута и уходит на IPv4.
    var rejectIPv6 = false
    /// Блокировать UDP 443 (QUIC) у приложений, привязанных к интерфейсу: браузер переходит на TCP.
    var blockQUIC = false
    /// Правила списков IP-подсетей по порядку: для приложений без своего правила (`IPLists.swift`).
    var lists: [IPListRule] = []
    /// Правила в сохранённой конфигурации есть, но не прочитались: работать «без правил» нельзя — правила
    /// «Блокировать» молча перестали бы действовать (REVIEW3, 4.10).
    var rulesUnreadable = false

    init(rules: RoutingRules = [:], manageAllApps: Bool = false) {
        self.rules = rules
        self.manageAllApps = manageAllApps
    }

    private enum LegacyKeys: String, CodingKey { case managedApps }

    /// Конфигурация сохраняется в настройках системы: старая версия могла быть без новых полей.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Правила прошлых версий (с интерфейсами вместо ролей) не читаются: приложение пришлёт новые при запуске,
        // а до тех пор расширение берёт последнюю рабочую конфигурацию (`rulesUnreadable`).
        do {
            rules = try c.decodeIfPresent(RoutingRules.self, forKey: .rules) ?? [:]
        } catch {
            rules = [:]
            rulesUnreadable = true
        }
        // Прошлые версии хранили сам список приложений.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        manageAllApps = try c.decodeIfPresent(Bool.self, forKey: .manageAllApps)
            ?? !(legacy.decodeIfPresent(Set<String>.self, forKey: .managedApps) ?? []).isEmpty
        unmanagedRule = (try? c.decodeIfPresent(AppRule.self, forKey: .unmanagedRule)) ?? unmanagedRule
        routeNames = try c.decodeIfPresent([String: String].self, forKey: .routeNames) ?? [:]
        abortOnChange = try c.decodeIfPresent(Bool.self, forKey: .abortOnChange) ?? true
        lanViaSystem = try c.decodeIfPresent(Bool.self, forKey: .lanViaSystem) ?? true
        rejectIPv6 = try c.decodeIfPresent(Bool.self, forKey: .rejectIPv6) ?? false
        blockQUIC = try c.decodeIfPresent(Bool.self, forKey: .blockQUIC) ?? false
        lists = (try? c.decodeIfPresent([IPListRule].self, forKey: .lists)) ?? []
    }

    /// Правило для процесса: своё, правило для управляемых приложений без правила или nil — отдать системе.
    func routeName(_ id: String) -> String {
        switch id {
        case RouteID.direct: return "Напрямую"
        case RouteID.system: return "По умолчанию"
        case RouteID.block: return "Заблокировано"
        default:
            let key = RouteID.vpnKey(id) ?? id
            return routeNames[key] ?? RouteID.defaultName(forVPN: key)
        }
    }

    /// Текущее правило соединения: своё, правило для приложений без правила (если оно было у управляемого приложения)
    /// или nil — правила больше нет.
    func rule(forApp app: String, managed: Bool) -> AppRule? {
        if let r = rules.match(signingID: app) { return r }
        return managed && manageAllApps ? unmanagedRule : nil
    }

    /// Правило для процесса без своего правила, по порядку: правило программы по пути к бинарнику,
    /// правило ответственного приложения (WebKit, XPC-службы), управляемый процесс или управляемое приложение.
    /// `app` — ключ, к которому относится соединение: по нему его показывают и обрывают; `managed` — правило
    /// для приложений без правила. Процессы root (службы, VPN-клиенты) под управление не берутся.
    func match(signingID id: String, path: String?, responsible: String?,
               responsiblePath: String? = nil, root: Bool = false) -> (rule: AppRule, app: String, managed: Bool)? {
        for p in [path, responsiblePath].compactMap({ $0 }) {
            if let r = rules[ProgramRule.key(p)] { return (r, ProgramRule.key(p), false) }
        }
        if let responsible, let r = rules.match(signingID: responsible) { return (r, responsible, false) }
        guard manageAllApps, !root else { return nil }
        if ManagedApps.contains(path: path, signingID: id) { return (unmanagedRule, id, true) }
        if let responsible, ManagedApps.contains(path: responsiblePath, signingID: responsible) {
            return (unmanagedRule, responsible, true)
        }
        return nil
    }
}

/// Приложения, которые SplitPipe держит у себя при «Управлять всеми приложениями»: бинарник внутри любого `.app`
/// (в том числе из `~/Downloads`, DerivedData, Steam, JetBrains Toolbox), кроме системных (`isSystem`). Приложения из
/// `/System/Applications` и Safari в cryptex — управляются. VPN-клиенты (их трафик через расширение зациклился бы)
/// и сам SplitPipe — нет.
enum ManagedApps {
    static func contains(path: String?, signingID: String) -> Bool {
        guard let path, path.contains(".app/Contents/MacOS/"), !isSystem(path) else { return false }
        if signingID.hasPrefix("dev.splitpipe") { return false }
        return !VPNCatalog.isClient(path: path, signingID: signingID)
    }

    /// Системные агенты и службы в `.app`: `/System/Library/CoreServices`, `/Library/Apple`, `/usr/libexec`, в том числе
    /// внутри cryptex (`/System/Cryptexes/OS/System/Library/…`).
    static func isSystem(_ path: String) -> Bool {
        path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") || path.contains("/System/Library/")
            || (path.contains("/Cryptexes/") && path.contains("/usr/"))
    }
}

/// Правила консольных программ хранятся по пути к бинарнику: у них нет bundle id, а signing id ad-hoc подписи
/// меняется с каждой сборкой.
enum ProgramRule {
    static let prefix = "path:"
    static func key(_ path: String) -> String { prefix + path }
    static func path(_ key: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }
}

enum ProviderRequest: Codable {
    case setConfig(ProviderConfig)
    /// Всё: правила, сеть, 400 последних соединений.
    case status
    /// Только нужное экрану: опрос раз в 1–2 с не должен каждый раз везти все правила и всю ленту (REVIEW3, 5).
    case statusParts(StatusParts)
    case probe(interface: String, url: String)
    /// STUN Binding Request через интерфейс: внешний IP по UDP (`host:port`).
    case stun(interface: String, server: String)
    /// Оборвать перенаправленные соединения приложения (и его helper-процессов).
    case abort(app: String)
    /// Статистика с `from` по интервалам `bucket` секунд (300 — из пятиминутных, иначе из часовых).
    case stats(from: Date, bucket: Int)
    case resetStats
    /// События журнала расширения после номера `after` журнала `journal` (другой журнал — все).
    case events(after: UInt64, journal: String?)
    /// Подсети списков: добавить или заменить эти (остальные остаются, пока на них ссылается `ProviderConfig.lists`).
    case setLists([CompiledIPList])
}

struct StatusParts: Codable, Hashable {
    enum Flows: Codable, Hashable {
        case none
        case all
        /// Последние `limit` соединений приложения (и его helper-процессов).
        case app(String, limit: Int)
    }

    var rules = false
    var network = true
    var flows = Flows.none
}

/// Трафик приложения по маршруту за интервал. `route` — фактический маршрут (`direct`, `vpn:<key>`, `block`):
/// «По умолчанию» записан по тому, куда трафик реально ушёл.
struct StatRow: Codable, Hashable {
    /// Начало интервала, секунды с 1970.
    var bucket: Int64
    var app: String
    var route: String
    var down: Int64 = 0
    var up: Int64 = 0
    var flows: Int = 0
    var blocked: Int = 0
}

struct ProviderStatus: Codable {
    var uid: UInt32
    var rules: RoutingRules
    var interfaces: [String]
    /// Как расширение видит сеть: по нему оно выбирает интерфейсы маршрутов.
    var network: NetworkState?
    var activeFlows: Int
    var recentFlows: [FlowRecord]
    /// Конфигурация не прочиталась при запуске прокси: что взято вместо неё. Приложение досылает свою.
    var configProblem: String? = nil
    /// Ответ на `statusParts` без правил: `rules` пустые не потому, что их нет.
    var rulesIncluded: Bool? = nil
    /// Какие списки IP у расширения (id → hash): другие или нет — приложение досылает.
    var listHashes: [String: String]? = nil
    /// Приложения без своего правила, чьи соединения расширение видело (signing id → когда последний раз):
    /// по ним приложение находит новые приложения.
    var unruledApps: [String: Date]? = nil
}

enum FlowState: String, Codable {
    case active, closed, aborted, blocked
    /// Правила нет — соединение отдано системе, расширение его не видит дальше.
    case passed
    /// Только в приложении: соединение приложения с правилом идёт мимо расширения (сторож правил).
    case bypass
}

struct FlowRecord: Codable, Hashable, Identifiable {
    var id: UInt64
    var date: Date
    /// Приложение или программа (`path:/usr/bin/curl`), к которой относится соединение.
    var app: String
    /// Процесс, если он не само приложение: `com.apple.WebKit.Networking` у Safari, `com.apple.curl` у `path:` правила.
    var process: String?
    var remote: String
    /// Имя, если приложение подключалось по имени (NSURLSession, Network.framework).
    var host: String?
    var proto: String
    /// Имя маршрута на момент соединения («Напрямую», «Amnezia VPN»).
    var route: String
    var state: FlowState
    /// Маршрут правила (`default`, `direct`, `vpn:<ключ>`, `block`) и тот, куда соединение ушло на самом деле
    /// (`direct` у «По умолчанию» без VPN, запасной маршрут). Фильтр ленты — по ним, а не по имени (REVIEW3, 5).
    /// nil — запись от расширения старой версии.
    var ruleRoute: String?
    var actualRoute: String?
    var bytesOut: Int64 = 0
    var bytesIn: Int64 = 0
}

/// Счётчики соединения: пишут очереди relay, читает `handleAppMessage`.
final class FlowStats: @unchecked Sendable {
    private let lock = NSLock()
    private var out: Int64 = 0
    private var inbound: Int64 = 0
    private var firstRemote: String?

    func sent(_ n: Int) { lock.lock(); out += Int64(n); lock.unlock() }
    func received(_ n: Int) { lock.lock(); inbound += Int64(n); lock.unlock() }
    func seen(remote: String) { lock.lock(); if firstRemote == nil { firstRemote = remote }; lock.unlock() }

    var snapshot: (out: Int64, inbound: Int64, remote: String?) {
        lock.lock(); defer { lock.unlock() }
        return (out, inbound, firstRemote)
    }
}

struct ProbeResult: Codable {
    var interface: String
    var ok: Bool
    var body: String
    var millis: Int
}

enum ProviderReply: Codable {
    case ok
    case status(ProviderStatus)
    case probe(ProbeResult)
    case aborted(Int)
    case stats([StatRow])
    case events(EventBatch)
    case error(String)
}

extension Dictionary where Key == String {
    /// Значение для signing id процесса: точное совпадение или helper-процесс (`<bundle id>.*`) — самый длинный префикс.
    /// По префиксам самого id (`a.b.c.d` → `a.b.c` → `a.b` → `a`), а не перебором ключей: это каждое соединение
    /// системы, а правил может быть сотни (REVIEW3, 5).
    func match(signingID id: String) -> Value? {
        if let r = self[id] { return r }
        var end = id.endIndex
        while let dot = id[..<end].lastIndex(of: ".") {
            if let r = self[String(id[..<dot])] { return r }
            end = dot
        }
        return nil
    }
}

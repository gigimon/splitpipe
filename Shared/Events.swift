import Foundation

/// Кто записал событие истории.
enum EventSource: String, Codable, CaseIterable {
    case app, proxy, helper
}

enum EventSeverity: String, Codable, Comparable {
    case info, warning, error

    private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Почему помощник снял свои маршруты.
enum RouteDropReason: Codable, Hashable {
    /// Линк физического интерфейса пропал или вернулся (роуминг Wi-Fi, сон).
    case link(interface: String, up: Bool)
    /// utun VPN удалён или потерял адрес — клиент перезапускает демон.
    case tunnelGone(interface: String)
    /// VPN снял свой маршрут по умолчанию (переподключение).
    case vpnDroppedDefault(interface: String)
    /// Событие ядра о Wi-Fi: смена точки, линк.
    case wifi(interface: String, event: String)
}

/// Что случилось — кодом, без текста: у root-процессов своя локаль (а у расширения нет локализаций), текст на языке
/// интерфейса собирает приложение. Маршруты — идентификаторами (`direct`, `vpn:<ключ>`), VPN — именем.
enum EventKind: Codable, Hashable {
    // Расширение
    case proxyStarted(rules: Int, manageAll: Bool)
    /// `reason` — `NEProviderStopReason.rawValue`.
    case proxyStopped(reason: Int)
    case defaultRouteChanged(from: String?, to: String?)
    case vpnAppeared(name: String, interface: String)
    case vpnDisappeared(name: String, interface: String)
    case physicalLost(reason: String)
    case physicalReturned(interface: String)
    /// Оборваны соединения: из-за смены сети (`network`) или правил.
    case flowsAborted(count: Int, network: Bool)
    case configProblem(String)
    /// Интерфейс так и не появился в `NWPathMonitor` — соединения ушли на запасной вариант.
    case interfaceTimeout(binding: String)

    // Помощник
    case helperStarted(version: String)
    /// `reason`: `signal`, `replaced`, `restart`.
    case helperExiting(reason: String)
    /// Действие или ошибка помощника (`did`/`fail`).
    case helper(HelperEvent)
    case routesDropped(RouteDropReason)

    // Приложение
    case enabled(Bool)
    /// VPN отключился дольше 10 с: заблокированные приложения и ушедшие на другой маршрут (`имя → маршрут`).
    case vpnDown(name: String, blocked: [String], moved: [String])
    case vpnUp(name: String)
    case killSwitchBlocking
    case proxyStoppedUnexpectedly
    /// Пользователь поменял правило: `route` nil — правило удалено.
    case ruleChanged(app: String, route: String?)
    case temporaryRouteStarted(app: String, route: String)
    case temporaryRouteEnded(app: String, restored: String, expired: Bool)
    /// Новое приложение: маршрут поставлен сам (`route`) или задан вопрос (nil).
    case newApp(app: String, route: String?)
    /// Ответ на вопрос о новом приложении: маршрут или nil — «По умолчанию», правило не создано.
    case newAppAnswered(app: String, route: String?)
    /// Сторож правил: у приложения с правилом `count` соединений мимо расширения.
    case bypassDetected(app: String, count: Int)

    var severity: EventSeverity {
        switch self {
        case .proxyStopped, .vpnDisappeared, .physicalLost, .defaultRouteChanged, .flowsAborted, .routesDropped,
             .helperExiting, .proxyStoppedUnexpectedly, .bypassDetected:
            .warning
        case .configProblem, .interfaceTimeout, .killSwitchBlocking:
            .error
        case .vpnDown(_, let blocked, _):
            blocked.isEmpty ? .warning : .error
        case .helper(let e):
            switch e {
            case .noGateway, .routesNotRestored, .anchorNotLoaded, .anchorNotCalled, .anchorShadowed: .error
            case .proxyNotRunning: .warning
            default: .info
            }
        default:
            .info
        }
    }
}

struct SPEvent: Codable, Hashable, Identifiable {
    /// Номер в журнале источника: растёт без пропусков, по нему приложение забирает новые.
    var seq: UInt64
    var date: Date
    var source: EventSource
    var kind: EventKind
    /// Журнал, в котором записано: после удаления файла номера начинаются заново.
    var journal: String

    var id: String { "\(source.rawValue):\(journal):\(seq)" }
    var severity: EventSeverity { kind.severity }
}

/// Ответ на запрос событий журнала: его идентификатор и события после указанного номера.
struct EventBatch: Codable {
    var journal: String
    var events: [SPEvent]
}

/// Журнал событий одного процесса: кольцо последних событий на диске (30 дней, не больше `limit`).
/// Пишется не чаще раза в 5 с и при `flush()`: события бывают пачками (роуминг Wi-Fi).
final class EventJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL?
    private let source: EventSource
    private var events: [SPEvent] = []
    private var journal: String
    private var nextSeq: UInt64 = 1
    private var saveScheduled = false
    private let queue = DispatchQueue(label: "dev.splitpipe.events")
    private let limit = 5000
    private let keep: TimeInterval = 30 * 86400

    private struct Saved: Codable {
        var journal: String
        var nextSeq: UInt64
        var events: [SPEvent]
    }

    init(source: EventSource, url: URL?) {
        self.source = source
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            journal = saved.journal
            nextSeq = saved.nextSeq
            events = saved.events
        } else {
            journal = UUID().uuidString
        }
    }

    func add(_ kind: EventKind, at date: Date = Date()) {
        lock.lock()
        events.append(SPEvent(seq: nextSeq, date: date, source: source, kind: kind, journal: journal))
        nextSeq += 1
        let schedule = !saveScheduled
        saveScheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.flush() } }
    }

    /// События после номера `seq` того же журнала; другой журнал (файл пересоздан) — все.
    func batch(after seq: UInt64, journal requested: String?) -> EventBatch {
        lock.lock(); defer { lock.unlock() }
        let from = requested == journal ? seq : 0
        return EventBatch(journal: journal, events: events.filter { $0.seq > from })
    }

    func flush() {
        lock.lock()
        saveScheduled = false
        let cutoff = Date().addingTimeInterval(-keep)
        events.removeAll { $0.date < cutoff }
        if events.count > limit { events.removeFirst(events.count - limit) }
        let saved = Saved(journal: journal, nextSeq: nextSeq, events: events)
        lock.unlock()
        guard let url, let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

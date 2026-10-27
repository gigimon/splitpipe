import XCTest

/// Журнал событий процесса (`EventJournal`: помощник, расширение) и объединённая история приложения (`EventLog`).
final class EventJournalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("splitpipe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSequenceAndBatches() {
        let j = EventJournal(source: .proxy, url: nil)
        j.add(.proxyStarted(rules: 2, manageAll: true))
        j.add(.vpnAppeared(name: "Amnezia VPN", interface: "utun4"))
        j.add(.flowsAborted(count: 3, network: true))
        let all = j.batch(after: 0, journal: nil)
        XCTAssertEqual(all.events.map(\.seq), [1, 2, 3])
        XCTAssertTrue(all.events.allSatisfy { $0.source == .proxy && $0.journal == all.journal })
        XCTAssertEqual(j.batch(after: 2, journal: all.journal).events.map(\.seq), [3])
        XCTAssertEqual(j.batch(after: 3, journal: all.journal).events, [])
        // Чужой журнал (файл пересоздан) — всё с начала.
        XCTAssertEqual(j.batch(after: 2, journal: "other").events.count, 3)
    }

    func testPersistenceKeepsJournalAndNumbering() {
        let url = dir.appendingPathComponent("events.json")
        let a = EventJournal(source: .helper, url: url)
        a.add(.helperStarted(version: "1"))
        a.add(.helper(.bypassEnabled(interfaces: ["en1"])))
        a.flush()
        let journal = a.batch(after: 0, journal: nil).journal

        let b = EventJournal(source: .helper, url: url)
        b.add(.routesDropped(.link(interface: "en1", up: false)))
        let batch = b.batch(after: 0, journal: journal)
        XCTAssertEqual(batch.journal, journal)
        XCTAssertEqual(batch.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(batch.events.last?.kind, .routesDropped(.link(interface: "en1", up: false)))
    }

    func testNewFileGetsNewJournal() {
        let a = EventJournal(source: .proxy, url: dir.appendingPathComponent("a.json"))
        let b = EventJournal(source: .proxy, url: dir.appendingPathComponent("b.json"))
        XCTAssertNotEqual(a.batch(after: 0, journal: nil).journal, b.batch(after: 0, journal: nil).journal)
    }

    func testRetentionAndLimit() {
        let j = EventJournal(source: .proxy, url: nil)
        j.add(.proxyStopped(reason: 1), at: Date().addingTimeInterval(-31 * 86400))
        for i in 0..<5005 { j.add(.flowsAborted(count: i, network: false)) }
        j.flush()
        let events = j.batch(after: 0, journal: nil).events
        XCTAssertEqual(events.count, 5000)
        // Старше 30 дней — выброшено, из лишних — самые старые.
        XCTAssertFalse(events.contains { $0.kind == .proxyStopped(reason: 1) })
        XCTAssertEqual(events.first?.kind, .flowsAborted(count: 5, network: false))
    }

    func testKindsRoundTripAndSeverity() throws {
        let kinds: [EventKind] = [
            .proxyStarted(rules: 1, manageAll: false), .proxyStopped(reason: 15), .defaultRouteChanged(from: nil, to: "vpn:amnezia"),
            .vpnDisappeared(name: "Amnezia VPN", interface: "utun4"), .physicalLost(reason: "none: no primary"),
            .configProblem("bad"), .interfaceTimeout(binding: "utun5#30"), .helperExiting(reason: "signal"),
            .helper(.anchorShadowed(rule: "block drop quick all")), .helper(.routesRestored(interface: "en1", gateway: "192.168.1.1")),
            .routesDropped(.wifi(interface: "en1", event: "bssidChanged")), .enabled(true),
            .vpnDown(name: "Amnezia VPN", blocked: ["Telegram"], moved: []), .vpnDown(name: "Amnezia VPN", blocked: [], moved: ["Opera → Напрямую"]),
            .ruleChanged(app: "org.telegram.desktop", route: nil), .temporaryRouteEnded(app: "a", restored: "direct", expired: true),
            .newApp(app: "a", route: nil), .newAppAnswered(app: "a", route: "direct"), .bypassDetected(app: "a", count: 2),
        ]
        let data = try JSONEncoder().encode(kinds)
        XCTAssertEqual(try JSONDecoder().decode([EventKind].self, from: data), kinds)

        XCTAssertEqual(EventKind.configProblem("x").severity, .error)
        XCTAssertEqual(EventKind.helper(.anchorNotCalled).severity, .error)
        XCTAssertEqual(EventKind.helper(.bypassEnabled(interfaces: [])).severity, .info)
        XCTAssertEqual(EventKind.vpnDown(name: "v", blocked: ["a"], moved: []).severity, .error)
        XCTAssertEqual(EventKind.vpnDown(name: "v", blocked: [], moved: ["a"]).severity, .warning)
        XCTAssertEqual(EventKind.bypassDetected(app: "a", count: 1).severity, .warning)
        XCTAssertEqual(EventKind.enabled(false).severity, .info)
        XCTAssertTrue(EventSeverity.info < .warning && EventSeverity.warning < .error)
    }
}

@MainActor
final class EventLogTests: XCTestCase {
    private func event(_ seq: UInt64, _ source: EventSource, _ journal: String, at offset: TimeInterval = 0,
                       _ kind: EventKind = .enabled(true)) -> SPEvent {
        SPEvent(seq: seq, date: Date().addingTimeInterval(offset), source: source, kind: kind, journal: journal)
    }

    func testAppEventsNumbered() {
        let log = EventLog(url: nil)
        log.add(.enabled(true))
        log.add(.killSwitchBlocking)
        XCTAssertEqual(log.events.map(\.seq), [1, 2])
        XCTAssertTrue(log.events.allSatisfy { $0.source == .app })
    }

    func testMergeDeduplicatesAndMovesCursor() {
        let log = EventLog(url: nil)
        log.merge(EventBatch(journal: "J", events: [event(1, .proxy, "J"), event(2, .proxy, "J")]), from: .proxy)
        XCTAssertEqual(log.cursor(.proxy)?.seq, 2)
        XCTAssertEqual(log.cursor(.proxy)?.journal, "J")
        // Повтор тех же событий (ответ пришёл дважды) — без дублей.
        log.merge(EventBatch(journal: "J", events: [event(2, .proxy, "J"), event(3, .proxy, "J")]), from: .proxy)
        XCTAssertEqual(log.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(log.cursor(.proxy)?.seq, 3)
        // Пустой ответ курсор не сбрасывает.
        log.merge(EventBatch(journal: "J", events: []), from: .proxy)
        XCTAssertEqual(log.cursor(.proxy)?.seq, 3)
    }

    func testSameSeqFromDifferentSourcesOrJournalsKept() {
        let log = EventLog(url: nil)
        log.merge(EventBatch(journal: "P", events: [event(1, .proxy, "P")]), from: .proxy)
        log.merge(EventBatch(journal: "H", events: [event(1, .helper, "H")]), from: .helper)
        // Журнал расширения пересоздан: номера с начала, но события другие.
        log.merge(EventBatch(journal: "P2", events: [event(1, .proxy, "P2")]), from: .proxy)
        XCTAssertEqual(log.events.count, 3)
        XCTAssertEqual(log.cursor(.proxy)?.journal, "P2")
        XCTAssertEqual(log.cursor(.helper)?.journal, "H")
    }

    func testLateEventsAreSortedByTime() {
        let log = EventLog(url: nil)
        log.add(.enabled(true))
        // Помощник прислал то, что было ночью, — встаёт раньше.
        log.merge(EventBatch(journal: "H", events: [event(1, .helper, "H", at: -3600, .helperStarted(version: "1"))]), from: .helper)
        XCTAssertEqual(log.events.map(\.source), [.helper, .app])
    }

    func testOldEventsDropped() {
        let log = EventLog(url: nil)
        log.merge(EventBatch(journal: "H", events: [event(1, .helper, "H", at: -40 * 86400), event(2, .helper, "H")]), from: .helper)
        XCTAssertEqual(log.events.map(\.seq), [2])
    }

    func testPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splitpipe-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = EventLog(url: url)
        a.add(.enabled(true))
        a.merge(EventBatch(journal: "P", events: [event(7, .proxy, "P")]), from: .proxy)
        a.save()

        let b = EventLog(url: url)
        XCTAssertEqual(b.events.count, 2)
        XCTAssertEqual(b.cursor(.proxy)?.seq, 7)
        b.add(.enabled(false))
        // Номера своих событий продолжаются.
        XCTAssertEqual(b.events.filter { $0.source == .app }.map(\.seq), [1, 2])
    }

    func testClear() {
        let log = EventLog(url: nil)
        log.add(.enabled(true))
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
    }
}

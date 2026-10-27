import Foundation

/// История событий: свои события приложения и забранные из журналов расширения и помощника — одной лентой.
/// Хранится у приложения (`history.json`, 30 дней): журналы источников короче и пропадают с удалением SplitPipe.
@MainActor
final class EventLog: ObservableObject {
    /// По времени, новые в конце.
    @Published private(set) var events: [SPEvent] = []
    private var ids: Set<String> = []
    /// До какого номера какого журнала уже забрали.
    private var cursors: [EventSource: Cursor] = [:]
    private var nextSeq: UInt64 = 1
    private var saveWork: DispatchWorkItem?
    private let limit = 20000
    private let keep: TimeInterval = 30 * 86400
    private static let appJournal = "app"

    struct Cursor: Codable {
        var journal: String
        var seq: UInt64
    }

    private struct Saved: Codable {
        var events: [SPEvent]
        var cursors: [String: Cursor]
        var nextSeq: UInt64
    }

    private let url: URL?

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SplitPipe/history.json")
    }

    /// `url` — для тестов; nil — не хранить на диске.
    init(url: URL? = EventLog.defaultURL) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        events = saved.events
        ids = Set(events.map(\.id))
        cursors = Dictionary(uniqueKeysWithValues: saved.cursors.compactMap { k, v in EventSource(rawValue: k).map { ($0, v) } })
        nextSeq = saved.nextSeq
    }

    /// Событие приложения.
    func add(_ kind: EventKind) {
        insert([SPEvent(seq: nextSeq, date: Date(), source: .app, kind: kind, journal: Self.appJournal)])
        nextSeq += 1
    }

    func cursor(_ source: EventSource) -> Cursor? { cursors[source] }

    /// События, забранные у расширения или помощника. Другой журнал (файл пересоздан) — номера с начала.
    func merge(_ batch: EventBatch, from source: EventSource) {
        let fresh = batch.events.filter { !ids.contains($0.id) }
        let last = batch.events.map(\.seq).max() ?? (cursors[source]?.journal == batch.journal ? cursors[source]!.seq : 0)
        cursors[source] = Cursor(journal: batch.journal, seq: last)
        if fresh.isEmpty { scheduleSave(); return }
        insert(fresh)
    }

    func clear() {
        events = []
        ids = []
        scheduleSave()
    }

    private func insert(_ new: [SPEvent]) {
        var all = events + new
        // Источники присылают пачками и с опозданием: порядок — по времени события, а не получения.
        if let first = new.map(\.date).min(), let lastOld = events.last?.date, first < lastOld {
            all.sort { $0.date < $1.date }
        }
        let cutoff = Date().addingTimeInterval(-keep)
        all.removeAll { $0.date < cutoff }
        if all.count > limit { all.removeFirst(all.count - limit) }
        events = all
        ids = Set(all.map(\.id))
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Записать сейчас, не дожидаясь отложенного сохранения.
    func save() {
        guard let url else { return }
        let saved = Saved(events: events, cursors: Dictionary(uniqueKeysWithValues: cursors.map { ($0.key.rawValue, $0.value) }),
                          nextSeq: nextSeq)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

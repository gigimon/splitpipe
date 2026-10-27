import Foundation

/// Статистика трафика по приложениям и маршрутам. Считает расширение — она копится и при закрытом приложении.
/// Пятиминутные интервалы хранятся 2 часа (вид «Час»), часовые — 30 дней; на диск (контейнер расширения) пишется
/// раз в минуту и при остановке прокси.
final class TrafficStats: @unchecked Sendable {
    private struct Key: Hashable {
        var bucket: Int64
        var app: String
        var route: String
    }

    private let lock = NSLock()
    private var fine: [Key: StatRow] = [:]
    private var hourly: [Key: StatRow] = [:]
    private var dirty = false
    private let fineStep: Int64 = 300
    private let hourStep: Int64 = 3600
    private let fineKeep: Int64 = 2 * 3600
    private let hourlyKeep: Int64 = 30 * 86400

    private let url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("stats.json")

    private struct Saved: Codable {
        var fine: [StatRow]
        var hourly: [StatRow]
    }

    init() {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        fine = Dictionary(saved.fine.map { (Key(bucket: $0.bucket, app: $0.app, route: $0.route), $0) }, uniquingKeysWith: { a, _ in a })
        hourly = Dictionary(saved.hourly.map { (Key(bucket: $0.bucket, app: $0.app, route: $0.route), $0) }, uniquingKeysWith: { a, _ in a })
    }

    func add(app: String, route: String, down: Int64 = 0, up: Int64 = 0, flows: Int = 0, blocked: Int = 0) {
        guard down != 0 || up != 0 || flows != 0 || blocked != 0 else { return }
        let now = Int64(Date().timeIntervalSince1970)
        lock.lock(); defer { lock.unlock() }
        for (step, keyPath) in [(fineStep, \TrafficStats.fine), (hourStep, \TrafficStats.hourly)] {
            let key = Key(bucket: now - now % step, app: app, route: route)
            var row = self[keyPath: keyPath][key] ?? StatRow(bucket: key.bucket, app: app, route: route)
            row.down += down
            row.up += up
            row.flows += flows
            row.blocked += blocked
            self[keyPath: keyPath][key] = row
        }
        dirty = true
    }

    /// Строки с `from` по интервалам `bucket` секунд. Приложение просит часовые и собирает сутки по своему часовому
    /// поясу; сутки здесь (по поясу root-процесса) — для приложения старой версии.
    func query(from: Date, bucket: Int) -> [StatRow] {
        lock.lock()
        let source = bucket <= Int(fineStep) ? Array(fine.values) : Array(hourly.values)
        lock.unlock()
        let first = Self.bucketStart(Int64(from.timeIntervalSince1970), size: Int64(bucket))
        var out: [Key: StatRow] = [:]
        for row in source {
            let b = Self.bucketStart(row.bucket, size: Int64(bucket))
            guard b >= first else { continue }
            let key = Key(bucket: b, app: row.app, route: row.route)
            var agg = out[key] ?? StatRow(bucket: b, app: row.app, route: row.route)
            agg.down += row.down
            agg.up += row.up
            agg.flows += row.flows
            agg.blocked += row.blocked
            out[key] = agg
        }
        return Array(out.values)
    }

    private static func bucketStart(_ t: Int64, size: Int64) -> Int64 {
        guard size >= 86400 else { return t - t % size }
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(t)))
        return Int64(day.timeIntervalSince1970)
    }

    func reset() {
        lock.lock()
        fine.removeAll()
        hourly.removeAll()
        dirty = true
        lock.unlock()
        save()
    }

    /// Отбрасывает старое и пишет на диск, если что-то поменялось.
    func save() {
        let now = Int64(Date().timeIntervalSince1970)
        lock.lock()
        guard dirty else { lock.unlock(); return }
        fine = fine.filter { now - $0.key.bucket < fineKeep }
        hourly = hourly.filter { now - $0.key.bucket < hourlyKeep }
        let saved = Saved(fine: Array(fine.values), hourly: Array(hourly.values))
        dirty = false
        lock.unlock()
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        } catch {
            logger.error("stats save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

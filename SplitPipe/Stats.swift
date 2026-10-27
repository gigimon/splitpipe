import Foundation

enum StatsPeriod: String, CaseIterable {
    case hour, today, week, month

    var title: String {
        switch self {
        case .hour: String(localized: "Час")
        case .today: String(localized: "Сегодня")
        case .week: String(localized: "7 дней")
        case .month: String(localized: "30 дней")
        }
    }

    /// Продолжение фразы: «Трафик через SplitPipe за сегодня».
    var subtitle: String {
        switch self {
        case .hour: String(localized: "за последний час")
        case .today: String(localized: "за сегодня")
        case .week: String(localized: "за 7 дней")
        case .month: String(localized: "за 30 дней")
        }
    }

    /// Шаг графика в секундах.
    var bucket: Int {
        switch self {
        case .hour: 300
        case .today: 3600
        case .week, .month: 86400
        }
    }

    func from(_ now: Date = Date()) -> Date {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        switch self {
        case .hour: return now.addingTimeInterval(-3600)
        case .today: return day
        case .week: return cal.date(byAdding: .day, value: -6, to: day)!
        case .month: return cal.date(byAdding: .day, value: -29, to: day)!
        }
    }

    /// Все интервалы периода, в том числе пустые: график без пропусков.
    func buckets(_ now: Date = Date()) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var t: Date
        switch self {
        case .hour:
            let s = Int64(from(now).timeIntervalSince1970)
            t = Date(timeIntervalSince1970: TimeInterval(s - s % 300))
        default:
            t = from(now)
        }
        while t <= now {
            out.append(t)
            t = self == .week || self == .month ? cal.date(byAdding: .day, value: 1, to: t)! : t.addingTimeInterval(TimeInterval(bucket))
        }
        return out
    }
}

/// Итоги по приложению или маршруту за период.
struct StatTotals {
    var down: Int64 = 0
    var up: Int64 = 0
    var flows = 0
    var blocked = 0
    var bytes: Int64 { down + up }

    mutating func add(_ r: StatRow) {
        down += r.down
        up += r.up
        flows += r.flows
        blocked += r.blocked
    }
}

extension AppModel {
    /// Статистика хранится в расширении: без работающего прокси её не получить.
    /// Сутки собираются здесь из часовых интервалов расширения: границы дня — по часовому поясу пользователя,
    /// а не root-процесса (REVIEW3, 5).
    func loadStats(_ period: StatsPeriod) async {
        let daily = period.bucket >= 86400
        if case .stats(let rows)? = await proxy.send(.stats(from: period.from(), bucket: daily ? 3600 : period.bucket)) {
            statRows = daily ? Self.byLocalDay(rows) : rows
            statsAvailable = true
        } else {
            statsAvailable = false
        }
    }

    private static func byLocalDay(_ rows: [StatRow]) -> [StatRow] {
        var out: [String: StatRow] = [:]
        for r in rows {
            let day = Int64(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.bucket))).timeIntervalSince1970)
            let key = "\(day)|\(r.app)|\(r.route)"
            var agg = out[key] ?? StatRow(bucket: day, app: r.app, route: r.route)
            agg.down += r.down
            agg.up += r.up
            agg.flows += r.flows
            agg.blocked += r.blocked
            out[key] = agg
        }
        return Array(out.values)
    }

    func resetStats() {
        Task {
            _ = await proxy.send(.resetStats)
            statRows = []
        }
    }
}

func formatBytes(_ b: Int64) -> String {
    b > 0 ? b.formatted(.byteCount(style: .file).locale(.app)) : "—"
}

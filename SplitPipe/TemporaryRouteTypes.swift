import Foundation

/// Временный маршрут приложения: на 15 минут, час, до выхода из приложения или до отключения VPN. Потом правило само
/// возвращается к прежнему. Расширение о нём не знает — у него обычное правило; срок отслеживает приложение. Если оно
/// закрыто, правило досрочно не вернётся: просроченные временные маршруты снимаются сразу при следующем запуске.
struct TemporaryRoute: Codable, Equatable {
    enum End: Codable, Equatable {
        case at(Date)
        /// Когда приложение закроется.
        case appQuit
        /// Когда VPN временного маршрута отключится.
        case vpnDisconnect
    }

    var route: String
    var end: End
    /// Правило до временного маршрута; nil — правила не было.
    var previous: AppRule?
    /// С какого момента VPN временного маршрута не виден. Переподключение (роуминг Wi-Fi, перезапуск демона) —
    /// ещё не отключение: снимаем, только если VPN не вернулся за `TemporaryRoute.vpnGrace`.
    var vpnDownSince: Date?

    static let vpnGrace: TimeInterval = 30
}

/// Варианты «на время…» в меню.
enum TemporaryDuration: CaseIterable, Identifiable {
    case minutes15, hour, untilQuit, untilVPNDisconnect

    var id: Self { self }

    var title: String {
        switch self {
        case .minutes15: String(localized: "15 минут")
        case .hour: String(localized: "1 час")
        case .untilQuit: String(localized: "До выхода из приложения")
        case .untilVPNDisconnect: String(localized: "До отключения VPN")
        }
    }

    var end: TemporaryRoute.End { end(from: Date()) }

    func end(from now: Date) -> TemporaryRoute.End {
        switch self {
        case .minutes15: .at(now.addingTimeInterval(15 * 60))
        case .hour: .at(now.addingTimeInterval(60 * 60))
        case .untilQuit: .appQuit
        case .untilVPNDisconnect: .vpnDisconnect
        }
    }

    /// Срок из ссылки: `15m`, `1h`, `quit`, `vpn`; nil или пусто — навсегда.
    static func parse(_ s: String?) throws -> TemporaryDuration? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "15m", "15": return .minutes15
        case "1h", "60m", "60": return .hour
        case "quit": return .untilQuit
        case "vpn": return .untilVPNDisconnect
        default: throw CommandError.badDuration(s)
        }
    }
}

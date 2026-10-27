import Foundation

extension Locale {
    /// Язык интерфейса — тот, что macOS выбрала из локализаций приложения по языкам системы (русский, иначе
    /// английский), остальное (регион, 24-часовое время, календарь) — системное. По ней же форматируются страны,
    /// даты и размеры: системная `Locale.current` при английском интерфейсе на, скажем, немецкой системе дала бы
    /// немецкие названия стран посреди английского текста.
    static let app: Locale = {
        var c = Locale.Components(locale: .current)
        c.languageComponents = Locale.Language.Components(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return Locale(components: c)
    }()
}

/// Тексты помощника: он присылает коды, а не строки — у root своя локаль.
extension HelperEvent {
    var text: String {
        switch self {
        case .routesRestored(let iface, let gateway): String(localized: "восстановлен маршрут через \(iface) (\(gateway))")
        case .routesRemoved(let ifs): String(localized: "сняты маршруты через \(ifs.joined(separator: ", "))")
        case .bypassEnabled(let ifs): String(localized: "обход kill switch через \(ifs.joined(separator: ", "))")
        case .bypassDisabled: String(localized: "обход kill switch выключен")
        case .noGateway(let iface): String(localized: "нет шлюза у \(iface)")
        case .routesNotRestored(let iface, let output): String(localized: "маршрут через \(iface) не восстановлен: \(output)")
        case .anchorNotLoaded(let output): String(localized: "pf-правило не загрузилось: \(output)")
        case .pfDisabled: String(localized: "pf выключен — обход не нужен")
        case .anchorNotCalled: String(localized: "в общем наборе правил pf нет вызова anchor \"com.apple/*\"")
        case .anchorShadowed(let rule): String(localized: "раньше нашего якоря в pf стоит: \(rule)")
        case .proxyNotRunning: String(localized: "прокси SplitPipe не работает — обход kill switch снят")
        }
    }
}

extension FlowRecord {
    /// Маршрут соединения на языке интерфейса. Расширение пишет в `route` готовое имя: для своих маршрутов — по-русски
    /// (у него нет локализаций), для VPN — имя клиента или данное пользователем, его переводить не нужно.
    var routeLabel: String {
        switch route {
        case "Напрямую": String(localized: "Напрямую")
        case "По умолчанию": String(localized: "По умолчанию")
        case "Заблокировано": String(localized: "Заблокировано")
        default: route
        }
    }
}

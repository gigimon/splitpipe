import SwiftUI

struct RouteInfo: Identifiable, Hashable {
    enum Kind { case direct, vpn }

    var id: String
    var kind: Kind
    var name: String
    var detail: String
    /// nil — маршрут сейчас недоступен (VPN отключён, нет сети).
    var interface: String?
    var address: String?
    var holdsDefault = false
    var tint: Color
    var symbol: String

    var up: Bool { interface != nil }
}

/// Куда фактически идёт трафик приложения с учётом недоступных маршрутов.
struct EffectiveRoute: Hashable {
    enum Block: Hashable { case rule, unavailable, noNetwork }

    /// Маршрут, через который идёт трафик; nil — заблокирован.
    var route: String?
    var block: Block?
    /// Выбранный маршрут, который сейчас недоступен.
    var unavailable: String?
    var fallbackUnavailable: String?
    var viaDefault = false
}

enum RouteDiscovery {
    static let amneziaTint = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let directTint = Color(red: 0.16, green: 0.66, blue: 0.36)
    private static let palette: [Color] = [
        Color(red: 0.04, green: 0.62, blue: 0.71),
        Color(red: 0.64, green: 0.35, blue: 0.85),
        Color(red: 0.93, green: 0.55, blue: 0.10),
        Color(red: 0.85, green: 0.30, blue: 0.50),
    ]

    static func tint(forVPN key: String) -> Color {
        if key == "amnezia" { return amneziaTint }
        return palette[key.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }

    static func defaultName(forVPN key: String) -> String { RouteID.defaultName(forVPN: key) }

    /// Текущие маршруты: основное физическое подключение и каждый `utun` с IPv4.
    /// `known` — VPN из правил: если их сейчас нет, они показываются отключёнными, а правило не теряется.
    /// Роли превращаются в интерфейсы так же, как в расширении (`NetworkState`), чтобы экран показывал то, что происходит.
    static func discover(names: [String: String], known: Set<String>) -> (routes: [RouteInfo], network: NetworkState) {
        let net = NetworkState.current()
        let ifs = SystemTools.interfaces()
        let defaultIf = net.defaultInterface
        let phys = ifs.first { $0.name == net.physical }
        let ethernet = phys.map { !$0.label.localizedCaseInsensitiveContains("Wi-Fi") } ?? false

        var routes = [RouteInfo(
            id: RouteID.direct, kind: .direct, name: String(localized: "Напрямую"),
            detail: phys.map { "\($0.label) · \($0.name)" } ?? String(localized: "нет сети"),
            interface: phys?.name, address: phys?.address, tint: directTint,
            symbol: ethernet ? "cable.connector" : "wifi")]

        var seen = Set<String>()
        for t in ifs where t.isTunnel {
            let key = net.vpnKey(forTunnel: t.name)
            let id = RouteID.vpn(key)
            seen.insert(id)
            routes.append(RouteInfo(
                id: id, kind: .vpn, name: names[key] ?? net.vpnName(forKey: key),
                detail: (net.vpns[t.name].map { $0.clientTitle + " · " } ?? "") + t.name,
                interface: t.name, address: t.address, holdsDefault: t.name == defaultIf,
                tint: tint(forVPN: key), symbol: "lock.shield"))
        }
        for id in known.sorted() where id.hasPrefix("vpn:") && !seen.contains(id) {
            let key = String(id.dropFirst(4))
            routes.append(RouteInfo(
                id: id, kind: .vpn, name: names[key] ?? defaultName(forVPN: key), detail: String(localized: "отключён"),
                interface: nil, tint: tint(forVPN: key), symbol: "lock.shield"))
        }
        return (routes, net)
    }
}

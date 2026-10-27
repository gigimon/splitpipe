import Foundation

/// Root-помощник (`SMAppService.daemon`): держит обход kill switch — pf-правило и scoped-маршруты физического
/// интерфейса (пока VPN держит маршрут по умолчанию), — пока SplitPipe включён, восстанавливает их после сна,
/// перезагрузки и переподключения VPN и снимает, когда они не нужны.
enum HelperConfig {
    static let machService = "dev.splitpipe.helper"
    static let plistName = "dev.splitpipe.helper.plist"
    static let pfAnchor = "com.apple/splitpipe"
    /// Помощник принимает подключения только от SplitPipe, подписанного нашей командой, и наоборот.
    static let appRequirement = #"identifier "dev.splitpipe.app" and anchor apple generic and certificate leaf[subject.OU] = "BL65NHTRYD""#
    static let helperRequirement = #"identifier "dev.splitpipe.helper" and anchor apple generic and certificate leaf[subject.OU] = "BL65NHTRYD""#
}

struct HelperStatus: Codable, Equatable {
    /// `CFBundleVersion` помощника: после обновления приложения старый процесс перезапускается.
    var version: String
    var enabled: Bool
    /// Интерфейсы в pf-правиле (`pass out quick on en1 user root`); пусто — правила нет.
    var anchorInterfaces: [String]
    var physical: String?
    /// «Напрямую» через физический интерфейс работает: есть scoped-маршрут или VPN не держит маршрут по умолчанию.
    var directUsable: Bool
    /// Последнее, что помощник исправил сам: «восстановлен маршрут через en1», и когда.
    var lastAction: String?
    var lastActionAt: Date?
    var lastError: String?
    /// Действует ли pf-правило: наш якорь вызывается в общем наборе правил pf раньше правил VPN. nil — не проверялось
    /// (SplitPipe выключен). Kill switch VPN-клиента при переподключении может перезагрузить pf так, что якорь не вызывается.
    var anchorEffective: Bool?
    /// Почему не действует, или «pf выключен».
    var pfNote: String?

    /// В JSON — прежний ключ `scopedRoute`: приложение и помощник разных версий понимают друг друга, пока помощник
    /// не перезапустился после обновления.
    private enum CodingKeys: String, CodingKey {
        case version, enabled, anchorInterfaces, physical, lastAction, lastActionAt, lastError, anchorEffective, pfNote
        case directUsable = "scopedRoute"
    }
}

@objc protocol HelperProtocol {
    /// Включает или выключает обход kill switch и сразу приводит систему в нужное состояние. Ответ — `HelperStatus` в JSON.
    func setEnabled(_ enabled: Bool, reply: @escaping (Data?) -> Void)
    func status(reply: @escaping (Data?) -> Void)
    /// Сбросить соединения процессов (`[Int32]` в JSON) и тех, за кого они отвечают, которые идут мимо расширения:
    /// открытые до SplitPipe. Ответ — число сброшенных соединений.
    func resetConnections(_ pids: Data, reply: @escaping (Int) -> Void)
    /// Завершиться, чтобы launchd запустил новую версию из обновлённого приложения.
    func restart(reply: @escaping () -> Void)
    /// События журнала помощника после номера `after` журнала `journal` (другой журнал — все): `EventBatch` в JSON.
    func events(after: UInt64, journal: String?, reply: @escaping (Data?) -> Void)
}

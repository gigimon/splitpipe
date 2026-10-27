import Foundation
import ServiceManagement

/// Root-помощник: регистрация в launchd (`SMAppService.daemon`, одно подтверждение в Login Items & Extensions)
/// и XPC с ним. Сам обход kill switch держит помощник — приложению достаточно сказать, включён ли SplitPipe.
@MainActor
final class HelperController: ObservableObject {
    @Published private(set) var registration: SMAppService.Status
    @Published private(set) var status: HelperStatus?
    /// Последнее действие, ошибка и замечание о pf кодами (`HelperEvent`) — текст на языке интерфейса.
    @Published private(set) var events = HelperEvents()
    @Published var lastError: String?
    private let service = SMAppService.daemon(plistName: HelperConfig.plistName)
    private var connection: NSXPCConnection?
    private var restarted = false

    init() { registration = service.status }

    var title: String {
        switch registration {
        case .enabled: status == nil ? String(localized: "не отвечает") : String(localized: "работает")
        case .requiresApproval: String(localized: "ждёт разрешения в System Settings → Login Items & Extensions")
        case .notRegistered: String(localized: "не установлен")
        case .notFound: String(localized: "не найден в приложении")
        @unknown default: "?"
        }
    }

    // Старый помощник (до перезапуска после обновления) событий не присылает — тогда его строки как есть.
    var lastActionText: String? { events.lastActionEvent?.text ?? status?.lastAction }
    var lastErrorText: String? { events.lastErrorEvent?.text ?? status?.lastError }
    var pfNoteText: String? { events.pfNoteEvent?.text ?? status?.pfNote }

    var running: Bool { registration == .enabled && status != nil }

    /// Регистрирует помощника. Первый раз macOS просит разрешить его в настройках — открываем их.
    func install() {
        do {
            try service.register()
        } catch {
            lastError = error.localizedDescription
        }
        registration = service.status
        if registration == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() async {
        _ = await call { $0.setEnabled(false, reply: $1) }
        try? await service.unregister()
        connection?.invalidate()
        connection = nil
        status = nil
        events = HelperEvents()
        registration = service.status
    }

    func refresh() async {
        registration = service.status
        guard registration == .enabled else { status = nil; return }
        apply(await call { $0.status(reply: $1) })
        await restartIfOutdated()
    }

    /// Обход kill switch нужен, пока SplitPipe включён.
    func setEnabled(_ on: Bool) async {
        registration = service.status
        guard registration == .enabled else { return }
        apply(await call { $0.setEnabled(on, reply: $1) })
        await restartIfOutdated()
    }

    /// Сбрасывает соединения процессов, идущие мимо расширения (открытые до SplitPipe). Число сброшенных.
    func resetConnections(pids: [pid_t]) async -> Int {
        guard registration == .enabled, !pids.isEmpty, let data = try? JSONEncoder().encode(pids) else { return 0 }
        return await withCheckedContinuation { cont in
            var done = false
            let finish: (Int) -> Void = { n in
                DispatchQueue.main.async {
                    guard !done else { return }
                    done = true
                    cont.resume(returning: n)
                }
            }
            guard let proxy = remote(onError: { _ in finish(0) }) else { finish(0); return }
            proxy.resetConnections(data) { finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(0) }
        }
    }

    /// События журнала помощника; nil — не ответил или старая версия без журнала.
    func events(after seq: UInt64, journal: String?) async -> EventBatch? {
        guard registration == .enabled else { return nil }
        return await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            guard let proxy = remote(onError: { _ in once.resume(nil) }) else { once.resume(nil); return }
            proxy.events(after: seq, journal: journal) { data in
                once.resume(data.flatMap { try? JSONDecoder().decode(EventBatch.self, from: $0) })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.resume(nil) }
        }
    }

    /// Процесс помощника живёт дольше приложения: после обновления SplitPipe работает старый бинарь.
    private func restartIfOutdated() async {
        let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard !restarted, let status, let mine, status.version != mine else { return }
        restarted = true
        // Помощник мог завершиться, не ответив: без обработчика ошибки и таймаута `refresh()` ждал бы вечно,
        // и статус помощника больше не обновлялся бы (REVIEW3, 4.5).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            guard let proxy = remote(onError: { _ in once.resume(()) }) else { once.resume(()); return }
            proxy.restart { once.resume(()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.resume(()) }
        }
        connection?.invalidate()
        connection = nil
        try? await Task.sleep(for: .seconds(1.5))
        apply(await call { $0.status(reply: $1) })
    }

    private func apply(_ reply: (HelperStatus, HelperEvents)?) {
        status = reply?.0
        events = reply?.1 ?? HelperEvents()
    }

    private func call(_ body: @escaping (HelperProtocol, @escaping (Data?) -> Void) -> Void) async -> (HelperStatus, HelperEvents)? {
        await withCheckedContinuation { cont in
            var done = false
            let finish: ((HelperStatus, HelperEvents)?) -> Void = { s in
                DispatchQueue.main.async {
                    guard !done else { return }
                    done = true
                    cont.resume(returning: s)
                }
            }
            guard let proxy = remote(onError: { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription }
                finish(nil)
            }) else { finish(nil); return }
            body(proxy) { data in
                guard let data, let status = try? JSONDecoder().decode(HelperStatus.self, from: data) else { finish(nil); return }
                finish((status, (try? JSONDecoder().decode(HelperEvents.self, from: data)) ?? HelperEvents()))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    private func remote(onError: ((Error) -> Void)? = nil) -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperConfig.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            // Отвечать должен только наш помощник.
            c.setCodeSigningRequirement(HelperConfig.helperRequirement)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { onError?($0) } as? HelperProtocol
    }
}

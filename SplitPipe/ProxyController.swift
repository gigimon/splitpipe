import AppKit
import Foundation
@preconcurrency import NetworkExtension
import os
import SystemExtensions

private let log = Logger(subsystem: Config.logSubsystem, category: "app")

enum ExtensionState: Equatable {
    case checking, notInstalled, awaitingApproval, activating, updating, active, needsReboot
    case failed(String)

    var title: String {
        switch self {
        case .checking: String(localized: "проверяю…")
        case .notInstalled: String(localized: "не установлено")
        case .awaitingApproval: String(localized: "ждёт разрешения в System Settings → Login Items & Extensions")
        case .activating: String(localized: "запрос активации…")
        case .updating: String(localized: "обновляю…")
        case .active: String(localized: "активировано")
        case .needsReboot: String(localized: "активируется после перезагрузки")
        case .failed(let e): String(localized: "ошибка: \(e)")
        }
    }
}

/// Установка system extension и управление NETransparentProxyManager.
///
/// Все операции с конфигурацией и сессией (сохранение, старт, стоп, замена расширения) идут строго по очереди
/// (`serialized`): одновременные `saveToPreferences` дают `configuration is stale`, а старт посреди замены расширения
/// оставлял систему без сети до перезагрузки. Запуск по требованию (`onDemandRules`) не используется: он делает прокси
/// обязательным для всей системы — новые соединения ждут провайдера, и если тот в этот момент заменяется или не
/// стартует, висит весь трафик, включая DNS и сам VPN. Автозапуск — приложение в Login Items включает прокси само.
@MainActor
final class ProxyController: NSObject, ObservableObject {
    @Published var extensionState: ExtensionState = .checking
    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?
    private var manager: NETransparentProxyManager? {
        didSet { configured = manager != nil }
    }
    /// Конфигурация прокси есть в настройках системы (пользователь разрешил её добавить).
    @Published private(set) var configured = false
    /// Конфигурация загружена и состояние расширения известно — до этого онбординг не показываем.
    @Published private(set) var loaded = false
    private var observer: NSObjectProtocol?
    private var observedConnection: NEVPNConnection?
    private var propertiesRequest: OSSystemExtensionRequest?
    /// Хвост очереди операций с `NETransparentProxyManager`.
    private var tail: Task<Void, Never>?
    /// Конфигурация, которую должно получить расширение (`push`), её ревизия и последняя подтверждённая.
    private var desired: ProviderConfig?
    private var desiredRevision = 0
    private var deliveredRevision = 0
    private var deliveryScheduled = false
    /// Замена расширения ждёт, пока система её закончит (`didFinishWithResult`).
    private var activationWaiter: CheckedContinuation<Void, Never>?
    private var activationWaiterID = 0
    private let defaults = UserDefaults.standard
    private static let wantsRunningKey = "proxyWanted"
    /// SplitPipe включён пользователем: после замены расширения и при запуске приложения прокси поднимается снова.
    private(set) var wantsRunning = false {
        didSet { defaults.set(wantsRunning, forKey: Self.wantsRunningKey) }
    }
    /// Настройка «Запуск при старте»: включать прокси при запуске приложения, если SplitPipe был включён.
    var startAtBoot = false
    /// Расширение установлено впервые (конфигурации прокси ещё нет): приложение сразу включает SplitPipe.
    var onFirstActivation: (() -> Void)?
    private var autoActivated = false

    /// Версия расширения внутри этого приложения.
    private var bundledVersion: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions/\(Config.extensionBundleID).systemextension")
        return Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
    }

    func activateExtension() {
        extensionState = .activating
        submitActivation()
    }

    private func submitActivation() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Config.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Спрашивает систему, установлено ли расширение. Если установлена другая версия, обновляет её.
    func checkExtension() {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Config.extensionBundleID, queue: .main)
        request.delegate = self
        propertiesRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func handle(_ properties: [OSSystemExtensionProperties]) {
        let current = properties.filter { !$0.isUninstalling }
        if let enabled = current.first(where: \.isEnabled) {
            if let bundled = bundledVersion, enabled.bundleVersion != bundled {
                updateExtension()
            } else {
                extensionState = .active
                if wantsRunning && startAtBoot { startSession() }
            }
        } else if current.contains(where: \.isAwaitingUserApproval) {
            extensionState = .awaitingApproval
        } else {
            extensionState = .notInstalled
            // Установка без лишних кликов: запрос на активацию сразу, macOS сама покажет, где разрешить.
            if !autoActivated {
                autoActivated = true
                activateExtension()
            }
        }
    }

    /// Замена расширения только при остановленной сессии: сначала стоп и ожидание `.disconnected`, потом замена
    /// и ожидание её конца, и только потом старт нового.
    private func updateExtension() {
        extensionState = .updating
        let resume = wantsRunning || status == .connected
        Task {
            await serialized {
                await self.stopAndWait()
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.activationWaiter = cont
                    self.activationWaiterID += 1
                    let id = self.activationWaiterID
                    self.submitActivation()
                    // Если система так и не ответила (ждёт разрешения), очередь не должна встать навсегда.
                    Task {
                        try? await Task.sleep(for: .seconds(60))
                        if self.activationWaiterID == id { self.finishActivationWait() }
                    }
                }
                if resume && self.extensionState == .active { await self.startIfStopped() }
            }
        }
    }

    private func finishActivationWait() {
        activationWaiter?.resume()
        activationWaiter = nil
    }

    func load() async {
        do {
            manager = try await NETransparentProxyManager.loadAllFromPreferences().first
        } catch {
            lastError = "loadAllFromPreferences: \(error.localizedDescription)"
        }
        // Прошлые версии хранили «включён» в запуске по требованию.
        wantsRunning = defaults.object(forKey: Self.wantsRunningKey) as? Bool
            ?? (manager?.isOnDemandEnabled == true || manager?.connection.status == .connected)
        observeStatus()
        if let m = manager, m.isOnDemandEnabled {
            await serialized { await self.disableOnDemand(m) }
        }
        checkExtension()
        loaded = true
    }

    func start(config: ProviderConfig) async {
        wantsRunning = true
        await serialized {
            await self.waitForStableStatus()
            do {
                let m = self.manager ?? NETransparentProxyManager()
                try await self.save(m, config: config)
                // Сохранённую при старте конфигурацию расширение прочитает само — повторная доставка не нужна.
                self.desired = config
                self.desiredRevision += 1
                self.deliveredRevision = self.desiredRevision
                try await m.loadFromPreferences()
                self.manager = m
                self.observeStatus()
                // Пока расширение заменяется, старт сделает замена, когда закончится.
                guard self.extensionState != .updating else { return }
                if m.connection.status == .disconnected || m.connection.status == .invalid {
                    try m.connection.startVPNTunnel()
                }
                self.lastError = nil
            } catch {
                self.lastError = "start: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        wantsRunning = false
        Task {
            await serialized {
                guard let m = self.manager else { return }
                if m.isOnDemandEnabled { await self.disableOnDemand(m) }
                m.connection.stopVPNTunnel()
            }
        }
    }

    /// Полное удаление: конфигурация прокси из настроек системы и само расширение.
    func uninstall() async {
        await serialized {
            await self.stopAndWait()
            try? await self.manager?.removeFromPreferences()
            self.manager = nil
            self.observeStatus()
        }
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Config.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Сохраняет правила в конфигурацию (переживут перезапуск) и отправляет их в работающее расширение.
    /// Конфигурация — желаемая, с ревизией: несколько изменений подряд уходят одной доставкой последней версии,
    /// а неподтверждённая расширением доставка повторяется (REVIEW3, 5). `force` — отправить, даже если не менялась
    /// (расширение её потеряло).
    func push(config: ProviderConfig, force: Bool = false) {
        guard force || config != desired else { return }
        desired = config
        desiredRevision += 1
        scheduleDelivery()
    }

    /// Одна доставка в очереди операций за раз: та, что уже стоит, возьмёт самую свежую конфигурацию.
    private func scheduleDelivery(after delay: Duration? = nil) {
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        Task {
            if let delay { try? await Task.sleep(for: delay) }
            await serialized { await self.deliver() }
        }
    }

    private func deliver() async {
        deliveryScheduled = false
        guard let config = desired, deliveredRevision < desiredRevision, let m = manager else { return }
        let revision = desiredRevision
        await waitForStableStatus()
        do {
            try await save(m, config: config)
        } catch {
            lastError = "save rules: \(error.localizedDescription)"
        }
        // Прокси не работает — конфигурация сохранена, при старте расширение прочитает её само.
        guard status == .connected else {
            deliveredRevision = max(deliveredRevision, revision)
            return
        }
        if case .ok? = await send(.setConfig(config)) {
            deliveredRevision = max(deliveredRevision, revision)
        } else {
            log.error("config revision \(revision) not confirmed by provider, retrying in 2 s")
            scheduleDelivery(after: .seconds(2))
        }
    }

    /// Не ответил за таймаут (замена расширения, зависание) — nil: иначе вставала бы вся очередь `serialized`
    /// (REVIEW3, 4.5). Проверка маршрута и STUN в расширении сами ждут до ~9 с — им дольше.
    func send(_ request: ProviderRequest) async -> ProviderReply? {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession,
              let data = try? JSONEncoder().encode(request) else { return nil }
        let timeout: TimeInterval = switch request {
        case .probe, .stun: 20
        default: 5
        }
        return await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume(nil) { log.error("provider did not answer in \(Int(timeout)) s") }
            }
            do {
                try session.sendProviderMessage(data) { response in
                    once.resume(response.flatMap { try? JSONDecoder().decode(ProviderReply.self, from: $0) })
                }
            } catch {
                once.resume(.error(error.localizedDescription))
            }
        }
    }

    // MARK: - Очередь операций

    /// Выполняет операцию после всех ранее поставленных.
    private func serialized<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    /// Ставит старт в очередь; если сессия уже работает, ничего не делает.
    private func startSession() {
        Task { await serialized { await self.startIfStopped() } }
    }

    /// Сразу после замены расширения nesessionmanager бывает ещё не готов: старт падает или сессия тут же
    /// останавливается, и прокси оставался выключенным до перезапуска приложения. Три попытки с паузой 2 с.
    /// `.invalid` — конфигурация ещё не перечитана после замены: тоже пробуем, перечитав её.
    private func startIfStopped() async {
        for attempt in 1...3 {
            await waitForStableStatus()
            // Пока ждали, SplitPipe могли выключить.
            guard wantsRunning, let m = manager,
                  m.connection.status == .disconnected || m.connection.status == .invalid else { return }
            if m.connection.status == .invalid { try? await m.loadFromPreferences() }
            do {
                try m.connection.startVPNTunnel()
                await waitFor { $0 != .disconnected && $0 != .invalid }
                await waitForStableStatus()
                if m.connection.status == .connected { return }
                log.error("proxy did not start (attempt \(attempt)): \(m.connection.status.rawValue)")
            } catch {
                lastError = "start: \(error.localizedDescription)"
                log.error("proxy start failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
            }
            guard attempt < 3 else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Останавливает сессию и ждёт `.disconnected`. Сессию, которую система уже остановила, не трогает.
    private func stopAndWait() async {
        guard let connection = manager?.connection else { return }
        await waitForStableStatus()
        if connection.status == .connected { connection.stopVPNTunnel() }
        await waitFor { $0 == .disconnected || $0 == .invalid }
    }

    /// Ждёт, пока сессия не в переходном состоянии: сохранять конфигурацию посреди старта или остановки нельзя.
    private func waitForStableStatus() async {
        await waitFor { $0 != .connecting && $0 != .disconnecting && $0 != .reasserting }
    }

    private func waitFor(_ done: (NEVPNStatus) -> Bool, timeout: Duration = .seconds(10)) async {
        guard let connection = manager?.connection else { return }
        let deadline = ContinuousClock.now + timeout
        while !done(connection.status), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func disableOnDemand(_ m: NETransparentProxyManager) async {
        m.isOnDemandEnabled = false
        m.onDemandRules = nil
        do {
            try await m.saveToPreferences()
        } catch {
            try? await m.loadFromPreferences()
            m.isOnDemandEnabled = false
            m.onDemandRules = nil
            do { try await m.saveToPreferences() } catch { lastError = String(localized: "запуск по требованию: \(error.localizedDescription)") }
        }
    }

    /// Вызывать внутри `serialized`. Если конфигурацию всё же поменяли снаружи (`configurationStale`), перечитываем
    /// и сохраняем ещё раз.
    private func save(_ m: NETransparentProxyManager, config: ProviderConfig) async throws {
        do {
            try configure(m, config: config)
            try await m.saveToPreferences()
        } catch let error as NSError where error.domain == NEVPNErrorDomain
            && error.code == NEVPNError.Code.configurationStale.rawValue {
            try await m.loadFromPreferences()
            try configure(m, config: config)
            try await m.saveToPreferences()
        }
    }

    private func configure(_ m: NETransparentProxyManager, config: ProviderConfig) throws {
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Config.extensionBundleID
        proto.serverAddress = "SplitPipe"
        proto.providerConfiguration = ["config": try JSONEncoder().encode(config)]
        m.protocolConfiguration = proto
        m.localizedDescription = "SplitPipe"
        m.isEnabled = true
        m.onDemandRules = nil
        m.isOnDemandEnabled = false
    }

    /// Наблюдатель — за текущим `connection`: после удаления и новой установки это другой объект.
    private func observeStatus() {
        status = manager?.connection.status ?? .invalid
        let connection = manager?.connection
        guard connection !== observedConnection else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedConnection = connection
        guard let connection else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.status = connection.status }
        }
    }
}

extension ProxyController: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.extensionState = .awaitingApproval
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        Task { @MainActor in self.handle(properties) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            guard request !== self.propertiesRequest else { return }
            self.extensionState = result == .completed ? .active : .needsReboot
            // Замену ждёт очередь операций: она же и запустит прокси снова.
            if self.activationWaiter != nil {
                self.finishActivationWait()
            } else if result == .completed && self.manager == nil {
                self.onFirstActivation?()
            } else if result == .completed && self.wantsRunning {
                self.startSession()
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.extensionState = .failed(error.localizedDescription)
            if request !== self.propertiesRequest { self.finishActivationWait() }
        }
    }
}

extension NEVPNStatus {
    var title: String {
        switch self {
        case .invalid: String(localized: "не настроен")
        case .disconnected: String(localized: "выключен")
        case .connecting: String(localized: "включается…")
        case .connected: String(localized: "работает")
        case .reasserting: String(localized: "переподключение…")
        case .disconnecting: String(localized: "выключается…")
        @unknown default: "?"
        }
    }
}

/// Продолжение, которое возобновляется ровно один раз — ответом или по таймауту, что раньше.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    /// true — возобновило именно это значение.
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}

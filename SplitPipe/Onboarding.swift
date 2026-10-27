import AppKit
import ServiceManagement

/// Шаг первого запуска. Состояние берётся из системы, а не из флажков: шаг готов, когда разрешение действительно есть.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case networkExtension, proxyConfiguration, helper

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .networkExtension: String(localized: "Сетевое расширение")
        case .proxyConfiguration: String(localized: "Конфигурация прокси")
        case .helper: String(localized: "Фоновый помощник")
        }
    }

    var detail: String {
        switch self {
        case .networkExtension: String(localized: "Перехватывает соединения приложений и направляет их по выбранному маршруту.")
        case .proxyConfiguration: String(localized: "macOS спросит разрешение подключить расширение к сетевому стеку.")
        case .helper: String(localized: "Настраивает правила pf и маршрут через Wi-Fi/Ethernet, чтобы SplitPipe работал вместе с kill switch вашего VPN.")
        }
    }

    var short: String {
        switch self {
        case .networkExtension: String(localized: "Расширение")
        case .proxyConfiguration: String(localized: "Прокси")
        case .helper: String(localized: "Помощник")
        }
    }
}

enum OnboardingState: Equatable {
    case pending, waiting(String), done, failed(String)
}

extension AppModel {
    func onboardingState(_ step: OnboardingStep) -> OnboardingState {
        switch step {
        case .networkExtension:
            switch proxy.extensionState {
            case .active: return .done
            case .awaitingApproval:
                return .waiting(String(localized: "Включите SplitPipe в System Settings → Login Items & Extensions → Network Extensions…"))
            case .activating, .updating, .checking: return .waiting(String(localized: "Запрос активации…"))
            case .needsReboot: return .failed(String(localized: "macOS активирует расширение после перезагрузки."))
            case .failed(let e): return .failed(String(localized: "Не удалось активировать: \(e)"))
            case .notInstalled: return .pending
            }
        case .proxyConfiguration:
            if proxy.configured { return .done }
            if let e = proxy.lastError, e.hasPrefix("start") { return .failed(String(localized: "Разрешение не получено: \(e)")) }
            return proxy.extensionState == .active && enabled ? .waiting(String(localized: "Подтвердите системный запрос…")) : .pending
        case .helper:
            switch helper.registration {
            case .enabled: return .done
            case .requiresApproval: return .waiting(String(localized: "Разрешите SplitPipe в разделе «Allow in the Background»…"))
            case .notFound: return .failed(String(localized: "Помощник не найден в приложении — переустановите SplitPipe."))
            default: return helper.lastError.map { .failed($0) } ?? .pending
            }
        }
    }

    /// Первый незаконченный шаг; nil — всё готово.
    var currentOnboardingStep: OnboardingStep? {
        OnboardingStep.allCases.first { onboardingState($0) != .done }
    }

    func performOnboarding(_ step: OnboardingStep) {
        switch step {
        case .networkExtension:
            if proxy.extensionState == .awaitingApproval {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            } else {
                proxy.activateExtension()
            }
        case .proxyConfiguration:
            proxy.lastError = nil
            setEnabled(true)
        case .helper:
            if helper.registration == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                helper.lastError = nil
                helper.install()
            }
        }
    }

    /// Уже всё настроено (обновление со старой версии, повторная установка) — онбординг не нужен.
    func skipOnboardingIfReady() async {
        guard !onboardingDone else { return }
        // `open SplitPipe.app --args -SPOnboarding YES` — показать онбординг и на настроенной машине (проверка вёрстки).
        if UserDefaults.standard.bool(forKey: "SPOnboarding") { return }
        for _ in 0..<20 where proxy.extensionState == .checking { try? await Task.sleep(for: .milliseconds(250)) }
        await helper.refresh()
        if currentOnboardingStep == nil { onboardingDone = true }
    }

    // MARK: - Dock и строка меню

    static func otherApp(_ app: NSRunningApplication?) -> String? {
        guard let id = app?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
        return id
    }

    /// Без значка в Dock приложение живёт в строке меню; хотя бы одно из двух всегда включено.
    func applyDockPolicy() {
        NSApp?.setActivationPolicy(settings.showInDock || !settings.showMenuBar ? .regular : .accessory)
    }
}

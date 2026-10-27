import SwiftUI

/// Первый запуск: три системных разрешения, дальше всё настраивается само.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var proxy: ProxyController
    let onFinish: () -> Void

    var body: some View {
        let current = model.currentOnboardingStep
        let done = OnboardingStep.allCases.filter { model.onboardingState($0) == .done }.count
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: current == nil ? 76 : 64, height: current == nil ? 76 : 64)
                    .padding(.bottom, 14)
                if current == nil {
                    finished
                } else {
                    Text("Настроим SplitPipe").font(.title.weight(.semibold))
                    Text("Три системных разрешения — дальше всё настроится само.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ProgressView(value: Double(done), total: Double(OnboardingStep.allCases.count))
                        .progressViewStyle(.linear)
                        .padding(.vertical, 20)
                    VStack(spacing: 10) {
                        ForEach(OnboardingStep.allCases) { step in
                            StepRow(step: step, state: model.onboardingState(step), isCurrent: step == current) {
                                model.performOnboarding(step)
                            }
                        }
                    }
                }
            }
            .frame(width: 460)
            .padding(.vertical, 40)
            // По центру окна, а если шаги не помещаются — прокрутка.
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
        }
        .scrollEdgeEffectHidden(true, for: .top)
        }
        .task {
            // Разрешения дают в System Settings: состояние помощника и расширения переспрашиваем, пока ждём.
            while !Task.isCancelled {
                await model.helper.refresh()
                if proxy.extensionState == .awaitingApproval { proxy.checkExtension() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var finished: some View {
        VStack(spacing: 0) {
            Text("Всё готово").font(.title.weight(.semibold))
            Text("SplitPipe работает. Выберите приложения и укажите, куда направлять их трафик.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            HStack(spacing: 12) {
                ForEach(OnboardingStep.allCases) { step in
                    Label(step.short, systemImage: "checkmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.green.opacity(0.13), in: Capsule())
                }
            }
            .padding(.vertical, 22)
            Toggle(isOn: $model.settings.startProxyAtBoot) {
                Text("Запускать SplitPipe при входе в систему")
                Text("Без окна, в строке меню, и сразу включать маршрутизацию. Можно поменять в настройках.")
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: 380, alignment: .leading)
            .padding(.bottom, 22)
            Button("Перейти к приложениям", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct StepRow: View {
    let step: OnboardingStep
    let state: OnboardingState
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).fontWeight(.semibold)
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                controls.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(isCurrent ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isFailed ? Color.red.opacity(0.6) : isCurrent ? Color.accentColor.opacity(0.5) : .clear))
        .opacity(state == .done || isCurrent || isFailed ? 1 : 0.55)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var badge: some View {
        ZStack {
            Circle().fill(badgeColor)
            switch state {
            case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            case .failed: Text("!").font(.system(size: 13, weight: .bold))
            default: Text("\(step.rawValue + 1)").font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(state == .done || isFailed || isCurrent ? .white : .secondary)
        .frame(width: 24, height: 24)
    }

    private var badgeColor: Color {
        switch state {
        case .done: .green
        case .failed: .red
        default: isCurrent ? .accentColor : Color.secondary.opacity(0.2)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .pending where isCurrent:
            Button(step == .proxyConfiguration ? String(localized: "Продолжить") : String(localized: "Установить"), action: action)
                .buttonStyle(.borderedProminent)
        case .waiting(let text) where isCurrent:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Открыть снова", action: action)
            }
        case .failed(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Повторить", action: action).buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }
}

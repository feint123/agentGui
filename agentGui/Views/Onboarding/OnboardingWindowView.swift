import SwiftUI
import SwiftData
import AppKit

enum OnboardingWindowScene {
    static let id = "onboarding-window"
}

struct OnboardingWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(ClaudeService.self) private var claudeService

    @State private var flowState = OnboardingFlowState()
    @State private var apiKeyInput = ""
    @State private var baseURLInput = ""
    @State private var workingDirectoryInput = ""
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var validationStatus: ConnectionValidationStatus?

    var body: some View {
        ZStack {
            BreathingLightBackground()
                .accessibilityIdentifier("onboarding.backgroundLayer")

            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    stepRail
                    heroPanel
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, 2)
            .frame(maxWidth: 980)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(OnboardingWindowConfigurator())
        .onAppear(perform: loadInputs)
    }


    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 64, height: 64)

                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("agentGui")
                        .font(.headline)
                        .foregroundStyle(.primary.opacity(0.88))

                    Text("为第一次启动保留一个独立、安静、可逐步完成的准备窗口。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary.opacity(0.62))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(OnboardingStep.allCases) { step in
                    stepRailRow(for: step)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 280, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.stepRail")
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroDragRegion

            VStack(alignment: .leading, spacing: 24) {
                heroHeader
                currentStepPanel
                footer
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.heroPanel")
    }

    private var heroDragRegion: some View {
        HStack(alignment: .center) {
            Spacer(minLength: 0)

            Capsule()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 88, height: 5)

            Spacer(minLength: 0)
        }
        .frame(height: 52)
        .background(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("onboarding.heroDragRegion")
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                labelPill(text: flowState.progressText)
                labelPill(text: "Desktop setup")
                labelPill(text: "Keyboard-first")
            }

            Text(flowState.currentStep.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier(flowState.currentStep.accessibilityTitleID)

            Text(currentStepSummary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentStepPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                switch flowState.currentStep {
                case .welcome:
                    welcomeStep
                case .connection:
                    connectionStep
                case .workspace:
                    workspaceStep
                }
            }
        }
       
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("稍后再说") {
                dismissWindow(id: OnboardingWindowScene.id)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()
        
            if flowState.canGoBack {
                Button("上一步") {
                    flowState.goBack()
                }
                .buttonStyle(.glass)
                .tint(.accentColor)
            }

            if flowState.canAdvance {
                Button("下一步") {
                    handleAdvance()
                }
                .disabled(!canAdvanceFromCurrentStep)
                .buttonStyle(.glass)
                .tint(.accentColor)

                .accessibilityIdentifier("onboarding.nextButton")
            } else {
                Button("开始使用") {
                    saveAllSettings()
                    dismissWindow(id: OnboardingWindowScene.id)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("onboarding.finishButton")
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                detailCard(icon: "bolt.horizontal.circle.fill", title: "专属首开区域", detail: "把第一次配置与后续工作界面分开，避免主窗口一上来就被提示打断。")
                detailCard(icon: "sparkles.tv.fill", title: "更像当前桌面产品", detail: "结构靠近 Raycast / Linear 这类新一代 macOS 应用：先看全局，再完成当前步骤。")
            }

            Text("你会先确认使用方式，再连接 Claude，最后把工作区准备好。完成后主窗口就进入正常工作状态。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                detailLine(title: "连接模型", detail: "API Key 是发送第一条消息的最低前提。")
                detailLine(title: "准备工作区", detail: "代码、文件、Bash、LSP 相关能力会依赖工作目录。")
                detailLine(title: "保持主界面干净", detail: "引导完成后，不再在聊天页顶部堆 onboarding 卡片。")
            }
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接步骤应该尽量短、直接，并允许立刻验证成功与否。")
                .foregroundStyle(.secondary)

            SecureField("Anthropic API Key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("onboarding.apiKeyField")

            TextField("Base URL，可留空使用官方地址", text: $baseURLInput)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button {
                    validateConnection()
                } label: {
                    if isValidating {
                        Label("验证中...", systemImage: "hourglass")
                    } else {
                        Label("验证连接", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isValidating)
                .accessibilityIdentifier("onboarding.validateButton")

                Button("打开完整设置") {
                    openWindow(id: SettingsWindowScene.id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if let validationMessage, let validationStatus {
                Label(validationMessage, systemImage: validationStatus == .passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(validationStatus == .passed ? .green : .red)
            }

            HStack(spacing: 12) {
                detailCard(icon: "lock.shield.fill", title: "先验证再继续", detail: "避免用户配完参数却在主窗口第一次发消息时才发现连接失败。")
                detailCard(icon: "slider.horizontal.3", title: "完整配置仍在设置页", detail: "首开只处理最小必要项，复杂选项保留到设置窗口。")
            }
        }
    }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("工作目录决定了文件、代码和命令相关能力能否建立可信上下文。")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                TextField("工作目录", text: $workingDirectoryInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("选择目录") {
                    chooseWorkingDirectory()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding.chooseDirectoryButton")
            }

            VStack(alignment: .leading, spacing: 10) {
                detailLine(title: "文件工具", detail: "会读写真实文件，建议只在可信项目目录里使用。")
                detailLine(title: "Bash 工具", detail: "会执行真实 shell 命令，适合在确认目录后再启用。")
                detailLine(title: "联网工具", detail: "Web Search / Fetch 依赖外网，建议按任务场景打开。")
            }
        }
    }

    private var currentStepSummary: String {
        switch flowState.currentStep {
        case .welcome:
            return "先看全局结构，再逐步完成配置。"
        case .connection:
            return "补齐最小必要连接配置，并立即验证。"
        case .workspace:
            return "给文件与代码能力一个可信的默认工作区。"
        }
    }

    private func stepRailRow(for step: OnboardingStep) -> some View {
        let isCurrent = step == flowState.currentStep
        let isCompleted = step.rawValue < flowState.currentStep.rawValue

        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color(nsColor: .tertiarySystemFill) : Color(nsColor: .quaternarySystemFill))
                    .frame(width: 30, height: 30)

                Image(systemName: isCompleted ? "checkmark" : "circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCompleted ? Color.green : (isCurrent ? Color.primary : Color.secondary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)

                Text(stepCaption(for: step))
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stepCaption(for step: OnboardingStep) -> String {
        switch step {
        case .welcome:
            return "理解这次首开流程"
        case .connection:
            return "配置并验证 Claude 连接"
        case .workspace:
            return "补齐目录与工具前提"
        }
    }

    private func labelPill(text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect()
    }

    private func detailLine(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
    private var canAdvanceFromCurrentStep: Bool {
        switch flowState.currentStep {
        case .welcome:
            return true
        case .connection:
            return !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .workspace:
            return false
        }
    }

    private func handleAdvance() {
        if flowState.currentStep == .connection {
            saveConnectionSettings()
        }
        flowState.advance()
    }

    private func loadInputs() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        apiKeyInput = settings.apiKey
        baseURLInput = settings.baseURL
        workingDirectoryInput = settings.workingDirectory
    }

    private func saveConnectionSettings() {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings.apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        try? persistenceCoordinator.save(modelContext, domain: .settings, userMessage: "首开连接设置未成功保存")
        claudeService.applyConnectionSettings(settings)
    }

    private func saveAllSettings() {
        saveConnectionSettings()
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings.workingDirectory = workingDirectoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        try? persistenceCoordinator.save(modelContext, domain: .settings, userMessage: "首开设置未成功保存")
        claudeService.applyConnectionSettings(settings)
    }

    private func validateConnection() {
        isValidating = true
        let previewSettings = AppSettings.testFixture(
            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        previewSettings.baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let result = await ConnectionValidationService().validate(settings: previewSettings)
            await MainActor.run {
                validationStatus = result.status
                validationMessage = result.messages.joined(separator: " ")
                isValidating = false
            }
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择工作目录"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectoryInput = url.standardizedFileURL.path
    }
}

private struct OnboardingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .forEach { button in
                button.alphaValue = 0.44
            }
    }
}

private enum OnboardingPreviewSupport {
    @MainActor
    static let container: ModelContainer = {
        let schema = Schema([AppSettings.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let settings = AppSettings.getOrCreate(in: context, persistenceCoordinator: .shared)
        settings.apiKey = "sk-ant-preview"
        settings.baseURL = "https://api.anthropic.com"
        settings.workingDirectory = "/Users/preview/Workspace"
        try? context.save()
        return container
    }()

    @MainActor
    static func makePreview() -> some View {
        OnboardingWindowView()
            .environment(ClaudeService())
            .environment(PersistenceCoordinator.shared)
            .modelContainer(container)
            .frame(width: 980, height: 680)
    }
}

#Preview("Onboarding Light") {
    OnboardingPreviewSupport.makePreview()
        .preferredColorScheme(.light)
}

#Preview("Onboarding Dark") {
    OnboardingPreviewSupport.makePreview()
        .preferredColorScheme(.dark)
}

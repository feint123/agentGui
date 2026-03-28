import Foundation
import Observation

@MainActor
@Observable
final class ACPProviderSettingsEditorViewModel: Identifiable {
    enum SavePhase: Equatable {
        case idle
        case validating
        case saving
    }

    struct CapabilityRow: Identifiable, Equatable {
        let title: String
        let value: String

        var id: String { title }
    }

    let id: UUID

    private let repository: ACPProviderProfileRepository
    private let validationService: ACPProviderValidationService
    private let existingProfileID: UUID?

    var displayName: String
    var executablePath: String
    var argumentsText: String
    var isEnabled: Bool
    var errorMessage: String?
    var savePhase: SavePhase
    var lastValidationSnapshot: ACPProviderValidationSnapshot?

    init(
        profile: ACPProviderProfile? = nil,
        repository: ACPProviderProfileRepository,
        validationService: ACPProviderValidationService = ACPProviderValidationService()
    ) {
        self.id = profile?.id ?? UUID()
        self.repository = repository
        self.validationService = validationService
        self.existingProfileID = profile?.id
        self.displayName = profile?.displayName ?? ""
        self.executablePath = profile?.executablePath ?? ""
        self.argumentsText = profile?.arguments.joined(separator: "\n") ?? ""
        self.isEnabled = profile?.isEnabled ?? true
        self.errorMessage = nil
        self.savePhase = .idle
        self.lastValidationSnapshot = profile?.validationSnapshot
    }

    var navigationTitle: String {
        existingProfileID == nil ? "新增 ACP Provider" : "编辑 ACP Provider"
    }

    var capabilityRows: [CapabilityRow] {
        guard let capabilities = lastValidationSnapshot?.agentCapabilities else {
            return []
        }

        var rows: [CapabilityRow] = []

        if let loadSession = capabilities.loadSession {
            rows.append(CapabilityRow(title: "会话恢复", value: loadSession ? "支持" : "不支持"))
        }

        if let promptValue = promptCapabilitySummary(capabilities.promptCapabilities) {
            rows.append(CapabilityRow(title: "多模态 Prompt", value: promptValue))
        }

        if let mcpValue = mcpCapabilitySummary(capabilities.mcpCapabilities) {
            rows.append(CapabilityRow(title: "MCP 传输", value: mcpValue))
        }

        if let sessionValue = sessionCapabilitySummary(capabilities.sessionCapabilities) {
            rows.append(CapabilityRow(title: "Session 列表", value: sessionValue))
        }

        return rows
    }

    var authMethodNames: [String] {
        (lastValidationSnapshot?.authMethods ?? []).map(\.name)
    }

    var canDelete: Bool {
        existingProfileID != nil
    }

    var isSaving: Bool {
        savePhase != .idle
    }

    var saveProgressMessage: String? {
        switch savePhase {
        case .idle:
            nil
        case .validating:
            "正在校验 Provider…"
        case .saving:
            "正在保存 Provider…"
        }
    }

    func save(reloading refresh: (@MainActor () throws -> Void)? = nil) async -> Bool {
        guard isSaving == false else {
            return false
        }

        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExecutablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedArguments = parsedArguments
        let isEnabled = isEnabled

        guard normalizedExecutablePath.isEmpty == false else {
            errorMessage = "请填写可执行文件路径。"
            return false
        }

        let effectiveDisplayName = normalizedDisplayName.isEmpty
            ? URL(fileURLWithPath: normalizedExecutablePath).lastPathComponent
            : normalizedDisplayName

        errorMessage = nil
        savePhase = isEnabled ? .validating : .saving
        defer { savePhase = .idle }

        var validationSnapshot = lastValidationSnapshot
        if isEnabled {
            let result = await Self.validateOffMainActor(
                validationService: validationService,
                displayName: effectiveDisplayName,
                executablePath: normalizedExecutablePath,
                arguments: parsedArguments
            )

            switch result {
            case .ready(let snapshot):
                validationSnapshot = snapshot
            case .missingExecutable, .initializeFailed:
                errorMessage = result.message
                return false
            }
        }

        savePhase = .saving

        do {
            let savedProfile = try repository.save(
                profileDraft: ACPProviderProfileDraft(
                    id: existingProfileID,
                    displayName: effectiveDisplayName,
                    executablePath: normalizedExecutablePath,
                    arguments: parsedArguments,
                    isEnabled: isEnabled,
                    validationSnapshot: validationSnapshot
                )
            )
            displayName = savedProfile.displayName
            executablePath = savedProfile.executablePath
            argumentsText = savedProfile.arguments.joined(separator: "\n")
            lastValidationSnapshot = savedProfile.validationSnapshot

            do {
                try refresh?()
            } catch {
                presentReloadFailure(error)
                return false
            }

            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    func save() async -> Bool {
        await save(reloading: nil)
    }

    func presentReloadFailure(_ error: Error) {
        errorMessage = "刷新 Provider 运行时失败：\(Self.describe(error))"
    }

    func presentDeleteFailure() {
        errorMessage = "删除 Provider 失败。"
    }

    private var parsedArguments: [String] {
        argumentsText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
    }

    private static func validateOffMainActor(
        validationService: ACPProviderValidationService,
        displayName: String,
        executablePath: String,
        arguments: [String]
    ) async -> ACPProviderValidationResult {
        await Task.detached(priority: .userInitiated) {
            await validationService.validate(
                displayName: displayName,
                executablePath: executablePath,
                arguments: arguments
            )
        }.value
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    private func promptCapabilitySummary(_ capabilities: ACPPromptCapabilities?) -> String? {
        guard let capabilities else {
            return nil
        }

        var enabled: [String] = []
        if capabilities.audio == true {
            enabled.append("音频")
        }
        if capabilities.embeddedContext == true {
            enabled.append("嵌入上下文")
        }
        if capabilities.image == true {
            enabled.append("图像")
        }

        return enabled.isEmpty ? "未声明" : enabled.joined(separator: "、")
    }

    private func mcpCapabilitySummary(_ capabilities: ACPMcpCapabilities?) -> String? {
        guard let capabilities else {
            return nil
        }

        var transports: [String] = []
        if capabilities.http == true {
            transports.append("HTTP")
        }
        if capabilities.sse == true {
            transports.append("SSE")
        }

        return transports.isEmpty ? "未声明" : transports.joined(separator: "、")
    }

    private func sessionCapabilitySummary(_ capabilities: ACPSessionCapabilities?) -> String? {
        guard let capabilities else {
            return nil
        }

        if let pageSize = capabilities.list?.pageSize {
            return "分页大小 \(pageSize)"
        }

        if capabilities.list != nil {
            return "支持"
        }

        return "未声明"
    }
}
import Testing
@testable import agentGui
import Foundation

struct ACPSessionConfigurationPresentationTests {
    @Test func builderUsesAdvertisedModesModelAndApprovals() {
        let snapshot = ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: [
                ACPSessionConfigOption(
                    meta: nil,
                    id: "model",
                    category: .model,
                    currentValue: "gpt-5",
                    options: .ungrouped([
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT-5", value: "gpt-5"),
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "GPT-5 Mini", value: "gpt-5-mini")
                    ]),
                    type: "select"
                ),
                ACPSessionConfigOption(
                    meta: nil,
                    id: "approvalMode",
                    category: nil,
                    currentValue: "default",
                    options: .ungrouped([
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "Default approvals", value: "default"),
                        ACPSessionConfigSelectOption(meta: nil, description: nil, name: "Bypass approvals", value: "never")
                    ]),
                    type: "select"
                )
            ],
            modes: ACPSessionModeState(
                meta: nil,
                availableModes: [
                    ACPSessionMode(meta: nil, description: nil, id: "plan", name: "Plan"),
                    ACPSessionMode(meta: nil, description: nil, id: "edit", name: "Edit")
                ],
                currentModeID: "edit"
            )
        )

        let presentation = ACPSessionConfigurationPresentationBuilder.make(
            providerID: .githubCopilotCLI,
            snapshot: snapshot
        )

        #expect(presentation.providerID == .githubCopilotCLI)
        #expect(presentation.selectedModeID == "edit")
        #expect(presentation.modeOptions.map(\.id) == ["plan", "edit"])
        #expect(presentation.modelConfig?.id == "model")
        #expect(presentation.modelConfig?.selectedValue == "gpt-5")
        #expect(presentation.approvalsConfig?.id == "approvalMode")
        #expect(presentation.approvalsConfig?.selectedValue == "default")
    }

    @Test func sessionExecutionPreferencesApplyACPSelectionsPerProvider() {
        var preferences = SessionExecutionPreferences()

        preferences.applyACPModeSelection(providerID: .githubCopilotCLI, modeID: "edit")
        preferences.applyACPConfigSelection(
            providerID: .githubCopilotCLI,
            configID: "model",
            value: "gpt-5-mini",
            modelConfigID: "model",
            approvalsConfigID: "approvalMode"
        )
        preferences.applyACPConfigSelection(
            providerID: .githubCopilotCLI,
            configID: "approvalMode",
            value: "never",
            modelConfigID: "model",
            approvalsConfigID: "approvalMode"
        )
        preferences.applyACPModeSelection(providerID: .openCodeCLI, modeID: "plan")

        #expect(preferences.gitHubCopilotCLI.modeID == "edit")
        #expect(preferences.gitHubCopilotCLI.modelID == "gpt-5-mini")
        #expect(preferences.gitHubCopilotCLI.approvalMode == "never")
        #expect(preferences.openCodeCLI.modeID == "plan")
        #expect(preferences.openCodeCLI.modelID == nil)
    }

    @Test func chatViewActionsDoesNotKeepExternalComposerOverrideBindings() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agentGui/Views/ChatView+Actions.swift")
        let source = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(source.contains("copilotComposerModelSelectionBinding") == false)
        #expect(source.contains("copilotComposerApprovalModeSelectionBinding") == false)
        #expect(source.contains("openCodeComposerModelSelectionBinding") == false)
        #expect(source.contains("openCodeComposerApprovalModeSelectionBinding") == false)
        #expect(source.contains("claudeAdapterComposerModelSelectionBinding") == false)
        #expect(source.contains("claudeAdapterComposerApprovalModeSelectionBinding") == false)
        #expect(source.contains("executionProviderSelectionBinding") == false)
        #expect(source.contains("executionProviderSelectionRawValueBinding") == false)
    }

    @Test func settingsExecutorsViewDoesNotExposeExternalApprovalModePickers() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agentGui/Views/Settings/SettingsExecutorsView.swift")
        let source = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(source.contains("settings.executors.copilotApprovalModePicker") == false)
        #expect(source.contains("settings.executors.openCodeApprovalModePicker") == false)
        #expect(source.contains("settings.executors.claudeAdapterApprovalModePicker") == false)
    }

    @Test func acpDescriptorsAndRuntimeDoNotKeepLegacyModelOverrideMetadata() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let descriptorSource = try String(
            contentsOf: repoRoot.appendingPathComponent("agentGui/Models/ACPExternalAgentDescriptor.swift"),
            encoding: .utf8
        )
        let runtimeSource = try String(
            contentsOf: repoRoot.appendingPathComponent("agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift"),
            encoding: .utf8
        )
        let contractsSource = try String(
            contentsOf: repoRoot.appendingPathComponent("agentGui/Services/ACP/ACPExternalProviderContracts.swift"),
            encoding: .utf8
        )

        #expect(descriptorSource.contains("supportsSessionModelOverrideByDefault") == false)
        #expect(descriptorSource.contains("sessionModelOverrideExtension") == false)
        #expect(descriptorSource.contains("executionBehavior") == false)
        #expect(runtimeSource.contains("supportsSessionModelOverrideFallback") == false)
        #expect(runtimeSource.contains("sessionModelOverrideExtension") == false)
        #expect(runtimeSource.contains("advertisedExtensionMethods") == false)
        #expect(contractsSource.contains("ACPExternalProviderExecutionBehavior") == false)
    }

    @Test func acpConfigurationControlsUseBorderlessButtonMenuChrome() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("agentGui/Views/ACPSessionConfigurationControls.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".menuStyle(.button)"))
        #expect(source.contains(".buttonStyle(.borderless)"))
        #expect(source.contains(".contentShape(Capsule(style: .continuous))"))
        #expect(source.contains(".background {"))
        #expect(source.contains(".overlay {"))
    }
}
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct GitHubCopilotCLIExecutionProviderTests {
    @Test func copilotDescriptorCapturesProviderSpecificExecutionBehavior() {
        let descriptor = ACPExternalAgentDescriptor.githubCopilot

        #expect(descriptor.defaultArguments == ["--acp", "--stdio"])
        #expect(descriptor.supportsSessionModelOverrideByDefault)
        #expect(descriptor.supportsCustomAgentName == false)
        #expect(descriptor.executionBehavior.requiresCapabilityNegotiationForModelOverride == false)
        #expect(descriptor.executionBehavior.supportsEnvironmentOverrides == false)
    }

    @Test func buildRuntimeClientUsesSharedExternalACPRuntimeClientByDefault() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let executableURL = try makeIdleExecutable(in: workingDirectory)
        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter()
        )
        let session = Session.fixture(title: "Copilot Shared Runtime")

        let runtimeClient = try await provider.buildRuntimeClient(
            configuration: GitHubCopilotCLIConfiguration(
                executablePath: executableURL.path,
                defaultModel: "",
                customAgentName: "",
                defaultApprovalMode: "default",
                useACPStdIO: true
            ),
            session: session,
            workingDirectory: workingDirectory.path,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            permissionResolver: { _, _ in nil },
            updateSink: { _ in }
        )

        #expect(runtimeClient is ACPExternalAgentRuntimeClient)

        await runtimeClient.close()
    }

    @Test func runtimeClientDoesNotReloadAlreadyAttachedSession() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let runtimeClient = try ACPExternalAgentRuntimeClient(
            launchConfiguration: GitHubCopilotCLILaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionLoadOnlyRubyAgentScript],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            supportsSessionModelOverrideFallback: true,
            eventSink: { _ in }
        )

        let firstHandshake = try await runtimeClient.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )
        let secondHandshake = try await runtimeClient.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        #expect(secondHandshake == firstHandshake)

        await runtimeClient.close()
    }

    @Test func runtimeClientLoadsExistingSessionInsteadOfCallingResume() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let runtimeClient = try ACPExternalAgentRuntimeClient(
            launchConfiguration: GitHubCopilotCLILaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionLoadOnlyRubyAgentScript],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            supportsSessionModelOverrideFallback: true,
            eventSink: { _ in }
        )

        let handshake = try await runtimeClient.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        #expect(handshake.remoteSessionID == "remote-existing")
        #expect(handshake.cliVersion == "1.2.3")

        await runtimeClient.close()
    }

    @Test func runtimeClientRejectsSwitchingToDifferentRemoteSessionOnSameRuntime() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let runtimeClient = try ACPExternalAgentRuntimeClient(
            launchConfiguration: GitHubCopilotCLILaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionLoadOnlyRubyAgentScript],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            supportsSessionModelOverrideFallback: true,
            eventSink: { _ in }
        )

        _ = try await runtimeClient.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        do {
            _ = try await runtimeClient.ensureSession(
                workingDirectory: workingDirectory.path,
                remoteSessionID: "remote-other"
            )
            Issue.record("Expected runtime client to reject switching to a different remote session")
        } catch let error as ACPExternalAgentRuntimeError {
            switch error {
            case .sessionAlreadyAttached(let current, let requested):
                #expect(current == "remote-existing")
                #expect(requested == "remote-other")
            default:
                Issue.record("Expected sessionAlreadyAttached error, got \(error.localizedDescription)")
            }
        }

        await runtimeClient.close()
    }

    @Test func providerDoesNotReloadRemoteSessionOnSecondTurn() async throws {
        let modelContext = try makeModelContext()
        let workingDirectory = makeTemporaryDirectory()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/ruby",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Multi Turn")
        session.workingDirectory = workingDirectory.path
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                try ACPExternalAgentRuntimeClient(
                    launchConfiguration: GitHubCopilotCLILaunchConfiguration(
                        command: "/usr/bin/ruby",
                        arguments: ["-rjson", "-e", multiTurnSessionReuseRubyAgentScript],
                        currentDirectoryURL: workingDirectory
                    ),
                    terminalRuntime: TerminalTaskRuntime.makeForTests(),
                    authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
                    supportsSessionModelOverrideFallback: true,
                    eventSink: updateSink
                )
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "first turn",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )
        try await provider.send(
            ConversationExecutionRequest(
                text: "second turn",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessages = session.messages
            .filter { $0.direction == .agent }
            .sorted { $0.sequence < $1.sequence }

        #expect(assistantMessages.count == 2)
        #expect(assistantMessages.allSatisfy { $0.status == .completed })
        #expect(assistantMessages.allSatisfy { ($0.errorMessage ?? "").isEmpty })
        #expect(assistantMessages.allSatisfy { !($0.textContent ?? "").contains("already loaded") })
    }

    @Test func providerClosesInactiveSessionRuntimeAndRestoresBindingWhenSwitchingSessions() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let sessionA = Session.fixture(title: "Copilot A")
        let sessionB = Session.fixture(title: "Copilot B")
        modelContext.insert(settings)
        modelContext.insert(sessionA)
        modelContext.insert(sessionB)
        try modelContext.save()

        let runtimeA1 = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-a", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        let runtimeB1 = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-b", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        let runtimeA2 = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-a", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        var runtimeQueue = [runtimeA1, runtimeB1, runtimeA2]

        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                let runtimeClient = try #require(runtimeQueue.isEmpty == false ? runtimeQueue.removeFirst() : nil)
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "session-a-first",
                session: sessionA,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )
        try await provider.send(
            ConversationExecutionRequest(
                text: "session-b-first",
                session: sessionB,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )
        try await provider.send(
            ConversationExecutionRequest(
                text: "session-a-second",
                session: sessionA,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        #expect(runtimeA1.closeCallCount == 1)
        #expect(runtimeB1.closeCallCount == 1)
        #expect(runtimeA1.ensureSessionRemoteSessionIDs == [nil])
        #expect(runtimeB1.ensureSessionRemoteSessionIDs == [nil])
        #expect(runtimeA2.ensureSessionRemoteSessionIDs == ["remote-a"])
    }

    @Test func providerRebuildsRuntimeWhenInitialEnsureSessionTimesOut() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Retry Initialize")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let stalledRuntime = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-stalled", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: [],
            ensureSessionError: ACPExternalAgentRuntimeError.initializeTimedOut
        )
        let recoveredRuntime = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-recovered", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        var runtimeQueue = [stalledRuntime, recoveredRuntime]

        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                let runtimeClient = try #require(runtimeQueue.isEmpty == false ? runtimeQueue.removeFirst() : nil)
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "retry initialize",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        #expect(stalledRuntime.closeCallCount == 1)
        #expect(stalledRuntime.ensureSessionRemoteSessionIDs == [nil])
        #expect(recoveredRuntime.ensureSessionRemoteSessionIDs == [nil])
        let binding = try ACPExternalSessionBindingStore(modelContext: modelContext).binding(
            for: session.sessionId,
            providerID: .githubCopilotCLI
        )
        #expect(binding?.remoteSessionID == "remote-recovered")
    }

    @Test func sendDoesNotProjectReplayUpdatesFromLoadedSessionIntoCurrentTurn() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Replay Restore")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        _ = try ACPExternalSessionBindingStore(modelContext: modelContext).upsert(
            sessionID: session.sessionId,
            providerID: .githubCopilotCLI,
            remoteSessionID: "remote-restored",
            agentVersion: "1.2.3",
            capabilities: nil,
            selectedModel: nil,
            selectedAgentName: nil
        )

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-restored", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            ensureSessionUpdates: [
                .session(
                    .agentMessageChunk(
                        ACPContentChunk(
                            meta: nil,
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "历史回复"))
                        )
                    )
                ),
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "read_file",
                            locations: nil,
                            rawInput: .object(["file_path": .string("/tmp/history.txt")]),
                            rawOutput: nil,
                            status: "completed",
                            title: "历史工具",
                            toolCallID: "tool-history"
                        )
                    )
                )
            ],
            updates: [
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "run_in_terminal",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: nil,
                            status: "in_progress",
                            title: "实时工具",
                            toolCallID: "tool-live"
                        )
                    )
                ),
                .session(
                    .toolCallUpdate(
                        ACPToolCallUpdatePayload(
                            meta: nil,
                            content: nil,
                            kind: "run_in_terminal",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: .string("echo live"),
                            status: "success",
                            title: "实时工具",
                            toolCallID: "tool-live"
                        )
                    )
                ),
                .session(
                    .agentMessageChunk(
                        ACPContentChunk(
                            meta: nil,
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "实时回复"))
                        )
                    )
                )
            ]
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "继续处理",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCalls = assistantMessage.agentRounds.flatMap(\.toolCalls)

        #expect(runtimeClient.ensureSessionRemoteSessionIDs == ["remote-restored"])
        ExternalACPProviderAssertionHelpers.expectLiveTurnProjection(
            assistantMessage: assistantMessage,
            toolCalls: toolCalls,
            expectedText: "实时回复",
            expectedToolCallID: "tool-live",
            expectedToolTitle: "实时工具",
            expectedToolOutput: "echo live"
        )
    }

    @Test func providerRestoresFromDurableBindingWithoutBridgeMirror() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Durable Binding")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        _ = try ACPExternalSessionBindingStore(modelContext: modelContext).upsert(
            sessionID: session.sessionId,
            providerID: .githubCopilotCLI,
            remoteSessionID: "remote-durable",
            agentVersion: "1.2.3",
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.2.3"
            ),
            selectedModel: nil,
            selectedAgentName: nil
        )

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-durable", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "restore durable binding",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let binding = try ACPExternalSessionBindingStore(modelContext: modelContext).binding(
            for: session.sessionId,
            providerID: .githubCopilotCLI
        )

        #expect(runtimeClient.ensureSessionRemoteSessionIDs == ["remote-durable"])
        #expect(binding?.remoteSessionID == "remote-durable")
    }

    @Test func sendProjectsCopilotUpdatesIntoAssistantMessageAndTools() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "gpt-5",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-123", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: [
                .session(
                    .agentThoughtChunk(
                        ACPContentChunk(
                            meta: nil,
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "inspect files"))
                        )
                    )
                ),
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "execute",
                            locations: .object(["path": .string("/tmp/project")]),
                            rawInput: nil,
                            rawOutput: nil,
                            status: "in_progress",
                            title: "run tests",
                            toolCallID: "tool-1"
                        )
                    )
                ),
                .session(
                    .toolCallUpdate(
                        ACPToolCallUpdatePayload(
                            meta: nil,
                            content: nil,
                            kind: "execute",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: .string("swift test"),
                            status: "success",
                            title: "run tests",
                            toolCallID: "tool-1"
                        )
                    )
                ),
                .session(
                    .agentMessageChunk(
                        ACPContentChunk(
                            meta: nil,
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "done"))
                        )
                    )
                )
            ]
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello copilot",
                session: session,
                modelID: "claude-ignored",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        #expect(assistantMessage.status == .completed)
        #expect(assistantMessage.textContent == "done")
        #expect(assistantMessage.agentRounds.first?.thinkingContent == "inspect files")
        #expect(assistantMessage.agentRounds.first?.toolCalls.first?.title == "run tests")
        #expect(assistantMessage.agentRounds.first?.toolCalls.first?.status == .success)
        #expect(assistantMessage.agentRounds.first?.toolCalls.first?.terminalOutput == "swift test")
        #expect(runtimeClient.promptRequests.count == 1)
        #expect(runtimeClient.promptRequests.first?.0 == "hello copilot")
        #expect(runtimeClient.promptRequests.first?.1 == "remote-123")
        #expect(runtimeClient.setModelRequests.count == 1)
        #expect(runtimeClient.setModelRequests.first?.0 == "gpt-5")
        #expect(runtimeClient.setModelRequests.first?.1 == "remote-123")
    }

    @Test func sendSkipsModelSelectionWhenCopilotDefaultModelIsEmpty() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "   ",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Model Fallback")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-model", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello copilot",
                session: session,
                modelID: "claude-sonnet-4-6",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let binding = try ACPExternalSessionBindingStore(modelContext: modelContext).binding(
            for: session.sessionId,
            providerID: .githubCopilotCLI
        )

        #expect(runtimeClient.setModelRequests.isEmpty)
        #expect(binding?.lastSelectedModel == nil)
    }

    @Test func sendMapsDefaultApprovalModeToDefaultApprovals() async throws {
        let approvalMode = try await capturedApprovalMode(for: "default")
        #expect(approvalMode == .defaultApprovals)
    }

    @Test func sendMapsOnRequestApprovalModeToDefaultApprovals() async throws {
        let approvalMode = try await capturedApprovalMode(for: "on-request")
        #expect(approvalMode == .defaultApprovals)
    }

    @Test func sendMapsNeverApprovalModeToBypassApprovals() async throws {
        let approvalMode = try await capturedApprovalMode(for: "never")
        #expect(approvalMode == .bypassApprovals)
    }

    @Test func sendFinalizesOutstandingReadToolCallsWhenTurnEnds() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Read")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-read", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: [
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "read_file",
                            locations: nil,
                            rawInput: .object(["file_path": .string("/tmp/README.md")]),
                            rawOutput: nil,
                            status: "in_progress",
                            title: "read file",
                            toolCallID: "tool-read"
                        )
                    )
                ),
                .session(
                    .agentMessageChunk(
                        ACPContentChunk(
                            meta: nil,
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "finished reading"))
                        )
                    )
                )
            ]
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "read file",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCall = try #require(assistantMessage.agentRounds.first?.toolCalls.first)

        #expect(assistantMessage.status == .completed)
        #expect(toolCall.kind == .read)
        #expect(toolCall.filePath == "/tmp/README.md")
        #expect(toolCall.status == .success)
        #expect(toolCall.endTime != nil)
    }

    @Test func sendMarksOutstandingToolCallsCancelledWhenPromptStopsCancelled() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Cancelled Tool")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-cancelled", cliVersion: "1.2.3"),
            stopReason: .cancelled,
            updates: [
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "run_in_terminal",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: nil,
                            status: "running",
                            title: "run command",
                            toolCallID: "tool-run"
                        )
                    )
                )
            ]
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "run command",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCall = try #require(assistantMessage.agentRounds.first?.toolCalls.first)

        #expect(assistantMessage.status == .cancelled)
        #expect(toolCall.kind == .execute)
        #expect(toolCall.status == .cancelled)
        #expect(toolCall.endTime != nil)
    }

    @Test func sendMarksOutstandingToolCallsFailedWhenPromptThrows() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Failed Tool")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-failed", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: [
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "str_replace",
                            locations: nil,
                            rawInput: .object(["path": .string("/tmp/README.md")]),
                            rawOutput: nil,
                            status: "pending",
                            title: "edit file",
                            toolCallID: "tool-edit"
                        )
                    )
                )
            ],
            promptError: RuntimeClientStubError.promptFailed
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        await #expect(throws: RuntimeClientStubError.promptFailed) {
            try await provider.send(
                ConversationExecutionRequest(
                    text: "edit file",
                    session: session,
                    modelID: "",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: [],
                    modelContext: modelContext
                )
            )
        }

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCall = try #require(assistantMessage.agentRounds.first?.toolCalls.first)

        #expect(assistantMessage.status == .failed)
        #expect(toolCall.kind == .edit)
        #expect(toolCall.status == .failed)
        #expect(toolCall.endTime != nil)
    }

    @Test func sendKeepsRejectedPermissionToolCallsCancelledAtTurnEnd() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Permission Reject")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let permissionCenter = ACPPermissionCenter()
        let permissionRequest = ACPRequestPermissionRequest(
            meta: nil,
            options: [
                ACPPermissionOption(meta: nil, kind: .rejectOnce, name: "Reject once", optionID: "reject-once"),
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow once", optionID: "allow-once")
            ],
            sessionID: "remote-permission",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: .object(["reason": .string("需要读取文件")]),
                kind: "read_file",
                locations: nil,
                rawInput: .object(["file_path": .string("/tmp/README.md")]),
                rawOutput: nil,
                status: "pending",
                title: "read file",
                toolCallID: "tool-permission"
            )
        )
        let runtimeClient = PermissionRuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-permission", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            permissionRequest: permissionRequest,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly, approvalMode: .defaultApprovals)
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: permissionCenter,
            runtimeClientFactory: { _, _, _, permissionResolver, updateSink in
                runtimeClient.permissionResolver = permissionResolver
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        let sendTask = Task {
            try await provider.send(
                ConversationExecutionRequest(
                    text: "read file",
                    session: session,
                    modelID: "",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: [],
                    modelContext: modelContext
                )
            )
        }

        while permissionCenter.pendingRequests.isEmpty {
            await Task.yield()
        }

        let pending = try #require(permissionCenter.pendingRequests.first)
        permissionCenter.selectOption(requestID: pending.id, optionID: "reject-once")

        try await sendTask.value

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCall = try #require(assistantMessage.agentRounds.first?.toolCalls.first)

        #expect(assistantMessage.status == .completed)
        #expect(toolCall.kind == .read)
        #expect(toolCall.status == .cancelled)
        #expect(toolCall.toolResultSummary == "权限被拒绝")
    }

    @Test func sendSeparatesPermissionRequestsFromToolExecutionRecords() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Permission Execute")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let permissionCenter = ACPPermissionCenter()
        let permissionRequest = ACPRequestPermissionRequest(
            meta: nil,
            options: [
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow once", optionID: "allow-once"),
                ACPPermissionOption(meta: nil, kind: .rejectOnce, name: "Reject once", optionID: "reject-once")
            ],
            sessionID: "remote-permission-execute",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: .object(["reason": .string("需要执行 shell 命令")]),
                kind: "run_in_terminal",
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                status: "pending",
                title: "run tests",
                toolCallID: "tool-run"
            )
        )
        let runtimeClient = PermissionRuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-permission-execute", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            permissionRequest: permissionRequest,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly, approvalMode: .defaultApprovals),
            updates: [
                .session(
                    .toolCall(
                        ACPToolCall(
                            meta: nil,
                            content: nil,
                            kind: "run_in_terminal",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: nil,
                            status: "in_progress",
                            title: "run tests",
                            toolCallID: "tool-run"
                        )
                    )
                ),
                .session(
                    .toolCallUpdate(
                        ACPToolCallUpdatePayload(
                            meta: nil,
                            content: nil,
                            kind: "run_in_terminal",
                            locations: nil,
                            rawInput: nil,
                            rawOutput: .string("swift test"),
                            status: "success",
                            title: "run tests",
                            toolCallID: "tool-run"
                        )
                    )
                )
            ]
        )

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: permissionCenter,
            runtimeClientFactory: { _, _, _, permissionResolver, updateSink in
                runtimeClient.permissionResolver = permissionResolver
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        let sendTask = Task {
            try await provider.send(
                ConversationExecutionRequest(
                    text: "run tests",
                    session: session,
                    modelID: "",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: [],
                    modelContext: modelContext
                )
            )
        }

        while permissionCenter.pendingRequests.isEmpty {
            await Task.yield()
        }

        let pending = try #require(permissionCenter.pendingRequests.first)
        permissionCenter.selectOption(requestID: pending.id, optionID: "allow-once")

        try await sendTask.value

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        let toolCalls = try #require(assistantMessage.agentRounds.first?.toolCalls)

        #expect(toolCalls.count == 2)

        let permissionRecord = try #require(toolCalls.first(where: { $0.isPermissionRequest }))
        #expect(permissionRecord.permissionTargetToolCallId == "tool-run")
        #expect(permissionRecord.status == .success)
        #expect(permissionRecord.toolResultSummary == "权限已批准")

        let executionRecord = try #require(toolCalls.first(where: { !$0.isPermissionRequest }))
        #expect(executionRecord.toolCallId == "tool-run")
        #expect(executionRecord.kind == .execute)
        #expect(executionRecord.status == .success)
        #expect(executionRecord.terminalOutput == "swift test")
    }

    @Test func cancelForwardsToActiveRuntime() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Cancel")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-cancel", cliVersion: nil),
            stopReason: .cancelled,
            updates: []
        )
        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "cancel me",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )
        await provider.cancel(session: session, modelContext: modelContext)

        #expect(runtimeClient.cancelledSessionIDs == ["remote-cancel"])

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
        ExternalACPProviderAssertionHelpers.expectCancelledMessageSettlesToolCalls(assistantMessage)
    }

    @Test func sendDoesNotExposeCommandsWhenRemoteACPDoesNotAdvertiseAny() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Missing Commands")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-seeded", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "no remote commands",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let commands = provider.remoteCommands(localSessionID: session.sessionId)
        #expect(commands.isEmpty)
    }

    @Test func sendExposesRemoteAdvertisedCommands() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: "default",
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Remote Commands")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-advertised", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: [
                .session(
                    .availableCommandsUpdate(
                        ACPAvailableCommandsUpdatePayload(
                            availableCommands: [
                                ACPAvailableCommand(
                                    description: "Remote review",
                                    input: ACPAvailableCommandInput(hint: "changes"),
                                    name: "review"
                                )
                            ]
                        )
                    )
                )
            ]
        )
        let provider = GitHubCopilotCLIExecutionProvider(
            availabilityService: GitHubCopilotCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            ),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "remote commands",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let commands = provider.remoteCommands(localSessionID: session.sessionId)
        #expect(commands.map(\.name) == ["review"])
        #expect(commands.first?.source == .remoteAdvertised)
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            ACPExternalSessionBinding.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeIdleExecutable(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-copilot")
        let script = "#!/bin/sh\ncat >/dev/null\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func capturedApprovalMode(for defaultApprovalMode: String) async throws -> ToolApprovalMode {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.githubCopilotCLIConfiguration = GitHubCopilotCLIConfiguration(
            executablePath: "/usr/bin/env",
            defaultModel: "",
            customAgentName: "",
            defaultApprovalMode: defaultApprovalMode,
            useACPStdIO: true
        )
        let session = Session.fixture(title: "Copilot Approval Mode")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let runtimeClient = RuntimeClientStub(
            handshake: GitHubCopilotCLISessionHandshake(remoteSessionID: "remote-approval", cliVersion: "1.2.3"),
            stopReason: .endTurn,
            updates: []
        )
        var capturedApprovalMode: ToolApprovalMode?

        let provider = GitHubCopilotCLIExecutionProvider(
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, authorizationPolicy, _, updateSink in
                capturedApprovalMode = authorizationPolicy.approvalMode
                runtimeClient.updateSink = updateSink
                return runtimeClient
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello copilot",
                session: session,
                modelID: "",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        return try #require(capturedApprovalMode)
    }

    private var sessionLoadOnlyRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

unless initialize_request["method"] == "initialize"
    abort("expected initialize, got #{initialize_request["method"]}")
end

initialize_response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
        "protocolVersion" => 1,
        "agentCapabilities" => {
            "loadSession" => true
        },
        "agentInfo" => {
            "name" => "copilot",
            "version" => "1.2.3"
        }
    }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

session_request = JSON.parse(STDIN.gets)

case session_request["method"]
when "session/load"
    unless session_request.dig("params", "sessionId") == "remote-existing"
        abort("expected sessionId remote-existing")
    end

    session_response = {
        "jsonrpc" => "2.0",
        "id" => session_request.fetch("id"),
        "result" => {}
    }
    STDOUT.write(JSON.generate(session_response) + "\n")
    STDOUT.flush
when "session/resume"
    session_error = {
        "jsonrpc" => "2.0",
        "id" => session_request.fetch("id"),
        "error" => {
            "code" => -32601,
            "message" => "Method not found",
            "data" => { "method" => "session/resume" }
        }
    }
    STDOUT.write(JSON.generate(session_error) + "\n")
    STDOUT.flush
else
    abort("unexpected method #{session_request["method"]}")
end
"""#
    }

        private var multiTurnSessionReuseRubyAgentScript: String {
                #"""
prompt_count = 0
session_loaded = false

loop do
    raw = STDIN.gets
    break if raw.nil?

    request = JSON.parse(raw)

    case request["method"]
    when "initialize"
        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "result" => {
                "protocolVersion" => 1,
                "agentCapabilities" => {
                    "loadSession" => true
                },
                "agentInfo" => {
                    "name" => "copilot",
                    "version" => "1.2.3"
                }
            }
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    when "session/new"
        abort("session already established") if session_loaded

        session_loaded = true
        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "result" => {
                "sessionId" => "remote-existing"
            }
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    when "session/load"
        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "error" => {
                "code" => -32000,
                "message" => "Session remote-existing is already loaded"
            }
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    when "session/prompt"
        prompt_count += 1
        expected_text = prompt_count == 1 ? "first turn" : "second turn"
        actual_text = request.dig("params", "prompt", 0, "text")
        abort("expected prompt #{expected_text.inspect}, got #{actual_text.inspect}") unless actual_text == expected_text

        notification = {
            "jsonrpc" => "2.0",
            "method" => "session/update",
            "params" => {
                "sessionId" => "remote-existing",
                "update" => {
                    "sessionUpdate" => "agent_message_chunk",
                    "content" => {
                        "type" => "text",
                        "text" => "reply-#{prompt_count}"
                    }
                }
            }
        }
        STDOUT.write(JSON.generate(notification) + "\n")
        STDOUT.flush

        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "result" => {
                "stopReason" => "end_turn"
            }
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    else
        abort("unexpected method #{request["method"]}")
    end
end
"""#
        }
}

@MainActor
private final class RuntimeClientStub: GitHubCopilotCLIRuntimeClient {
    let handshake: GitHubCopilotCLISessionHandshake
    let stopReason: ACPStopReason
    let ensureSessionUpdates: [CopilotACPUpdate]
    let updates: [CopilotACPUpdate]
    let ensureSessionError: (any Error)?
    let promptError: (any Error)?

    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?
    private(set) var ensureSessionRemoteSessionIDs: [String?] = []
    private(set) var promptRequests: [(String, String)] = []
    private(set) var setModelRequests: [(String, String)] = []
    private(set) var cancelledSessionIDs: [String] = []
    private(set) var closeCallCount = 0
    private(set) var initializeCallCount = 0

    init(
        handshake: GitHubCopilotCLISessionHandshake,
        stopReason: ACPStopReason,
        ensureSessionUpdates: [CopilotACPUpdate] = [],
        updates: [CopilotACPUpdate],
        ensureSessionError: (any Error)? = nil,
        promptError: (any Error)? = nil
    ) {
        self.handshake = handshake
        self.stopReason = stopReason
        self.ensureSessionUpdates = ensureSessionUpdates
        self.updates = updates
        self.ensureSessionError = ensureSessionError
        self.promptError = promptError
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> GitHubCopilotCLISessionHandshake {
        _ = workingDirectory
        ensureSessionRemoteSessionIDs.append(remoteSessionID)
        if let ensureSessionError {
            throw ensureSessionError
        }
        for update in ensureSessionUpdates {
            await updateSink?(update)
        }
        return handshake
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        initializeCallCount += 1
        if let ensureSessionError {
            throw ensureSessionError
        }
        return handshake.capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        _ = workingDirectory
        ensureSessionRemoteSessionIDs.append(remoteSessionID)
        if let ensureSessionError {
            throw ensureSessionError
        }
        for update in ensureSessionUpdates {
            await updateSink?(update)
        }
        return handshake
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        _ = workingDirectory
        ensureSessionRemoteSessionIDs.append(nil)
        if let ensureSessionError {
            throw ensureSessionError
        }
        for update in ensureSessionUpdates {
            await updateSink?(update)
        }
        return handshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        setModelRequests.append((modelID, sessionID))
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        promptRequests.append((text, sessionID))
        for update in updates {
            await updateSink?(update)
        }
        if let promptError {
            throw promptError
        }
        return stopReason
    }

    func cancel(sessionID: String) async throws {
        cancelledSessionIDs.append(sessionID)
    }

    func close() async {
        closeCallCount += 1
    }
}

private enum RuntimeClientStubError: Error {
    case promptFailed
}

@MainActor
private final class PermissionRuntimeClientStub: GitHubCopilotCLIRuntimeClient {
    let handshake: GitHubCopilotCLISessionHandshake
    let stopReason: ACPStopReason
    let permissionRequest: ACPRequestPermissionRequest
    let authorizationPolicy: ToolAuthorizationPolicy
    let updates: [CopilotACPUpdate]

    var permissionResolver: ((ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)?
    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?

    init(
        handshake: GitHubCopilotCLISessionHandshake,
        stopReason: ACPStopReason,
        permissionRequest: ACPRequestPermissionRequest,
        authorizationPolicy: ToolAuthorizationPolicy,
        updates: [CopilotACPUpdate] = []
    ) {
        self.handshake = handshake
        self.stopReason = stopReason
        self.permissionRequest = permissionRequest
        self.authorizationPolicy = authorizationPolicy
        self.updates = updates
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> GitHubCopilotCLISessionHandshake {
        _ = workingDirectory
        _ = remoteSessionID
        return handshake
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        handshake.capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        _ = workingDirectory
        _ = remoteSessionID
        return handshake
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        _ = workingDirectory
        return handshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        _ = modelID
        _ = sessionID
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        _ = text
        _ = sessionID
        await updateSink?(.permission(permissionRequest))
        _ = await permissionResolver?(permissionRequest, authorizationPolicy)
        for update in updates {
            await updateSink?(update)
        }
        return stopReason
    }

    func cancel(sessionID: String) async throws {
        _ = sessionID
    }

    func close() async {}
}
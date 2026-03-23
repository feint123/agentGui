import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct OpenCodeCLIExecutionProviderTests {
  @Test func openCodeDescriptorCapturesProviderSpecificExecutionBehavior() {
    let descriptor = ACPExternalAgentDescriptor.openCode

    #expect(descriptor.defaultArguments == ["acp"])
    #expect(descriptor.supportsSessionModelOverrideByDefault == false)
    #expect(descriptor.supportsCustomAgentName == false)
    #expect(descriptor.executionBehavior.requiresCapabilityNegotiationForModelOverride)
    #expect(descriptor.executionBehavior.supportsEnvironmentOverrides == false)
  }

    @Test func sendPersistsSessionBindingAndAppliesModelOverrideWhenCapabilityAllows() async throws {
        let modelContext = try makeModelContext()
        let workingDirectory = makeTemporaryDirectory()
        let logFile = workingDirectory.appendingPathComponent("opencode.log")
        let agentScript = try makeOpenCodeAgentScript(
          in: workingDirectory,
          logFile: logFile,
          responseText: "open response",
          supportsModelOverride: true
        )

        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
            executablePath: agentScript.path,
            defaultModel: "gpt-5",
          defaultApprovalMode: "default"
        )
        let session = Session.fixture(title: "OpenCode")
        session.workingDirectory = workingDirectory.path
        session.executionPreferences = SessionExecutionPreferences(
            builtInModelID: nil,
            openCodeCLI: OpenCodeCLISessionPreferences(modelID: "gpt-5-mini", approvalMode: "never")
        )
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let provider = OpenCodeCLIExecutionProvider(
            availabilityService: availabilityService(),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter()
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello opencode",
                session: session,
                modelID: "ignored-built-in-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let assistantMessage = try #require(session.messages.first(where: { $0.direction == .agent }))
    let binding = try ACPExternalSessionBindingStore(modelContext: modelContext).binding(
      for: session.sessionId,
      providerID: .openCodeCLI
    )
        let logText = try String(contentsOf: logFile, encoding: .utf8)

        #expect(assistantMessage.status == .completed)
        #expect(assistantMessage.textContent == "open response")
        #expect(binding?.remoteSessionID == "remote-open")
        #expect(binding?.lastSelectedModel == "gpt-5-mini")
        #expect(binding?.negotiatedCapabilities?.supportsSessionModelOverride == true)
        #expect(logText.contains("session/set_model"))
        #expect(logText.contains("model=gpt-5-mini"))
        #expect(logText.contains("prompt=hello opencode"))
    }

    @Test func sendSkipsModelOverrideWhenCapabilityDoesNotAdvertiseSupport() async throws {
        let modelContext = try makeModelContext()
        let workingDirectory = makeTemporaryDirectory()
        let logFile = workingDirectory.appendingPathComponent("opencode.log")
        let agentScript = try makeOpenCodeAgentScript(
          in: workingDirectory,
          logFile: logFile,
          responseText: "open response",
          supportsModelOverride: false
        )

        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
            executablePath: agentScript.path,
            defaultModel: "gpt-5",
          defaultApprovalMode: "default"
        )
        let session = Session.fixture(title: "OpenCode No Override")
        session.workingDirectory = workingDirectory.path
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let provider = OpenCodeCLIExecutionProvider(
            availabilityService: availabilityService(),
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter()
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello opencode",
                session: session,
                modelID: "ignored-built-in-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: modelContext
            )
        )

        let binding = try ACPExternalSessionBindingStore(modelContext: modelContext).binding(
          for: session.sessionId,
          providerID: .openCodeCLI
        )
        let logText = try String(contentsOf: logFile, encoding: .utf8)

        #expect(binding?.remoteSessionID == "remote-open")
        #expect(binding?.lastSelectedModel == nil)
        #expect(binding?.negotiatedCapabilities?.supportsSessionModelOverride == false)
        #expect(!logText.contains("session/set_model"))
        #expect(logText.contains("prompt=hello opencode"))
    }

      @Test func providerClosesInactiveSessionRuntimeAndRestoresBindingWhenSwitchingSessions() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
          executablePath: "/usr/bin/env",
          defaultModel: "",
          defaultApprovalMode: "default",
          environment: [:],
          useACPStdIO: true
        )
        let sessionA = Session.fixture(title: "OpenCode A")
        let sessionB = Session.fixture(title: "OpenCode B")
        modelContext.insert(settings)
        modelContext.insert(sessionA)
        modelContext.insert(sessionB)
        try modelContext.save()

        let runtimeA1 = RuntimeClientStub(
          handshake: ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-a",
            capabilities: ACPExternalAgentCapabilitySnapshot(
              loadSession: true,
              supportsSessionModelOverride: true,
              agentVersion: "0.1.0"
            )
          ),
          stopReason: .endTurn,
          updates: []
        )
        let runtimeB1 = RuntimeClientStub(
          handshake: ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-b",
            capabilities: ACPExternalAgentCapabilitySnapshot(
              loadSession: true,
              supportsSessionModelOverride: true,
              agentVersion: "0.1.0"
            )
          ),
          stopReason: .endTurn,
          updates: []
        )
        let runtimeA2 = RuntimeClientStub(
          handshake: ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-a",
            capabilities: ACPExternalAgentCapabilitySnapshot(
              loadSession: true,
              supportsSessionModelOverride: true,
              agentVersion: "0.1.0"
            )
          ),
          stopReason: .endTurn,
          updates: []
        )
        var runtimeQueue = [runtimeA1, runtimeB1, runtimeA2]

        let provider = OpenCodeCLIExecutionProvider(
          availabilityService: availabilityService(),
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

      @Test func providerRestoresRemoteBindingFromPersistentStoreWithFreshProviderInstance() async throws {
        let modelContext = try makeModelContext()
        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
          executablePath: "/usr/bin/env",
          defaultModel: "",
          defaultApprovalMode: "default",
          environment: [:],
          useACPStdIO: true
        )
        let session = Session.fixture(title: "OpenCode Restore")
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let firstRuntime = RuntimeClientStub(
          handshake: ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-restored",
            capabilities: ACPExternalAgentCapabilitySnapshot(
              loadSession: true,
              supportsSessionModelOverride: true,
              agentVersion: "0.1.0"
            )
          ),
          stopReason: .endTurn,
          updates: []
        )
        let firstProvider = OpenCodeCLIExecutionProvider(
          availabilityService: availabilityService(),
          terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
          permissionCenter: ACPPermissionCenter(),
          runtimeClientFactory: { _, _, _, _, updateSink in
            firstRuntime.updateSink = updateSink
            return firstRuntime
          }
        )

        try await firstProvider.send(
          ConversationExecutionRequest(
            text: "first-send",
            session: session,
            modelID: "",
            selectedFilePath: nil,
            selectedText: nil,
            directives: [],
            modelContext: modelContext
          )
        )

        let restoredRuntime = RuntimeClientStub(
          handshake: ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-restored",
            capabilities: ACPExternalAgentCapabilitySnapshot(
              loadSession: true,
              supportsSessionModelOverride: true,
              agentVersion: "0.1.0"
            )
          ),
          stopReason: .endTurn,
          updates: []
        )
        let restoredProvider = OpenCodeCLIExecutionProvider(
          availabilityService: availabilityService(),
          terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
          permissionCenter: ACPPermissionCenter(),
          runtimeClientFactory: { _, _, _, _, updateSink in
            restoredRuntime.updateSink = updateSink
            return restoredRuntime
          }
        )

        try await restoredProvider.send(
          ConversationExecutionRequest(
            text: "second-send",
            session: session,
            modelID: "",
            selectedFilePath: nil,
            selectedText: nil,
            directives: [],
            modelContext: modelContext
          )
        )

        #expect(firstRuntime.ensureSessionRemoteSessionIDs == [nil])
        #expect(restoredRuntime.ensureSessionRemoteSessionIDs == ["remote-restored"])
      }

  @Test func sendDoesNotProjectReplayUpdatesFromLoadedSessionIntoCurrentTurn() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Replay Restore")
    modelContext.insert(settings)
    modelContext.insert(session)
    modelContext.insert(
      ACPExternalSessionBinding(
        localSessionID: session.sessionId,
        providerIDRaw: ConversationExecutionProviderID.openCodeCLI.rawValue,
        remoteSessionID: "remote-restored",
        agentVersion: "0.1.0"
      )
    )
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-restored",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
      stopReason: .endTurn,
      ensureSessionUpdates: [
        .session(
          .agentMessageChunk(
            ACPContentChunk(
              meta: nil,
              content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "历史 OpenCode 回复"))
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
              rawInput: .object(["file_path": .string("/tmp/history-open.txt")]),
              rawOutput: nil,
              status: "completed",
              title: "历史 OpenCode 工具",
              toolCallID: "tool-history-open"
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
              title: "OpenCode 实时工具",
              toolCallID: "tool-live-open"
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
              rawOutput: .string("open live output"),
              status: "success",
              title: "OpenCode 实时工具",
              toolCallID: "tool-live-open"
            )
          )
        ),
        .session(
          .agentMessageChunk(
            ACPContentChunk(
              meta: nil,
              content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "OpenCode 实时回复"))
            )
          )
        )
      ]
    )

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
      terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
      permissionCenter: ACPPermissionCenter(),
      runtimeClientFactory: { _, _, _, _, updateSink in
        runtimeClient.updateSink = updateSink
        return runtimeClient
      }
    )

    try await provider.send(
      ConversationExecutionRequest(
        text: "继续 OpenCode 任务",
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
      expectedText: "OpenCode 实时回复",
      expectedToolCallID: "tool-live-open",
      expectedToolTitle: "OpenCode 实时工具",
      expectedToolOutput: "open live output"
    )
  }

  @Test func cancelForwardsToActiveRuntimeAndSettlesOutstandingToolCalls() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Cancel")
    modelContext.insert(settings)
    modelContext.insert(session)
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-cancel",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
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
              toolCallID: "tool-run-open"
            )
          )
        )
      ]
    )
    let provider = OpenCodeCLIExecutionProvider(
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

  @Test func sendSeparatesPermissionRequestsFromToolExecutionRecords() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Permission Execute")
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
      sessionID: "remote-open-permission",
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
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-open-permission",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: true,
          agentVersion: "0.1.0"
        )
      ),
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

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
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

  @Test func sendProjectsRemoteCommandsAndPlanIntoLocalFeatureState() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Features")
    modelContext.insert(settings)
    modelContext.insert(session)
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-feature",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
      stopReason: .endTurn,
      updates: [
        .session(
          .availableCommandsUpdate(
            ACPAvailableCommandsUpdatePayload(
              availableCommands: [
                ACPAvailableCommand(
                  description: "Run review",
                  input: ACPAvailableCommandInput(hint: "scope"),
                  name: "review"
                )
              ]
            )
          )
        ),
        .session(
          .plan(
            ACPPlanUpdatePayload(
              entries: [
                ACPPlanEntry(content: "Write tests", priority: .medium, status: .inProgress)
              ]
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

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
      terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
      permissionCenter: ACPPermissionCenter(),
      runtimeClientFactory: { _, _, _, _, updateSink in
        runtimeClient.updateSink = updateSink
        return runtimeClient
      }
    )

    try await provider.send(
      ConversationExecutionRequest(
        text: "feature sync",
        session: session,
        modelID: "",
        selectedFilePath: nil,
        selectedText: nil,
        directives: [],
        modelContext: modelContext
      )
    )

    let commands = provider.remoteCommands(localSessionID: session.sessionId, remoteSessionID: "remote-feature")
    #expect(commands.map(\.name) == ["review"])
    #expect(commands.first?.inputHint == "scope")

    let taskStateStore = SessionTaskStateStore(modelContext: modelContext)
    #expect(taskStateStore.todoItems(for: session.sessionId).map(\.title) == ["Write tests"])
    #expect(taskStateStore.todoItems(for: session.sessionId).map(\.status) == [.inProgress])
    #expect(provider.remotePlan(localSessionID: session.sessionId)?.entries.map(\.content) == ["Write tests"])
  }

  @Test func prepareForActivationPreloadsRemoteCommandsForSlashMenu() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Slash Warmup")
    modelContext.insert(settings)
    modelContext.insert(session)
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-warmup",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
      stopReason: .endTurn,
      ensureSessionUpdates: [
        .session(
          .availableCommandsUpdate(
            ACPAvailableCommandsUpdatePayload(
              availableCommands: [
                ACPAvailableCommand(
                  description: "Run review",
                  input: ACPAvailableCommandInput(hint: "scope"),
                  name: "review"
                )
              ]
            )
          )
        )
      ],
      updates: []
    )

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
      terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
      permissionCenter: ACPPermissionCenter(),
      runtimeClientFactory: { _, _, _, _, updateSink in
        runtimeClient.updateSink = updateSink
        return runtimeClient
      }
    )

    await provider.prepareForActivation(
      session: session,
      isActiveProvider: true,
      modelContext: modelContext,
      trigger: .slashCommandWarmup
    )

    let commands = provider.remoteCommands(localSessionID: session.sessionId)

    #expect(runtimeClient.ensureSessionRemoteSessionIDs == [nil])
    #expect(commands.map(\.name) == ["review"])
    #expect(commands.first?.inputHint == "scope")
  }

  @Test func prepareForActivationSelectionDoesNotWarmRemoteACPState() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Selection Warmup")
    modelContext.insert(settings)
    modelContext.insert(session)
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-selection",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
      stopReason: .endTurn,
      ensureSessionUpdates: [
        .session(
          .availableCommandsUpdate(
            ACPAvailableCommandsUpdatePayload(
              availableCommands: [
                ACPAvailableCommand(
                  description: "Run review",
                  input: ACPAvailableCommandInput(hint: "scope"),
                  name: "review"
                )
              ]
            )
          )
        )
      ],
      updates: []
    )

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
      terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
      permissionCenter: ACPPermissionCenter(),
      runtimeClientFactory: { _, _, _, _, updateSink in
        runtimeClient.updateSink = updateSink
        return runtimeClient
      }
    )

    await provider.prepareForActivation(
      session: session,
      isActiveProvider: true,
      modelContext: modelContext,
      trigger: .selection
    )

    #expect(runtimeClient.ensureSessionRemoteSessionIDs.isEmpty)
    #expect(provider.remoteCommands(localSessionID: session.sessionId).isEmpty)
  }

  @Test func sendRestoresFeatureStateFromSessionLoadUpdates() async throws {
    let modelContext = try makeModelContext()
    let settings = AppSettings.testFixture(apiKey: "")
    settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
      executablePath: "/usr/bin/env",
      defaultModel: "",
      defaultApprovalMode: "default",
      environment: [:],
      useACPStdIO: true
    )
    let session = Session.fixture(title: "OpenCode Restored Features")
    modelContext.insert(settings)
    modelContext.insert(session)
    modelContext.insert(
      ACPExternalSessionBinding(
        localSessionID: session.sessionId,
        providerIDRaw: ConversationExecutionProviderID.openCodeCLI.rawValue,
        remoteSessionID: "remote-restored-features",
        agentVersion: "0.1.0"
      )
    )
    try modelContext.save()

    let runtimeClient = RuntimeClientStub(
      handshake: ACPExternalAgentSessionHandshake(
        remoteSessionID: "remote-restored-features",
        capabilities: ACPExternalAgentCapabilitySnapshot(
          loadSession: true,
          supportsSessionModelOverride: false,
          agentVersion: "0.1.0"
        )
      ),
      stopReason: .endTurn,
      ensureSessionUpdates: [
        .session(
          .availableCommandsUpdate(
            ACPAvailableCommandsUpdatePayload(
              availableCommands: [
                ACPAvailableCommand(
                  description: "Restored review",
                  input: ACPAvailableCommandInput(hint: "scope"),
                  name: "review"
                )
              ]
            )
          )
        ),
        .session(
          .plan(
            ACPPlanUpdatePayload(
              entries: [
                ACPPlanEntry(content: "Restore state", priority: .medium, status: .pending)
              ]
            )
          )
        )
      ],
      updates: []
    )

    let provider = OpenCodeCLIExecutionProvider(
      availabilityService: availabilityService(),
      terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
      permissionCenter: ACPPermissionCenter(),
      runtimeClientFactory: { _, _, _, _, updateSink in
        runtimeClient.updateSink = updateSink
        return runtimeClient
      }
    )

    try await provider.send(
      ConversationExecutionRequest(
        text: "resume",
        session: session,
        modelID: "",
        selectedFilePath: nil,
        selectedText: nil,
        directives: [],
        modelContext: modelContext
      )
    )

    let commands = provider.remoteCommands(localSessionID: session.sessionId)
    let taskStateStore = SessionTaskStateStore(modelContext: modelContext)

    #expect(commands.map(\.name) == ["review"])
    #expect(taskStateStore.todoItems(for: session.sessionId).map(\.title) == ["Restore state"])
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

    private func availabilityService() -> OpenCodeCLIAvailabilityService {
        OpenCodeCLIAvailabilityService(
            sharedService: ACPCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            )
        )
    }

    private func makeOpenCodeAgentScript(
      in directory: URL,
      logFile: URL,
      responseText: String,
      supportsModelOverride: Bool
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent("opencode-test-agent")
      let escapedLogPath = logFile.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      let escapedResponseText = responseText.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      let script = """
#!/usr/bin/env ruby
require "json"

    log_path = "\(escapedLogPath)"
    response_text = "\(escapedResponseText)"
  supports_model_override = \(supportsModelOverride ? "true" : "false")

def append_log(path, line)
  return unless path && !path.empty?
  File.open(path, "a") { |file| file.puts(line) }
end

loop do
  raw = STDIN.gets
  break if raw.nil?

  request = JSON.parse(raw)
  method = request["method"]
  append_log(log_path, method)

  case method
  when "initialize"
    capabilities = { "loadSession" => true }
    capabilities["sessionCapabilities"] = {} if supports_model_override
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {
        "protocolVersion" => 1,
        "agentCapabilities" => capabilities,
        "agentInfo" => {
          "name" => "opencode",
          "version" => "0.1.0"
        }
      }
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "session/new"
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {
        "sessionId" => "remote-open"
      }
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "session/set_model"
    append_log(log_path, "model=#{request.dig("params", "modelId")}")
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {}
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  when "session/prompt"
    append_log(log_path, "prompt=#{request.dig("params", "prompt", 0, "text")}")
    notification = {
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => {
        "sessionId" => "remote-open",
        "update" => {
          "sessionUpdate" => "agent_message_chunk",
          "content" => {
            "type" => "text",
            "text" => response_text
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
  when "session/cancel"
    response = {
      "jsonrpc" => "2.0",
      "id" => request.fetch("id"),
      "result" => {}
    }
    STDOUT.write(JSON.generate(response) + "\n")
    STDOUT.flush
  else
    abort("unexpected method #{method}")
  end
end
"""

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

  @MainActor
  private final class RuntimeClientStub: OpenCodeCLIRuntimeClient {
    let handshake: ACPExternalAgentSessionHandshake
    let stopReason: ACPStopReason
    let ensureSessionUpdates: [CopilotACPUpdate]
    let updates: [CopilotACPUpdate]
    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?

    private(set) var promptRequests: [(String, String)] = []
    private(set) var setModelRequests: [(String, String)] = []
    private(set) var cancelledSessionIDs: [String] = []
    private(set) var ensureSessionRemoteSessionIDs: [String?] = []
    private(set) var closeCallCount: Int = 0
    private(set) var initializeCallCount: Int = 0

    init(
      handshake: ACPExternalAgentSessionHandshake,
      stopReason: ACPStopReason,
      ensureSessionUpdates: [CopilotACPUpdate] = [],
      updates: [CopilotACPUpdate],
      updateSink: (@Sendable (CopilotACPUpdate) async -> Void)? = nil
    ) {
      self.handshake = handshake
      self.stopReason = stopReason
      self.ensureSessionUpdates = ensureSessionUpdates
      self.updates = updates
      self.updateSink = updateSink
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake {
      _ = workingDirectory
      ensureSessionRemoteSessionIDs.append(remoteSessionID)
      for update in ensureSessionUpdates {
        if let updateSink {
          await updateSink(normalizedSessionUpdate(update))
        }
      }
      return handshake
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
      initializeCallCount += 1
      return handshake.capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
      _ = workingDirectory
      ensureSessionRemoteSessionIDs.append(remoteSessionID)
      for update in ensureSessionUpdates {
        if let updateSink {
          await updateSink(normalizedSessionUpdate(update))
        }
      }
      return handshake
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
      _ = workingDirectory
      ensureSessionRemoteSessionIDs.append(nil)
      for update in ensureSessionUpdates {
        if let updateSink {
          await updateSink(normalizedSessionUpdate(update))
        }
      }
      return handshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
      setModelRequests.append((modelID, sessionID))
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
      promptRequests.append((text, sessionID))
      for update in updates {
        if let updateSink {
          await updateSink(normalizedSessionUpdate(update))
        }
      }
      return stopReason
    }

    func cancel(sessionID: String) async throws {
      cancelledSessionIDs.append(sessionID)
    }

    func close() async {
      closeCallCount += 1
    }

    private func normalizedSessionUpdate(_ update: CopilotACPUpdate) -> CopilotACPUpdate {
      switch update {
      case .session(let sessionUpdate):
        return .sessionNotification(
          ACPSessionNotification(
            meta: nil,
            sessionID: handshake.remoteSessionID,
            update: sessionUpdate
          )
        )
      case .sessionNotification, .permission:
        return update
      }
    }
  }

  @MainActor
  private final class PermissionRuntimeClientStub: OpenCodeCLIRuntimeClient {
    let handshake: ACPExternalAgentSessionHandshake
    let stopReason: ACPStopReason
    let permissionRequest: ACPRequestPermissionRequest
    let authorizationPolicy: ToolAuthorizationPolicy
    let updates: [CopilotACPUpdate]

    var permissionResolver: ((ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)?
    var updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?

    init(
      handshake: ACPExternalAgentSessionHandshake,
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

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake {
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
        await updateSink?(normalizedSessionUpdate(update))
      }
      return stopReason
    }

    private func normalizedSessionUpdate(_ update: CopilotACPUpdate) -> CopilotACPUpdate {
      switch update {
      case .session(let sessionUpdate):
        return .sessionNotification(
          ACPSessionNotification(
            meta: nil,
            sessionID: handshake.remoteSessionID,
            update: sessionUpdate
          )
        )
      case .sessionNotification, .permission:
        return update
      }
    }

    func cancel(sessionID: String) async throws {
      _ = sessionID
    }

    func close() async {}
  }
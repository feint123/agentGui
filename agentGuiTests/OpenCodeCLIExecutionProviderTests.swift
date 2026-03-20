import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct OpenCodeCLIExecutionProviderTests {
    @Test func sendPersistsSessionBindingAndAppliesModelOverrideWhenCapabilityAllows() async throws {
        let modelContext = try makeModelContext()
        let workingDirectory = makeTemporaryDirectory()
        let logFile = workingDirectory.appendingPathComponent("opencode.log")
        let agentScript = try makeOpenCodeAgentScript(in: workingDirectory)

        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
            executablePath: agentScript.path,
            defaultModel: "gpt-5",
            defaultApprovalMode: "default",
            environment: [
                "OPENCODE_TEST_LOG_PATH": logFile.path,
                "OPENCODE_TEST_RESPONSE_TEXT": "open response",
                "OPENCODE_TEST_SUPPORTS_MODEL_OVERRIDE": "1"
            ],
            useACPStdIO: true
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

        let sessionBridge = CopilotSessionBridge()
        let provider = OpenCodeCLIExecutionProvider(
            sessionBridge: sessionBridge,
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
        let binding = await sessionBridge.binding(for: session.sessionId, providerID: .openCodeCLI)
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
        let agentScript = try makeOpenCodeAgentScript(in: workingDirectory)

        let settings = AppSettings.testFixture(apiKey: "")
        settings.openCodeCLIConfiguration = OpenCodeCLIConfiguration(
            executablePath: agentScript.path,
            defaultModel: "gpt-5",
            defaultApprovalMode: "default",
            environment: [
                "OPENCODE_TEST_LOG_PATH": logFile.path,
                "OPENCODE_TEST_RESPONSE_TEXT": "open response",
                "OPENCODE_TEST_SUPPORTS_MODEL_OVERRIDE": "0"
            ],
            useACPStdIO: true
        )
        let session = Session.fixture(title: "OpenCode No Override")
        session.workingDirectory = workingDirectory.path
        modelContext.insert(settings)
        modelContext.insert(session)
        try modelContext.save()

        let sessionBridge = CopilotSessionBridge()
        let provider = OpenCodeCLIExecutionProvider(
            sessionBridge: sessionBridge,
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

        let binding = await sessionBridge.binding(for: session.sessionId, providerID: .openCodeCLI)
        let logText = try String(contentsOf: logFile, encoding: .utf8)

        #expect(binding?.remoteSessionID == "remote-open")
        #expect(binding?.lastSelectedModel == nil)
        #expect(binding?.negotiatedCapabilities?.supportsSessionModelOverride == false)
        #expect(!logText.contains("session/set_model"))
        #expect(logText.contains("prompt=hello opencode"))
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

    private func makeOpenCodeAgentScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("opencode-test-agent")
        let script = #"""
#!/usr/bin/env ruby
require "json"

log_path = ENV["OPENCODE_TEST_LOG_PATH"]
response_text = ENV.fetch("OPENCODE_TEST_RESPONSE_TEXT", "done")
supports_model_override = ENV.fetch("OPENCODE_TEST_SUPPORTS_MODEL_OVERRIDE", "0") == "1"

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
"""#

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}
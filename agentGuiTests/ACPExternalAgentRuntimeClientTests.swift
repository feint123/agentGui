import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPExternalAgentRuntimeClientTests {
    @Test func runtimeAndDescriptorsDoNotExposeLegacySessionModelOverrideMetadata() throws {
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

    @Test func setSessionConfigOptionUsesStandardACPMethod() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let logFile = workingDirectory.appendingPathComponent("runtime.log")
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionConfigRubyAgentScript(logFile: logFile.path)],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.createSession(workingDirectory: workingDirectory.path)
        let configOptions = try await client.setSessionConfigOption("model", value: "gpt-5-mini", sessionID: handshake.remoteSessionID)

        let logText = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logText.contains("session/set_config_option"))
        #expect(logText.contains("config=model"))
        #expect(logText.contains("value=gpt-5-mini"))
        #expect(configOptions.first?.currentValue == "gpt-5-mini")

        await client.close()
    }

    @Test func setSessionModeUsesStandardACPMethod() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let logFile = workingDirectory.appendingPathComponent("runtime.log")
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionConfigRubyAgentScript(logFile: logFile.path)],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.createSession(workingDirectory: workingDirectory.path)
        try await client.setSessionMode("review", sessionID: handshake.remoteSessionID)

        let logText = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logText.contains("session/set_mode"))
        #expect(logText.contains("mode=review"))

        await client.close()
    }

    @Test func createSessionCapturesConfigSnapshotFromNewSession() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", sessionConfigSnapshotRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.createSession(workingDirectory: workingDirectory.path)

        #expect(handshake.configurationSnapshot.configOptions.count == 1)
        #expect(handshake.configurationSnapshot.configOptions.first?.currentValue == "gpt-5-mini")
        #expect(handshake.configurationSnapshot.modes?.currentModeID == "build")
        #expect(handshake.configurationSnapshot.modes?.availableModes.count == 2)

        await client.close()
    }

    @Test func loadSessionCapturesConfigSnapshotFromLoadResponse() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", loadSessionConfigSnapshotRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try #require(await client.loadSessionIfPossible(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        ))

        #expect(handshake.configurationSnapshot.configOptions.count == 1)
        #expect(handshake.configurationSnapshot.configOptions.first?.currentValue == "claude-sonnet-4")
        #expect(handshake.configurationSnapshot.modes?.currentModeID == "review")

        await client.close()
    }

    @Test func loadSessionIfPossibleReturnsNilWhenRestoreFails() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", failingLoadSessionRubyAgentScript.replacingOccurrences(of: "remote-new-after-fallback", with: "remote-should-not-create")],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.loadSessionIfPossible(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        #expect(handshake == nil)

        await client.close()
    }

    @Test func createSessionReturnsFreshHandshake() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", noLoadSessionRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.createSession(workingDirectory: workingDirectory.path)

        #expect(handshake.remoteSessionID == "remote-new")
        #expect(handshake.capabilities.loadSession == false)

        await client.close()
    }

    @Test func ensureSessionFallsBackToNewSessionWhenLoadIsNotAdvertised() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", noLoadSessionRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        #expect(handshake.remoteSessionID == "remote-new")
        #expect(handshake.capabilities.loadSession == false)
        #expect(handshake.capabilities.agentVersion == "0.4.0")

        await client.close()
    }

    @Test func ensureSessionFallsBackToNewSessionWhenLoadFails() async throws {
        let workingDirectory = makeTemporaryDirectory()
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: ACPExternalAgentLaunchConfiguration(
                command: "/usr/bin/ruby",
                arguments: ["-rjson", "-e", failingLoadSessionRubyAgentScript],
                environmentOverrides: [:],
                currentDirectoryURL: workingDirectory
            ),
            terminalRuntime: TerminalTaskRuntime.makeForTests(),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            eventSink: { _ in }
        )

        let handshake = try await client.ensureSession(
            workingDirectory: workingDirectory.path,
            remoteSessionID: "remote-existing"
        )

        #expect(handshake.remoteSessionID == "remote-new-after-fallback")
        #expect(handshake.capabilities.loadSession == true)
        #expect(handshake.capabilities.agentVersion == "0.5.0")

        await client.close()
    }


    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var noLoadSessionRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

unless initialize_request["method"] == "initialize"
    abort("expected initialize")
end

initialize_response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
        "protocolVersion" => 1,
        "agentCapabilities" => {
            "loadSession" => false
        },
        "agentInfo" => {
            "name" => "opencode",
            "version" => "0.4.0"
        }
    }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

session_request = JSON.parse(STDIN.gets)
abort("expected session/new") unless session_request["method"] == "session/new"

session_response = {
    "jsonrpc" => "2.0",
    "id" => session_request.fetch("id"),
    "result" => {
        "sessionId" => "remote-new"
    }
}
STDOUT.write(JSON.generate(session_response) + "\n")
STDOUT.flush
"""#
    }

    private var failingLoadSessionRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

unless initialize_request["method"] == "initialize"
    abort("expected initialize")
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
            "version" => "0.5.0"
        }
    }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

load_request = JSON.parse(STDIN.gets)
abort("expected session/load") unless load_request["method"] == "session/load"

load_error = {
    "jsonrpc" => "2.0",
    "id" => load_request.fetch("id"),
    "error" => {
        "code" => -32000,
        "message" => "load failed"
    }
}
STDOUT.write(JSON.generate(load_error) + "\n")
STDOUT.flush

session_request = JSON.parse(STDIN.gets)
abort("expected session/new after fallback") unless session_request["method"] == "session/new"

session_response = {
    "jsonrpc" => "2.0",
    "id" => session_request.fetch("id"),
    "result" => {
        "sessionId" => "remote-new-after-fallback"
    }
}
STDOUT.write(JSON.generate(session_response) + "\n")
STDOUT.flush
"""#
    }

    private var hangingInitializeRubyAgentScript: String {
        #"""
sleep
"""#
    }

    private var sessionConfigSnapshotRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

unless initialize_request["method"] == "initialize"
    abort("expected initialize")
end

initialize_response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
        "protocolVersion" => 1,
        "agentCapabilities" => {
            "loadSession" => false
        },
        "agentInfo" => {
            "name" => "copilot",
            "version" => "1.0.0"
        }
    }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

session_request = JSON.parse(STDIN.gets)
abort("expected session/new") unless session_request["method"] == "session/new"

session_response = {
    "jsonrpc" => "2.0",
    "id" => session_request.fetch("id"),
    "result" => {
        "sessionId" => "remote-new",
        "configOptions" => [
            {
                "category" => "model",
                "currentValue" => "gpt-5-mini",
                "options" => [
                    { "name" => "GPT-5 Mini", "value" => "gpt-5-mini" }
                ],
                "type" => "string"
            }
        ],
        "modes" => {
            "availableModes" => [
                { "id" => "build", "name" => "Build" },
                { "id" => "review", "name" => "Review" }
            ],
            "currentModeId" => "build"
        }
    }
}
STDOUT.write(JSON.generate(session_response) + "\n")
STDOUT.flush
"""#
    }

    private var loadSessionConfigSnapshotRubyAgentScript: String {
        #"""
initialize_request = JSON.parse(STDIN.gets)

unless initialize_request["method"] == "initialize"
    abort("expected initialize")
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
            "version" => "1.1.0"
        }
    }
}
STDOUT.write(JSON.generate(initialize_response) + "\n")
STDOUT.flush

load_request = JSON.parse(STDIN.gets)
abort("expected session/load") unless load_request["method"] == "session/load"

load_response = {
    "jsonrpc" => "2.0",
    "id" => load_request.fetch("id"),
    "result" => {
        "configOptions" => [
            {
                "category" => "model",
                "currentValue" => "claude-sonnet-4",
                "options" => [
                    { "name" => "Claude Sonnet 4", "value" => "claude-sonnet-4" }
                ],
                "type" => "string"
            }
        ],
        "modes" => {
            "availableModes" => [
                { "id" => "build", "name" => "Build" },
                { "id" => "review", "name" => "Review" }
            ],
            "currentModeId" => "review"
        }
    }
}
STDOUT.write(JSON.generate(load_response) + "\n")
STDOUT.flush
"""#
    }

        private func sessionConfigRubyAgentScript(logFile: String) -> String {
                let escapedLogFile = logFile
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")

                return #"""
            log_file = "__LOG_FILE__"

def append_log(path, line)
    return if path.nil? || path.empty?
    File.open(path, "a") { |file| file.puts(line) }
end

initialize_request = JSON.parse(STDIN.gets)
append_log(log_file, initialize_request["method"])

response = {
    "jsonrpc" => "2.0",
    "id" => initialize_request.fetch("id"),
    "result" => {
        "protocolVersion" => 1,
        "agentCapabilities" => {
            "loadSession" => false
        },
        "agentInfo" => {
            "name" => "opencode",
            "version" => "0.6.0"
        }
    }
}
STDOUT.write(JSON.generate(response) + "\n")
STDOUT.flush

session_request = JSON.parse(STDIN.gets)
append_log(log_file, session_request["method"])
abort("expected session/new") unless session_request["method"] == "session/new"

session_response = {
    "jsonrpc" => "2.0",
    "id" => session_request.fetch("id"),
    "result" => {
        "sessionId" => "remote-extension"
    }
}
STDOUT.write(JSON.generate(session_response) + "\n")
STDOUT.flush

while (raw = STDIN.gets)
    request = JSON.parse(raw)
    append_log(log_file, request["method"])
    if request["method"] == "session/set_config_option"
        append_log(log_file, "config=#{request.dig("params", "configId")}")
        append_log(log_file, "value=#{request.dig("params", "value")}")
        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "result" => {
                "configOptions" => [
                    {
                        "category" => "model",
                        "currentValue" => request.dig("params", "value"),
                        "options" => [
                            { "name" => "GPT-5 Mini", "value" => "gpt-5-mini" }
                        ],
                        "type" => "string"
                    }
                ]
            }
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    elsif request["method"] == "session/set_mode"
        append_log(log_file, "mode=#{request.dig("params", "modeId")}")
        response = {
            "jsonrpc" => "2.0",
            "id" => request.fetch("id"),
            "result" => {}
        }
        STDOUT.write(JSON.generate(response) + "\n")
        STDOUT.flush
    end
end
"""#
    .replacingOccurrences(of: "__LOG_FILE__", with: escapedLogFile)
        }
}
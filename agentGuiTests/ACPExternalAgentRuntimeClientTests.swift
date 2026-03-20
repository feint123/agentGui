import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPExternalAgentRuntimeClientTests {
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
}
import Foundation
import Testing
@testable import agentGui

struct ACPManagedClientRuntimeTests {

    @Test func closeStopsManagedProcess() async throws {
        let managed = try ACPManagedClientRuntime.launch(command: "/bin/cat")

        #expect(managed.isRunning)

        await managed.close()

        #expect(!managed.isRunning)
    }

    @Test func launchLocalBridgesFileReadRequestsFromManagedProcess() async throws {
        let workspaceRoot = makeTemporaryDirectory()
        let fileURL = workspaceRoot.appendingPathComponent("sample.txt")
        try "managed-runtime".write(to: fileURL, atomically: true, encoding: .utf8)

        let managed = try ACPManagedClientRuntime.launchLocal(
            command: "/usr/bin/ruby",
            arguments: ["-rjson", "-e", rubyAgentScript, fileURL.path],
            currentDirectoryURL: workspaceRoot,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { _ in TerminalTaskRuntime.makeForTests() }
        )

        let response = try #require(
            try await managed.runtime.sendExtensionRequest(name: "probe", params: [:])
        )

        #expect(response.objectValue?["echoedContent"]?.stringValue == "managed-runtime")

        await managed.close()
    }

    private var rubyAgentScript: String {
        #"""
request = JSON.parse(STDIN.gets)
client_request = {
    "jsonrpc" => "2.0",
    "id" => "read-file-1",
    "method" => "fs/read_text_file",
    "params" => {
        "path" => ARGV[0],
        "sessionId" => "session-managed"
    }
}
STDOUT.write(JSON.generate(client_request) + "\n")
STDOUT.flush
client_response = JSON.parse(STDIN.gets)
response = {
    "jsonrpc" => "2.0",
    "id" => request.fetch("id"),
    "result" => {
        "echoedContent" => client_response.dig("result", "content")
    }
}
STDOUT.write(JSON.generate(response) + "\n")
STDOUT.flush

"""#
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
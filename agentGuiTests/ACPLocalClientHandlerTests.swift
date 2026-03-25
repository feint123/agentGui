import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPLocalClientHandlerTests {
    @Test func readsAndWritesFilesWithinAllowedRoots() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let fileURL = tempDirectory.appendingPathComponent("notes.txt")
        let runtime = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            allowedRoots: [tempDirectory],
            terminalRuntimeProvider: { _ in runtime }
        )

        _ = try await handler.handleWriteTextFile(
            ACPWriteTextFileRequest(
                meta: nil,
                content: "alpha\nbeta\ngamma\ndelta",
                path: fileURL.path,
                sessionID: "session-files"
            )
        )

        let response = try #require(
            try await handler.handleReadTextFile(
                ACPReadTextFileRequest(
                    meta: nil,
                    limit: 2,
                    line: 2,
                    path: fileURL.path,
                    sessionID: "session-files"
                )
            )
        )

        #expect(response.content == "beta\ngamma")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "alpha\nbeta\ngamma\ndelta")
    }

    @Test func rejectsFileAccessOutsideAllowedRoots() async throws {
        let tempDirectory = makeTemporaryDirectory()
        let outsideURL = makeTemporaryDirectory().appendingPathComponent("outside.txt")
        try "nope".write(to: outsideURL, atomically: true, encoding: .utf8)
        let runtime = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            allowedRoots: [tempDirectory],
            terminalRuntimeProvider: { _ in runtime }
        )

        await #expect(throws: ACPRequestError.resourceNotFound(uri: outsideURL.path)) {
            try await handler.handleReadTextFile(
                ACPReadTextFileRequest(
                    meta: nil,
                    limit: nil,
                    line: nil,
                    path: outsideURL.path,
                    sessionID: "session-files"
                )
            )
        }
    }

    @Test func permissionRequestsRespectAuthorizationPolicy() async throws {
        let runtime = TerminalTaskRuntime.makeForTests()
        let allowHandler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { _ in runtime }
        )
        let denyHandler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            terminalRuntimeProvider: { _ in runtime }
        )
        let request = ACPRequestPermissionRequest(
            meta: nil,
            options: [
                ACPPermissionOption(meta: nil, kind: .rejectOnce, name: "Reject", optionID: "reject"),
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow once", optionID: "allow-once")
            ],
            sessionID: "session-permission",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: nil,
                kind: "execute",
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                status: "pending",
                title: "Run shell command",
                toolCallID: "tool-42"
            )
        )

        let allowedResponse = try #require(try await allowHandler.handleRequestPermission(request))
        switch allowedResponse.outcome {
        case .selected(let outcome):
            #expect(outcome.optionID == "allow-once")
        default:
            Issue.record("Expected execution permission to be granted for act-limited policy")
        }

        let deniedResponse = try #require(try await denyHandler.handleRequestPermission(request))
        switch deniedResponse.outcome {
        case .cancelled:
            break
        default:
            Issue.record("Expected execution permission to be denied for observe-only policy")
        }
    }

    @Test func terminalLifecycleReturnsOutputAndSupportsRelease() async throws {
        let runtime = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { _ in runtime }
        )

        let createResponse = try #require(
            try await handler.handleCreateTerminal(
                ACPCreateTerminalRequest(
                    meta: nil,
                    args: nil,
                    command: "/usr/bin/env",
                    cwd: nil,
                    env: [ACPEnvVariable(meta: nil, name: "ACP_SAMPLE", value: "hello world")],
                    outputByteLimit: nil,
                    sessionID: "session-terminal"
                )
            )
        )

        let terminalID = createResponse.terminalID
        let waitResponse = try #require(
            try await handler.handleWaitForTerminalExit(
                ACPWaitForTerminalExitRequest(meta: nil, sessionID: "session-terminal", terminalID: terminalID)
            )
        )
        #expect(waitResponse.exitCode == 0)

        let outputResponse = try #require(
            try await handler.handleTerminalOutput(
                ACPTerminalOutputRequest(meta: nil, sessionID: "session-terminal", terminalID: terminalID)
            )
        )
        #expect(outputResponse.output.contains("ACP_SAMPLE=hello world"))
        #expect(outputResponse.truncated == false)

        _ = try #require(
            try await handler.handleReleaseTerminal(
                ACPReleaseTerminalRequest(meta: nil, sessionID: "session-terminal", terminalID: terminalID)
            )
        )

        await #expect(throws: ACPRequestError.resourceNotFound(uri: terminalID)) {
            try await handler.handleTerminalOutput(
                ACPTerminalOutputRequest(meta: nil, sessionID: "session-terminal", terminalID: terminalID)
            )
        }
    }

    @Test func terminalOutputRespectsByteLimit() async throws {
        let runtime = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { _ in runtime }
        )

        let createResponse = try #require(
            try await handler.handleCreateTerminal(
                ACPCreateTerminalRequest(
                    meta: nil,
                    args: ["abcdef"],
                    command: "/usr/bin/printf",
                    cwd: nil,
                    env: nil,
                    outputByteLimit: 3,
                    sessionID: "session-truncate"
                )
            )
        )

        _ = try #require(
            try await handler.handleWaitForTerminalExit(
                ACPWaitForTerminalExitRequest(meta: nil, sessionID: "session-truncate", terminalID: createResponse.terminalID)
            )
        )

        let outputResponse = try #require(
            try await handler.handleTerminalOutput(
                ACPTerminalOutputRequest(meta: nil, sessionID: "session-truncate", terminalID: createResponse.terminalID)
            )
        )
        #expect(outputResponse.output == "def")
        #expect(outputResponse.truncated)
    }

    @Test func terminalCreatePassesArgumentsWithoutShellExpansion() async throws {
        let runtime = TerminalTaskRuntime.makeForTests()
        let handler = ACPLocalClientHandler(
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            terminalRuntimeProvider: { _ in runtime }
        )

        let createResponse = try #require(
            try await handler.handleCreateTerminal(
                ACPCreateTerminalRequest(
                    meta: nil,
                    args: ["-c", "import os,sys; print(os.environ['ACP_LITERAL']); print(sys.argv[1])", "$(echo hacked)"],
                    command: "/usr/bin/python3",
                    cwd: nil,
                    env: [ACPEnvVariable(meta: nil, name: "ACP_LITERAL", value: "a value with spaces")],
                    outputByteLimit: nil,
                    sessionID: "session-structured-terminal"
                )
            )
        )

        _ = try #require(
            try await handler.handleWaitForTerminalExit(
                ACPWaitForTerminalExitRequest(meta: nil, sessionID: "session-structured-terminal", terminalID: createResponse.terminalID)
            )
        )

        let outputResponse = try #require(
            try await handler.handleTerminalOutput(
                ACPTerminalOutputRequest(meta: nil, sessionID: "session-structured-terminal", terminalID: createResponse.terminalID)
            )
        )

        #expect(outputResponse.output.contains("a value with spaces"))
        #expect(outputResponse.output.contains("$(echo hacked)"))
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

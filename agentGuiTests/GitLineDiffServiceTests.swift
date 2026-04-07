import Testing
import Foundation
@testable import agentGui

// MARK: - Mock

private struct MockCommandRunner: GitCommandRunning {
    let result: GitCommandResult

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        result
    }
}

// MARK: - Tests

struct GitLineDiffServiceTests {

    private let workspaceRoot = URL(filePath: "/tmp/repo")

    @Test func emptyDiffOutput_returnsEmptyMap() async {
        let runner = MockCommandRunner(result: GitCommandResult(stdout: "", stderr: "", exitCode: 0))
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "src/main.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result.isEmpty)
    }

    @Test func nonZeroExitCode_returnsEmptyMap() async {
        let runner = MockCommandRunner(result: GitCommandResult(
            stdout: "fatal: not a git repository", stderr: "", exitCode: 128)
        )
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "file.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result.isEmpty)
    }

    @Test func validDiffOutput_returnsCorrectMap() async {
        let diffOutput = """
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let runner = MockCommandRunner(result: GitCommandResult(stdout: diffOutput, stderr: "", exitCode: 0))
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = workspaceRoot.appending(path: "src/main.swift")
        let result = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: workspaceRoot)
        #expect(result[1] == .added)
        #expect(result[2] == .added)
    }

    @Test func relativePath_computedFromWorkspaceRoot() async {
        var capturedArgs: [String] = []
        struct CapturingRunner: GitCommandRunning {
            let capture: @Sendable ([String]) -> Void
            func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
                capture(arguments)
                return GitCommandResult(stdout: "", stderr: "", exitCode: 0)
            }
        }
        let runner = CapturingRunner { capturedArgs = $0 }
        let service = GitLineDiffService(commandRunner: runner)
        let fileURL = URL(filePath: "/tmp/repo/Sources/App.swift")
        let root = URL(filePath: "/tmp/repo")
        _ = await service.fetchLineDiff(fileURL: fileURL, workspaceRoot: root)
        // 断言使用了 -U0 和正确的相对路径
        #expect(capturedArgs.contains("-U0"))
        #expect(capturedArgs.contains("Sources/App.swift"))
    }
}

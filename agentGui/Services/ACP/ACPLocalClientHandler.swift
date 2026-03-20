import Foundation

actor ACPLocalClientHandler: ACPClientHandler {
    typealias TerminalRuntimeProvider = @Sendable (String) -> TerminalTaskRuntime
    typealias PermissionResolver = @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?

    private struct TerminalState: Sendable {
        let sessionID: String
        let outputByteLimit: Int?
    }

    private let authorizationPolicy: ToolAuthorizationPolicy
    private let allowedRoots: [URL]
    private let fileManager = FileManager.default
    private let terminalRuntimeProvider: TerminalRuntimeProvider
    private let permissionResolver: PermissionResolver?
    private var terminalStates: [String: TerminalState] = [:]

    init(
        authorizationPolicy: ToolAuthorizationPolicy,
        allowedRoots: [URL] = [],
        terminalRuntimeProvider: @escaping TerminalRuntimeProvider,
        permissionResolver: PermissionResolver? = nil
    ) {
        self.authorizationPolicy = authorizationPolicy
        self.allowedRoots = allowedRoots.map(Self.normalizeRoot)
        self.terminalRuntimeProvider = terminalRuntimeProvider
        self.permissionResolver = permissionResolver
    }

    func handleRequestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse? {
        if let permissionResolver {
            return await permissionResolver(request, authorizationPolicy)
        }
        return ACPPermissionPolicyEvaluator.defaultResponse(for: request, policy: authorizationPolicy)
    }

    func handleReadTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse? {
        let url = try validatedFileURL(path: request.path)

        guard fileManager.fileExists(atPath: url.path) else {
            throw ACPRequestError.resourceNotFound(uri: url.path)
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let selected = Self.sliceLines(content, line: request.line, limit: request.limit)
            return ACPReadTextFileResponse(meta: nil, content: selected)
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleWriteTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse? {
        let url = try validatedFileURL(path: request.path)

        do {
            try request.content.write(to: url, atomically: true, encoding: .utf8)
            return ACPWriteTextFileResponse(meta: nil)
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleCreateTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse? {
        let terminalID = UUID().uuidString
        let runtime = terminalRuntimeProvider(request.sessionID)
        let commandLine = Self.makeCommandLine(
            command: request.command,
            args: request.args ?? [],
            env: request.env ?? []
        )

        do {
            _ = try await runtime.startDetached(
                command: commandLine,
                taskId: terminalID,
                workingDirectory: request.cwd
            )
            terminalStates[terminalID] = TerminalState(sessionID: request.sessionID, outputByteLimit: request.outputByteLimit)
            return ACPCreateTerminalResponse(meta: nil, terminalID: terminalID)
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleTerminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse? {
        let state = try terminalState(for: request.terminalID, sessionID: request.sessionID)
        let runtime = terminalRuntimeProvider(state.sessionID)

        do {
            let output = try await runtime.readOutput(taskId: request.terminalID)
            let snapshot = try await runtime.status(taskId: request.terminalID)
            let truncatedOutput = Self.truncateOutput(output, byteLimit: state.outputByteLimit)
            return ACPTerminalOutputResponse(
                meta: nil,
                exitStatus: snapshot.status.isTerminal
                    ? ACPTerminalExitStatus(meta: nil, exitCode: snapshot.exitCode.map(Int.init), signal: snapshot.terminationSignal.map(String.init))
                    : nil,
                output: truncatedOutput.output,
                truncated: truncatedOutput.truncated
            )
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleWaitForTerminalExit(_ request: ACPWaitForTerminalExitRequest) async throws -> ACPWaitForTerminalExitResponse? {
        let state = try terminalState(for: request.terminalID, sessionID: request.sessionID)
        let runtime = terminalRuntimeProvider(state.sessionID)

        do {
            let snapshot = try await runtime.status(taskId: request.terminalID)
            if snapshot.status.isTerminal {
                return ACPWaitForTerminalExitResponse(meta: nil, exitCode: snapshot.exitCode.map(Int.init), signal: snapshot.terminationSignal.map(String.init))
            }

            let outcome = try await runtime.waitForDetachedTask(taskId: request.terminalID)
            return ACPWaitForTerminalExitResponse(
                meta: nil,
                exitCode: outcome.exitCode.map(Int.init),
                signal: outcome.terminationSignal.map(String.init)
            )
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleKillTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse? {
        let state = try terminalState(for: request.terminalID, sessionID: request.sessionID)
        let runtime = terminalRuntimeProvider(state.sessionID)

        do {
            try await runtime.terminate(taskId: request.terminalID, force: true)
            return ACPKillTerminalResponse(meta: nil)
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    func handleReleaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse? {
        let state = try terminalState(for: request.terminalID, sessionID: request.sessionID)
        let runtime = terminalRuntimeProvider(state.sessionID)

        do {
            try await runtime.cleanup(taskId: request.terminalID)
            terminalStates.removeValue(forKey: request.terminalID)
            return ACPReleaseTerminalResponse(meta: nil)
        } catch {
            throw ACPRequestError.internalError(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    private func validatedFileURL(path: String) throws -> URL {
        guard NSString(string: path).isAbsolutePath else {
            throw ACPRequestError.invalidParams(data: .object(["reason": .string("Expected absolute file path")]))
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL

        if !allowedRoots.isEmpty {
            let normalizedPath = url.path
            let isAllowed = allowedRoots.contains { root in
                normalizedPath == root.path || normalizedPath.hasPrefix(root.path + "/")
            }
            guard isAllowed else {
                throw ACPRequestError.resourceNotFound(uri: url.path)
            }
        }

        return url
    }

    private func terminalState(for terminalID: String, sessionID: String) throws -> TerminalState {
        guard let state = terminalStates[terminalID], state.sessionID == sessionID else {
            throw ACPRequestError.resourceNotFound(uri: terminalID)
        }
        return state
    }

    nonisolated private static func normalizeRoot(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    nonisolated private static func sliceLines(_ content: String, line: Int?, limit: Int?) -> String {
        let allLines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let startIndex = max((line ?? 1) - 1, 0)
        guard startIndex < allLines.count else { return "" }

        let endIndex: Int
        if let limit {
            endIndex = min(startIndex + max(limit, 0), allLines.count)
        } else {
            endIndex = allLines.count
        }

        return allLines[startIndex..<endIndex].map(String.init).joined(separator: "\n")
    }

    nonisolated private static func makeCommandLine(command: String, args: [String], env: [ACPEnvVariable]) -> String {
        var segments: [String] = []
        if !env.isEmpty {
            segments.append("env")
            segments.append(contentsOf: env.map { "\($0.name)=\(shellEscapeEnvValue($0.value))" })
        }
        segments.append(contentsOf: ([command] + args).map(shellEscape))
        return segments.joined(separator: " ")
    }

    nonisolated private static func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:=@")
        if value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func shellEscapeEnvValue(_ value: String) -> String {
        shellEscape(value)
    }

    nonisolated private static func truncateOutput(_ output: String, byteLimit: Int?) -> (output: String, truncated: Bool) {
        guard let byteLimit, byteLimit >= 0 else {
            return (output, false)
        }

        if output.lengthOfBytes(using: .utf8) <= byteLimit {
            return (output, false)
        }

        var characters = Array(output)
        while !characters.isEmpty && String(characters).lengthOfBytes(using: .utf8) > byteLimit {
            characters.removeFirst()
        }
        return (String(characters), true)
    }
}

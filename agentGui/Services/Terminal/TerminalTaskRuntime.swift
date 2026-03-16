import Foundation

enum TerminalRuntimeError: Error, Equatable, LocalizedError {
    case taskNotFound
    case taskAlreadyExists

    var errorDescription: String? {
        switch self {
        case .taskNotFound:
            return "Error: terminal task not found for the provided task_id"
        case .taskAlreadyExists:
            return "Error: terminal task_id already exists in this session. Reuse it with status/read_output, call cleanup first, or choose a different task_id."
        }
    }
}

actor TerminalTaskRuntime {
    private let registry: TerminalRuntimeRegistry
    private let transcriptStore: TerminalTranscriptStore
    private var controllers: [String: PtyProcessController] = [:]
    private var detachedTasks: [String: Task<TerminalExecutionOutcome, Error>] = [:]
    private let sessionId: String

    init(
        registry: TerminalRuntimeRegistry,
        transcriptStore: TerminalTranscriptStore,
        sessionId: String = "terminal-runtime"
    ) {
        self.registry = registry
        self.transcriptStore = transcriptStore
        self.sessionId = sessionId
    }

    @MainActor
    static func makeForTests() -> TerminalTaskRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return TerminalTaskRuntime(
            registry: BashTaskRegistry(),
            transcriptStore: TerminalTranscriptStore(baseDirectory: directory)
        )
    }

    func startAttached(command: String, taskId: String, workingDirectory: String? = nil) async throws -> TerminalExecutionOutcome {
        print("[bash-runtime] startAttached session=\(sessionId) task_id=\(taskId) command=\(command) workingDirectory=\(workingDirectory ?? "nil")")
        try await ensureTaskAvailable(taskId: taskId)
        let controller = try PtyProcessController(
            command: command,
            shell: "/bin/zsh",
            workingDirectory: workingDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        controllers[taskId] = controller

        let transcriptPath = try await prepareTask(taskId: taskId, command: command, executionMode: .attached)
        if var snapshot = await registry.snapshot(taskId: taskId) {
            snapshot.status = .running
            snapshot.pid = controller.processIdentifier
            await registry.upsert(snapshot)
        }
        let result = try await controller.runUntilExit()
        let outcome = try await finalizeTask(
            taskId: taskId,
            transcriptPath: transcriptPath,
            result: result
        )
        print("[bash-runtime] startAttached finished session=\(sessionId) task_id=\(taskId) completion=\(outcome.completionReason.rawValue)")
        controllers[taskId] = nil
        return outcome
    }

    func startDetached(command: String, taskId: String, workingDirectory: String? = nil) async throws -> TerminalTaskSnapshot {
        print("[bash-runtime] startDetached session=\(sessionId) task_id=\(taskId) command=\(command) workingDirectory=\(workingDirectory ?? "nil")")
        try await ensureTaskAvailable(taskId: taskId)
        let controller = try PtyProcessController(
            command: command,
            shell: "/bin/zsh",
            workingDirectory: workingDirectory,
            environment: ProcessInfo.processInfo.environment
        )
        controllers[taskId] = controller

        let transcriptPath = try await prepareTask(taskId: taskId, command: command, executionMode: .detached)
        try controller.start()

        var snapshot = try await requireSnapshot(taskId: taskId)
        snapshot.status = .running
        snapshot.pid = controller.processIdentifier
        await registry.upsert(snapshot)

        detachedTasks[taskId] = Task {
            let result = try await controller.waitForExit()
            return try await self.finalizeTask(taskId: taskId, transcriptPath: transcriptPath, result: result)
        }

        print("[bash-runtime] startDetached running session=\(sessionId) task_id=\(taskId) pid=\(snapshot.pid ?? 0)")
        return snapshot
    }

    func status(taskId: String) async throws -> TerminalTaskSnapshot {
        print("[bash-runtime] status lookup session=\(sessionId) task_id=\(taskId)")
        return try await requireSnapshot(taskId: taskId)
    }

    func readOutput(taskId: String, tailLines: Int = 20) async throws -> String {
        print("[bash-runtime] readOutput session=\(sessionId) task_id=\(taskId) tailLines=\(tailLines)")
        if let controller = controllers[taskId] {
            let liveOutput = controller.currentOutput()
            if !liveOutput.isEmpty {
                print("[bash-runtime] readOutput using live controller session=\(sessionId) task_id=\(taskId) chars=\(liveOutput.count)")
                return liveOutput
            }
        }
        print("[bash-runtime] readOutput falling back to transcript session=\(sessionId) task_id=\(taskId)")
        return try transcriptStore.readTail(taskId: taskId, lineCount: tailLines)
    }

    func sendInput(taskId: String, input: String) async throws {
        guard let controller = controllers[taskId] else { throw TerminalRuntimeError.taskNotFound }
        try controller.sendInput(input)
    }

    func interrupt(taskId: String) async throws {
        guard let controller = controllers[taskId] else { throw TerminalRuntimeError.taskNotFound }
        try controller.interrupt()
    }

    func terminate(taskId: String, force: Bool) async throws {
        guard let controller = controllers[taskId] else { throw TerminalRuntimeError.taskNotFound }
        try controller.terminate(force: force)
    }

    func cleanup(taskId: String) async throws {
        controllers[taskId] = nil
        detachedTasks[taskId] = nil
    }

    func waitForDetachedTask(taskId: String) async throws -> TerminalExecutionOutcome {
        guard let task = detachedTasks[taskId] else { throw TerminalRuntimeError.taskNotFound }
        let outcome = try await task.value
        detachedTasks[taskId] = nil
        controllers[taskId] = nil
        return outcome
    }

    private func ensureTaskAvailable(taskId: String) async throws {
        if await registry.snapshot(taskId: taskId) != nil || controllers[taskId] != nil {
            print("[bash-runtime] ensureTaskAvailable conflict session=\(sessionId) task_id=\(taskId)")
            throw TerminalRuntimeError.taskAlreadyExists
        }
    }

    private func requireSnapshot(taskId: String) async throws -> TerminalTaskSnapshot {
        guard let snapshot = await registry.snapshot(taskId: taskId) else {
            print("[bash-runtime] requireSnapshot MISS session=\(sessionId) task_id=\(taskId) controllerExists=\(controllers[taskId] != nil) detachedExists=\(detachedTasks[taskId] != nil)")
            throw TerminalRuntimeError.taskNotFound
        }
        print("[bash-runtime] requireSnapshot HIT session=\(sessionId) task_id=\(taskId) status=\(snapshot.status.rawValue)")
        return snapshot
    }

    private func prepareTask(taskId: String, command: String, executionMode: TerminalExecutionMode) async throws -> String {
        try transcriptStore.createTranscript(taskId: taskId)
        let transcriptPath = transcriptStore.transcriptURL(taskId: taskId).path
        print("[bash-runtime] prepareTask session=\(sessionId) task_id=\(taskId) mode=\(executionMode.rawValue) transcript=\(transcriptPath)")
        let snapshot = TerminalTaskSnapshot(
            id: taskId,
            sessionId: sessionId,
            command: command,
            executionMode: executionMode,
            status: .launching,
            transcriptPath: transcriptPath,
            startedAt: Date()
        )
        await registry.upsert(snapshot)
        return transcriptPath
    }

    private func finalizeTask(taskId: String, transcriptPath: String, result: PtyProcessResult) async throws -> TerminalExecutionOutcome {
        print("[bash-runtime] finalizeTask session=\(sessionId) task_id=\(taskId) exit=\(result.exitCode) outputChars=\(result.output.count)")
        try transcriptStore.append(result.output, to: taskId)

        let completionReason: TerminalCompletionReason = result.exitCode == 0 ? .exitedZero : .exitedNonZero
        let outcome = TerminalExecutionOutcome(
            taskId: taskId,
            exitCode: result.exitCode,
            terminationSignal: nil,
            completionReason: completionReason,
            startedAt: (await registry.snapshot(taskId: taskId))?.startedAt,
            endedAt: Date(),
            transcriptPath: transcriptPath,
            finalOutputSnippet: result.output
        )

        if var snapshot = await registry.snapshot(taskId: taskId) {
            snapshot.status = result.exitCode == 0 ? .completed : .failed
            snapshot.exitCode = result.exitCode
            snapshot.endedAt = outcome.endedAt
            snapshot.completionReason = completionReason
            snapshot.latestOutputSnippet = result.output
            snapshot.transcriptPath = transcriptPath
            await registry.upsert(snapshot)
        }

        return outcome
    }
}
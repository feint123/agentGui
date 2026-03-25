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
    private let shellIntegrationParser = TerminalShellIntegrationParser()
    private let vtParser = TerminalVTParser()
    private let keyEncoder = TerminalKeyEncoder()
    private var controllers: [String: PtyProcessController] = [:]
    private var detachedTasks: [String: Task<TerminalExecutionOutcome, Error>] = [:]
    private var screenModels: [String: TerminalScreenModel] = [:]
    private var rawScreenOutputs: [String: String] = [:]
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

    func startDetached(
        command: String,
        args: [String],
        environment: [String: String],
        taskId: String,
        workingDirectory: String? = nil
    ) async throws -> TerminalTaskSnapshot {
        print("[bash-runtime] startDetached structured session=\(sessionId) task_id=\(taskId) command=\(command) args=\(args.joined(separator: " ")) workingDirectory=\(workingDirectory ?? "nil")")
        try await ensureTaskAvailable(taskId: taskId)
        let controller = try PtyProcessController(
            executable: command,
            arguments: args,
            workingDirectory: workingDirectory,
            environment: environment
        )
        controllers[taskId] = controller

        let transcriptPath = try await prepareTask(
            taskId: taskId,
            command: ([command] + args).joined(separator: " "),
            executionMode: .detached
        )
        try controller.start()

        var snapshot = try await requireSnapshot(taskId: taskId)
        snapshot.status = .running
        snapshot.pid = controller.processIdentifier
        await registry.upsert(snapshot)

        detachedTasks[taskId] = Task {
            let result = try await controller.waitForExit()
            return try await self.finalizeTask(taskId: taskId, transcriptPath: transcriptPath, result: result)
        }

        print("[bash-runtime] startDetached structured running session=\(sessionId) task_id=\(taskId) pid=\(snapshot.pid ?? 0)")
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
        print("[bash-runtime] sendInput session=\(sessionId) task_id=\(taskId) chars=\(input.count) payload=\(input.debugDescription)")
        try controller.sendInput(input)
    }

    func applyInteractionActions(taskId: String, actions: [TerminalInteractionAction]) async throws {
        guard let controller = controllers[taskId] else { throw TerminalRuntimeError.taskNotFound }

        print("[bash-runtime] applyInteractionActions session=\(sessionId) task_id=\(taskId) actions=\(actions.map(actionLabel).joined(separator: ", "))")

        for action in actions {
            switch action {
            case .key(let key):
                print("[bash-runtime] applyInteractionAction key session=\(sessionId) task_id=\(taskId) key=\(key.rawValue)")
                try controller.sendInput(keyEncoder.encode(key))
            case .text(let text):
                print("[bash-runtime] applyInteractionAction text session=\(sessionId) task_id=\(taskId) payload=\(text.debugDescription)")
                try controller.sendInput(text)
            case .wait(let milliseconds):
                print("[bash-runtime] applyInteractionAction wait session=\(sessionId) task_id=\(taskId) milliseconds=\(milliseconds)")
                let duration = UInt64(max(milliseconds, 0)) * 1_000_000
                try await Task.sleep(nanoseconds: duration)
            case .signal(let signal):
                print("[bash-runtime] applyInteractionAction signal session=\(sessionId) task_id=\(taskId) signal=\(signal.rawValue)")
                switch signal {
                case .interrupt:
                    try controller.interrupt()
                case .terminate:
                    try controller.terminate(force: false)
                }
            }
        }
    }

    private func actionLabel(_ action: TerminalInteractionAction) -> String {
        switch action {
        case .key(let key):
            return key.rawValue
        case .text(let text):
            return "text:\(text)"
        case .wait(let milliseconds):
            return "wait:\(milliseconds)ms"
        case .signal(let signal):
            return signal.rawValue
        }
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
        screenModels[taskId] = nil
        rawScreenOutputs[taskId] = nil
    }

    func screenSnapshot(taskId: String) async throws -> TerminalScreenSnapshot {
        guard screenModels[taskId] != nil else {
            throw TerminalRuntimeError.taskNotFound
        }

        try await syncScreenModel(taskId: taskId)

        if let controller = controllers[taskId],
           let liveSnapshot = await registry.snapshot(taskId: taskId),
           !liveSnapshot.status.isTerminal {
            let currentOutput = controller.currentRawOutput()
            let needsSettling = currentOutput.contains("\r") || currentOutput.contains("\u{001B}[")

            if needsSettling {
                for _ in 0..<8 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    try await syncScreenModel(taskId: taskId)

                    if let refreshed = await registry.snapshot(taskId: taskId), refreshed.status.isTerminal {
                        break
                    }
                }
            }
        }

        if let initialSnapshot = screenModels[taskId]?.snapshot(),
           initialSnapshot.plainTextLines.joined().isEmpty,
           controllers[taskId] != nil {
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 50_000_000)
                try await syncScreenModel(taskId: taskId)
                if let updatedSnapshot = screenModels[taskId]?.snapshot(),
                   !updatedSnapshot.plainTextLines.joined().isEmpty {
                    return updatedSnapshot
                }
            }
        }

        guard let screenModel = screenModels[taskId] else {
            throw TerminalRuntimeError.taskNotFound
        }

        return screenModel.snapshot()
    }

    func ingestShellIntegrationOutput(taskId: String, output: String) async throws {
        var snapshot = try await requireSnapshot(taskId: taskId)
        let events = shellIntegrationParser.parse(output)

        for event in events {
            switch event {
            case .property(let name, let value):
                if name == "Cwd" {
                    snapshot.currentWorkingDirectory = value
                }
            case .commandLine(let line):
                snapshot.shellCommandLine = line
            case .commandFinished(let exitCode):
                snapshot.exitCode = exitCode
            case .promptStart, .promptEnd, .commandStart:
                break
            }
        }

        await registry.upsert(snapshot)
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
        screenModels[taskId] = TerminalScreenModel()
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
        rawScreenOutputs[taskId] = result.rawOutput
        var screenModel = TerminalScreenModel()
        for event in vtParser.parse(result.rawOutput) {
            screenModel.apply(event)
        }
        screenModels[taskId] = screenModel

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

    private func syncScreenModel(taskId: String) async throws {
        guard var screenModel = screenModels[taskId] else {
            throw TerminalRuntimeError.taskNotFound
        }

        let snapshot = await registry.snapshot(taskId: taskId)
        let liveOutput = controllers[taskId]?.currentRawOutput() ?? ""
        let persistedOutput = rawScreenOutputs[taskId] ?? snapshot?.latestOutputSnippet ?? ""
        let sourceOutput = persistedOutput.count >= liveOutput.count ? persistedOutput : liveOutput

        screenModel = TerminalScreenModel()
        for event in vtParser.parse(sourceOutput) {
            screenModel.apply(event)
        }
        screenModels[taskId] = screenModel
    }
}
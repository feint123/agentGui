//
//  BashSession.swift
//  agentGui
//

import Foundation

/// 持久化 bash session，通过轮询哨兵标记检测命令完成
actor BashSession {

    private struct ActiveCommand {
        let sentinel: String
        var transcript: String = ""
        var lastReportedLength: Int = 0
    }

    private var process: Process?
    private var stdinHandle: FileHandle?

    /// 当前命令的输出缓冲
    private var outputBuffer = ""
    /// 等待的哨兵字符串
    private var currentSentinel = ""
    /// 当前正在运行的前台命令
    private var activeCommand: ActiveCommand?
    /// 最大缓冲字节数 (50 KB)
    private let maxOutputBytes = 50_000
    /// 启动时使用的工作目录（用于自动重启）
    private var lastWorkingDirectory: String? = nil
    /// 启动时注入的环境变量覆盖（用于自动重启）
    private var lastEnvironmentOverrides: [String: String] = [:]

    // MARK: - Lifecycle

    func start(workingDirectory: String? = nil, environmentOverrides: [String: String] = [:]) {
        lastWorkingDirectory = workingDirectory
        lastEnvironmentOverrides = environmentOverrides
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = []

        // Resolve the user's full login-shell PATH so tools like npx, brew, nvm etc. are found.
        // macOS app sandboxing inherits a minimal PATH; running a one-shot login shell
        // (sourcing ~/.zshrc for nvm-style setups) gives us the real PATH.
        proc.environment = ShellEnvironmentResolver.resolvedEnvironment(
            environmentOverrides: environmentOverrides
        )

        if let wd = workingDirectory, !wd.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { await self?.append(str) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { await self?.append(str) }
        }

        try? proc.run()
        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
    }

    private func append(_ str: String) {
        outputBuffer += str
        if outputBuffer.count > maxOutputBytes {
            outputBuffer = String(outputBuffer.suffix(maxOutputBytes))
        }

        guard var activeCommand else { return }
        activeCommand.transcript += str
        if activeCommand.transcript.count > maxOutputBytes {
            let overflow = activeCommand.transcript.count - maxOutputBytes
            activeCommand.transcript = String(activeCommand.transcript.suffix(maxOutputBytes))
            activeCommand.lastReportedLength = max(0, activeCommand.lastReportedLength - overflow)
        }
        self.activeCommand = activeCommand
    }

    // MARK: - Execution

    /// 返回当前输出缓冲快照，供外部轮询实时展示。
    func currentOutput() -> String { outputBuffer }

    /// 返回底层 shell process 当前是否仍然存活。
    func isProcessAlive() -> Bool {
        process?.isRunning ?? false
    }

    /// 返回当前前台命令自上次读取后的输出增量。
    func currentOutputDelta() -> String {
        reportedDelta(from: activeCommand?.transcript ?? "")
    }

    /// 在持久化 session 中执行命令。
    ///
    /// - Parameters:
    ///   - command: 要执行的 shell 命令。
    ///   - timeout: 最长等待秒数（默认 300s）。超时后返回已有输出并重启 session。
    ///   - background: 若为 true，命令以后台模式运行（`&`），输出重定向至临时 log 文件，
    ///     立即返回 PID 和 log 路径。适用于服务器、watcher 等不会主动退出的进程。
    ///     使用 `cat <logpath>` 或 `tail -f <logpath>` 读取后续输出。
    ///   - interactive: 若为 true，在命令输出进入静默后立刻返回，让调用方继续通过 `sendInput`
    ///     回答交互式问题，而不是一直阻塞到命令彻底结束。
    func execute(
        _ command: String,
        timeout: TimeInterval = 300,
        background: Bool = false,
        interactive: Bool = false
    ) async -> String {
        if !(process?.isRunning ?? false) {
            start(workingDirectory: lastWorkingDirectory, environmentOverrides: lastEnvironmentOverrides)
            // Give bash time to fully initialize before writing to stdin
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        }

        if activeCommand != nil {
            return "Error: a foreground bash command is still running. Send input to it, interrupt it, or restart the bash session before starting another command."
        }

        let sentinel = "BASH_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        currentSentinel = sentinel
        activeCommand = ActiveCommand(sentinel: sentinel)
        // Yield to flush any pending readabilityHandler append tasks from the previous command
        await Task.yield()
        outputBuffer = ""

        if background {
            // Fork command to background; redirect output to a temp log file.
            let logFile = "/tmp/agentgui_\(UUID().uuidString.prefix(8)).log"
            let cmd = "{ \(command); } > \(logFile) 2>&1 & echo \"[Background] PID: $! | Log: \(logFile)\"; printf '\\n%s\\n' '\(sentinel)'\n"
            stdinHandle?.write(Data(cmd.utf8))
            // Short deadline — the echo + sentinel should arrive within seconds
            let deadline = Date().addingTimeInterval(10)
            while true {
                if outputBuffer.contains(sentinel) {
                    let parts = outputBuffer.components(separatedBy: sentinel)
                    let result = (parts.first ?? "").trimmingCharacters(in: .newlines)
                    currentSentinel = ""
                    activeCommand = nil
                    outputBuffer = ""
                    return result.isEmpty ? "[Background] Process started (no PID echo received)" : result
                }
                if Date() > deadline {
                    currentSentinel = ""
                    activeCommand = nil
                    outputBuffer = ""
                    return "[Background] Process started (launch confirmation timed out). Check \"/tmp/agentgui_*.log\" for output."
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // 包裹命令捕获 stderr，然后输出哨兵
        let cmd = "{ \(command); } 2>&1; printf '\\n%s\\n' '\(sentinel)'\n"
        stdinHandle?.write(Data(cmd.utf8))

        return await awaitForegroundCommand(timeout: timeout, interactive: interactive)
    }

    /// 向当前交互式前台命令继续发送输入。
    func sendInput(_ input: String, timeout: TimeInterval = 2) async -> String {
        guard activeCommand != nil else {
            return "Error: there is no interactive bash command waiting for input."
        }

        let payload = input.hasSuffix("\n") ? input : input + "\n"
        stdinHandle?.write(Data(payload.utf8))
        return await awaitForegroundCommand(timeout: timeout, interactive: true)
    }

    /// 向当前前台命令发送 Ctrl-C，并返回新的输出。
    func interrupt(timeout: TimeInterval = 2) async -> String {
        guard activeCommand != nil else {
            return "Error: there is no foreground bash command to interrupt."
        }

        stdinHandle?.write(Data([0x03]))
        return await awaitForegroundCommand(timeout: timeout, interactive: true)
    }

    /// 向当前前台命令发送 SIGTERM；若无前台任务则终止整个 shell。
    func terminateCurrentCommand() {
        if activeCommand != nil {
            process?.terminate()
            process = nil
            stdinHandle = nil
            activeCommand = nil
            currentSentinel = ""
            outputBuffer = ""
            start(workingDirectory: lastWorkingDirectory, environmentOverrides: lastEnvironmentOverrides)
            return
        }

        terminate()
    }

    private func awaitForegroundCommand(timeout: TimeInterval, interactive: Bool) async -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var previousLength = activeCommand?.transcript.count ?? 0
        var lastProgressAt = Date()

        while true {
            guard let activeCommand else {
                return "Error: bash command state was lost unexpectedly."
            }

            if let range = activeCommand.transcript.range(of: activeCommand.sentinel) {
                let completedOutput = String(activeCommand.transcript[..<range.lowerBound])
                    .trimmingCharacters(in: .newlines)
                let delta = reportedDelta(from: completedOutput)
                currentSentinel = ""
                self.activeCommand = nil
                outputBuffer = ""

                if interactive {
                    return delta.isEmpty ? "[Interactive bash] Command completed." : delta
                }
                return completedOutput.isEmpty ? "(no output)" : completedOutput
            }

            if interactive {
                let currentLength = activeCommand.transcript.count
                if currentLength != previousLength {
                    previousLength = currentLength
                    lastProgressAt = Date()
                } else if Date().timeIntervalSince(lastProgressAt) >= 0.75 {
                    return markInteractiveProgress()
                }
            }

            if Date() > deadline {
                if interactive {
                    return markInteractiveProgress(timeoutNotice: true)
                }

                let partial = activeCommand.transcript.trimmingCharacters(in: .newlines)
                currentSentinel = ""
                self.activeCommand = nil
                outputBuffer = ""
                // Restart the bash session so subsequent commands work in a clean state
                restart(workingDirectory: lastWorkingDirectory)
                return partial + (partial.isEmpty ? "" : "\n") + "[Timed out after \(Int(timeout))s — bash session restarted]"
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func reportedDelta(from transcript: String) -> String {
        guard var activeCommand else { return transcript }

        let safeOffset = min(activeCommand.lastReportedLength, transcript.count)
        let start = transcript.index(transcript.startIndex, offsetBy: safeOffset)
        let delta = String(transcript[start...]).trimmingCharacters(in: .newlines)
        activeCommand.lastReportedLength = transcript.count
        self.activeCommand = activeCommand
        return delta
    }

    private func markInteractiveProgress(timeoutNotice: Bool = false) -> String {
        let delta = reportedDelta(from: activeCommand?.transcript ?? "")
        let notice = timeoutNotice
            ? "[Interactive bash] Command is still running after waiting and may need more input."
            : "[Interactive bash] Command is still running and may need more input."

        if delta.isEmpty {
            return "\(notice)\nSend another bash tool call with {\"input\":\"...\",\"interactive\":true} to continue, or {\"interrupt\":true} to cancel."
        }

        return """
        \(notice)
        New output:
        \(delta)

        Send another bash tool call with {"input":"...","interactive":true} to continue, or {"interrupt":true} to cancel.
        """
    }

    func restart(workingDirectory: String? = nil, environmentOverrides: [String: String]? = nil) {
        let resolvedWorkingDirectory = workingDirectory ?? lastWorkingDirectory
        let resolvedEnvironmentOverrides = environmentOverrides ?? lastEnvironmentOverrides
        process?.terminate()
        process = nil
        stdinHandle = nil
        outputBuffer = ""
        currentSentinel = ""
        activeCommand = nil
        start(workingDirectory: resolvedWorkingDirectory, environmentOverrides: resolvedEnvironmentOverrides)
    }

    func terminate() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        activeCommand = nil
    }
}

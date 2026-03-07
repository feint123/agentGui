//
//  BashSession.swift
//  agentGui
//

import Foundation

/// 持久化 bash session，通过轮询哨兵标记检测命令完成
actor BashSession {

    private var process: Process?
    private var stdinHandle: FileHandle?

    /// 当前命令的输出缓冲
    private var outputBuffer = ""
    /// 等待的哨兵字符串
    private var currentSentinel = ""
    /// 最大缓冲字节数 (50 KB)
    private let maxOutputBytes = 50_000
    /// 启动时使用的工作目录（用于自动重启）
    private var lastWorkingDirectory: String? = nil

    // MARK: - Lifecycle

    func start(workingDirectory: String? = nil) {
        lastWorkingDirectory = workingDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = []

        // Resolve the user's full login-shell PATH so tools like npx, brew, nvm etc. are found.
        // macOS app sandboxing inherits a minimal PATH; running a one-shot login shell
        // (sourcing ~/.zshrc for nvm-style setups) gives us the real PATH.
        var env = ProcessInfo.processInfo.environment
        if let loginPath = BashSession.resolveLoginShellPath(), !loginPath.isEmpty {
            env["PATH"] = loginPath
        }
        proc.environment = env

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
    }

    // MARK: - Execution

    /// 在持久化 session 中执行命令，最多等待 timeout 秒
    func execute(_ command: String, timeout: TimeInterval = 30) async -> String {
        if !(process?.isRunning ?? false) {
            start()
            // Give bash time to fully initialize before writing to stdin
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        }

        let sentinel = "BASH_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        currentSentinel = sentinel
        // Yield to flush any pending readabilityHandler append tasks from the previous command
        await Task.yield()
        outputBuffer = ""

        // 包裹命令捕获 stderr，然后输出哨兵
        let cmd = "{ \(command); } 2>&1; printf '\\n%s\\n' '\(sentinel)'\n"
        stdinHandle?.write(Data(cmd.utf8))

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // 检查哨兵
            if outputBuffer.contains(sentinel) {
                let parts = outputBuffer.components(separatedBy: sentinel)
                let result = (parts.first ?? "").trimmingCharacters(in: .newlines)
                currentSentinel = ""
                outputBuffer = ""
                return result.isEmpty ? "(no output)" : result
            }
            if Date() > deadline {
                let partial = outputBuffer
                currentSentinel = ""
                outputBuffer = ""
                // Restart the bash session so subsequent commands work in a clean state
                restart(workingDirectory: lastWorkingDirectory)
                return partial + (partial.isEmpty ? "" : "\n") + "[Timed out after \(Int(timeout))s — bash session restarted]"
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms 轮询
        }
    }

    func restart(workingDirectory: String? = nil) {
        process?.terminate()
        process = nil
        stdinHandle = nil
        outputBuffer = ""
        currentSentinel = ""
        start(workingDirectory: workingDirectory)
    }

    func terminate() {
        process?.terminate()
        process = nil
    }

    // MARK: - Login PATH Resolution

    /// Runs a one-shot login zsh shell to obtain the user's real PATH.
    /// Sources ~/.zshrc inline so that nvm / volta / etc. path additions are included.
    nonisolated private static func resolveLoginShellPath() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l = login shell: loads /etc/zprofile and ~/.zprofile (Homebrew, etc.)
        // We also source ~/.zshrc to capture nvm/volta/etc. PATH additions.
        proc.arguments = ["-l", "-c", "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; echo $PATH"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe() // discard stderr
        try? proc.run()
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

enum ShellEnvironmentResolver {
    static func resolvedEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentOverrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = baseEnvironment
        if let loginPath = resolveLoginShellPath(), !loginPath.isEmpty {
            environment["PATH"] = loginPath
        }
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return environment
    }

    static func resolveLoginShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; echo $PATH"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
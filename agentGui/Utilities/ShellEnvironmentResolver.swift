import Foundation

enum ShellEnvironmentResolver {
    typealias LoginShellPathResolver = @Sendable ([String: String]) -> String?
    typealias LoginShellPathProcessRunner = @Sendable ([String: String]) -> String?

    nonisolated
    static func resolvedEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environmentOverrides: [String: String] = [:],
        loginShellPathResolver: LoginShellPathResolver = resolveLoginShellPath
    ) -> [String: String] {
        var environment = baseEnvironment
        if let loginPath = loginShellPathResolver(baseEnvironment), !loginPath.isEmpty {
            environment["PATH"] = loginPath
        }
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return environment
    }

    nonisolated
    static func resolveExecutableURL(
        command: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        loginShellPathResolver: LoginShellPathResolver = resolveLoginShellPath
    ) -> URL? {
        let environment = resolvedEnvironment(
            baseEnvironment: baseEnvironment,
            loginShellPathResolver: loginShellPathResolver
        )
        return resolveExecutableURL(command: command, environment: environment, fileManager: fileManager)
    }

    nonisolated
    static func resolveExecutableURL(
        command: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if NSString(string: trimmed).isAbsolutePath {
            let url = URL(fileURLWithPath: trimmed)
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }

        let searchPath = environment["PATH"] ?? ""
        for candidatePath in searchPath.split(separator: ":").map(String.init) where !candidatePath.isEmpty {
            let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true).appendingPathComponent(trimmed)
            if fileManager.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        return nil
    }

    nonisolated
    static func resolveLoginShellPath(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        resolveLoginShellPath(baseEnvironment: baseEnvironment, processRunner: defaultLoginShellPathProcessRunner)
    }

    nonisolated
    static func resolveLoginShellPath(
        baseEnvironment: [String: String],
        processRunner: LoginShellPathProcessRunner
    ) -> String? {
        let cacheKey = loginShellPathCacheKey(for: baseEnvironment)
        if let cached = cachedLoginShellPath(for: cacheKey) {
            return cached
        }

        let resolved = processRunner(baseEnvironment)
        cacheQueue.sync {
            cachedLoginShellPaths[cacheKey] = resolved
        }
        return resolved
    }

    nonisolated
    static func resetLoginShellPathCacheForTesting() {
        cacheQueue.sync {
            cachedLoginShellPaths.removeAll()
        }
    }

    nonisolated
    private static func defaultLoginShellPathProcessRunner(baseEnvironment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; echo $PATH"]
        process.environment = baseEnvironment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated
    private static func loginShellPathCacheKey(for baseEnvironment: [String: String]) -> String {
        let keys = ["HOME", "PATH", "SHELL", "USER", "ZDOTDIR"]
        return keys.map { key in
            "\(key)=\(baseEnvironment[key] ?? "")"
        }.joined(separator: "\n")
    }

    nonisolated
    private static func cachedLoginShellPath(for cacheKey: String) -> String? {
        cacheQueue.sync {
            cachedLoginShellPaths[cacheKey] ?? nil
        }
    }

    private static let cacheQueue = DispatchQueue(label: "com.agentgui.shell-environment-resolver.cache")
    private static var cachedLoginShellPaths: [String: String?] = [:]
}
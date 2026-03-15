import Foundation

struct LSPInstallCommand: Sendable, Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String?

    init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

struct LSPInstallCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol LSPInstallCommandRunning: Sendable {
    func run(_ command: LSPInstallCommand) async -> LSPInstallCommandResult
}

protocol LSPInstallFileManaging: AnyObject {
    func createDirectory(at url: URL) throws
    func writeExecutableFile(at url: URL, contents: String) throws
    func createOrReplaceSymlink(at url: URL, destination: URL) throws
    func fileExists(at url: URL) -> Bool
}

struct LSPInstallActivityEvent: Sendable {
    let phase: LSPInstallPhase?
    let progressMessage: String?
    let logMessage: String?
    let logLevel: LSPInstallLogLevel
    let detectedVersion: String?
    let failureMessage: String?

    init(
        phase: LSPInstallPhase? = nil,
        progressMessage: String? = nil,
        logMessage: String? = nil,
        logLevel: LSPInstallLogLevel = .info,
        detectedVersion: String? = nil,
        failureMessage: String? = nil
    ) {
        self.phase = phase
        self.progressMessage = progressMessage
        self.logMessage = logMessage
        self.logLevel = logLevel
        self.detectedVersion = detectedVersion
        self.failureMessage = failureMessage
    }
}

enum LSPInstallStrategy: Sendable {
    case managedInstall
    case executableProbe
    case failingExecutableProbe
    case successfulProbe(executablePath: String)
}

extension LSPInstallStrategy {
    func execute(
        provider: LSPProviderDefinition,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        installRoot: URL,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        switch self {
        case .managedInstall:
            return await managedInstall(
                provider: provider,
                commandRunner: commandRunner,
                fileSystem: fileSystem,
                installRoot: installRoot,
                report: report
            )

        case .failingExecutableProbe:
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: "无法找到可执行文件",
                logLevel: .error,
                failureMessage: "无法找到可执行文件"
            ))
            return LSPInstallResult(
                providerID: provider.id,
                status: .failed,
                message: "无法找到可执行文件",
                recoverySuggestion: .recheckPath
            )

        case .successfulProbe(let executablePath):
            let version = await probeVersion(
                executablePath: executablePath,
                commandRunner: commandRunner,
                report: report
            )
            return installedResult(provider: provider, executablePath: executablePath, version: version, message: "已检测到可执行文件")

        case .executableProbe:
            await report(LSPInstallActivityEvent(phase: .preparing, progressMessage: "探测可执行文件"))
            let environment = LSPProcessEnvironmentResolver.resolvedEnvironment()
            guard let executableURL = LSPProcessEnvironmentResolver.resolveExecutableURL(
                command: provider.defaultServerTemplate.launchCommand,
                environment: environment
            ) else {
                await report(LSPInstallActivityEvent(
                    phase: .failed,
                    progressMessage: "安装失败",
                    logMessage: "未检测到可执行文件",
                    logLevel: .error,
                    failureMessage: "未检测到可执行文件"
                ))
                return LSPInstallResult(
                    providerID: provider.id,
                    status: .failed,
                    message: "未检测到可执行文件",
                    recoverySuggestion: .recheckPath
                )
            }

            let version = await probeVersion(
                executablePath: executableURL.path,
                commandRunner: commandRunner,
                report: report
            )
            return installedResult(provider: provider, executablePath: executableURL.path, version: version, message: "已检测到可执行文件")
        }
    }

    private func managedInstall(
        provider: LSPProviderDefinition,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        installRoot: URL,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        let layout = LSPManagedInstallLayout(installRoot: installRoot, providerID: provider.id)

        await report(LSPInstallActivityEvent(phase: .preparing, progressMessage: "准备安装目录"))

        do {
            try fileSystem.createDirectory(at: layout.installRoot)
            try fileSystem.createDirectory(at: layout.binDirectory)
            try fileSystem.createDirectory(at: layout.providerDirectory)
        } catch {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: error.localizedDescription,
                logLevel: .error,
                failureMessage: error.localizedDescription
            ))
            return fileFailure(provider: provider, error: error)
        }

        switch provider.recommendedInstallMethod {
        case .builtIn:
            return await Self.executableProbe.execute(
                provider: provider,
                commandRunner: commandRunner,
                fileSystem: fileSystem,
                installRoot: installRoot,
                report: report
            )

        case .npmGlobal:
            return await installNPMProvider(provider: provider, layout: layout, commandRunner: commandRunner, fileSystem: fileSystem, report: report)

        case .goTool:
            return await installGoProvider(provider: provider, layout: layout, commandRunner: commandRunner, fileSystem: fileSystem, report: report)

        case .cargo:
            return await installCargoProvider(provider: provider, layout: layout, commandRunner: commandRunner, fileSystem: fileSystem, report: report)

        case .homebrew:
            return await installHomebrewProvider(provider: provider, layout: layout, commandRunner: commandRunner, fileSystem: fileSystem, report: report)

        case .manual:
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: "当前 provider 仅支持手工配置",
                logLevel: .error,
                failureMessage: "当前 provider 仅支持手工配置"
            ))
            return LSPInstallResult(
                providerID: provider.id,
                status: .failed,
                message: "当前 provider 仅支持手工配置",
                recoverySuggestion: .configureManually
            )
        }
    }

    private func installNPMProvider(
        provider: LSPProviderDefinition,
        layout: LSPManagedInstallLayout,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        let prefix = layout.providerDirectory.appendingPathComponent("npm-prefix", isDirectory: true)
        let managedExecutable = layout.binDirectory.appendingPathComponent(provider.defaultServerTemplate.id)
        let nodeBin = prefix.appendingPathComponent("node_modules/.bin", isDirectory: true)

        do {
            try fileSystem.createDirectory(at: prefix)
        } catch {
            return fileFailure(provider: provider, error: error)
        }

        let command = LSPInstallCommand(
            executable: "npm",
            arguments: ["install", "--prefix", prefix.path] + provider.installPackageIdentifiers
        )
        await report(commandEvent(command, progressMessage: "执行 npm 安装"))
        let result = await commandRunner.run(command)
        guard result.exitCode == 0 else {
            await report(commandFailureEvent(result, message: result.stderr))
            return commandFailure(provider: provider, result: result)
        }

        let wrapper = "#!/bin/zsh\nexport PATH=\"\(nodeBin.path):$PATH\"\nexec \"\(nodeBin.appendingPathComponent(provider.defaultServerTemplate.id).path)\" \"$@\"\n"

        do {
            try fileSystem.writeExecutableFile(at: managedExecutable, contents: wrapper)
        } catch {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: error.localizedDescription,
                logLevel: .error,
                failureMessage: error.localizedDescription
            ))
            return fileFailure(provider: provider, error: error)
        }

        let version = await probeVersion(executablePath: managedExecutable.path, commandRunner: commandRunner, report: report)
        return installedResult(provider: provider, executablePath: managedExecutable.path, version: version, message: "已完成 npm 安装")
    }

    private func installGoProvider(
        provider: LSPProviderDefinition,
        layout: LSPManagedInstallLayout,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        let gopath = layout.providerDirectory.appendingPathComponent("gopath", isDirectory: true)
        let managedExecutable = layout.binDirectory.appendingPathComponent(provider.defaultServerTemplate.id)

        do {
            try fileSystem.createDirectory(at: gopath)
        } catch {
            return fileFailure(provider: provider, error: error)
        }

        let command = LSPInstallCommand(
            executable: "go",
            arguments: ["install", provider.installPackageIdentifiers.first ?? provider.id],
            environment: [
                "GOBIN": layout.binDirectory.path,
                "GOPATH": gopath.path
            ]
        )
        await report(commandEvent(command, progressMessage: "执行 go install"))
        let result = await commandRunner.run(command)
        guard result.exitCode == 0 else {
            await report(commandFailureEvent(result, message: result.stderr))
            return commandFailure(provider: provider, result: result)
        }

        guard fileSystem.fileExists(at: managedExecutable) else {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: "安装完成但未在受管目录生成可执行文件",
                logLevel: .error,
                failureMessage: "安装完成但未在受管目录生成可执行文件"
            ))
            return LSPInstallResult(
                providerID: provider.id,
                status: .failed,
                message: "安装完成但未在受管目录生成可执行文件",
                recoverySuggestion: .recheckPath
            )
        }

        let version = await probeVersion(executablePath: managedExecutable.path, commandRunner: commandRunner, report: report)
        return installedResult(provider: provider, executablePath: managedExecutable.path, version: version, message: "已完成 go install")
    }

    private func installCargoProvider(
        provider: LSPProviderDefinition,
        layout: LSPManagedInstallLayout,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        let cargoRoot = layout.providerDirectory.appendingPathComponent("cargo-root", isDirectory: true)
        let installedExecutable = cargoRoot.appendingPathComponent("bin/\(provider.defaultServerTemplate.id)")
        let managedExecutable = layout.binDirectory.appendingPathComponent(provider.defaultServerTemplate.id)

        do {
            try fileSystem.createDirectory(at: cargoRoot)
        } catch {
            return fileFailure(provider: provider, error: error)
        }

        let command = LSPInstallCommand(
            executable: "cargo",
            arguments: ["install", "--locked", "--root", cargoRoot.path, provider.installPackageIdentifiers.first ?? provider.id]
        )
        await report(commandEvent(command, progressMessage: "执行 cargo install"))
        let result = await commandRunner.run(command)
        guard result.exitCode == 0 else {
            await report(commandFailureEvent(result, message: result.stderr))
            return commandFailure(provider: provider, result: result)
        }

        guard fileSystem.fileExists(at: installedExecutable) else {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: "cargo 安装完成但未生成目标可执行文件",
                logLevel: .error,
                failureMessage: "cargo 安装完成但未生成目标可执行文件"
            ))
            return LSPInstallResult(
                providerID: provider.id,
                status: .failed,
                message: "cargo 安装完成但未生成目标可执行文件",
                recoverySuggestion: .recheckPath
            )
        }

        do {
            try fileSystem.createOrReplaceSymlink(at: managedExecutable, destination: installedExecutable)
        } catch {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: error.localizedDescription,
                logLevel: .error,
                failureMessage: error.localizedDescription
            ))
            return fileFailure(provider: provider, error: error)
        }

        let version = await probeVersion(executablePath: managedExecutable.path, commandRunner: commandRunner, report: report)
        return installedResult(provider: provider, executablePath: managedExecutable.path, version: version, message: "已完成 cargo install")
    }

    private func installHomebrewProvider(
        provider: LSPProviderDefinition,
        layout: LSPManagedInstallLayout,
        commandRunner: LSPInstallCommandRunning,
        fileSystem: LSPInstallFileManaging,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> LSPInstallResult {
        let formula = provider.installPackageIdentifiers.first ?? provider.id
        let installCommand = LSPInstallCommand(executable: "brew", arguments: ["install", formula])
        await report(commandEvent(installCommand, progressMessage: "执行 brew install"))
        let installResult = await commandRunner.run(installCommand)
        guard installResult.exitCode == 0 else {
            await report(commandFailureEvent(installResult, message: installResult.stderr))
            return commandFailure(provider: provider, result: installResult)
        }

        let prefixCommand = LSPInstallCommand(executable: "brew", arguments: ["--prefix", formula])
        await report(commandEvent(prefixCommand, progressMessage: "解析 brew 安装前缀"))
        let prefixResult = await commandRunner.run(prefixCommand)
        guard prefixResult.exitCode == 0 else {
            await report(commandFailureEvent(prefixResult, message: prefixResult.stderr))
            return commandFailure(provider: provider, result: prefixResult)
        }

        let prefixPath = prefixResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let installedExecutable = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent("bin/\(provider.defaultServerTemplate.id)")
        let managedExecutable = layout.binDirectory.appendingPathComponent(provider.defaultServerTemplate.id)

        guard fileSystem.fileExists(at: installedExecutable) else {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: "brew 安装完成但未找到目标可执行文件",
                logLevel: .error,
                failureMessage: "brew 安装完成但未找到目标可执行文件"
            ))
            return LSPInstallResult(
                providerID: provider.id,
                status: .failed,
                message: "brew 安装完成但未找到目标可执行文件",
                recoverySuggestion: .recheckPath
            )
        }

        do {
            try fileSystem.createOrReplaceSymlink(at: managedExecutable, destination: installedExecutable)
        } catch {
            await report(LSPInstallActivityEvent(
                phase: .failed,
                progressMessage: "安装失败",
                logMessage: error.localizedDescription,
                logLevel: .error,
                failureMessage: error.localizedDescription
            ))
            return fileFailure(provider: provider, error: error)
        }

        let version = await probeVersion(executablePath: managedExecutable.path, commandRunner: commandRunner, report: report)
        return installedResult(provider: provider, executablePath: managedExecutable.path, version: version, message: "已完成 brew 安装")
    }

    private func installedResult(provider: LSPProviderDefinition, executablePath: String, version: String?, message: String) -> LSPInstallResult {
        let definition = provider.defaultServerTemplate.replacingLaunchCommand(executablePath)
        return LSPInstallResult(
            providerID: provider.id,
            status: .installed,
            message: message,
            recoverySuggestion: .none,
            executablePath: executablePath,
            installedDefinition: definition,
            installedProviderRecord: LSPInstalledProviderRecord(
                providerID: provider.id,
                executablePath: executablePath,
                version: version,
                installedAt: Date()
            )
        )
    }

    private func commandFailure(provider: LSPProviderDefinition, result: LSPInstallCommandResult) -> LSPInstallResult {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return LSPInstallResult(
            providerID: provider.id,
            status: .failed,
            message: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "安装命令执行失败" : detail.trimmingCharacters(in: .whitespacesAndNewlines),
            recoverySuggestion: .installCommand
        )
    }

    private func fileFailure(provider: LSPProviderDefinition, error: Error) -> LSPInstallResult {
        LSPInstallResult(
            providerID: provider.id,
            status: .failed,
            message: "无法准备受管安装目录：\(error.localizedDescription)",
            recoverySuggestion: .configureManually
        )
    }

    private func probeVersion(
        executablePath: String,
        commandRunner: LSPInstallCommandRunning,
        report: @Sendable (LSPInstallActivityEvent) async -> Void
    ) async -> String? {
        await report(LSPInstallActivityEvent(phase: .probingVersion, progressMessage: "探测版本"))

        let attempts = [["--version"], ["version"], ["-version"]]
        for arguments in attempts {
            let command = LSPInstallCommand(executable: executablePath, arguments: arguments)
            await report(commandEvent(command, progressMessage: "探测版本"))
            let result = await commandRunner.run(command)
            let output = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if result.exitCode == 0, let output {
                let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
                await report(LSPInstallActivityEvent(logMessage: normalized, detectedVersion: normalized))
                return normalized
            }
        }

        await report(LSPInstallActivityEvent(logMessage: "未检测到版本信息"))
        return nil
    }

    private func commandEvent(_ command: LSPInstallCommand, progressMessage: String) -> LSPInstallActivityEvent {
        LSPInstallActivityEvent(
            phase: .installing,
            progressMessage: progressMessage,
            logMessage: "执行命令: \(command.executable) \(command.arguments.joined(separator: " "))"
        )
    }

    private func commandFailureEvent(_ result: LSPInstallCommandResult, message: String) -> LSPInstallActivityEvent {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return LSPInstallActivityEvent(
            phase: .failed,
            progressMessage: "安装失败",
            logMessage: normalized.isEmpty ? "安装命令执行失败" : normalized,
            logLevel: .error,
            failureMessage: normalized.isEmpty ? "安装命令执行失败" : normalized
        )
    }
}

struct LiveLSPInstallCommandRunner: LSPInstallCommandRunning {
    func run(_ command: LSPInstallCommand) async -> LSPInstallCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let mergedEnvironment = LSPProcessEnvironmentResolver.resolvedEnvironment().merging(command.environment) { _, new in new }
                let executableURL = LSPProcessEnvironmentResolver.resolveExecutableURL(
                    command: command.executable,
                    environment: mergedEnvironment
                ) ?? URL(fileURLWithPath: command.executable)

                let process = Process()
                process.executableURL = executableURL
                process.arguments = command.arguments
                process.environment = mergedEnvironment
                if let workingDirectory = command.workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: LSPInstallCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(returning: LSPInstallCommandResult(exitCode: 1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }
}

final class LiveLSPInstallFileSystem: LSPInstallFileManaging {
    private let fileManager = FileManager.default

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeExecutableFile(at url: URL, contents: String) throws {
        let data = Data(contents.utf8)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        fileManager.createFile(atPath: url.path, contents: data)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func createOrReplaceSymlink(at url: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

private struct LSPManagedInstallLayout {
    let installRoot: URL
    let providerID: String

    var binDirectory: URL {
        installRoot.appendingPathComponent("bin", isDirectory: true)
    }

    var providerDirectory: URL {
        installRoot.appendingPathComponent("providers/\(providerID)", isDirectory: true)
    }
}
import Foundation

struct ACPProviderValidationService: Sendable {
    typealias ExecutableResolver = @Sendable (String) -> URL?
    typealias RuntimeFactory = @Sendable (ACPExternalAgentLaunchConfiguration) throws -> any ACPProviderValidationRuntime

    private let initializeTimeoutNanoseconds: UInt64
    private let workingDirectoryURL: URL
    private let executableResolver: ExecutableResolver
    private let runtimeFactory: RuntimeFactory

    init(
        initializeTimeoutNanoseconds: UInt64 = 15_000_000_000,
        workingDirectoryURL: URL = FileManager.default.temporaryDirectory,
        executableResolver: @escaping ExecutableResolver = {
            ShellEnvironmentResolver.resolveExecutableURL(command: $0)
        },
        runtimeFactory: @escaping RuntimeFactory = { configuration in
            try LiveACPProviderValidationRuntime(configuration: configuration)
        }
    ) {
        self.initializeTimeoutNanoseconds = initializeTimeoutNanoseconds
        self.workingDirectoryURL = workingDirectoryURL
        self.executableResolver = executableResolver
        self.runtimeFactory = runtimeFactory
    }

    func validate(
        displayName: String,
        executablePath: String,
        arguments: [String]
    ) async -> ACPProviderValidationResult {
        guard let resolvedExecutableURL = executableResolver(executablePath) else {
            return .missingExecutable("未找到 \(displayName) 可执行文件：\(executablePath)")
        }

        let runtime: any ACPProviderValidationRuntime
        do {
            runtime = try runtimeFactory(
                ACPExternalAgentLaunchConfiguration(
                    command: resolvedExecutableURL.path,
                    arguments: arguments,
                    currentDirectoryURL: workingDirectoryURL
                )
            )
        } catch {
            return .initializeFailed(Self.describe(error))
        }

        do {
            let response = try await initializeWithTimeout(runtime: runtime)
            await runtime.close()
            return .ready(
                ACPExternalAgentRuntimeClient.makeValidationSnapshot(
                    from: response,
                    resolvedExecutablePath: resolvedExecutableURL.path,
                    verifiedAt: Date()
                )
            )
        } catch {
            await runtime.close()
            return .initializeFailed(Self.describe(error))
        }
    }

    private func initializeWithTimeout(
        runtime: any ACPProviderValidationRuntime
    ) async throws -> ACPInitializeResponse {
        let request = ACPExternalAgentRuntimeClient.makeInitializeRequest()
        let initializeTask = Task {
            try await runtime.initialize(request)
        }

        defer { initializeTask.cancel() }

        return try await withThrowingTaskGroup(of: ACPInitializeResponse.self) { group in
            group.addTask {
                try await initializeTask.value
            }
            group.addTask { [initializeTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: initializeTimeoutNanoseconds)
                throw ACPExternalAgentRuntimeError.initializeTimedOut
            }

            guard let response = try await group.next() else {
                throw ACPRequestError.internalError(data: .object(["reason": .string("Missing initialize response")]))
            }

            group.cancelAll()
            return response
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

private actor LiveACPProviderValidationRuntime: ACPProviderValidationRuntime {
    private let managedRuntime: ACPManagedClientRuntime

    init(configuration: ACPExternalAgentLaunchConfiguration) throws {
        self.managedRuntime = try ACPManagedClientRuntime.launch(
            command: configuration.command,
            arguments: configuration.arguments,
            environmentOverrides: configuration.environmentOverrides,
            currentDirectoryURL: configuration.currentDirectoryURL
        )
    }

    func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        try await managedRuntime.runtime.initialize(request)
    }

    func close() async {
        await managedRuntime.close()
    }
}
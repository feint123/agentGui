import Foundation

nonisolated final class ACPManagedClientRuntime {
    let runtime: ACPClientRuntime

    private let supervisor: ACPProcessSupervisor

    private init(runtime: ACPClientRuntime, supervisor: ACPProcessSupervisor) {
        self.runtime = runtime
        self.supervisor = supervisor
    }

    var isRunning: Bool {
        supervisor.process?.isRunning ?? false
    }

    var processIdentifier: Int32? {
        supervisor.process?.processIdentifier
    }

    static func launch(
        command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        clientHandler: (any ACPClientHandler)? = nil,
        standardErrorHandler: ((String) -> Void)? = nil,
        streamObserver: ACPConnection.StreamObserver? = nil,
        errorObserver: ACPConnection.ErrorObserver? = nil
    ) throws -> ACPManagedClientRuntime {
        let supervisor = ACPProcessSupervisor()
        let transport = try supervisor.start(
            command: command,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: currentDirectoryURL,
            standardErrorHandler: standardErrorHandler
        )
        let router = clientHandler.map(ACPMessageRouter.clientRouter) ?? ACPMessageRouter()
        let connection = ACPConnection(
            transport: transport,
            router: router,
            observers: streamObserver.map { [$0] } ?? [],
            errorObservers: errorObserver.map { [$0] } ?? []
        )
        let runtime = ACPClientRuntime(connection: connection)
        return ACPManagedClientRuntime(runtime: runtime, supervisor: supervisor)
    }

    static func launchLocal(
        command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        authorizationPolicy: ToolAuthorizationPolicy,
        allowedRoots: [URL] = [],
        terminalRuntimeProvider: @escaping @Sendable (String) -> TerminalTaskRuntime,
        permissionResolver: (@Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)? = nil,
        standardErrorHandler: ((String) -> Void)? = nil,
        streamObserver: ACPConnection.StreamObserver? = nil,
        errorObserver: ACPConnection.ErrorObserver? = nil
    ) throws -> ACPManagedClientRuntime {
        let normalizedRoots = normalizeAllowedRoots(primary: currentDirectoryURL, additional: allowedRoots)
        let localHandler = ACPLocalClientHandler(
            authorizationPolicy: authorizationPolicy,
            allowedRoots: normalizedRoots,
            terminalRuntimeProvider: terminalRuntimeProvider,
            permissionResolver: permissionResolver
        )

        return try launch(
            command: command,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: currentDirectoryURL,
            clientHandler: localHandler,
            standardErrorHandler: standardErrorHandler,
            streamObserver: streamObserver,
            errorObserver: errorObserver
        )
    }

    func close() async {
        await runtime.close()
        supervisor.stop()
    }

    deinit {
        supervisor.stop()
    }

    private static func normalizeAllowedRoots(primary: URL?, additional: [URL]) -> [URL] {
        var seen: Set<String> = []
        var normalized: [URL] = []

        for candidate in ([primary].compactMap { $0 } + additional).map(\.standardizedFileURL) {
            if seen.insert(candidate.path).inserted {
                normalized.append(candidate)
            }
        }

        return normalized
    }
}

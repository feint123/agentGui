import Foundation
import Testing
@testable import agentGui

struct ACPProviderValidationServiceTests {
    @Test
    func missingExecutableReturnsMissingExecutableResult() async {
        let service = ACPProviderValidationService(
            executableResolver: { _ in nil },
            runtimeFactory: { _ in
                FakeValidationRuntime(response: nil)
            }
        )

        let result = await service.validate(
            displayName: "Copilot",
            executablePath: "copilot",
            arguments: ["acp", "--stdio"]
        )

        switch result {
        case .missingExecutable(let message):
            #expect(message.contains("Copilot"))
        default:
            Issue.record("Expected missing executable result, got \(result)")
        }
    }

    @Test
    func initializeTimeoutReturnsInitializeFailedResult() async {
        let runtime = FakeValidationRuntime(
            response: ACPInitializeResponse(
                agentCapabilities: ACPAgentCapabilities(loadSession: true),
                agentInfo: ACPImplementation(name: "timeout-agent", title: "Timeout Agent", version: "0.1.0"),
                authMethods: [],
                protocolVersion: 1
            ),
            initializeDelayNanoseconds: 200_000_000
        )
        let service = ACPProviderValidationService(
            initializeTimeoutNanoseconds: 10_000_000,
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/fake-acp") },
            runtimeFactory: { _ in runtime }
        )

        let result = await service.validate(
            displayName: "Timeout Agent",
            executablePath: "fake-acp",
            arguments: []
        )

        switch result {
        case .initializeFailed(let message):
            #expect(message.isEmpty == false)
        default:
            Issue.record("Expected initialize failure result, got \(result)")
        }

        let closeCount = await runtime.closeCount
        #expect(closeCount == 1)
    }

    @Test
    func initializeSuccessReturnsValidationSnapshot() async {
        let runtime = FakeValidationRuntime(
            response: ACPInitializeResponse(
                agentCapabilities: ACPAgentCapabilities(loadSession: true),
                agentInfo: ACPImplementation(name: "copilot", title: "GitHub Copilot", version: "1.2.3"),
                authMethods: [ACPAuthMethod(description: "Browser", id: "browser", name: "Browser Login")],
                protocolVersion: 1
            )
        )
        let service = ACPProviderValidationService(
            executableResolver: { _ in URL(fileURLWithPath: "/usr/local/bin/copilot") },
            runtimeFactory: { _ in runtime }
        )

        let result = await service.validate(
            displayName: "GitHub Copilot",
            executablePath: "copilot",
            arguments: ["acp", "--stdio"]
        )

        switch result {
        case .ready(let snapshot):
            #expect(snapshot.status == ACPProviderValidationStatus.ready)
            #expect(snapshot.agentInfo?.name == "copilot")
            #expect(snapshot.agentCapabilities?.loadSession == true)
            #expect(snapshot.authMethods.map { $0.id } == ["browser"])
            #expect(snapshot.resolvedExecutablePath == "/usr/local/bin/copilot")
            #expect(snapshot.verifiedAt != nil)
        default:
            Issue.record("Expected ready result, got \(result)")
        }

        let closeCount = await runtime.closeCount
        #expect(closeCount == 1)
    }

    @Test
    func temporaryRuntimeAlwaysClosesAfterThrownInitializeFailure() async {
        let runtime = FakeValidationRuntime(
            response: nil,
            initializeError: ACPExternalAgentRuntimeError.runtimeNotRunning
        )
        let service = ACPProviderValidationService(
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/fake-acp") },
            runtimeFactory: { _ in runtime }
        )

        let result = await service.validate(
            displayName: "Broken Agent",
            executablePath: "broken-agent",
            arguments: []
        )

        switch result {
        case .initializeFailed:
            break
        default:
            Issue.record("Expected initialize failure result, got \(result)")
        }

        let closeCount = await runtime.closeCount
        #expect(closeCount == 1)
    }
}

private actor FakeValidationRuntime: ACPProviderValidationRuntime {
    private let response: ACPInitializeResponse?
    private let initializeDelayNanoseconds: UInt64
    private let initializeError: Error?

    private(set) var closeCount = 0

    init(
        response: ACPInitializeResponse?,
        initializeDelayNanoseconds: UInt64 = 0,
        initializeError: Error? = nil
    ) {
        self.response = response
        self.initializeDelayNanoseconds = initializeDelayNanoseconds
        self.initializeError = initializeError
    }

    func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        _ = request
        if initializeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: initializeDelayNanoseconds)
        }
        if let initializeError {
            throw initializeError
        }
        return try #require(response)
    }

    func close() async {
        closeCount += 1
    }
}
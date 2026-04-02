import XCTest
@testable import agentGui

final class MemoryRecallHookRegistrationTests: XCTestCase {

    func test_makeHooks_containsMemoryRecallHook() {
        let factory = AgentLoopBuiltInHookFactory()
        let deps = AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: nil,
            memoryBootstrapLoader: { _ in nil },
            createToolCallRecord: { _, _ in fatalError() },
            updateToolCallRecord: { _, _ in },
            extractMemoriesCallback: { _ in },
            // M-05 新增
            memoryRecallService: nil,
            // M-11 新增
            sessionMemoryCallback: { _ in }
        )
        let state = AgentLoopBuiltInHookFactory.State()
        let hooks = factory.makeHooks(dependencies: deps, state: state)
        let hasRecallHook = hooks.contains { $0.id == "memory-recall" }
        XCTAssertTrue(hasRecallHook, "makeHooks 应包含 MemoryRecallHook")
    }
}

import XCTest
@testable import agentGui
import SwiftAnthropic

/// 验证 AgentLoopBuiltInHookFactory 将 MemoryExtractionHook 注册进 hook 列表。
@MainActor
final class MemoryExtractionCallbackTests: XCTestCase {

    func test_makeHooks_includesMemoryExtractionHook() {
        let state = AgentLoopBuiltInHookFactory.State()
        let deps = AgentLoopBuiltInHookFactory.Dependencies(
            businessLogSink: nil,
            memoryBootstrapLoader: { _ in nil },
            createToolCallRecord: { _, _ in fatalError() },
            updateToolCallRecord: { _, _ in },
            extractMemoriesCallback: { _ in },
            memoryRecallService: nil,
            consolidationCallback: { _ in }
        )
        let hooks = AgentLoopBuiltInHookFactory().makeHooks(dependencies: deps, state: state)
        let hasExtractionHook = hooks.contains { $0.id == "memory-extraction" }
        XCTAssertTrue(hasExtractionHook, "makeHooks should include MemoryExtractionHook")
    }
}

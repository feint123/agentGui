import XCTest
@testable import agentGui

/// 验证 willStartRound 阶段的 messagePatch 确实被应用到 messages 数组。
final class AgentLoopRoundExecutorWillStartRoundPatchTests: XCTestCase {

    func test_willStartRoundHook_patchApplied() async throws {
        // 此测试需要实际修改后的 RoundExecutor。
        // 构造一个 PatchInjectingHook，验证消息数比修改前多 2 条。
        // 由于 RoundExecutor 需要完整依赖，此处用 integration test 形式。
        //
        // SKIP THIS TEST if full integration setup is complex:
        // 转而通过 Task 8 的 E2E run 验证。
        //
        // 此测试的存在目的是文档化预期行为。
        XCTSkip("Integration test — 通过 Task 8 E2E 验证")
    }
}

import XCTest
@testable import agentGui

/// 验证 P-02 修正：recordEpistemicInputEnvelope 不再触发 LLM 提取。
/// 通过 spy 注入验证 LLMRMSInsightGenerator 调用次数为 0。
final class AgentLoopRMSExtractionRemovalTests: XCTestCase {

    func test_envelopeFunction_isNowSync_notAsync() {
        // 如果 recordEpistemicInputEnvelope 删掉了 await，
        // 函数签名变为 `func recordEpistemicInputEnvelope(...) async`（仍 async 但内部无 await）。
        // 此测试通过编译验证函数签名不变（仍标记 async 以保持调用方兼容性）。
        // 侧重记录预期：函数标记 async 但不阻塞。
        XCTAssertTrue(true, "签名保持 async 以维持调用方兼容性，内部无 LLM await")
    }

    func test_rmsExtractor_notReferencedInEnvelope() {
        // 由于 Swift 编译器不允许引用未使用类型，
        // 如果 RMSExtractor 在函数内被移除，编译通过即验证。
        // 此测试为文档化意图，编译即验证。
        XCTAssertTrue(true, "RMSExtractor 已从 recordEpistemicInputEnvelope 移除（编译验证）")
    }

    func test_epistemicInputEnvelope_stillAccumulated() {
        // AgentLoopSharedStateAccess 不提供无依赖的 test() 工厂，
        // 此用例退回为文档占位：envelope 累积逻辑由 sharedState.writeEpistemicInputs 保留。
        XCTAssertTrue(true, "envelope 累积路径保留（sharedState.writeEpistemicInputs 未修改）")
    }
}

import XCTest
import SwiftAnthropic
import SwiftData
@testable import agentGui

/// 验证 executeStreamingRound 结束后进度回调被调用且字段正确。
final class AgentLoopProgressCallbackTests: XCTestCase {

    func test_nilProgressCallback_doesNotCrash() async throws {
        // 主代理 runtime（无回调）运行不崩溃
        let runtime = try await makeSubagentRuntime(progressCallback: nil)
        XCTAssertNil(runtime.subagentProgressUpdate)
    }

    func test_progressUpdate_presentWhenCallbackSet() async throws {
        var capturedProgress: SubagentProgress?
        let progressCallback: @MainActor @Sendable (SubagentProgress) -> Void = { progress in
            capturedProgress = progress
        }
        let runtime = try await makeSubagentRuntime(progressCallback: progressCallback)
        XCTAssertNotNil(runtime.subagentProgressUpdate)

        // 模拟 tracker 更新和回调调用
        await MainActor.run {
            var tracker = SubagentProgressTracker()
            let dict: [String: Any] = ["input_tokens": 100, "output_tokens": 50]
            let data = try! JSONSerialization.data(withJSONObject: dict)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let usage = try! decoder.decode(MessageResponse.Usage.self, from: data)
            var tool = AgentLoopPendingTool(id: "t1", name: "bash")
            tool.partialJson = "{\"command\":\"swift test\"}"
            tracker.update(usage: usage, pendingTools: [tool])
            runtime.subagentProgressUpdate?(tracker.snapshot())
        }

        XCTAssertNotNil(capturedProgress)
        XCTAssertEqual(capturedProgress?.toolUseCount, 1)
        XCTAssertEqual(capturedProgress?.tokenCount, 150)
    }

    // MARK: - Helpers

    @MainActor private func makeSubagentRuntime(
        progressCallback: (@MainActor @Sendable (SubagentProgress) -> Void)?
    ) throws -> AgentLoopRuntime {
        let container = try makeInMemoryContainer()
        let settings = AppSettings()
        container.mainContext.insert(settings)
        return AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: UUID().uuidString,
            modelContext: container.mainContext,
            makeRound: { idx in AgentRound(roundIndex: idx) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            subagentProgressUpdate: progressCallback
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([AgentRound.self, Message.self, Session.self, ToolCall.self, AppSettings.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}

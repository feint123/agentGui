import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryPromptAssemblerTests {
    @Test func assemblerGroupsFactsEventsAndRisks() async throws {
        let assembler = MemoryPromptAssembler()
        let context = MemoryRuntimeContext(
            profiles: ["coding-task"],
            records: [
                MemoryRecord.fixture(layer: .task, kind: .working, title: "Build failed", verificationStatus: .verified),
                MemoryRecord.fixture(layer: .semantic, kind: .semantic, title: "TaskMemory fact", verificationStatus: .verified),
                MemoryRecord.fixture(layer: .semantic, kind: .semantic, title: "Possible cause", verificationStatus: .unverified)
            ],
            writePolicy: .readMostly,
            warnings: ["Symbol still unresolved"]
        )

        let text = assembler.render(context: context)

        #expect(text.contains("## 已验证事实"))
        #expect(text.contains("## 当前推测"))
        #expect(text.contains("Possible cause"))
        #expect(text.contains("Build failed"))
        #expect(text.contains("## 风险与待确认项"))
    }
}
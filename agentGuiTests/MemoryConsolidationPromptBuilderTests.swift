import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationPromptBuilderTests {

    private let builder = MemoryConsolidationPromptBuilder()

    @Test func promptContainsFourPhases() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp/memory"),
            sessionIds: ["aaa", "bbb"],
            sessionCount: 2
        )
        #expect(prompt.contains("Phase 1"))
        #expect(prompt.contains("Phase 2"))
        #expect(prompt.contains("Phase 3"))
        #expect(prompt.contains("Phase 4"))
    }

    @Test func promptContainsMemoryDirPath() {
        let memDir = URL(fileURLWithPath: "/Users/feint/.agentgui/memory")
        let prompt = builder.build(
            memoryDir: memDir,
            sessionIds: ["x"],
            sessionCount: 1
        )
        #expect(prompt.contains(memDir.path))
    }

    @Test func promptListsSessionIds() {
        let ids = ["session-abc", "session-def"]
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: ids,
            sessionCount: ids.count
        )
        for id in ids {
            #expect(prompt.contains(id))
        }
    }

    @Test func promptContainsMEMORYMDConstraint() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: [],
            sessionCount: 0
        )
        #expect(prompt.contains("MEMORY.md"))
        #expect(prompt.contains("200"))   // 行数上限
    }

    @Test func promptContainsToolConstraintNote() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: [],
            sessionCount: 0
        )
        // 工具约束：只允许读操作，不允许 bash 写入
        #expect(prompt.lowercased().contains("read-only") || prompt.lowercased().contains("只读"))
    }
}

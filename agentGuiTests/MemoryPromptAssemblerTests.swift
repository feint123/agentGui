import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryPromptAssemblerTests {
    @Test func assemblerRendersFrontiersCounterexamplesConstraintsAndDebt() async throws {
        let assembler = MemoryPromptAssembler()
        let context = MemoryRuntimeContext(
            profiles: ["coding-task"],
            records: [
                MemoryRecord.fixture(layer: .task, kind: .working, title: "Known failure", verificationStatus: .verified)
            ],
            writePolicy: .readMostly,
            warnings: [],
            epistemicState: EpistemicState(
                frontiers: [
                    FrontierMemory(
                        frontierId: "f-1",
                        goal: "Fix build",
                        openClaim: "Need to confirm shared scheme",
                        uncertaintyType: .tooling,
                        impactLevel: .high,
                        suggestedProbe: "Run xcodebuild -list",
                        stopCondition: "Scheme confirmed"
                    )
                ],
                activeConstraints: [
                    ConstraintMemory(id: "c-1", summary: "Inspect before editing", scope: .session(id: "s1"))
                ],
                verificationDebt: [
                    VerificationDebt(id: "d-1", claim: "Shared scheme exists", reason: "No direct evidence yet")
                ],
                counterexamples: [
                    CounterexampleMemory(
                        id: "ce-1",
                        summary: "Do not edit before checking scheme",
                        replacementAction: "Inspect build configuration first"
                    )
                ]
            )
        )

        let text = assembler.render(context: context)

        #expect(text.contains("## 未决前沿"))
        #expect(text.contains("Need to confirm shared scheme"))
        #expect(text.contains("## 激活反例"))
        #expect(text.contains("Do not edit before checking scheme"))
        #expect(text.contains("## 当前约束"))
        #expect(text.contains("Inspect before editing"))
        #expect(text.contains("## 验证债务"))
        #expect(text.contains("Shared scheme exists"))
        #expect(text.contains("## 支持性事实"))
    }

    @Test func assemblerGroupsFactsEventsAndRisks() async throws {
        let assembler = MemoryPromptAssembler()
        let context = MemoryRuntimeContext(
            profiles: ["coding-task"],
            records: [
                MemoryRecord.fixture(layer: .task, kind: .working, title: "Build failed", verificationStatus: .verified),
                MemoryRecord.fixture(layer: .semantic, kind: .semantic, title: "Verified repo fact", verificationStatus: .verified),
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

    @Test func budgetEnforcerTrimsLowestPrioritySectionsFirst() async throws {
        let assembler = MemoryPromptAssembler()
        let enforcer = MemoryPromptBudgetEnforcer()
        let context = MemoryRuntimeContext(
            profiles: ["coding-task"],
            records: [
                MemoryRecord.fixture(layer: .task, kind: .working, title: "Known failure", summary: String(repeating: "verified fact ", count: 8), verificationStatus: .verified),
                MemoryRecord.fixture(layer: .semantic, kind: .semantic, title: "Possible cause", summary: String(repeating: "speculative warning ", count: 8), verificationStatus: .unverified),
                MemoryRecord.fixture(layer: .episodic, kind: .episodic, title: "Past event", summary: String(repeating: "episodic trail ", count: 8), verificationStatus: .partial)
            ],
            warnings: [String(repeating: "user still needs confirmation ", count: 4)]
        )

        let sections = assembler.sections(for: context)
        let result = enforcer.enforce(sections: sections, budget: 160)

        #expect(result.renderedPrompt.contains("## 已验证事实"))
        #expect(result.trimmedSectionIDs.contains("speculative-records"))
        #expect(result.trimmedSectionIDs.contains("episodic-records"))
        #expect(result.postEnforcementPromptChars <= 160)
    }
}
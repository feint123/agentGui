import Foundation
import Testing
@testable import agentGui

@MainActor
struct RMSInsightGenerationTests {

    @Test func makeMemoryWriteInsightUsesInjectedGeneratorResult() async throws {
        let service = ClaudeService()
        let generator = StubRequiredInsightGenerator(
            insight: .counterexample(
                id: "memory-insight-1",
                summary: "Edit-first caused regression",
                appliesWhen: "xcodebuild smoke failure",
                changesDecision: "avoid repeating the remembered failure mode",
                replacementAction: "Inspect current state before acting",
                evidenceRefs: ["tool:memory_write"],
                scope: .user,
                confidence: 0.88
            )
        )

        let insight = try await service.makeMemoryWriteInsight(
            id: "memory-insight-1",
            content: "Edit-first caused regression. Inspect current state before acting.",
            normalizedTitle: "xcodebuild smoke failure",
            scope: .user,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generator: generator
        )

        #expect(insight.kind == .counterexample)
        #expect(insight.summary == "Edit-first caused regression")
        #expect(insight.appliesWhen == "xcodebuild smoke failure")
        #expect(insight.replacementAction == "Inspect current state before acting")
    }
}

private struct StubRequiredInsightGenerator: RMSInsightGenerating {
    var insight: RMSInsight

    func generateStateDelta(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        updatedAt: Date
    ) async throws -> RMSStateDelta? {
        _ = existing
        _ = envelope
        _ = updatedAt
        return nil
    }

    func generateRequiredInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight {
        _ = content
        var generated = insight
        generated.id = id
        generated.scope = scope
        generated.updatedAt = updatedAt
        if generated.appliesWhen.isEmpty {
            generated.appliesWhen = normalizedTitle
        }
        return generated
    }

    func generateOptionalInsight(
        id: String,
        content: String,
        envelope: EpistemicInputEnvelope,
        event: AtomicEpistemicEvent,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight? {
        _ = id
        _ = content
        _ = envelope
        _ = event
        _ = scope
        _ = updatedAt
        return nil
    }
}
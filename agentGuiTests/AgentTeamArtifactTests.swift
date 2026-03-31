import Foundation
import Testing
@testable import agentGui

struct AgentTeamArtifactTests {

    @Test
    func artifactRoundTripsThroughJSON() throws {
        let producerRef = ExecutionProviderReference.builtIn
        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let artifact = AgentTeamArtifact(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            kind: .implementationPlan,
            title: "修复方案草案",
            producer: producerRef,
            taskCardID: cardID,
            version: 1,
            summary: "包含三个子步骤的修复计划",
            payload: .text("## 修复步骤\n1. 修改 Actor\n2. 补充 tests\n3. 提交 PR"),
            status: .submitted
        )

        let data = try JSONEncoder().encode(artifact)
        let decoded = try JSONDecoder().decode(AgentTeamArtifact.self, from: data)

        #expect(decoded == artifact)
    }

    @Test
    func artifactBoardStateRoundTripsThroughJSON() throws {
        let cardID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let artifact = AgentTeamArtifact(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            kind: .patchProposal,
            title: "PR #42",
            producer: .builtIn,
            taskCardID: cardID,
            version: 2,
            summary: "新增 AgentTeamArtifact 类型",
            payload: .text("diff --git a/Models/AgentTeamArtifact.swift"),
            status: .accepted
        )
        let board = AgentTeamArtifactBoardState(artifacts: [artifact])

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(AgentTeamArtifactBoardState.self, from: data)

        #expect(decoded == board)
    }

    @Test
    func artifactBoardFiltersArtifactsByTaskCard() {
        let cardA = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let cardB = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let artifactForA = AgentTeamArtifact(
            id: UUID(), kind: .ideaDraft, title: "草案A",
            producer: .builtIn, taskCardID: cardA, version: 1,
            summary: "属于卡A", payload: .text("内容A"), status: .draft
        )
        let artifactForB = AgentTeamArtifact(
            id: UUID(), kind: .explorationReport, title: "报告B",
            producer: .builtIn, taskCardID: cardB, version: 1,
            summary: "属于卡B", payload: .text("内容B"), status: .draft
        )
        let board = AgentTeamArtifactBoardState(artifacts: [artifactForA, artifactForB])

        let resultA = board.artifacts(for: cardA)
        let resultB = board.artifacts(for: cardB)

        #expect(resultA.count == 1)
        #expect(resultA.first?.taskCardID == cardA)
        #expect(resultB.count == 1)
        #expect(resultB.first?.taskCardID == cardB)
    }

    @Test
    func artifactBoardFiltersArtifactsByProducer() {
        let cardID = UUID()
        let builtInArtifact = AgentTeamArtifact(
            id: UUID(), kind: .brief, title: "Brief",
            producer: .builtIn, taskCardID: cardID, version: 1,
            summary: "由 builtIn 产出", payload: .text("内容"), status: .submitted
        )
        let externalRef = ExecutionProviderReference.externalACP(
            profileID: LegacyExternalACPProviderKey.githubCopilotCLI.presetProfileID
        )
        let externalArtifact = AgentTeamArtifact(
            id: UUID(), kind: .validationReport, title: "Validation",
            producer: externalRef, taskCardID: cardID, version: 1,
            summary: "由外部 provider 产出", payload: .text("报告内容"), status: .draft
        )
        let board = AgentTeamArtifactBoardState(artifacts: [builtInArtifact, externalArtifact])

        #expect(board.artifacts(by: .builtIn).count == 1)
        #expect(board.artifacts(by: externalRef).count == 1)
    }

    @Test
    func artifactKindCoversAllFirstPhaseKinds() {
        let allKinds: [AgentTeamArtifactKind] = [
            .brief, .ideaDraft, .explorationReport, .implementationPlan,
            .patchProposal, .validationReport, .reviewReport, .finalSynthesis
        ]
        for kind in allKinds {
            let restored = AgentTeamArtifactKind(rawValue: kind.rawValue)
            #expect(restored == kind)
        }
    }

    @Test
    func artifactStatusCoversAllExpectedCases() {
        let allStatuses: [AgentTeamArtifactStatus] = [.draft, .submitted, .accepted, .rejected]
        for status in allStatuses {
            let restored = AgentTeamArtifactStatus(rawValue: status.rawValue)
            #expect(restored == status)
        }
    }
}

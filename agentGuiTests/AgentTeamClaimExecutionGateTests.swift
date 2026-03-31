import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentTeamClaimExecutionGateTests {
    @Test
    func localSessionDoesNotRequireTeamContext() throws {
        let gate = AgentTeamClaimExecutionGate()
        let session = Session.fixture(title: "普通会话")

        try gate.validate(
            session: session,
            state: nil,
            providerReference: .builtIn,
            teamContext: nil
        )
    }

    @Test
    func teamExecutionRejectsMissingContext() {
        let gate = AgentTeamClaimExecutionGate()
        let fixture = makeAcceptedBuiltInFixture()

        do {
            try gate.validate(
                session: fixture.session,
                state: fixture.state,
                providerReference: .builtIn,
                teamContext: nil
            )
            Issue.record("Expected missing team context to be rejected")
        } catch let error as AgentTeamClaimExecutionGate.Error {
            #expect(error == .missingTeamContext)
            #expect(error.localizedDescription.contains("缺少 claim 上下文"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func teamExecutionRejectsWrongOwner() {
        let gate = AgentTeamClaimExecutionGate()
        let fixture = makeAcceptedBuiltInFixture()
        let wrongProvider = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference

        do {
            try gate.validate(
                session: fixture.session,
                state: fixture.state,
                providerReference: wrongProvider,
                teamContext: fixture.context
            )
            Issue.record("Expected mismatched owner to be rejected")
        } catch let error as AgentTeamClaimExecutionGate.Error {
            #expect(
                error == .providerIsNotCurrentOwner(
                    taskCardID: fixture.cardID,
                    expected: .builtIn,
                    actual: wrongProvider
                )
            )
            #expect(error.localizedDescription.contains("不是 task card"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func teamExecutionRejectsNonAcceptedClaim() {
        let gate = AgentTeamClaimExecutionGate()
        let fixture = makeAcceptedBuiltInFixture()
        let staleClaimID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let staleClaim = AgentTeamClaim(
            id: staleClaimID,
            providerReference: .builtIn,
            taskCardID: fixture.cardID,
            confidence: 0.7,
            rationaleSummary: "过期 claim",
            requiredCapabilities: ["swift"],
            expectedArtifacts: ["patchProposal"],
            estimatedCostSummary: "medium",
            status: .pending,
            submittedAt: Date(timeIntervalSince1970: 2)
        )
        fixture.state.claimBoardState = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: fixture.cardID,
                    title: "修复主路径",
                    goal: "建立 claim gate",
                    phase: .claimed,
                    owner: .builtIn,
                    claimIDs: [fixture.claimID, staleClaimID]
                )
            ],
            claims: [fixture.acceptedClaim, staleClaim]
        )

        do {
            try gate.validate(
                session: fixture.session,
                state: fixture.state,
                providerReference: .builtIn,
                teamContext: AgentTeamExecutionContext(taskCardID: fixture.cardID, claimID: staleClaimID)
            )
            Issue.record("Expected stale claim to be rejected")
        } catch let error as AgentTeamClaimExecutionGate.Error {
            #expect(error == .claimNotAccepted(claimID: staleClaimID, acceptedClaimID: fixture.claimID))
            #expect(error.localizedDescription.contains("accepted claim"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func teamExecutionAcceptsAcceptedOwner() throws {
        let gate = AgentTeamClaimExecutionGate()
        let fixture = makeAcceptedBuiltInFixture()

        try gate.validate(
            session: fixture.session,
            state: fixture.state,
            providerReference: .builtIn,
            teamContext: fixture.context
        )
    }

    @Test
    func teamExecutionRejectsClaimMissingFromCardRegistration() {
        let gate = AgentTeamClaimExecutionGate()
        let fixture = makeAcceptedBuiltInFixture()
        fixture.state.claimBoardState = AgentTeamClaimBoardState(
            cards: [
                AgentTeamClaimCard(
                    id: fixture.cardID,
                    title: "修复主路径",
                    goal: "建立 claim gate",
                    phase: .claimed,
                    owner: .builtIn,
                    claimIDs: []
                )
            ],
            claims: [fixture.acceptedClaim]
        )

        do {
            try gate.validate(
                session: fixture.session,
                state: fixture.state,
                providerReference: .builtIn,
                teamContext: fixture.context
            )
            Issue.record("Expected unregistered claim to be rejected")
        } catch let error as AgentTeamClaimExecutionGate.Error {
            #expect(error == .claimNotRegisteredOnTaskCard(claimID: fixture.claimID, taskCardID: fixture.cardID))
            #expect(error.localizedDescription.contains("未注册到 task card"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func executionPayloadRoundTripsTeamContext() throws {
        let teamContext = AgentTeamExecutionContext(
            taskCardID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            claimID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let payload = ExecutionPayloadDraft.userPrompt(
            text: "执行主任务",
            modelID: "claude-3-7-sonnet",
            selectedFilePath: nil,
            selectedText: nil,
            directives: [],
            teamContext: teamContext
        )

        let decoded = try #require(ExecutionPayloadDraft(json: payload.encodedJSON))

        #expect(decoded.teamContext == teamContext)
    }
}

@MainActor
private func makeAcceptedBuiltInFixture() -> (
    session: Session,
    state: AgentTeamSessionState,
    context: AgentTeamExecutionContext,
    cardID: UUID,
    claimID: UUID,
    acceptedClaim: AgentTeamClaim
) {
    let session = Session.fixture(title: "修复 ACP", kind: .agentTeam)
    let state = AgentTeamSessionState(session: session)
    session.agentTeamState = state

    let cardID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let claimID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let acceptedClaim = AgentTeamClaim(
        id: claimID,
        providerReference: .builtIn,
        taskCardID: cardID,
        confidence: 0.95,
        rationaleSummary: "适合负责主执行路径",
        requiredCapabilities: ["swift"],
        expectedArtifacts: ["patchProposal"],
        estimatedCostSummary: "medium",
        status: .accepted,
        submittedAt: Date(timeIntervalSince1970: 1)
    )
    state.claimBoardState = AgentTeamClaimBoardState(
        cards: [
            AgentTeamClaimCard(
                id: cardID,
                title: "修复主路径",
                goal: "建立 claim gate",
                phase: .claimed,
                owner: .builtIn,
                claimIDs: [claimID]
            )
        ],
        claims: [acceptedClaim]
    )

    return (
        session: session,
        state: state,
        context: AgentTeamExecutionContext(taskCardID: cardID, claimID: claimID),
        cardID: cardID,
        claimID: claimID,
        acceptedClaim: acceptedClaim
    )
}
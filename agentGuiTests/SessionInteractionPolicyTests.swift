import Testing
@testable import agentGui

@MainActor
struct SessionInteractionPolicyTests {
    @Test func channelSessionsDisableComposerAndRename() {
        let session = Session.fixture(title: "Feishu")
        session.kind = .channel

        let policy = SessionInteractionPolicy(session: session)

        #expect(policy.canSend == false)
        #expect(policy.canRename == false)
        #expect(policy.canDelete == false)
        #expect(policy.readOnlyReason.isEmpty == false)
    }

    @Test func localSessionsRemainFullyEditable() {
        let session = Session.fixture(title: "Local")

        let policy = SessionInteractionPolicy(session: session)

        #expect(policy.canSend)
        #expect(policy.canRename)
        #expect(policy.canDelete)
        #expect(policy.readOnlyReason.isEmpty)
    }
}
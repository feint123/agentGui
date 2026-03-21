import Testing
@testable import agentGui

@MainActor
struct SessionKindTests {
    @Test func localSessionDefaultsToEditableKind() {
        let session = Session()

        #expect(session.kind == .local)
        #expect(session.isReadOnly == false)
        #expect(session.displaySourceTitle == "本地会话")
    }
}
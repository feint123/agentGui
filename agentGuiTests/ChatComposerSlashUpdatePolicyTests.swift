import Foundation
import Testing
@testable import agentGui

struct ChatComposerSlashUpdatePolicyTests {

    @Test func ignoresNonSlashInputWhenSlashStateIsInactive() {
        let action = ChatComposerSlashUpdatePolicy.action(for: "hello world", currentQuery: nil)

        #expect(action == .ignore)
    }

    @Test func clearsSlashStateWhenSlashTokenDisappears() {
        let action = ChatComposerSlashUpdatePolicy.action(for: "hello world", currentQuery: "plan")

        #expect(action == .clear)
    }

    @Test func ignoresUpdatesWhenSlashTokenIsUnchanged() {
        let action = ChatComposerSlashUpdatePolicy.action(for: "prefix /plan", currentQuery: "plan")

        #expect(action == .ignore)
    }

    @Test func debouncesWhenSlashTokenChanges() {
        let action = ChatComposerSlashUpdatePolicy.action(for: "/pla", currentQuery: "pl")

        guard case .debouncedSync(let detected) = action else {
            Issue.record("Expected a debounced sync action")
            return
        }

        #expect(detected.rawToken == "/pla")
        #expect(detected.query == "pla")
    }
}

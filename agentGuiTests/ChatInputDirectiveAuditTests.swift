import Foundation
import Testing
@testable import agentGui

struct ChatInputDirectiveAuditTests {

    @Test func appendsAuditTrailWhenDirectivesExist() async throws {
        let text = ChatInputDirectiveAudit.appendAuditTrail(
            to: "Implement this feature.",
            directives: [.skill(SkillInputDirective(directoryName: "brainstorming", displayName: "brainstorming"))]
        )

        #expect(text.contains("[Active directives] skill=brainstorming"))
    }

    @Test func leavesTextUntouchedWithoutDirectives() async throws {
        let text = ChatInputDirectiveAudit.appendAuditTrail(to: "Implement this feature.", directives: [])

        #expect(text == "Implement this feature.")
    }
}
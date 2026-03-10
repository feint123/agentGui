import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatInputCommandParserTests {

    @Test func detectsSlashQueryAtStartOfComposer() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "/brain")

        #expect(result?.rawToken == "/brain")
        #expect(result?.query == "brain")
    }

    @Test func detectsEmptySlashQuery() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "/")

        #expect(result?.rawToken == "/")
        #expect(result?.query == "")
    }

    @Test func detectsSlashQueryAfterWhitespace() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "help me /brain")

        #expect(result?.rawToken == "/brain")
        #expect(result?.query == "brain")
    }

    @Test func ignoresAbsolutePathLikeTokens() async throws {
        let result = ChatInputCommandParser.detectSlashQuery(in: "/Users/feint/project")

        #expect(result == nil)
    }

    @Test func buildsSkillDirectiveFromSelectedItem() async throws {
        let item = ChatSlashCommandItem(
            id: "skill:brainstorming",
            kind: .skill,
            title: "brainstorming",
            subtitle: "Use when exploring feature requirements.",
            aliases: ["brainstorming"],
            badge: "Skill",
            isEnabledByDefault: false,
            payload: .skill(directoryName: "brainstorming")
        )

        let directive = ChatInputCommandParser.makeDirective(from: item)

        #expect(directive == .skill(SkillInputDirective(directoryName: "brainstorming", displayName: "brainstorming")))
    }
}
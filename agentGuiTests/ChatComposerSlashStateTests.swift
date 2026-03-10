import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerSlashStateTests {

    @Test func updateFromSlashQueryOpensCandidates() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(directoryName: "brainstorming", name: "brainstorming", description: "Explore requirements."),
                        makeSkill(directoryName: "web-search", name: "web-search", description: "Search the web.")
                    ],
                    enabledSkillNames: []
                )
            ]
        )
        var state = ChatComposerSlashState()

        state.update(for: "/brain", registry: registry)

        #expect(state.query == "brain")
        #expect(state.candidates.count == 1)
        #expect(state.candidates.first?.title == "brainstorming")
        #expect(state.highlightedItemID == "skill:brainstorming")
    }

    @Test func moveSelectionCyclesWithinCandidates() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(directoryName: "brainstorming", name: "brainstorming", description: "Explore requirements."),
                        makeSkill(directoryName: "web-search", name: "web-search", description: "Search the web.")
                    ],
                    enabledSkillNames: []
                )
            ]
        )
        var state = ChatComposerSlashState()
        state.update(for: "/", registry: registry)

        state.moveSelection(delta: 1)
        #expect(state.highlightedItemID == "skill:web-search")

        state.moveSelection(delta: 1)
        #expect(state.highlightedItemID == "skill:brainstorming")
    }

    @Test func selectingHighlightedItemRemovesTokenAndCreatesDirective() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(directoryName: "brainstorming", name: "brainstorming", description: "Explore requirements.")
                    ],
                    enabledSkillNames: []
                )
            ]
        )
        var state = ChatComposerSlashState()
        state.update(for: "/brain", registry: registry)

        let result = state.selectHighlightedItem(in: "/brain fix this layout")

        #expect(result.updatedText == "fix this layout")
        #expect(result.directive == ChatInputDirective.skill(SkillInputDirective(directoryName: "brainstorming", displayName: "brainstorming")))
    }

    private func makeSkill(directoryName: String, name: String, description: String) -> Skill {
        Skill(
            directoryName: directoryName,
            name: name,
            description: description,
            path: URL(fileURLWithPath: "/tmp/\(directoryName)", isDirectory: true),
            contentURL: URL(fileURLWithPath: "/tmp/\(directoryName)/SKILL.md")
        )
    }
}
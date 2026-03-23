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

    @Test func selectingHighlightedACPCommandKeepsCommandTextAndDoesNotCreateDirective() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                ACPChatSlashCommandProvider(
                    commands: [
                        ACPCommandDescriptor(
                            providerID: .openCodeCLI,
                            remoteSessionID: "remote-1",
                            name: "plan",
                            description: "Create a plan",
                            inputHint: "what to plan"
                        )
                    ]
                )
            ]
        )
        var state = ChatComposerSlashState()
        state.update(for: "/pl", registry: registry)

        let result = state.selectHighlightedItem(in: "/pl")

        #expect(result.updatedText == "/plan ")
        #expect(result.directive == nil)
    }

    @Test func updateFromSlashQueryRetainsAllCandidatesInsteadOfTruncatingToEight() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                ACPChatSlashCommandProvider(
                    commands: (1...12).map { index in
                        ACPCommandDescriptor(
                            providerID: .openCodeCLI,
                            remoteSessionID: "remote-1",
                            name: "command-\(index)",
                            description: "Command \(index)"
                        )
                    }
                )
            ]
        )
        var state = ChatComposerSlashState()

        state.update(for: "/", registry: registry)

        #expect(state.candidates.count == 12)
        #expect(state.candidates.first?.title == "command-1")
        #expect(state.candidates.last?.title == "command-12")
    }

    @Test func moveSelectionCanReachCandidatesBeyondOriginalEightItemCap() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                ACPChatSlashCommandProvider(
                    commands: (1...12).map { index in
                        ACPCommandDescriptor(
                            providerID: .openCodeCLI,
                            remoteSessionID: "remote-1",
                            name: "command-\(index)",
                            description: "Command \(index)"
                        )
                    }
                )
            ]
        )
        var state = ChatComposerSlashState()

        state.update(for: "/", registry: registry)
        for _ in 0..<9 {
            state.moveSelection(delta: 1)
        }

        #expect(state.highlightedItemID == "acp:opencode_cli:command-10")
        #expect(state.selectedItem?.title == "command-10")
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
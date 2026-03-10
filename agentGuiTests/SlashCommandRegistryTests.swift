import Foundation
import Testing
@testable import agentGui

@MainActor
struct SlashCommandRegistryTests {

    @Test func skillProviderBuildsGenericSlashItems() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(
                            directoryName: "brainstorming",
                            name: "brainstorming",
                            description: "Use when exploring feature requirements."
                        )
                    ],
                    enabledSkillNames: []
                )
            ]
        )

        let items = registry.items(matching: "brain")

        #expect(items.count == 1)
        #expect(items.first?.kind == .skill)
        #expect(items.first?.title == "brainstorming")
        #expect(items.first?.subtitle == "Use when exploring feature requirements.")
        #expect(items.first?.badge == "Skill")
    }

    @Test func registryMatchesNameDirectoryAndDescription() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(
                            directoryName: "web-search",
                            name: "searching-web",
                            description: "Use when researching the internet."
                        )
                    ],
                    enabledSkillNames: []
                )
            ]
        )

        #expect(registry.items(matching: "searching").count == 1)
        #expect(registry.items(matching: "web-search").count == 1)
        #expect(registry.items(matching: "internet").count == 1)
    }

    @Test func enabledSkillsSortAheadOfDisabledSkills() async throws {
        let registry = ChatSlashCommandRegistry(
            providers: [
                SkillChatSlashCommandProvider(
                    skills: [
                        makeSkill(directoryName: "web-search", name: "web-search", description: "Search the web."),
                        makeSkill(directoryName: "brainstorming", name: "brainstorming", description: "Explore requirements.")
                    ],
                    enabledSkillNames: ["web-search"]
                )
            ]
        )

        let items = registry.items(matching: "")

        #expect(items.map { $0.title } == ["web-search", "brainstorming"])
        #expect(items.first?.isEnabledByDefault == true)
        #expect(items.last?.isEnabledByDefault == false)
    }

    @Test func skillServiceCanResolveSkillByDisplayNameOrDirectoryName() async throws {
        let service = SkillService()
        service.availableSkills = [
            makeSkill(directoryName: "brainstorming", name: "feature-brainstorming", description: "Explore requirements.")
        ]

        #expect(service.skill(namedOrDirectoryName: "brainstorming")?.directoryName == "brainstorming")
        #expect(service.skill(namedOrDirectoryName: "feature-brainstorming")?.name == "feature-brainstorming")
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
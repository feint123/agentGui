import Foundation
import Testing
@testable import agentGui

@MainActor
struct SlashCommandRequestAssemblyTests {

    @Test func explicitSkillDirectiveExtendsEffectiveSkillSetAndPrompt() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let skillDirectory = tempRoot.appendingPathComponent("brainstorming", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let contentURL = skillDirectory.appendingPathComponent("SKILL.md")
        try "# Brainstorming\nUse this skill for exploration.".write(to: contentURL, atomically: true, encoding: .utf8)

        let skill = Skill(
            directoryName: "brainstorming",
            name: "brainstorming",
            description: "Explore feature requirements.",
            path: skillDirectory,
            contentURL: contentURL
        )

        let skillService = SkillService()
        skillService.availableSkills = [skill]

        let service = ClaudeService()
        service.skillService = skillService

        let resolution = try service.resolveTurnSkillContextForTests(
            enabledSkillNames: [],
            directives: [.skill(SkillInputDirective(directoryName: "brainstorming", displayName: "brainstorming"))]
        )

        #expect(resolution.effectiveSkills.map(\.directoryName) == ["brainstorming"])
        #expect(resolution.explicitlyActivatedSkills.map(\.skill.directoryName) == ["brainstorming"])

        let settings = AppSettings()
        let prompt = service.makeSystemPromptForTests(
            skills: resolution.effectiveSkills,
            explicitlyActivatedSkills: resolution.explicitlyActivatedSkills,
            workingDirectory: "/tmp/project",
            settings: settings,
            session: nil
        )

        #expect(prompt.contains("## Explicitly Activated Skills For This Turn"))
        #expect(prompt.contains("brainstorming"))
        #expect(prompt.contains("Use this skill for exploration."))
    }

    @Test func missingExplicitSkillFailsBeforeSend() throws {
        let service = ClaudeService()
        service.skillService = SkillService()

        #expect(throws: ClaudeError.self) {
            try service.resolveTurnSkillContextForTests(
                enabledSkillNames: [],
                directives: [.skill(SkillInputDirective(directoryName: "missing-skill", displayName: "missing-skill"))]
            )
        }
    }
}
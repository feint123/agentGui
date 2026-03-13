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
        let runtimeContext = SystemPromptRuntimeContext(
            currentDateTimeText: "2026-03-13T10:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 26.0 (25A100)",
            hostName: "feint-macbook",
            workingDirectory: "/tmp/project",
            workingDirectorySource: "global default working directory",
            proxySummary: nil
        )
        let prompt = service.makeSystemPromptForTests(
            skills: resolution.effectiveSkills,
            explicitlyActivatedSkills: resolution.explicitlyActivatedSkills,
            workingDirectory: "/tmp/project",
            settings: settings,
            session: nil,
            runtimeContextOverride: runtimeContext
        )

        #expect(prompt.contains("## Runtime Environment"))
        #expect(prompt.contains("Current date/time: 2026-03-13T10:30:00+08:00"))
        #expect(prompt.contains("Time zone: Asia/Shanghai"))
        #expect(prompt.contains("Locale: zh_CN"))
        #expect(prompt.contains("Operating system: macOS 26.0 (25A100)"))
        #expect(prompt.contains("Host: feint-macbook"))
        #expect(prompt.contains("Working directory: /tmp/project (source: global default working directory)"))
        #expect(prompt.contains("## Explicitly Activated Skills For This Turn"))
        #expect(prompt.contains("brainstorming"))
        #expect(prompt.contains("Use this skill for exploration."))
    }

    @Test func systemPromptIncludesProxyAndSessionScopedRuntimeFacts() throws {
        let service = ClaudeService()
        let settings = AppSettings()
        settings.enableNetworkProxy = true
        settings.networkProxyURL = "http://127.0.0.1:7890"
        settings.networkProxyBypassList = "localhost, example.com"

        let session = Session(title: "Session")
        session.workingDirectory = "/workspace/feature"

        let prompt = service.makeSystemPromptForTests(
            skills: [],
            workingDirectory: session.workingDirectory,
            settings: settings,
            session: session,
            runtimeContextOverride: SystemPromptRuntimeContext(
                currentDateTimeText: "2026-03-13T11:00:00+08:00",
                timezoneIdentifier: "Asia/Shanghai",
                localeIdentifier: "zh_CN",
                operatingSystemText: "macOS 26.0 (25A100)",
                hostName: "feint-macbook",
                workingDirectory: "/workspace/feature",
                workingDirectorySource: "session-bound working directory",
                proxySummary: "enabled via http://127.0.0.1:7890; bypass: localhost, example.com"
            )
        )

        #expect(prompt.contains("Working directory: /workspace/feature (source: session-bound working directory)"))
        #expect(prompt.contains("Network proxy: enabled via http://127.0.0.1:7890; bypass: localhost, example.com"))
        #expect(prompt.contains("Reality constraints:"))
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
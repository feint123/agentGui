import Foundation
import Testing
@testable import agentGui

@MainActor
struct SkillServiceTests {
    @Test
    func loadSkillsReadsDirectoriesAsynchronously() async throws {
        let skillsDirectory = try makeSkillsDirectory(structure: [
            ("alpha-skill", "---\nname: Alpha\ndescription: First skill\n---\n# Alpha\n"),
            ("beta-skill", "---\nname: Beta\ndescription: Second skill\n---\n# Beta\n")
        ])

        let service = SkillService(skillsDirectory: skillsDirectory)

        await service.loadSkills()

        #expect(service.availableSkills.map(\.directoryName) == ["alpha-skill", "beta-skill"])
        #expect(service.availableSkills.map(\.name) == ["Alpha", "Beta"])
    }

    @Test
    func readSkillContentLoadsAndCachesResolvedContent() async throws {
        let skillsDirectory = try makeSkillsDirectory(structure: [
            (
                "alpha-skill",
                "---\nname: Alpha\ndescription: First skill\n---\nSee /references/guide.md\n"
            )
        ], extraFiles: [
            ("alpha-skill/references/guide.md", "guide")
        ])

        let service = SkillService(skillsDirectory: skillsDirectory)
        await service.loadSkills()

        let content = try #require(await service.readSkillContent(name: "alpha-skill"))
        let normalizedContent = normalizeTemporaryPathPrefixes(in: content)
        let skillDirectoryPath = skillsDirectory
            .appendingPathComponent("alpha-skill", isDirectory: true)
            .path
        let referencePath = skillsDirectory
            .appendingPathComponent("alpha-skill/references/guide.md")
            .path
        #expect(normalizedContent.contains(normalizeTemporaryPathPrefixes(in: "skill_directory: \(skillDirectoryPath)")))
        #expect(normalizedContent.contains(normalizeTemporaryPathPrefixes(in: referencePath)))

        let cachedContent = try #require(await service.readSkillContent(name: "Alpha"))
        #expect(cachedContent == content)
    }

    private func makeSkillsDirectory(
        structure: [(directory: String, content: String)],
        extraFiles: [(path: String, content: String)] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for item in structure {
            let directoryURL = root.appendingPathComponent(item.directory, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try item.content.write(
                to: directoryURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        for file in extraFiles {
            let fileURL = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return root
    }

    private func normalizeTemporaryPathPrefixes(in value: String) -> String {
        value.replacingOccurrences(of: "/private/var/", with: "/var/")
    }
}
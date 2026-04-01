import XCTest
@testable import agentGui

final class SkillManifestTests: XCTestCase {

    // MARK: - SkillExecutionContext

    func test_executionContext_rawValueRoundTrip() {
        XCTAssertEqual(SkillExecutionContext(rawValue: "inline"), .inline)
        XCTAssertEqual(SkillExecutionContext(rawValue: "fork"),   .fork)
        XCTAssertNil(SkillExecutionContext(rawValue: "unknown"))
    }

    func test_executionContext_default_isInline() {
        // Skill constructed without explicit context should default to .inline
        let skill = Skill.fixture()
        XCTAssertEqual(skill.executionContext, .inline)
    }

    // MARK: - SkillSource

    func test_skillSource_rawValueRoundTrip() {
        XCTAssertEqual(SkillSource(rawValue: "user"),    .user)
        XCTAssertEqual(SkillSource(rawValue: "project"), .project)
        XCTAssertEqual(SkillSource(rawValue: "managed"), .managed)
        XCTAssertEqual(SkillSource(rawValue: "bundled"), .bundled)
        XCTAssertNil(SkillSource(rawValue: "unknown"))
    }

    func test_skillSource_default_isUser() {
        let skill = Skill.fixture()
        XCTAssertEqual(skill.loadedFrom, .user)
    }

    // MARK: - EffortLevel

    func test_effortLevel_rawValueRoundTrip() {
        XCTAssertEqual(EffortLevel(rawValue: "low"),    .low)
        XCTAssertEqual(EffortLevel(rawValue: "medium"), .medium)
        XCTAssertEqual(EffortLevel(rawValue: "high"),   .high)
        XCTAssertEqual(EffortLevel(rawValue: "max"),    .max)
        XCTAssertNil(EffortLevel(rawValue: "critical"))
    }

    func test_effortLevel_default_isNil() {
        let skill = Skill.fixture()
        XCTAssertNil(skill.effort)
    }
}

// MARK: - Test Fixtures

private extension Skill {
    /// Minimal valid Skill for tests — uses default values for all new fields.
    static func fixture(
        directoryName: String = "test-skill",
        name: String = "Test Skill",
        description: String = "A test skill",
        path: URL = URL(fileURLWithPath: "/tmp/test-skill"),
        contentURL: URL = URL(fileURLWithPath: "/tmp/test-skill/SKILL.md")
    ) -> Skill {
        Skill(
            directoryName: directoryName,
            name: name,
            description: description,
            path: path,
            contentURL: contentURL
        )
    }
}

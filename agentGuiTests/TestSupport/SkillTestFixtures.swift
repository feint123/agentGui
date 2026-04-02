// agentGuiTests/TestSupport/SkillTestFixtures.swift
import Foundation
@testable import agentGui

extension Skill {
    /// Minimal valid Skill for unit tests. All fields default to safe values.
    static func fixture(
        directoryName: String = "test-skill",
        name: String = "Test Skill",
        description: String = "A test skill",
        whenToUse: String? = nil,
        argumentHint: String? = nil,
        argumentNames: [String] = [],
        allowedTools: [String] = [],
        model: String? = nil,
        effort: EffortLevel? = nil,
        executionContext: SkillExecutionContext = .inline,
        agent: String? = nil,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        version: String? = nil,
        paths: [String]? = nil,
        hasReferenceFiles: Bool = false,
        loadedFrom: SkillSource = .user,
        path: URL = URL(fileURLWithPath: "/tmp/test-skill"),
        contentURL: URL = URL(fileURLWithPath: "/tmp/test-skill/SKILL.md")
    ) -> Skill {
        Skill(
            directoryName: directoryName,
            name: name,
            description: description,
            path: path,
            contentURL: contentURL,
            whenToUse: whenToUse,
            argumentHint: argumentHint,
            argumentNames: argumentNames,
            allowedTools: allowedTools,
            model: model,
            effort: effort,
            executionContext: executionContext,
            agent: agent,
            userInvocable: userInvocable,
            disableModelInvocation: disableModelInvocation,
            version: version,
            paths: paths,
            hasReferenceFiles: hasReferenceFiles,
            loadedFrom: loadedFrom
        )
    }
}

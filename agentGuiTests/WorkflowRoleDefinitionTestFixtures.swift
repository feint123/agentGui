// agentGuiTests/WorkflowRoleDefinitionTestFixtures.swift
@testable import agentGui
import Foundation

extension WorkflowRoleDefinition {
    static func explorerFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "explore",
            displayName: "Explorer",
            description: "Explores codebase",
            systemPrompt: "You are an explorer.",
            enableTextEditor: true,
            enableBash: false,
            modelPreference: .haiku,
            background: false,
            omitMainContext: true,
            isOneShot: true
        )
    }

    static func verifierFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "verifier",
            displayName: "Verifier",
            description: "Verifies fixes",
            systemPrompt: "You are a verifier.",
            enableTextEditor: false,
            enableBash: true,
            modelPreference: .inherit,
            background: true,
            omitMainContext: false,
            criticalReminder: "CRITICAL: end with VERDICT: PASS, FAIL, or PARTIAL.",
            isOneShot: false
        )
    }

    static func workerFixture() -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "worker",
            displayName: "Worker",
            description: "Implements changes",
            systemPrompt: "You are a worker.",
            enableTextEditor: true,
            enableBash: true,
            modelPreference: .inherit,
            background: false,
            omitMainContext: false,
            isOneShot: false
        )
    }
}

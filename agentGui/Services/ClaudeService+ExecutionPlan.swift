//
//  ClaudeService+ExecutionPlan.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Create Execution Plan

    /// Parses the `create_execution_plan` tool call, persists the plan to `Session.planJson`,
    /// and returns a human-readable confirmation string.
    @discardableResult
    func executeCreateExecutionPlan(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let goal = input["goal"]?.stringValue else {
            return "Error: missing required parameter 'goal'"
        }
        guard let stepsValue = input["steps"] else {
            return "Error: missing required parameter 'steps'"
        }
        let anySteps = dynamicContentToAny(stepsValue)
        guard
            let stepsArray = anySteps as? [[String: Any]],
            let stepsData = try? JSONSerialization.data(withJSONObject: stepsArray),
            let parsedSteps = try? JSONDecoder().decode([PlanStep].self, from: stepsData)
        else {
            return "Error: failed to parse 'steps' array — each item must have 'id' (string) and 'title' (string)"
        }

        var assumptions: [String] = []
        if let assumptionsValue = input["assumptions"] {
            let anyAssumptions = dynamicContentToAny(assumptionsValue)
            if let arr = anyAssumptions as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                assumptions = decoded
            }
        }

        var successCriteria: [String] = []
        if let criteriaValue = input["success_criteria"] {
            let anyCriteria = dynamicContentToAny(criteriaValue)
            if let arr = anyCriteria as? [Any],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                successCriteria = decoded
            }
        }

        let plan = ExecutionPlan(
            goal: goal,
            steps: parsedSteps,
            assumptions: assumptions,
            successCriteria: successCriteria
        )

        // single source of truth shared with the workflow plan path.
        persistPlan(plan, sessionId: sessionId, modelContext: modelContext)

        let stepList = parsedSteps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)" }
            .joined(separator: "\n")
        return """
        Execution plan recorded.
        Goal: \(goal)
        Steps (\(parsedSteps.count)):
        \(stepList)
        Assumptions: \(assumptions.isEmpty ? "none" : assumptions.joined(separator: "; "))
        Success criteria: \(successCriteria.isEmpty ? "none" : successCriteria.joined(separator: "; "))
        """
    }

    /// Encodes `plan` as JSON and writes it to the matching `Session.planJson`.
    func persistPlan(_ plan: ExecutionPlan, sessionId: String, modelContext: ModelContext) {
        let store = SessionTaskStateStore(modelContext: modelContext)
        try? store.savePlan(plan, for: sessionId)
    }

    // MARK: - Verify Completion

    @discardableResult
    func executeVerifyCompletion(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext,
        claimAssessmentOverride: ExecutionClaimAssessment? = nil
    ) async -> String {
        let dynamicToStringArray: (MessageResponse.Content.DynamicContent) -> [String]? = { value in
            let any = self.dynamicContentToAny(value)
            guard let arr = any as? [Any],
                  let data = try? JSONSerialization.data(withJSONObject: arr),
                  let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return nil }
            return decoded
        }

        guard let verifiedValue = input["verified"],
              let verified = dynamicToStringArray(verifiedValue) else {
            return "Error: missing or invalid 'verified' parameter (expected array of strings)"
        }
        guard let notVerifiedValue = input["not_verified"],
              let notVerified = dynamicToStringArray(notVerifiedValue) else {
            return "Error: missing or invalid 'not_verified' parameter (expected array of strings)"
        }

        let conclusion = input["conclusion"]?.stringValue
        let verification = CompletionVerification(
            verified: verified,
            notVerified: notVerified,
            conclusion: conclusion
        )
        let store = SessionTaskStateStore(modelContext: modelContext)
        do {
            try store.saveVerification(verification, for: sessionId)
            sessionVerifications[sessionId] = verification
        } catch {
            return "Error: failed to persist verification"
        }

        var output = "Verification recorded.\n"
        output += "✅ Verified (\(verified.count)):\n"
        output += verified.map { "  - \($0)" }.joined(separator: "\n")
        let evidence = sessionExecutionEvidence[sessionId] ?? []
        let claimAssessment: ExecutionClaimAssessment?
        if let claimAssessmentOverride {
            claimAssessment = claimAssessmentOverride
        } else if evidence.isEmpty,
                  let service,
                  let assessment = await assessVerificationClaims(verified, service: service, modelId: currentModelId) {
            claimAssessment = assessment
        } else {
            claimAssessment = nil
        }
        if evidence.isEmpty, ExecutionGuard.shouldWarnForVerificationClaims(claimAssessment) {
            output += "\n⚠️ Warning: verification claims mention execution results, but there is no execution evidence recorded for this session."
        }
        if !notVerified.isEmpty {
            output += "\n⚠️ Not verified (\(notVerified.count)):\n"
            output += notVerified.map { "  - \($0)" }.joined(separator: "\n")
        }
        if let conclusion {
            output += "\nConclusion: \(conclusion)"
        }
        return output
    }
}

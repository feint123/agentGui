import Foundation
import SwiftAnthropic

struct ExecutionRequirement: Equatable, Sendable {
    let requiresExecution: Bool
    let confidence: Double
    let reason: String?

    nonisolated static var none: ExecutionRequirement {
        ExecutionRequirement(requiresExecution: false, confidence: 0, reason: nil)
    }

    nonisolated static let confidenceThreshold = 0.75

    nonisolated static func makePrompt(for userText: String) -> String {
        """
        Determine whether the user's latest request requires actual tool execution in the local environment as part of fulfilling the request.

        User request:
        \(userText)

        Respond ONLY with a valid JSON object in this exact schema:
        {
          "requiresExecution": <true|false>,
          "confidence": <number 0.0-1.0>,
          "rationale": <string>
        }

        Rules:
        - requiresExecution = true only when fulfilling the request correctly requires actually using a command or built-in tool in the environment.
        - Built-in tool execution includes actions such as editing files, fetching external content, writing memory/state, launching workflows or subagents, or other tool-mediated operations that do real work beyond pure explanation.
        - requiresExecution = false for explanation-only requests, planning, how-to guidance, code-only edits without execution, or analysis that does not require running anything.
        - confidence should be high only when the intent is explicit and unambiguous.
        - Return JSON only. No markdown fences.
        """
    }

    static func fromAssessment(_ assessment: ExecutionRequirementAssessment) -> ExecutionRequirement {
        let clampedConfidence = max(0, min(1, assessment.confidence))
        return ExecutionRequirement(
            requiresExecution: assessment.requiresExecution && clampedConfidence >= confidenceThreshold,
            confidence: clampedConfidence,
            reason: assessment.rationale
        )
    }

    static func parseAssessment(from text: String) -> ExecutionRequirementAssessment? {
        let cleaned = stripMarkdownFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutionRequirementAssessment.self, from: data)
    }

    static func parseClaimAssessment(from text: String) -> ExecutionClaimAssessment? {
        let cleaned = stripMarkdownFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutionClaimAssessment.self, from: data)
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newline)...])
            }
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExecutionRequirementAssessment: Codable, Equatable, Sendable {
    let requiresExecution: Bool
    let confidence: Double
    let rationale: String
}

struct ExecutionClaimAssessment: Codable, Equatable, Sendable {
    let claimsExecutionResults: Bool
    let confidence: Double
    let rationale: String
}

private let executionRequirementSystemPrompt = """
You are an intent classifier for an AI coding assistant. Your only job is to determine whether the user's request requires real tool execution in the environment. Output only strict JSON.
"""

private let executionClaimSystemPrompt = """
You are a classifier for completion-verification statements. Decide whether the provided verification items claim that a command, build, test, or runtime verification was actually executed. Output only strict JSON.
"""

extension ClaudeService {
    func assessExecutionRequirement(
        for userText: String,
        service: any AnthropicService,
        modelId: String
    ) async -> ExecutionRequirement {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let params = MessageParameter(
            model: .other(classifierModelId(preferredModelId: modelId)),
            messages: [
                .init(role: .user, content: .text(ExecutionRequirement.makePrompt(for: trimmed)))
            ],
            maxTokens: 256,
            system: makeEphemeralSystemPrompt(executionRequirementSystemPrompt)
        )

        do {
            let response = try await service.createMessage(params)
            guard let textContent = response.content.compactMap({ block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }).first,
            let assessment = ExecutionRequirement.parseAssessment(from: textContent) else {
                return .none
            }
            return ExecutionRequirement.fromAssessment(assessment)
        } catch {
            return .none
        }
    }

    private func classifierModelId(preferredModelId: String) -> String {
        preferredModelId.isEmpty ? "claude-haiku-4-5" : "claude-haiku-4-5"
    }

    func assessVerificationClaims(
        _ verified: [String],
        service: any AnthropicService,
        modelId: String
    ) async -> ExecutionClaimAssessment? {
        guard !verified.isEmpty else { return nil }
        let joined = verified.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        Determine whether these verification statements claim that an execution result was actually observed from a real command, build, test, or runtime check.

        Verification statements:
        \(joined)

        Respond ONLY with a valid JSON object in this exact schema:
        {
          "claimsExecutionResults": <true|false>,
          "confidence": <number 0.0-1.0>,
          "rationale": <string>
        }
        """

        let params = MessageParameter(
            model: .other(classifierModelId(preferredModelId: modelId)),
            messages: [.init(role: .user, content: .text(prompt))],
            maxTokens: 256,
            system: makeEphemeralSystemPrompt(executionClaimSystemPrompt)
        )

        do {
            let response = try await service.createMessage(params)
            guard let textContent = response.content.compactMap({ block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }).first else {
                return nil
            }
            return ExecutionRequirement.parseClaimAssessment(from: textContent)
        } catch {
            return nil
        }
    }
}

enum ExecutionEvidenceKind: String, Hashable {
    case bash
    case builtinTool
    case executorSubagent
    case workflow
}

enum ExecutionGuardDecision: Equatable {
    case allow
    case requestExecution(prompt: String)
    case fail(reason: String)
}

enum ExecutionGuard {
    static func resolveFinalization(
        requirement: ExecutionRequirement,
        evidenceKinds: Set<ExecutionEvidenceKind>,
        retryCount: Int
    ) -> ExecutionGuardDecision {
        guard requirement.requiresExecution else { return .allow }
        guard evidenceKinds.isEmpty else { return .allow }

        if retryCount == 0 {
            return .requestExecution(prompt: correctionPrompt)
        }

        return .fail(reason: "Execution required but no execution-capable tool was used before end_turn")
    }

    static func evidenceKind(
        toolName: String,
        input: MessageResponse.Content.Input,
        result: ToolExecutionResult
    ) -> ExecutionEvidenceKind? {
        switch toolName {
        case "bash":
            return .bash
        case "run_subagent":
            return input["agent_name"]?.stringValue == "executor" ? .executorSubagent : nil
        case "start_workflow":
            return result.isError ? nil : .workflow
        case _ where builtinExecutionToolNames.contains(toolName):
            return .builtinTool
        default:
            return nil
        }
    }

    static func shouldWarnForVerificationClaims(_ assessment: ExecutionClaimAssessment?) -> Bool {
        guard let assessment else { return false }
        let clampedConfidence = max(0, min(1, assessment.confidence))
        return assessment.claimsExecutionResults && clampedConfidence >= ExecutionRequirement.confidenceThreshold
    }

    private static let builtinExecutionToolNames: Set<String> = [
        "str_replace_based_edit_tool",
        "str_replace_editor",
        "web_search",
        "web_fetch",
        "ask_user_question",
        "analyze_image",
        "read_pdf",
        "memory_write",
        "story_memory_create_project",
        "story_memory_attach_project",
        "story_memory_upsert_character",
        "story_memory_upsert_chapter",
        "story_memory_upsert_scene",
        "story_memory_upsert_world_rule",
        "story_memory_upsert_location",
        "story_memory_upsert_foreshadow",
        "story_memory_upsert_style_profile",
        "story_memory_update_continuity_issue",
        "story_memory_append_event",
        "story_memory_query",
        "story_memory_verify_continuity"
    ]

    static let correctionPrompt = "You must actually execute the requested work using bash, a relevant built-in tool, the executor subagent, or start_workflow. Do not claim completion without a real tool call."
}
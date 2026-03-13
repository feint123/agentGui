import Foundation
import SwiftAnthropic

enum VerificationEvidenceSupport {
    nonisolated static let confidenceThreshold = 0.75
    nonisolated static let autoVerificationThreshold = 0.68

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

struct ExecutionClaimAssessment: Codable, Equatable, Sendable {
    let claimsExecutionResults: Bool
    let confidence: Double
    let rationale: String
}

struct AutoVerificationAssessment: Codable, Equatable, Sendable {
    let shouldAutoVerify: Bool
    let taskRequiresToolExecution: Bool
    let answerClaimsCompletion: Bool
    let confidence: Double
    let rationale: String
}

private let executionClaimSystemPrompt = """
You are a classifier for completion-verification statements. Decide whether the provided verification items claim that a command, build, test, or runtime verification was actually executed. Output only strict JSON.
"""

private let autoVerificationSystemPrompt = """
You are a classifier for deciding whether an agent run should automatically enter verification before finishing. Focus on whether the user's request required real tool-backed execution or an observable side effect, and whether the final answer claims that work is already done. Output only strict JSON.
"""

extension ClaudeService {
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
            return VerificationEvidenceSupport.parseClaimAssessment(from: textContent)
        } catch {
            return nil
        }
    }

    func assessAutoVerificationNeed(
        userRequest: String,
        currentAnswer: String,
        service: any AnthropicService,
        modelId: String
    ) async -> AutoVerificationAssessment? {
        guard ExecutionGuard.mayRequireToolBackedVerification(
            userRequest: userRequest,
            currentAnswer: currentAnswer
        ) else {
            return nil
        }

        let prompt = """
        Decide whether this run should automatically enter verification before being allowed to finish.

        User request:
        \(userRequest)

        Final answer:
        \(currentAnswer)

        Auto verification should be enabled when BOTH of these are true:
        1. The user request likely required real tool-backed execution, file mutation, deletion, rename, build, test, shell action, or another observable side effect.
        2. The final answer appears to claim that the requested work is completed or succeeded.

        Respond ONLY with a valid JSON object in this exact schema:
        {
          "shouldAutoVerify": <true|false>,
          "taskRequiresToolExecution": <true|false>,
          "answerClaimsCompletion": <true|false>,
          "confidence": <number 0.0-1.0>,
          "rationale": <string>
        }
        """

        let params = MessageParameter(
            model: .other(classifierModelId(preferredModelId: modelId)),
            messages: [.init(role: .user, content: .text(prompt))],
            maxTokens: 256,
            system: makeEphemeralSystemPrompt(autoVerificationSystemPrompt)
        )

        do {
            let response = try await service.createMessage(params)
            guard let textContent = response.content.compactMap({ block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }).first else {
                return nil
            }
            return ExecutionGuard.parseAutoVerificationAssessment(from: textContent)
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

enum ExecutionGuard {
    static func evidenceKind(
        toolName: String,
        input: MessageResponse.Content.Input,
        result: ToolExecutionResult
    ) -> ExecutionEvidenceKind? {
        switch toolName {
        case "bash":
            return .bash
        case "run_subagent":
            return input["agent_name"]?.stringValue == "worker" ? .executorSubagent : nil
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
        return assessment.claimsExecutionResults && clampedConfidence >= VerificationEvidenceSupport.confidenceThreshold
    }

    static func parseAutoVerificationAssessment(from text: String) -> AutoVerificationAssessment? {
        let trimmed = stripMarkdownFences(text)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AutoVerificationAssessment.self, from: data)
    }

    static func shouldAutoVerify(_ assessment: AutoVerificationAssessment?) -> Bool {
        guard let assessment else { return false }
        let clampedConfidence = max(0, min(1, assessment.confidence))
        return assessment.shouldAutoVerify &&
            assessment.taskRequiresToolExecution &&
            assessment.answerClaimsCompletion &&
            clampedConfidence >= VerificationEvidenceSupport.autoVerificationThreshold
    }

    static func mayRequireToolBackedVerification(
        userRequest: String,
        currentAnswer: String
    ) -> Bool {
        let combined = (userRequest + "\n" + currentAnswer).lowercased()
        return toolBackedVerificationHints.contains { combined.contains($0) }
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

    private static let toolBackedVerificationHints: [String] = [
        "delete ",
        "remove ",
        "rename ",
        "move ",
        "edit ",
        "modify ",
        "update file",
        "create file",
        "write file",
        "patch ",
        "run ",
        "build ",
        "test ",
        "install ",
        "execute ",
        "shell",
        "bash",
        "删除",
        "移除",
        "重命名",
        "移动",
        "修改文件",
        "删除文件",
        "创建文件",
        "运行",
        "构建",
        "测试",
        "执行"
    ]

}
//
//  ClaudeService+Reflection.swift
//  agentGui
//
//  Self-evaluation pass after a completed agent turn.
//  The model reviews its own output, assigns a confidence score, lists concerns,
//  and recommends fixes. If confidence is below the threshold the loop retries.
//

import Foundation
import SwiftAnthropic

// MARK: - Reflection Result

/// Transient result of one reflection pass (not persisted directly — stored flat on AgentRound).
struct Reflection {
    /// Estimated quality of the completed turn (0 = terrible, 1 = perfect).
    let confidence: Double
    /// List of issues or uncertainties the model noticed.
    let concerns: [String]
    /// Concrete suggestions to fix detected issues.
    let suggestedFixes: [String]
    /// Whether the loop should re-run with the suggested fixes.
    let shouldRetry: Bool
}

// MARK: - Reflection Prompt

private let reflectionSystemPrompt = """
You are a self-review assistant. Your only job is to evaluate the quality of an AI assistant's most recent response and output a JSON object. Do not add commentary outside the JSON.
"""

private func reflectionUserPrompt(threshold: Double) -> String {
    """
    Review the assistant's most recent response in the conversation above.

    Respond ONLY with a valid JSON object in this exact schema:
    {
      "confidence": <number 0.0–1.0>,
      "concerns": [<string>, ...],
      "suggestedFixes": [<string>, ...],
      "shouldRetry": <true|false>
    }

    Rules:
    - confidence: 1.0 = goal fully achieved with no issues; 0.0 = completely wrong or incomplete.
    - concerns: list any factual errors, missing steps, or unreliable tool results. Empty array if none.
    - suggestedFixes: for each concern, one concrete corrective action. Empty array if none.
    - shouldRetry: set to true ONLY when confidence < \(String(format: "%.2f", threshold)) AND there are actionable fixes.

    Return only the JSON object, no markdown fences or extra text.
    """
}

// MARK: - ClaudeService Extension

extension ClaudeService {

    /// Performs one reflection pass on the current conversation.
    ///
    /// - Parameters:
    ///   - messages: The full conversation so far (including tool results from the last turn).
    ///   - service: The Anthropic service to use (same as main loop).
    ///   - modelId: Model ID (same as main loop).
    ///   - settings: AppSettings providing the confidence threshold.
    /// - Returns: A `Reflection`, or `nil` if the call fails or JSON cannot be parsed.
    func reflectOnRound(
        messages: [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings
    ) async -> Reflection? {
        let threshold = settings.reflectionConfidenceThreshold
        let userMsg = MessageParameter.Message(
            role: .user,
            content: .text(reflectionUserPrompt(threshold: threshold))
        )
        let params = MessageParameter(
            model: .other(modelId),
            messages: messages + [userMsg],
            maxTokens: 1024,
            system: .text(reflectionSystemPrompt)
        )

        do {
            let response = try await service.createMessage(params)
            // Extract first text block from the response
            guard let textContent = response.content.compactMap({ block -> String? in
                if case .text(let t, _) = block { return t }
                return nil
            }).first else {
                print("[Reflection] No text block in response")
                return nil
            }
            return parseReflection(from: textContent, threshold: threshold)
        } catch {
            print("[Reflection] API call failed: \(error)")
            return nil
        }
    }

    // MARK: - JSON Parsing

    private func parseReflection(from text: String, threshold: Double) -> Reflection? {
        // Strip optional markdown fences the model may add despite instructions
        let cleaned = stripMarkdownFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }

        struct RawReflection: Decodable {
            let confidence: Double
            let concerns: [String]
            let suggestedFixes: [String]
            let shouldRetry: Bool
        }

        do {
            let raw = try JSONDecoder().decode(RawReflection.self, from: data)
            let clampedConfidence = max(0.0, min(1.0, raw.confidence))
            return Reflection(
                confidence: clampedConfidence,
                concerns: raw.concerns,
                suggestedFixes: raw.suggestedFixes,
                shouldRetry: raw.shouldRetry && clampedConfidence < threshold
            )
        } catch {
            print("[Reflection] JSON parse failed: \(error)\nRaw text: \(text)")
            return nil
        }
    }

    private func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            // Remove opening fence (```json or ```)
            if let newline = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newline)...])
            }
            // Remove closing fence
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

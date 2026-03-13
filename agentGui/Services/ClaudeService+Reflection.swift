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
You are a failure-analysis assistant. A specific failure has just occurred in an AI agent loop. \
Your job is to analyse the failure, identify root causes, and propose concrete fixes. \
Output only a JSON object — no commentary outside it.
"""

private func reflectionUserPrompt(threshold: Double, failureTrigger: FailureTrigger?) -> String {
    let triggerSection: String
    if let trigger = failureTrigger {
        triggerSection = """
        ## Failure Event
        \(trigger.description)

        Analyse the cause of this specific failure and suggest concrete corrective actions.
        """
    } else {
        triggerSection = "Review the assistant's most recent response in the conversation above."
    }

    return """
    \(triggerSection)

    Respond ONLY with a valid JSON object in this exact schema:
    {
      "confidence": <number 0.0–1.0>,
      "concerns": [<string>, ...],
      "suggestedFixes": [<string>, ...],
      "shouldRetry": <true|false>
    }

    Rules:
    - confidence: 1.0 = failure fully understood with clear fix; 0.0 = cause unknown.
    - concerns: root causes of the failure. Required when a failure trigger is provided.
    - suggestedFixes: for each concern, one concrete, actionable corrective step.
    - shouldRetry: true ONLY when confidence < \(String(format: "%.2f", threshold)) AND there are actionable fixes.

    Return only the JSON object, no markdown fences or extra text.
    """
}

// MARK: - ClaudeService Extension

extension ClaudeService {

    /// Performs one failure-driven reflection pass on the current conversation.
    ///
    /// - Parameters:
    ///   - messages: The full conversation so far (including tool results from the last turn).
    ///   - service: The Anthropic service to use (same as main loop).
    ///   - modelId: Model ID (same as main loop).
    ///   - settings: AppSettings providing the confidence threshold.
    ///   - failureTrigger: The failure event that triggered this reflection pass (non-nil in normal use).
    /// - Returns: A `Reflection`, or `nil` if the call fails or JSON cannot be parsed.
    func reflectOnRound(
        messages: [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String,
        settings: AppSettings,
        failureTrigger: FailureTrigger? = nil
    ) async -> Reflection? {
        let threshold = settings.reflectionConfidenceThreshold
        let userMsg = MessageParameter.Message(
            role: .user,
            content: .text(reflectionUserPrompt(threshold: threshold, failureTrigger: failureTrigger))
        )
        let params = MessageParameter(
            model: .other(modelId),
            messages: messages + [userMsg],
            maxTokens: 1024,
            system: makeEphemeralSystemPrompt(reflectionSystemPrompt)
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
        ReflectionJSONDecoder.parse(text: text, threshold: threshold)
    }
}

enum ReflectionJSONDecoder {
    struct RawReflection: Decodable {
        let confidence: Double
        let concerns: [String]
        let suggestedFixes: [String]
        let shouldRetry: Bool
    }

    static func parse(text: String, threshold: Double) -> Reflection? {
        do {
            let raw = try ModelResponseJSONExtractor.decode(
                RawReflection.self,
                from: text,
                salvage: salvageRawReflection(from:)
            )
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

    private static func salvageRawReflection(from text: String) -> RawReflection? {
        guard let confidence = extractDoubleField(named: "confidence", from: text),
              let concerns = extractStringArrayField(named: "concerns", from: text),
              let suggestedFixes = extractStringArrayField(named: "suggestedFixes", from: text),
              let shouldRetry = extractBoolField(named: "shouldRetry", from: text) else {
            return nil
        }

        return RawReflection(
            confidence: confidence,
            concerns: concerns,
            suggestedFixes: suggestedFixes,
            shouldRetry: shouldRetry
        )
    }

    private static func extractDoubleField(named field: String, from text: String) -> Double? {
        let pattern = #"\"\#(field)\"\s*:\s*(-?\d+(?:\.\d+)?)"#
        return firstCapture(matching: pattern, in: text).flatMap(Double.init)
    }

    private static func extractBoolField(named field: String, from text: String) -> Bool? {
        let pattern = #"\"\#(field)\"\s*:\s*(true|false)"#
        return firstCapture(matching: pattern, in: text).flatMap(Bool.init)
    }

    private static func extractStringArrayField(named field: String, from text: String) -> [String]? {
        let source = ModelResponseJSONExtractor.stripMarkdownFences(text)
        let fieldToken = "\"\(field)\""
        guard let fieldRange = source.range(of: fieldToken),
              let arrayStart = source[fieldRange.upperBound...].firstIndex(of: "[") else {
            return nil
        }

        let characters = Array(source[arrayStart...])
        var index = 1
        var items: [String] = []
        var depth = 1

        while index < characters.count {
            let character = characters[index]

            if character == "[" {
                depth += 1
                index += 1
                continue
            }

            if character == "]" {
                depth -= 1
                if depth == 0 {
                    return items
                }
                index += 1
                continue
            }

            if character == "\"" {
                guard let token = readQuotedToken(from: characters, startIndex: index) else {
                    return items.isEmpty ? nil : items
                }

                let nextSignificant = firstNonWhitespace(in: characters, startingAt: token.nextIndex)
                if depth == 1, nextSignificant == ":" {
                    return items.isEmpty ? nil : items
                }

                items.append(token.value)
                index = token.nextIndex
                continue
            }

            index += 1
        }

        return items.isEmpty ? nil : items
    }

    private static func readQuotedToken(from characters: [Character], startIndex: Int) -> (value: String, nextIndex: Int)? {
        var index = startIndex + 1
        var value = ""
        var isEscaping = false

        while index < characters.count {
            let character = characters[index]

            if isEscaping {
                value.append(character)
                isEscaping = false
                index += 1
                continue
            }

            if character == "\\" {
                isEscaping = true
                index += 1
                continue
            }

            if character == "\"" {
                return (value, index + 1)
            }

            value.append(character)
            index += 1
        }

        return nil
    }

    private static func firstNonWhitespace(in characters: [Character], startingAt index: Int) -> Character? {
        var currentIndex = index
        while currentIndex < characters.count {
            let character = characters[currentIndex]
            if !character.isWhitespace {
                return character
            }
            currentIndex += 1
        }
        return nil
    }

    private static func firstCapture(matching pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

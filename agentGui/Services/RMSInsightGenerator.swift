import Foundation
import SwiftAnthropic

protocol RMSInsightGenerating {
    func generateStateDelta(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        updatedAt: Date
    ) async throws -> RMSStateDelta?

    func generateRequiredInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight

    func generateOptionalInsight(
        id: String,
        content: String,
        envelope: EpistemicInputEnvelope,
        event: AtomicEpistemicEvent,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight?
}

struct LLMRMSInsightGenerator: RMSInsightGenerating {
    let service: any AnthropicService
    let modelId: String

    func generateStateDelta(
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        updatedAt: Date
    ) async throws -> RMSStateDelta? {
        let response = try await requestStateDelta(existing: existing, envelope: envelope)
        return makeStateDelta(
            response: response,
            existing: existing,
            envelope: envelope,
            updatedAt: updatedAt
        )
    }

    func generateRequiredInsight(
        id: String,
        content: String,
        normalizedTitle: String,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight {
        let response = try await requestRequiredInsight(content: content, normalizedTitle: normalizedTitle, scope: scope)
        return makeInsight(
            id: id,
            response: response,
            scope: scope,
            evidenceRefs: ["tool:memory_write"],
            updatedAt: updatedAt,
            fallbackSummary: content,
            fallbackAppliesWhen: normalizedTitle == "Memory" ? "general" : normalizedTitle
        )
    }

    func generateOptionalInsight(
        id: String,
        content: String,
        envelope: EpistemicInputEnvelope,
        event: AtomicEpistemicEvent,
        scope: MemoryScope,
        updatedAt: Date
    ) async throws -> RMSInsight? {
        let response = try await requestOptionalInsight(content: content, envelope: envelope, event: event, scope: scope)
        guard response.shouldStore else {
            return nil
        }
        return makeInsight(
            id: id,
            response: response,
            scope: scope,
            evidenceRefs: event.sourceRefs,
            updatedAt: updatedAt,
            fallbackSummary: content,
            fallbackAppliesWhen: fallbackAppliesWhen(envelope: envelope)
        )
    }

    private func requestRequiredInsight(
        content: String,
        normalizedTitle: String,
        scope: MemoryScope
    ) async throws -> RequiredInsightResponse {
        let prompt = """
        Analyze the following user-authored memory content and convert it into exactly one RMS insight.

        Allowed kinds: constraint, counterexample, tactic.

        Return ONLY valid JSON with this schema:
        {
          "kind": "constraint|counterexample|tactic",
          "summary": "string",
          "appliesWhen": "string",
          "changesDecision": "string",
          "replacementAction": "string",
          "confidence": 0.0
        }

        Rules:
        - `summary` should be concise and decision-relevant.
        - `appliesWhen` should describe when this memory should be activated.
        - `changesDecision` should explain how the next action changes.
        - `replacementAction` is required for counterexamples; otherwise use an empty string.
        - `confidence` must be between 0 and 1.

        Scope: \(scope.namespace)
        Normalized title: \(normalizedTitle)
        Content:
        \(content)
        """

        return try await execute(prompt: prompt, responseType: RequiredInsightResponse.self)
    }

        private func requestStateDelta(
                existing: RMSState?,
                envelope: EpistemicInputEnvelope
        ) async throws -> StateDeltaResponse {
                let existingSummary = renderExistingState(existing)
                let userMessages = renderList(envelope.userAgentMessages)
                let toolObservations = renderList(envelope.toolObservations)
                let eventLines = renderEventList(envelope.events)
                let prompt = """
                Compress the current task cognition into a concise RMS state delta.

                Return ONLY valid JSON with this schema:
                {
                    "summary": "string",
                    "frontiers": [
                        {
                            "openClaim": "string",
                            "suggestedProbe": "string",
                            "stopCondition": "string"
                        }
                    ],
                    "constraints": ["string"],
                    "counterexamples": [
                        {
                            "summary": "string",
                            "replacementAction": "string"
                        }
                    ],
                    "verificationDebts": [
                        {
                            "claim": "string",
                            "reason": "string"
                        }
                    ],
                    "candidateActions": ["string"],
                    "stopSignals": ["string"]
                }

                Rules:
                - Record only high-signal, reusable task cognition.
                - Aggressively compress wording; do not copy full user text unless absolutely necessary.
                - Keep `summary` to one short sentence describing the task state.
                - Include at most 3 items per array.
                - Prefer evidence-seeking probes over generic actions.
                - `verificationDebts` should capture unresolved claims that still need direct proof.
                - `stopSignals` should capture concrete conditions that indicate a frontier can stop.
                - If a section has nothing valuable, return an empty array or empty string.

                Existing task state:
                \(existingSummary)

                Recent user and assistant messages:
                \(userMessages)

                Tool observations:
                \(toolObservations)

                Recent epistemic events:
                \(eventLines)
                """

                return try await execute(prompt: prompt, responseType: StateDeltaResponse.self)
        }

    private func requestOptionalInsight(
        content: String,
        envelope: EpistemicInputEnvelope,
        event: AtomicEpistemicEvent,
        scope: MemoryScope
    ) async throws -> OptionalInsightResponse {
        let taskSummary = fallbackAppliesWhen(envelope: envelope)
        let userMessages = renderList(envelope.userAgentMessages)
        let toolObservations = renderList(envelope.toolObservations)
        let candidateActions = renderList(envelope.events.filter { $0.kind == .actionProposed }.map(\.summary))
        let prompt = """
        Analyze whether this event should become a reusable RMS insight.

        Allowed kinds: constraint, counterexample, tactic.
        If the content is too local, too weak, or not reusable, reject it.

        Return ONLY valid JSON with this schema:
        {
          "shouldStore": true,
          "kind": "constraint|counterexample|tactic",
          "summary": "string",
          "appliesWhen": "string",
          "changesDecision": "string",
          "replacementAction": "string",
          "confidence": 0.0
        }

        Rules:
        - Set `shouldStore` to false when the content should not become long-term memory.
        - When `shouldStore` is false, other fields may be empty strings.
        - `summary` should be concise and reusable.
        - `appliesWhen` should describe the problem shape where the memory matters.
        - `changesDecision` should explain how future action selection changes.
        - `replacementAction` is required for counterexamples; otherwise use an empty string.
        - `confidence` must be between 0 and 1.

        Task summary: \(taskSummary)
        Scope: \(scope.namespace)
        Event kind: \(event.kind.rawValue)
        Event content:
        \(content)

        Recent user/assistant messages:
        \(userMessages)

        Tool observations:
        \(toolObservations)

        Candidate actions:
        \(candidateActions)
        """

        return try await execute(prompt: prompt, responseType: OptionalInsightResponse.self)
    }

    private func execute<Response: Decodable>(
        prompt: String,
        responseType: Response.Type
    ) async throws -> Response {
        let params = MessageParameter(
            model: .other(modelId),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 512,
            system: .text("You classify RMS insights. Output JSON only.")
        )
        let response = try await service.createMessage(params)
        let text = response.content.compactMap { block -> String? in
            if case .text(let value, _) = block {
                return value
            }
            return nil
        }.joined(separator: "\n")
        return try ModelResponseJSONExtractor.decode(responseType, from: text)
    }

    private func makeInsight(
        id: String,
        response: InsightResponseProviding,
        scope: MemoryScope,
        evidenceRefs: [String],
        updatedAt: Date,
        fallbackSummary: String,
        fallbackAppliesWhen: String
    ) -> RMSInsight {
        let summary = trimmed(response.summary).isEmpty ? trimmed(fallbackSummary) : trimmed(response.summary)
        let appliesWhen = trimmed(response.appliesWhen).isEmpty ? trimmed(fallbackAppliesWhen) : trimmed(response.appliesWhen)
        let changesDecision = trimmed(response.changesDecision).isEmpty
            ? "apply this remembered insight before choosing the next action"
            : trimmed(response.changesDecision)
        let replacementAction = trimmed(response.replacementAction)
        let normalizedReplacement = replacementAction.isEmpty ? nil : replacementAction
        let confidence = min(max(response.confidence, 0), 1)

        return RMSInsight(
            id: id,
            kind: response.kind,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            replacementAction: response.kind == .counterexample ? (normalizedReplacement ?? "Inspect current state before acting") : normalizedReplacement,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence,
            updatedAt: updatedAt
        )
    }

    private func makeStateDelta(
        response: StateDeltaResponse,
        existing: RMSState?,
        envelope: EpistemicInputEnvelope,
        updatedAt: Date
    ) -> RMSStateDelta? {
        let taskSummary = trimmed(response.summary)
        let goal = [taskSummary, existing?.summary, envelope.userAgentMessages.first]
            .compactMap { value in
                let normalized = trimmed(value ?? "")
                return normalized.isEmpty ? nil : normalized
            }
            .first ?? ""

        let frontiers = response.frontiers.enumerated().compactMap { index, frontier -> RMSFrontier? in
            let openClaim = trimmed(frontier.openClaim)
            guard !openClaim.isEmpty else { return nil }
            return RMSFrontier(
                id: "frontier-\(envelope.roundIndex)-llm-\(index)",
                goal: goal,
                openClaim: openClaim,
                suggestedProbe: trimmed(frontier.suggestedProbe),
                stopCondition: trimmed(frontier.stopCondition)
            )
        }

        let constraints = response.constraints.enumerated().compactMap { index, summary -> RMSConstraint? in
            let normalized = trimmed(summary)
            guard !normalized.isEmpty else { return nil }
            return RMSConstraint(
                id: "constraint-\(envelope.roundIndex)-llm-\(index)",
                summary: normalized,
                scope: .session(id: envelope.sessionID)
            )
        }

        let counterexamples = response.counterexamples.enumerated().compactMap { index, item -> RMSCounterexample? in
            let summary = trimmed(item.summary)
            guard !summary.isEmpty else { return nil }
            return RMSCounterexample(
                id: "counterexample-\(envelope.roundIndex)-llm-\(index)",
                summary: summary,
                replacementAction: trimmed(item.replacementAction)
            )
        }

        let verificationDebts = response.verificationDebts.enumerated().compactMap { index, item -> RMSVerificationDebt? in
            let claim = trimmed(item.claim)
            guard !claim.isEmpty else { return nil }
            return RMSVerificationDebt(
                id: "verification-debt-\(envelope.roundIndex)-llm-\(index)",
                claim: claim,
                reason: trimmed(item.reason)
            )
        }

        let delta = RMSStateDelta(
            summary: taskSummary.isEmpty ? nil : taskSummary,
            frontiers: frontiers,
            constraints: constraints,
            counterexamples: counterexamples,
            verificationDebts: verificationDebts,
            candidateActions: uniqueStrings(response.candidateActions),
            stopSignals: uniqueStrings(response.stopSignals)
        )

        if isMeaningful(delta) {
            return delta
        }

        _ = updatedAt
        return nil
    }

    private func renderExistingState(_ existing: RMSState?) -> String {
        guard let existing else { return "- none" }
        let snapshot = existing.stableSnapshot()
        let lines = [
            "- summary: \(snapshot.summary.isEmpty ? "none" : snapshot.summary)",
            "- frontiers: \(snapshot.frontiers.map(\.openClaim).joined(separator: " | "))",
            "- constraints: \(snapshot.constraints.map(\.summary).joined(separator: " | "))",
            "- counterexamples: \(snapshot.counterexamples.map(\.summary).joined(separator: " | "))",
            "- verification debt: \(snapshot.verificationDebts.map(\.claim).joined(separator: " | "))",
            "- candidate actions: \(snapshot.candidateActions.joined(separator: " | "))",
            "- stop signals: \(snapshot.stopSignals.joined(separator: " | "))"
        ]
        return lines.joined(separator: "\n")
    }

    private func renderEventList(_ values: [AtomicEpistemicEvent]) -> String {
        let normalized = values.compactMap { event -> String? in
            let summary = trimmed(event.summary)
            guard !summary.isEmpty else { return nil }
            return "- \(event.kind.rawValue): \(summary)"
        }
        guard !normalized.isEmpty else { return "- none" }
        return normalized.joined(separator: "\n")
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = trimmed(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func isMeaningful(_ delta: RMSStateDelta) -> Bool {
        delta.summary?.isEmpty == false ||
            !delta.frontiers.isEmpty ||
            !delta.constraints.isEmpty ||
            !delta.counterexamples.isEmpty ||
            !delta.verificationDebts.isEmpty ||
            !delta.candidateActions.isEmpty ||
            !delta.stopSignals.isEmpty
    }

    private func fallbackAppliesWhen(envelope: EpistemicInputEnvelope) -> String {
        let values = [
            envelope.userAgentMessages.first,
            envelope.toolObservations.first
        ]
        for value in values {
            let trimmedValue = trimmed(value ?? "")
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }
        return "general"
    }

    private func renderList(_ values: [String]) -> String {
        let normalized = values.map(trimmed).filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return "- none" }
        return normalized.map { "- \($0)" }.joined(separator: "\n")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private protocol InsightResponseProviding {
    var kind: RMSInsightKind { get }
    var summary: String { get }
    var appliesWhen: String { get }
    var changesDecision: String { get }
    var replacementAction: String { get }
    var confidence: Double { get }
}

private struct RequiredInsightResponse: Codable, InsightResponseProviding {
    var kind: RMSInsightKind
    var summary: String
    var appliesWhen: String
    var changesDecision: String
    var replacementAction: String
    var confidence: Double
}

private struct OptionalInsightResponse: Codable, InsightResponseProviding {
    var shouldStore: Bool
    var kind: RMSInsightKind
    var summary: String
    var appliesWhen: String
    var changesDecision: String
    var replacementAction: String
    var confidence: Double
}

private struct StateDeltaResponse: Codable {
    var summary: String
    var frontiers: [StateDeltaFrontierResponse]
    var constraints: [String]
    var counterexamples: [StateDeltaCounterexampleResponse]
    var verificationDebts: [StateDeltaVerificationDebtResponse]
    var candidateActions: [String]
    var stopSignals: [String]
}

private struct StateDeltaFrontierResponse: Codable {
    var openClaim: String
    var suggestedProbe: String
    var stopCondition: String
}

private struct StateDeltaCounterexampleResponse: Codable {
    var summary: String
    var replacementAction: String
}

private struct StateDeltaVerificationDebtResponse: Codable {
    var claim: String
    var reason: String
}
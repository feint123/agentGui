import Foundation
import SwiftAnthropic
import SwiftData

struct AgentLoopVerificationOutcome: Equatable {
    let passed: Bool
    let report: CompletionVerification
    let failureTrigger: FailureTrigger?
}

@MainActor
struct AgentLoopVerificationCoordinator {
    let claudeService: ClaudeService
    let service: any AnthropicService
    let modelId: String
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext
    let runID: String
    let roundIndex: Int
    let parentMessage: Message?

    func verify(
        currentAnswer: String,
        executionEvidence: Set<ExecutionEvidenceKind>,
        existingVerification: CompletionVerification?,
        latestFailureTrigger: FailureTrigger?
    ) async throws -> AgentLoopVerificationOutcome {
        let store = SessionTaskStateStore(modelContext: modelContext)
        let logContext = BusinessLogContext(
            runID: runID,
            sessionID: sessionId,
            roundIndex: roundIndex,
            phase: "verifying"
        )
        let verification = existingVerification ?? CompletionVerification(
            verified: [],
            notVerified: [],
            conclusion: nil
        )

        let task = makeVerifierTask(
            currentAnswer: currentAnswer,
            executionEvidence: executionEvidence,
            verification: verification,
            latestFailureTrigger: latestFailureTrigger
        )
        let input: MessageResponse.Content.Input = [
            "agent_name": .string("verifier"),
            "task": .string(task)
        ]
        BusinessMonitor.emit(
            .verifierSubagentStarted,
            context: logContext,
            metadata: [
                "agentName": "verifier",
                "verifiedCount": verification.verified.count,
                "notVerifiedCount": verification.notVerified.count,
                "executionEvidenceCount": executionEvidence.count,
                "hasVerifyCompletionRecord": existingVerification != nil
            ],
            sink: claudeService.businessLogSink
        )
        let record = claudeService.makeToolCallRecord(
            toolUseId: "verify-subagent-\(UUID().uuidString)",
            toolName: "run_subagent",
            input: input,
            message: parentMessage,
            executionContext: .mainAgent
        )
        if parentMessage == nil {
            modelContext.insert(record)
        }
        try? modelContext.save()

        let agentMessage = try await claudeService.runNamedSubagent(
            name: "verifier",
            task: task,
            toolCallRecord: record,
            service: service,
            modelId: modelId,
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )

        record.subagentResultKind = agentMessage.content.kindLabel
        if !agentMessage.metadata.isEmpty {
            record.subagentMessageMetadata = agentMessage.metadata
        }
        record.status = agentMessage.isError ? .failed : .success
        record.endTime = Date()
        try? modelContext.save()
        BusinessMonitor.emit(
            .verifierSubagentFinished,
            context: logContext,
            metadata: [
                "agentName": "verifier",
                "resultKind": agentMessage.content.kindLabel,
                "isError": agentMessage.isError,
                "textLength": agentMessage.apiText.count,
                "textPreview": String(agentMessage.apiText.prefix(240))
            ],
            sink: claudeService.businessLogSink
        )

        let payload = parseVerifierPayload(from: agentMessage.apiText)
        let failedItems = payload?.failedItems ?? []
        let missingEvidence = payload?.missingEvidence ?? ["Verifier output could not be parsed"]
        let derivedPassed = (payload?.passed ?? false) && failedItems.isEmpty && missingEvidence.isEmpty
        let summary = payload?.summary ?? (agentMessage.isError ? agentMessage.apiText : "Verifier output could not be parsed")
        let update = VerificationAssessmentUpdate(
            passed: derivedPassed,
            summary: summary,
            missingEvidence: missingEvidence,
            riskAreas: payload?.riskAreas ?? [],
            recommendedNextAction: payload?.recommendedNextAction,
            verifierAgent: "verifier"
        )
        try store.updateVerificationAssessment(update, for: sessionId)
        BusinessMonitor.emit(
            .verificationCompleted,
            context: logContext,
            metadata: [
                "passed": derivedPassed,
                "summary": summary,
                "failedItemCount": failedItems.count,
                "missingEvidenceCount": missingEvidence.count,
                "riskAreaCount": payload?.riskAreas.count ?? 0,
                "parsedPayload": payload != nil,
                "rawPreview": String(agentMessage.apiText.prefix(240))
            ],
            sink: claudeService.businessLogSink
        )

        let report = store.verification(for: sessionId) ?? CompletionVerification(
            verified: verification.verified,
            notVerified: verification.notVerified,
            conclusion: verification.conclusion,
            passed: update.passed,
            summary: update.summary,
            missingEvidence: update.missingEvidence,
            riskAreas: update.riskAreas,
            recommendedNextAction: update.recommendedNextAction,
            verifierAgent: update.verifierAgent
        )
        let failureTrigger = derivedPassed ? nil : FailureTrigger.verificationFailure(detail: summary)
        return AgentLoopVerificationOutcome(passed: derivedPassed, report: report, failureTrigger: failureTrigger)
    }

    private func makeVerifierTask(
        currentAnswer: String,
        executionEvidence: Set<ExecutionEvidenceKind>,
        verification: CompletionVerification,
        latestFailureTrigger: FailureTrigger?
    ) -> String {
        let evidenceText = buildExecutionEvidenceText(executionEvidence: executionEvidence)
        let verifiedText = verification.verified.isEmpty
            ? "- none"
            : verification.verified.map { "- \($0)" }.joined(separator: "\n")
        let notVerifiedText = verification.notVerified.isEmpty
            ? "- none"
            : verification.notVerified.map { "- \($0)" }.joined(separator: "\n")

        // Keep the verifier task self-contained because the subagent cannot ask follow-ups.
        return """
        ## Context

        Current answer / final agent response:
        \(currentAnswer)

        Execution evidence (tools actually invoked):
        \(evidenceText)

        Structured verification record, if any. If none exists, derive verification directly from observed execution evidence:
        - Verified: \(verifiedText)
        - Not verified: \(notVerifiedText)
        - Conclusion: \(verification.conclusion ?? "none")

        Latest failure trigger (host-detected issue, if any):
        \(latestFailureTrigger?.description ?? "none")

        Return ONLY valid JSON in this schema:
        {
          "passed": <true|false>,
          "summary": "short verdict",
          "verified_items": ["item"],
          "failed_items": ["item"],
          "missing_evidence": ["item"],
          "risk_areas": ["item"],
          "recommended_next_action": "finish|reflect|retry_execution|gather_context",
          "confidence": 0.0
        }
        """
    }

    private func buildExecutionEvidenceText(executionEvidence: Set<ExecutionEvidenceKind>) -> String {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.session?.sessionId == sessionId }
        )
        let rootToolCalls = ((try? modelContext.fetch(descriptor)) ?? [])
            .flatMap(\.toolCalls)
            .sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
        return Self.buildExecutionEvidenceText(
            executionEvidence: executionEvidence,
            toolCalls: rootToolCalls
        )
    }

    static func buildExecutionEvidenceTextForTests(
        executionEvidence: Set<ExecutionEvidenceKind>,
        toolCalls: [ToolCall]
    ) -> String {
        buildExecutionEvidenceText(executionEvidence: executionEvidence, toolCalls: toolCalls)
    }

    private static func buildExecutionEvidenceText(
        executionEvidence: Set<ExecutionEvidenceKind>,
        toolCalls: [ToolCall]
    ) -> String {
        let signalText = executionEvidence.isEmpty
            ? "none"
            : executionEvidence.map(\.rawValue).sorted().joined(separator: ", ")
        let entries = toolCalls.map(makeEvidenceEntry(from:))
        let renderedEntries = entries.flatMap { renderEvidenceEntry($0, depth: 0) }

        var lines = [
            "High-level signals: \(signalText)",
            "Observed tool activity:"
        ]
        if renderedEntries.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: renderedEntries)
        }
        return lines.joined(separator: "\n")
    }

    private static func makeEvidenceEntry(from toolCall: ToolCall) -> VerificationEvidenceEntry {
        let headline: String
        if toolCall.kind == .subagent {
            headline = "subagent: \(toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.rawValue)"
        } else {
            headline = "\(toolCall.kind.rawValue): \(toolCall.title ?? toolCall.kind.displayName)"
        }

        var details: [VerificationEvidenceDetail] = []

        if let filePath = trimmed(toolCall.filePath) {
            details.append(.init(label: "path", value: filePath))
        }
        if let command = commandText(from: toolCall) {
            details.append(.init(label: "command", value: command))
        }
        if let target = targetText(from: toolCall) {
            details.append(.init(label: "target", value: target))
        }
        if let task = trimmed(toolCall.subagentTask) {
            details.append(.init(label: "task", value: task))
        }
        if let resultKind = trimmed(toolCall.subagentResultKind) {
            details.append(.init(label: "result", value: resultKind))
        }
        if let status = trimmed(toolCall.terminalTaskStatus) ?? statusText(from: toolCall), !status.isEmpty {
            details.append(.init(label: "status", value: status))
        }
        if let summary = trimmed(toolCall.toolResultSummary) {
            details.append(.init(label: "summary", value: summary))
        }
        if let output = firstUsefulLine(in: toolCall.terminalOutput) {
            details.append(.init(label: "output", value: output))
        }
        if let payloadRef = trimmed(toolCall.toolPayloadRef) {
            details.append(.init(label: "payload_ref", value: payloadRef))
        }

        let childEntries = nestedToolCalls(from: toolCall)
            .map(makeEvidenceEntry(from:))

        return VerificationEvidenceEntry(
            headline: headline,
            details: uniqued(details),
            children: childEntries
        )
    }

    private static func nestedToolCalls(from toolCall: ToolCall) -> [ToolCall] {
        toolCall.subagentRounds
            .sorted { $0.roundIndex < $1.roundIndex }
            .flatMap { round in
                round.toolCalls.sorted { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) }
            }
    }

    private static func renderEvidenceEntry(_ entry: VerificationEvidenceEntry, depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)- \(entry.headline)"]
        for detail in entry.details {
            lines.append("\(indent)  \(detail.label): \(detail.value)")
        }
        for child in entry.children {
            lines.append(contentsOf: renderEvidenceEntry(child, depth: depth + 1))
        }
        return lines
    }

    private static func commandText(from toolCall: ToolCall) -> String? {
        if let promptSummary = trimmed(toolCall.terminalPromptSummary) {
            return promptSummary
        }
        guard toolCall.kind == .execute else { return nil }
        return trimmed(toolCall.title)
    }

    private static func targetText(from toolCall: ToolCall) -> String? {
        guard let title = trimmed(toolCall.title) else { return nil }
        if toolCall.kind == .fetch, title.hasPrefix("获取: ") {
            return String(title.dropFirst(4))
        }
        if toolCall.kind == .search, title.hasPrefix("搜索: ") {
            return String(title.dropFirst(4))
        }
        return nil
    }

    private static func statusText(from toolCall: ToolCall) -> String? {
        switch toolCall.status {
        case .success:
            return "success"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        case .inProgress:
            return nil
        }
    }

    private static func firstUsefulLine(in text: String?) -> String? {
        guard let text = trimmed(text) else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func uniqued(_ details: [VerificationEvidenceDetail]) -> [VerificationEvidenceDetail] {
        var seen = Set<String>()
        var result: [VerificationEvidenceDetail] = []
        for detail in details {
            let key = "\(detail.label)::\(detail.value)"
            if seen.insert(key).inserted {
                result.append(detail)
            }
        }
        return result
    }

    private func parseVerifierPayload(from text: String) -> VerifierPayload? {
        Self.parseVerifierPayloadForTests(from: text)
    }

    static func parseVerifierPayloadForTests(from text: String) -> VerifierPayload? {
        let candidates = verifierJSONCandidates(from: text)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let payload = try? JSONDecoder().decode(VerifierPayload.self, from: data) {
                return payload
            }
        }
        return nil
    }

    private static func verifierJSONCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }

        let unfenced = stripMarkdownFences(trimmed)
        if !unfenced.isEmpty, unfenced != trimmed {
            candidates.append(unfenced)
        }

        if let extracted = extractFirstJSONObject(from: trimmed), !extracted.isEmpty {
            candidates.append(extracted)
        }

        if let extractedFromUnfenced = extractFirstJSONObject(from: unfenced), !extractedFromUnfenced.isEmpty {
            candidates.append(extractedFromUnfenced)
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
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

    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let startIndex = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in text[startIndex...].indices {
            let character = text[index]

            if isEscaping {
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[startIndex...index])
                }
            }
        }

        return nil
    }
}

private struct VerificationEvidenceEntry: Equatable {
    let headline: String
    let details: [VerificationEvidenceDetail]
    let children: [VerificationEvidenceEntry]
}

private struct VerificationEvidenceDetail: Equatable {
    let label: String
    let value: String
}

struct VerifierPayload: Codable {
    let passed: Bool
    let summary: String
    let verifiedItems: [String]
    let failedItems: [String]
    let missingEvidence: [String]
    let riskAreas: [String]
    let recommendedNextAction: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case passed
        case summary
        case verifiedItems = "verified_items"
        case failedItems = "failed_items"
        case missingEvidence = "missing_evidence"
        case riskAreas = "risk_areas"
        case recommendedNextAction = "recommended_next_action"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passed = try container.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        verifiedItems = try container.decodeIfPresent([String].self, forKey: .verifiedItems) ?? []
        failedItems = try container.decodeIfPresent([String].self, forKey: .failedItems) ?? []
        missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        riskAreas = try container.decodeIfPresent([String].self, forKey: .riskAreas) ?? []
        recommendedNextAction = try container.decodeIfPresent(String.self, forKey: .recommendedNextAction)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}
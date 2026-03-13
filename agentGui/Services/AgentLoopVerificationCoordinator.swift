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
        let lspPromptContext = buildLSPPromptContext()
        return Self.buildExecutionEvidenceText(
            executionEvidence: executionEvidence,
            toolCalls: rootToolCalls,
            lspServerID: lspPromptContext.serverID,
            lspServerStateSummary: lspPromptContext.serverStateSummary,
            diagnosticsSnapshot: lspPromptContext.diagnosticsSnapshot
        )
    }

    static func buildExecutionEvidenceTextForTests(
        executionEvidence: Set<ExecutionEvidenceKind>,
        toolCalls: [ToolCall],
        lspServerID: String? = nil,
        lspServerStateSummary: String? = nil,
        diagnosticsSnapshot: LSPDiagnosticsSnapshot? = nil
    ) -> String {
        buildExecutionEvidenceText(
            executionEvidence: executionEvidence,
            toolCalls: toolCalls,
            lspServerID: lspServerID,
            lspServerStateSummary: lspServerStateSummary,
            diagnosticsSnapshot: diagnosticsSnapshot
        )
    }

    private static func buildExecutionEvidenceText(
        executionEvidence: Set<ExecutionEvidenceKind>,
        toolCalls: [ToolCall],
        lspServerID: String? = nil,
        lspServerStateSummary: String? = nil,
        diagnosticsSnapshot: LSPDiagnosticsSnapshot? = nil
    ) -> String {
        let signalText = executionEvidence.isEmpty
            ? "none"
            : executionEvidence.map(\.rawValue).sorted().joined(separator: ", ")
        // Keep the verifier prompt focused by ranking concrete evidence before rendering it.
        let entries = prioritizeEvidenceEntries(toolCalls.map(makeEvidenceEntry(from:)))
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

        if lspServerID != nil || lspServerStateSummary != nil || diagnosticsSnapshot != nil {
            lines.append(contentsOf: renderLSPPromptSummary(
                serverID: lspServerID,
                serverStateSummary: lspServerStateSummary,
                diagnosticsSnapshot: diagnosticsSnapshot
            ))
        }
        return lines.joined(separator: "\n")
    }

    private func buildLSPPromptContext() -> (serverID: String?, serverStateSummary: String?, diagnosticsSnapshot: LSPDiagnosticsSnapshot?) {
        let workspaceContext = claudeService.currentWorkspaceContext
        guard settings.enableLSPTools,
              !workspaceContext.workingDirectory.isEmpty,
              let filePath = workspaceContext.selectedFilePath,
              let registry = try? LSPServerRegistry(settings: settings) else {
            return (nil, nil, nil)
        }

        let resolver = LSPWorkspaceResolver()
        guard let binding = resolver.resolve(
            filePath: filePath,
            workingDirectory: workspaceContext.workingDirectory,
            registry: registry,
            settings: settings
        ) else {
            return (nil, nil, nil)
        }

        let uri = URL(fileURLWithPath: filePath).absoluteString
        return (
            binding.serverID,
            claudeService.lspServerManager?.state(for: workspaceContext.workingDirectory, serverID: binding.serverID)?.summaryText,
            claudeService.lspServerManager?.diagnosticsStore.snapshot(for: workspaceContext.workingDirectory, uri: uri)
        )
    }

    private static func renderLSPPromptSummary(
        serverID: String?,
        serverStateSummary: String?,
        diagnosticsSnapshot: LSPDiagnosticsSnapshot?
    ) -> [String] {
        var lines = ["LSP context:"]
        lines.append("- LSP server: \(serverID ?? "none")")
        lines.append("- LSP state: \(serverStateSummary ?? "none")")

        guard let diagnosticsSnapshot else {
            lines.append("- Diagnostics: none")
            return lines
        }

        let severityCounts = Dictionary(grouping: diagnosticsSnapshot.diagnostics, by: \.severity)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        let preview = diagnosticsSnapshot.diagnostics.prefix(3).map(\.message).joined(separator: " | ")
        lines.append("- Diagnostics: \(diagnosticsSnapshot.diagnostics.count) total [\(severityCounts)]")
        if !preview.isEmpty {
            lines.append("- Diagnostics preview: \(preview)")
        }
        return lines
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

        let childEntries = prioritizeEvidenceEntries(
            nestedToolCalls(from: toolCall)
                .map(makeEvidenceEntry(from:))
        )

        return VerificationEvidenceEntry(
            headline: headline,
            details: uniqued(details),
            children: childEntries,
            timestamp: toolCall.startTime,
            riskScore: riskScore(for: toolCall),
            isSummary: false
        )
    }

    private static func prioritizeEvidenceEntries(
        _ entries: [VerificationEvidenceEntry],
        limit: Int = 3
    ) -> [VerificationEvidenceEntry] {
        guard entries.count > limit else { return entries }

        // Higher-risk evidence stays visible first; recency breaks ties so the verifier sees
        // the latest concrete actions before older, lower-signal activity.
        let sorted = entries.sorted { lhs, rhs in
            if lhs.riskScore != rhs.riskScore {
                return lhs.riskScore > rhs.riskScore
            }
            return (lhs.timestamp ?? .distantPast) > (rhs.timestamp ?? .distantPast)
        }

        let kept = Array(sorted.prefix(limit))
        let omittedCount = max(0, sorted.count - kept.count)
        guard omittedCount > 0 else { return kept }

        // Preserve the fact that more evidence exists without flooding the verifier prompt.
        return kept + [
            VerificationEvidenceEntry(
                headline: "omitted \(omittedCount) older/lower-priority evidence entries",
                details: [],
                children: [],
                timestamp: nil,
                riskScore: Int.min,
                isSummary: true
            )
        ]
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
        if entry.isSummary {
            return lines
        }
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

    private static func riskScore(for toolCall: ToolCall) -> Int {
        var score = 0

        // Failures and mutating/command-execution tools are the most important verification signals.
        switch toolCall.status {
        case .failed:
            score += 100
        case .cancelled:
            score += 80
        case .success:
            score += 10
        case .inProgress:
            score += 20
        }

        switch toolCall.kind {
        case .execute:
            score += 70
        case .edit, .delete:
            score += 60
        case .subagent:
            score += 50
        case .fetch:
            score += 35
        case .search:
            score += 25
        case .read:
            score += 15
        case .plan, .todo, .askUser, .switchMode, .think, .other:
            score += 20
        }

        if toolCall.filePath != nil {
            score += 5
        }
        if toolCall.terminalPromptSummary != nil {
            score += 5
        }
        if !toolCall.subagentRounds.isEmpty {
            score += 10
        }

        return score
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
        ModelResponseJSONExtractor.decodeIfPresent(VerifierPayload.self, from: text)
    }
}

private struct VerificationEvidenceEntry: Equatable {
    let headline: String
    let details: [VerificationEvidenceDetail]
    let children: [VerificationEvidenceEntry]
    let timestamp: Date?
    let riskScore: Int
    let isSummary: Bool
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
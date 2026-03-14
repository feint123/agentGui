import Foundation

struct AgentLoopVerificationReduction: Equatable {
    let report: CompletionVerification
    let verificationState: VerificationState
    let failureTrigger: FailureTrigger?
}

struct AgentLoopVerificationCoordinator {
    private static func buildVerificationState(
        payload: VerifierPayload?,
        verification: CompletionVerification,
        executionEvidence: Set<ExecutionEvidenceKind>,
        fallbackSummary: String
    ) -> VerificationState {
        let claims = buildClaims(from: verification)
        let evidence = buildEvidence(from: executionEvidence)
        let frontier = buildFrontier(from: payload, claims: claims)
        let openQuestions = payload?.missingEvidence ?? (payload == nil ? [fallbackSummary] : [])
        let residualRisks = payload?.residualRisks ?? payload?.riskAreas ?? []
        let riskScore = min(1, Double(openQuestions.count) * 0.22 + Double(residualRisks.count) * 0.18 + Double(frontier.count) * 0.20)
        let supportedClaims = claims.filter { $0.status == .supported }.map(\.text)
        let contradictedClaims = claims.filter { $0.status == .contradicted }.map(\.text)
        let openClaims = frontier.map(\.openQuestion)

        let decision: VerificationDecision
        let stopReason: String
        if frontier.isEmpty, openQuestions.isEmpty, residualRisks.isEmpty {
            decision = .pass
            stopReason = payload?.summary ?? fallbackSummary
        } else if !openQuestions.isEmpty {
            decision = .abstain
            stopReason = payload?.summary ?? openQuestions.joined(separator: "; ")
        } else if !frontier.isEmpty {
            decision = .revise
            stopReason = payload?.summary ?? frontier.map(\.openQuestion).joined(separator: "; ")
        } else {
            decision = .fail
            stopReason = payload?.summary ?? residualRisks.joined(separator: "; ")
        }

        let certificate = ConvergenceCertificate(
            decision: decision,
            supportedClaims: supportedClaims,
            contradictedClaims: contradictedClaims,
            openClaims: openClaims,
            residualRisks: residualRisks,
            expectedValueOfMoreVerification: decision == .pass ? 0 : max(0.1, riskScore),
            stopReason: stopReason
        )

        return VerificationState(
            riskScore: riskScore,
            claims: claims,
            evidence: evidence,
            frontier: frontier,
            repairQueue: payload?.recommendedNextAction.map { [$0] } ?? [],
            openQuestions: openQuestions,
            certificate: certificate
        )
    }

    static func buildVerificationStateForTests(
        payload: VerifierPayload?,
        verification: CompletionVerification,
        executionEvidence: Set<ExecutionEvidenceKind>,
        fallbackSummary: String
    ) -> VerificationState {
        buildVerificationState(
            payload: payload,
            verification: verification,
            executionEvidence: executionEvidence,
            fallbackSummary: fallbackSummary
        )
    }

    static func reduceVerifierResult(
        rawText: String,
        existingVerification: CompletionVerification?,
        executionEvidence: Set<ExecutionEvidenceKind>,
        verifierAgent: String = "verifier"
    ) -> AgentLoopVerificationReduction {
        let verification = existingVerification ?? CompletionVerification(verified: [], notVerified: [])
        let payload = parseVerifierPayloadForTests(from: rawText)
        let verificationState = buildVerificationState(
            payload: payload,
            verification: verification,
            executionEvidence: executionEvidence,
            fallbackSummary: rawText
        )
        let certificate = verificationState.certificate
        let update = VerificationAssessmentUpdate(
            passed: certificate?.decision == .pass,
            summary: certificate?.stopReason ?? rawText,
            missingEvidence: verificationState.openQuestions,
            riskAreas: certificate?.residualRisks ?? [],
            recommendedNextAction: payload?.recommendedNextAction,
            verifierAgent: verifierAgent,
            verificationState: verificationState
        )
        var report = verification
        report.applyAssessment(update)
        report.recordedAt = Date()
        let failureTrigger = update.passed ? nil : FailureTrigger.verificationFailure(detail: update.summary)
        return AgentLoopVerificationReduction(
            report: report,
            verificationState: verificationState,
            failureTrigger: failureTrigger
        )
    }

    private static func buildClaims(from verification: CompletionVerification) -> [VerificationClaim] {
        let supported = verification.verified.map { text in
            VerificationClaim(
                id: claimID(for: text),
                text: text,
                claimType: claimType(for: text),
                importance: 0.9,
                verifiability: 0.7,
                status: .supported,
                evidenceRefs: []
            )
        }
        let unsupported = verification.notVerified.map { text in
            VerificationClaim(
                id: claimID(for: text),
                text: text,
                claimType: claimType(for: text),
                importance: 0.7,
                verifiability: 0.5,
                status: .contradicted,
                evidenceRefs: []
            )
        }
        return supported + unsupported
    }

    private static func buildEvidence(from executionEvidence: Set<ExecutionEvidenceKind>) -> [VerificationEvidence] {
        executionEvidence.sorted(by: { $0.rawValue < $1.rawValue }).map { evidence in
            VerificationEvidence(
                id: "evidence-\(evidence.rawValue)",
                source: evidence.rawValue,
                summary: evidence.rawValue,
                strength: 0.8,
                sourceRefs: ["execution:\(evidence.rawValue)"]
            )
        }
    }

    private static func buildFrontier(from payload: VerifierPayload?, claims: [VerificationClaim]) -> [VerificationFrontierItem] {
        let ranking = payload?.frontierRanking ?? []
        if !ranking.isEmpty {
            return ranking.map { item in
                let matchedClaim = claims.first { claim in
                    claim.id == item.claimID || item.reason.localizedCaseInsensitiveContains(claim.text)
                }
                let type = matchedClaim?.claimType ?? claimType(for: item.reason)
                return VerificationFrontierItem(
                    id: item.claimID,
                    claimID: matchedClaim?.id ?? item.claimID,
                    claimType: type,
                    openQuestion: item.reason,
                    recommendedProbe: item.recommendedProbe,
                    riskScore: type == .execution ? 0.9 : 0.7
                )
            }
        }

        return (payload?.missingEvidence ?? []).enumerated().map { index, question in
            let type = claimType(for: question)
            return VerificationFrontierItem(
                id: "frontier-\(index)",
                claimID: "claim-\(index)",
                claimType: type,
                openQuestion: question,
                recommendedProbe: payload?.recommendedNextAction ?? "gather_context",
                riskScore: type == .execution ? 0.9 : 0.6
            )
        }
    }

    private static func claimID(for text: String) -> String {
        let normalized = text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return "claim-\(normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-")))"
    }

    private static func claimType(for text: String) -> VerificationClaimType {
        let lowercased = text.lowercased()
        if lowercased.contains("pass") || lowercased.contains("build") || lowercased.contains("test") || lowercased.contains("run") || lowercased.contains("execut") {
            return .execution
        }
        if lowercased.contains("file") || lowercased.contains("path") || lowercased.contains("diff") {
            return .fileState
        }
        if lowercased.contains("cover") || lowercased.contains("requirement") {
            return .coverage
        }
        if lowercased.contains("policy") {
            return .policy
        }
        if lowercased.contains("citation") || lowercased.contains("source") {
            return .citation
        }
        if lowercased.contains("fact") || lowercased.contains("docs") || lowercased.contains("api") {
            return .factual
        }
        return .behavioral
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
    struct FrontierRankingItem: Codable, Equatable {
        let claimID: String
        let reason: String
        let recommendedProbe: String

        enum CodingKeys: String, CodingKey {
            case claimID = "claim_id"
            case reason
            case recommendedProbe = "recommended_probe"
        }

            init(claimID: String, reason: String, recommendedProbe: String) {
                self.claimID = claimID
                self.reason = reason
                self.recommendedProbe = recommendedProbe
            }
    }

    let passed: Bool
    let summary: String
    let verifiedItems: [String]
    let failedItems: [String]
    let missingEvidence: [String]
    let riskAreas: [String]
    let residualRisks: [String]
    let frontierRanking: [FrontierRankingItem]
    let recommendedNextAction: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case passed
        case summary
        case verifiedItems = "verified_items"
        case failedItems = "failed_items"
        case missingEvidence = "missing_evidence"
        case riskAreas = "risk_areas"
        case residualRisks = "residual_risks"
        case frontierRanking = "frontier_ranking"
        case recommendedNextAction = "recommended_next_action"
        case confidence
    }

    init(
        passed: Bool = false,
        summary: String = "",
        verifiedItems: [String] = [],
        failedItems: [String] = [],
        missingEvidence: [String] = [],
        riskAreas: [String] = [],
        residualRisks: [String] = [],
        frontierRanking: [FrontierRankingItem] = [],
        recommendedNextAction: String? = nil,
        confidence: Double? = nil
    ) {
        self.passed = passed
        self.summary = summary
        self.verifiedItems = verifiedItems
        self.failedItems = failedItems
        self.missingEvidence = missingEvidence
        self.riskAreas = riskAreas
        self.residualRisks = residualRisks
        self.frontierRanking = frontierRanking
        self.recommendedNextAction = recommendedNextAction
        self.confidence = confidence
    }

    init(
        frontierRanking: [FrontierRankingItem],
        missingEvidence: [String],
        residualRisks: [String],
        recommendedNextAction: String?
    ) {
        self.init(
            passed: false,
            summary: "",
            verifiedItems: [],
            failedItems: [],
            missingEvidence: missingEvidence,
            riskAreas: [],
            residualRisks: residualRisks,
            frontierRanking: frontierRanking,
            recommendedNextAction: recommendedNextAction,
            confidence: nil
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passed = try container.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        verifiedItems = try container.decodeIfPresent([String].self, forKey: .verifiedItems) ?? []
        failedItems = try container.decodeIfPresent([String].self, forKey: .failedItems) ?? []
        missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        riskAreas = try container.decodeIfPresent([String].self, forKey: .riskAreas) ?? []
        residualRisks = try container.decodeIfPresent([String].self, forKey: .residualRisks) ?? []
        frontierRanking = try container.decodeIfPresent([FrontierRankingItem].self, forKey: .frontierRanking) ?? []
        recommendedNextAction = try container.decodeIfPresent(String.self, forKey: .recommendedNextAction)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
    }
}
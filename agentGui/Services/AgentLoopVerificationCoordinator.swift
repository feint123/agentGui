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
        let evidenceText = executionEvidence.isEmpty
            ? "none"
            : executionEvidence.map(\.rawValue).sorted().joined(separator: ", ")
        let verifiedText = verification.verified.isEmpty
            ? "- none"
            : verification.verified.map { "- \($0)" }.joined(separator: "\n")
        let notVerifiedText = verification.notVerified.isEmpty
            ? "- none"
            : verification.notVerified.map { "- \($0)" }.joined(separator: "\n")

        // Keep the verifier task self-contained because the subagent cannot ask follow-ups.
        return """
        You are a completion verifier. Your job is to assess whether the host agent genuinely completed its task based on the evidence provided. You do NOT re-execute the task or ask for more information.

        ## CRITICAL: Understanding execution evidence

        The "execution evidence kinds" field tells you what execution-capable tools were actually invoked during the agent's run:
        - **bash** — bash commands were executed in a real terminal session. The agent ran shell commands.
        - **builtinTool** — built-in tools (file editor, web search, etc.) were used to produce a result.
        - **executorSubagent** — an executor subagent was delegated to carry out work.
        - **workflow** — a workflow was launched and completed.

        If execution evidence is present, real execution happened. You are NOT entitled to demand additional proof.

        ## CRITICAL: Side-effect operations produce no visible output

        Many shell operations produce zero stdout output on success — this is correct POSIX behavior:
        - File/directory deletion (`rm`, `rmdir`) — silent on success
        - File moves and renames (`mv`) — silent on success
        - Permission changes (`chmod`, `chown`) — silent on success
        - Directory creation (`mkdir`) — silent on success
        - Writing to files, git commits, `git add` — often silent

        Do NOT reject a completion as "unverified" just because the operation left no terminal output. Empty output from bash is evidence of success for these operations.

        ## What to assess

        Set `passed: true` when ALL of the following hold:
        1. If execution was required, execution evidence is present (bash/builtinTool/executorSubagent/workflow).
        2. The agent's answer is consistent with having completed the task (no contradictions, no unexplained failures).
        3. There is no explicit error message or failure in the answer.
        4. The task does not require a verifiable output that is conspicuously absent (e.g., a test run with no output when output was expected, or a file creation with no confirmation).

        Set `passed: false` only when:
        - Execution evidence is absent but the task clearly required execution (e.g., the agent claims to have run code but no bash/tool evidence exists).
        - The agent's own answer reports a failure or error.
        - There is a concrete, specific contradiction between the claimed outcome and known facts.

        ## Context

        Current answer / final agent response:
        \(currentAnswer)

        Execution evidence (tools actually invoked):
        \(evidenceText)

        Structured verification record (from verify_completion call, if any):
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
import Foundation

struct MemoryDecisionImpactEvaluator {
    func assess(
        candidate: MemoryCandidate,
        request: MemoryRuntimeRequest,
        epistemicState: EpistemicState
    ) -> MemoryDecisionImpactAssessment {
        let lowerSummary = candidate.summary.lowercased()
        let lowerTitle = candidate.title.lowercased()
        let lowerRequest = request.userRequest.lowercased()

        let decisionDeltaValue = decisionDeltaValue(
            for: candidate,
            lowerSummary: lowerSummary,
            lowerTitle: lowerTitle,
            lowerRequest: lowerRequest,
            epistemicState: epistemicState
        )
        let transferValue = transferValue(for: candidate, lowerSummary: lowerSummary, lowerTitle: lowerTitle)
        let evidenceValue = evidenceValue(for: candidate)
        let decayResistance = decayResistanceValue(for: candidate, lowerSummary: lowerSummary)

        return MemoryDecisionImpactAssessment(
            decisionDelta: MemoryAdmissionGateResult(
                passes: decisionDeltaValue >= 0.5,
                value: decisionDeltaValue,
                rationale: decisionDeltaValue >= 0.65
                    ? "candidate changes action ordering or stop/go behavior"
                    : "candidate does not materially change the next action"
            ),
            transfer: MemoryAdmissionGateResult(
                passes: transferValue >= 0.55,
                value: transferValue,
                rationale: transferValue >= 0.55
                    ? "candidate is reusable across similar task families"
                    : "candidate appears too local or cosmetic to transfer"
            ),
            evidence: MemoryAdmissionGateResult(
                passes: evidenceValue >= 0.6,
                value: evidenceValue,
                rationale: evidenceValue >= 0.6
                    ? "candidate is backed by direct runtime evidence"
                    : "candidate lacks direct evidence anchors"
            ),
            decay: MemoryAdmissionGateResult(
                passes: decayResistance >= 0.45,
                value: decayResistance,
                rationale: decayResistance >= 0.45
                    ? "candidate is stable enough to survive beyond this exact run"
                    : "candidate is too environment-bound or fast-decaying"
            )
        )
    }

    private func decisionDeltaValue(
        for candidate: MemoryCandidate,
        lowerSummary: String,
        lowerTitle: String,
        lowerRequest: String,
        epistemicState: EpistemicState
    ) -> Double {
        var value = 0.2

        let actionKeywords = ["run ", "rerun", "inspect", "verify", "test", "avoid", "block", "confirm", "scheme", "build", "probe"]
        if actionKeywords.contains(where: { lowerSummary.contains($0) || lowerTitle.contains($0) }) {
            value += 0.35
        }

        if candidate.tags.contains(where: { ["counterexample", "anti-pattern", "tactic-kernel", "constraint", "verification-debt"].contains($0) }) {
            value += 0.25
        }

        if epistemicState.frontiers.contains(where: {
            let claim = $0.openClaim.lowercased()
            return lowerSummary.contains(claim) || claim.contains(lowerSummary) || lowerRequest.contains(claim)
        }) {
            value += 0.2
        }

        if candidate.layer == .instant || candidate.layer == .episodic {
            value -= 0.1
        }

        if lowerSummary.contains("readme") || lowerTitle.contains("readme") || lowerSummary.contains("subtitle") {
            value = min(value, 0.3)
        }

        return value.clamped(to: 0...1)
    }

    private func transferValue(for candidate: MemoryCandidate, lowerSummary: String, lowerTitle: String) -> Double {
        var value = 0.25

        if candidate.domainProfile == "coding-task" {
            value += 0.2
        }
        if candidate.kind == .procedural || candidate.tags.contains("tactic-kernel") || candidate.tags.contains("counterexample") {
            value += 0.35
        }
        if isReusableScope(candidate.scope) {
            value += 0.1
        }
        if lowerSummary.contains("this run") || lowerSummary.contains("temporary") || lowerTitle.contains("attempt ") {
            value -= 0.3
        }

        return value.clamped(to: 0...1)
    }

    private func evidenceValue(for candidate: MemoryCandidate) -> Double {
        var value = candidate.confidence.clamped(to: 0...1) * 0.35

        if candidate.verificationStatus == .verified {
            value += 0.4
        } else if candidate.verificationStatus == .partial {
            value += 0.2
        }

        if !candidate.sourceRefs.isEmpty {
            value += 0.25
        }

        return value.clamped(to: 0...1)
    }

    private func decayResistanceValue(for candidate: MemoryCandidate, lowerSummary: String) -> Double {
        var value = 0.6

        if isSessionScope(candidate.scope) {
            value -= 0.15
        }
        if candidate.layer == .instant {
            value -= 0.2
        }
        if lowerSummary.contains("temporary") || lowerSummary.contains("today") || lowerSummary.contains("current run") {
            value -= 0.25
        }
        if candidate.tags.contains("tactic-kernel") || candidate.tags.contains("counterexample") {
            value += 0.15
        }

        return value.clamped(to: 0...1)
    }

    private func isReusableScope(_ scope: MemoryScope) -> Bool {
        switch scope {
        case .user, .workspace, .project:
            return true
        case .session, .thread, .workflowRun:
            return false
        }
    }

    private func isSessionScope(_ scope: MemoryScope) -> Bool {
        if case .session = scope {
            return true
        }
        return false
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

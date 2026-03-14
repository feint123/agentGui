import Foundation

struct EpistemicStateReducer {
    func reduce(
        _ output: EpistemicExtractionOutput,
        into state: EpistemicState,
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace()
    ) -> (state: EpistemicState, influenceTrace: MemoryInfluenceTrace) {
        var nextState = state
        var nextTrace = influenceTrace

        for object in output.objects {
            nextTrace.activatedMemoryIDs = appendUnique(object.id, to: nextTrace.activatedMemoryIDs)

            switch object.kind {
            case .frontier:
                if !object.decisionDelta.isEmpty {
                    nextState.candidateActions = appendUnique(object.decisionDelta, to: nextState.candidateActions)
                    nextTrace.rankedActionIDs = appendUnique(object.decisionDelta, to: nextTrace.rankedActionIDs)
                }
                let frontier = FrontierMemory(
                    frontierId: object.id,
                    goal: "Resolve active task",
                    openClaim: object.summary,
                    uncertaintyType: .unknown,
                    impactLevel: object.evidenceLevel == .verified ? .medium : .high,
                    suggestedProbe: object.decisionDelta,
                    stopCondition: object.evidenceLevel == .verified ? "Evidence confirmed" : "Evidence gathered"
                )
                upsertFrontier(frontier, into: &nextState.frontiers)

            case .constraint:
                let constraint = ConstraintMemory(
                    id: object.id,
                    summary: object.summary,
                    scope: .session(id: "epistemic-runtime")
                )
                upsertConstraint(constraint, into: &nextState.activeConstraints)

            case .verificationDebt:
                let debt = VerificationDebt(
                    id: object.id,
                    claim: object.summary,
                    reason: output.missingEvidence.first ?? object.decisionDelta
                )
                upsertDebt(debt, into: &nextState.verificationDebt)

            case .counterexample:
                let counterexample = CounterexampleMemory(
                    id: object.id,
                    summary: object.summary,
                    replacementAction: object.decisionDelta
                )
                upsertCounterexample(counterexample, into: &nextState.counterexamples)

            case .tacticKernel, .atomicEvent:
                continue
            }
        }

        nextState.activatedMemories = Array(Set(nextTrace.activatedMemoryIDs)).sorted()

        if !output.missingEvidence.isEmpty {
            for missing in output.missingEvidence {
                let debt = VerificationDebt(
                    id: "debt-\(missing)",
                    claim: missing,
                    reason: output.decisionImpactNote.isEmpty ? "Missing supporting evidence" : output.decisionImpactNote
                )
                upsertDebt(debt, into: &nextState.verificationDebt)
            }
        }

        return (nextState, nextTrace)
    }

    private func appendUnique(_ value: String, to array: [String]) -> [String] {
        guard !value.isEmpty else { return array }
        if array.contains(value) {
            return array
        }
        return array + [value]
    }

    private func upsertFrontier(_ frontier: FrontierMemory, into frontiers: inout [FrontierMemory]) {
        if let index = frontiers.firstIndex(where: { $0.frontierId == frontier.frontierId }) {
            frontiers[index] = frontier
        } else {
            frontiers.append(frontier)
        }
    }

    private func upsertConstraint(_ constraint: ConstraintMemory, into constraints: inout [ConstraintMemory]) {
        if let index = constraints.firstIndex(where: { $0.id == constraint.id }) {
            constraints[index] = constraint
        } else {
            constraints.append(constraint)
        }
    }

    private func upsertDebt(_ debt: VerificationDebt, into debts: inout [VerificationDebt]) {
        if let index = debts.firstIndex(where: { $0.id == debt.id }) {
            debts[index] = debt
        } else {
            debts.append(debt)
        }
    }

    private func upsertCounterexample(_ counterexample: CounterexampleMemory, into counterexamples: inout [CounterexampleMemory]) {
        if let index = counterexamples.firstIndex(where: { $0.id == counterexample.id }) {
            counterexamples[index] = counterexample
        } else {
            counterexamples.append(counterexample)
        }
    }
}
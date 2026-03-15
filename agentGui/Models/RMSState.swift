import Foundation

struct RMSFrontier: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var goal: String
    var openClaim: String
    var suggestedProbe: String
    var stopCondition: String
}

struct RMSConstraint: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var scope: MemoryScope
}

struct RMSCounterexample: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var replacementAction: String
}

struct RMSVerificationDebt: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var claim: String
    var reason: String
}

struct RMSState: Codable, Equatable, Sendable {
    var taskID: String
    var sessionID: String
    var threadID: String
    var summary: String
    var frontiers: [RMSFrontier]
    var constraints: [RMSConstraint]
    var counterexamples: [RMSCounterexample]
    var verificationDebts: [RMSVerificationDebt]
    var candidateActions: [String]
    var stopSignals: [String]
    var updatedAt: Date?

    init(
        taskID: String,
        sessionID: String,
        threadID: String,
        summary: String,
        frontiers: [RMSFrontier] = [],
        constraints: [RMSConstraint] = [],
        counterexamples: [RMSCounterexample] = [],
        verificationDebts: [RMSVerificationDebt] = [],
        candidateActions: [String] = [],
        stopSignals: [String] = [],
        updatedAt: Date? = nil
    ) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.threadID = threadID
        self.summary = summary
        self.frontiers = frontiers
        self.constraints = constraints
        self.counterexamples = counterexamples
        self.verificationDebts = verificationDebts
        self.candidateActions = candidateActions
        self.stopSignals = stopSignals
        self.updatedAt = updatedAt
    }
}

extension RMSState {
    nonisolated func stableSnapshot() -> RMSState {
        let trim: (String) -> String = { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var snapshot = self
        snapshot.taskID = trim(taskID)
        snapshot.sessionID = trim(sessionID)
        snapshot.threadID = trim(threadID)
        snapshot.summary = trim(summary)
        snapshot.frontiers = frontiers.compactMap { frontier in
            let openClaim = trim(frontier.openClaim)
            guard !openClaim.isEmpty else {
                return nil
            }

            return RMSFrontier(
                id: trim(frontier.id),
                goal: trim(frontier.goal),
                openClaim: openClaim,
                suggestedProbe: trim(frontier.suggestedProbe),
                stopCondition: trim(frontier.stopCondition)
            )
        }
        snapshot.constraints = constraints.compactMap { constraint in
            let summary = trim(constraint.summary)
            guard !summary.isEmpty else {
                return nil
            }

            return RMSConstraint(
                id: trim(constraint.id),
                summary: summary,
                scope: constraint.scope
            )
        }
        snapshot.counterexamples = counterexamples.compactMap { counterexample in
            let summary = trim(counterexample.summary)
            guard !summary.isEmpty else {
                return nil
            }

            return RMSCounterexample(
                id: trim(counterexample.id),
                summary: summary,
                replacementAction: trim(counterexample.replacementAction)
            )
        }
        snapshot.verificationDebts = verificationDebts.compactMap { debt in
            let claim = trim(debt.claim)
            guard !claim.isEmpty else {
                return nil
            }

            return RMSVerificationDebt(
                id: trim(debt.id),
                claim: claim,
                reason: trim(debt.reason)
            )
        }
        snapshot.candidateActions = candidateActions.map(trim).filter { !$0.isEmpty }
        snapshot.stopSignals = stopSignals.map(trim).filter { !$0.isEmpty }
        return snapshot
    }

    static func fixture(
        taskID: String = "task-1",
        sessionID: String = "session-1",
        threadID: String = "thread-1",
        summary: String = "Fixture summary",
        frontiers: [RMSFrontier] = [],
        constraints: [RMSConstraint] = [],
        counterexamples: [RMSCounterexample] = [],
        verificationDebts: [RMSVerificationDebt] = [],
        candidateActions: [String] = [],
        stopSignals: [String] = [],
        updatedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RMSState {
        RMSState(
            taskID: taskID,
            sessionID: sessionID,
            threadID: threadID,
            summary: summary,
            frontiers: frontiers,
            constraints: constraints,
            counterexamples: counterexamples,
            verificationDebts: verificationDebts,
            candidateActions: candidateActions,
            stopSignals: stopSignals,
            updatedAt: updatedAt
        )
    }
}
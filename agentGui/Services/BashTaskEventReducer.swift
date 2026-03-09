import Foundation

struct TerminalTaskObservation: Equatable, Sendable {
    var appendedOutput: String
    var processIsAlive: Bool
    var idleDuration: TimeInterval
    var promptDecision: TerminalPromptDecision?
    var didBackgroundLaunch: Bool
    var didTimeout: Bool
    var exitCode: Int?
    var observedAt: Date

    init(
        appendedOutput: String,
        processIsAlive: Bool,
        idleDuration: TimeInterval,
        promptDecision: TerminalPromptDecision?,
        didBackgroundLaunch: Bool,
        didTimeout: Bool,
        exitCode: Int?,
        observedAt: Date = Date()
    ) {
        self.appendedOutput = appendedOutput
        self.processIsAlive = processIsAlive
        self.idleDuration = idleDuration
        self.promptDecision = promptDecision
        self.didBackgroundLaunch = didBackgroundLaunch
        self.didTimeout = didTimeout
        self.exitCode = exitCode
        self.observedAt = observedAt
    }
}

struct TerminalTaskReduction: Equatable, Sendable {
    var snapshot: TerminalTaskSnapshot
    var events: [TerminalTaskEvent]
}

struct BashTaskEventReducer {
    private let promptIdleThreshold: TimeInterval = 0.75

    func reduce(previous: TerminalTaskSnapshot, observation: TerminalTaskObservation) -> TerminalTaskReduction {
        var snapshot = previous
        var events: [TerminalTaskEvent] = []

        snapshot.lastScanAt = observation.observedAt

        if !observation.appendedOutput.isEmpty {
            snapshot.latestOutputSnippet = observation.appendedOutput
            events.append(
                TerminalTaskEvent(
                    taskId: snapshot.id,
                    timestamp: observation.observedAt,
                    kind: .output,
                    summary: "Received terminal output",
                    rawText: observation.appendedOutput
                )
            )
        }

        if observation.didTimeout {
            snapshot.status = .timedOut
            snapshot.prompt = nil
            snapshot.endedAt = observation.observedAt
            events.append(stateChangedEvent(taskId: snapshot.id, timestamp: observation.observedAt, status: .timedOut))
            return TerminalTaskReduction(snapshot: snapshot, events: events)
        }

        if let exitCode = observation.exitCode, !observation.processIsAlive {
            snapshot.status = exitCode == 0 ? .completed : .failed
            snapshot.prompt = nil
            snapshot.endedAt = observation.observedAt
            events.append(
                TerminalTaskEvent(
                    taskId: snapshot.id,
                    timestamp: observation.observedAt,
                    kind: .processExit,
                    summary: exitCode == 0 ? "Process exited successfully" : "Process exited with code \(exitCode)",
                    rawText: observation.appendedOutput,
                    structuredPayloadJSON: "{\"exitCode\":\(exitCode)}"
                )
            )
            return TerminalTaskReduction(snapshot: snapshot, events: events)
        }

        if observation.didBackgroundLaunch {
            snapshot.status = .runningBackground
            snapshot.prompt = nil
            events.append(
                TerminalTaskEvent(
                    taskId: snapshot.id,
                    timestamp: observation.observedAt,
                    kind: .backgroundRegistered,
                    summary: "Background task registered",
                    rawText: observation.appendedOutput
                )
            )
            return TerminalTaskReduction(snapshot: snapshot, events: events)
        }

        if let promptDecision = observation.promptDecision, observation.idleDuration >= promptIdleThreshold {
            snapshot.prompt = promptDecision.snapshot
            snapshot.riskLevel = riskLevel(for: promptDecision.snapshot.kind)

            events.append(
                TerminalTaskEvent(
                    taskId: snapshot.id,
                    timestamp: observation.observedAt,
                    kind: .promptDetected,
                    summary: "Prompt detected: \(promptDecision.snapshot.kind.rawValue)",
                    rawText: promptDecision.snapshot.promptText
                )
            )

            if promptDecision.shouldAutoReply {
                snapshot.status = .waitingForPrompt
                events.append(stateChangedEvent(taskId: snapshot.id, timestamp: observation.observedAt, status: .waitingForPrompt))
            } else {
                snapshot.status = .needsUserDecision
                events.append(
                    TerminalTaskEvent(
                        taskId: snapshot.id,
                        timestamp: observation.observedAt,
                        kind: .userDecisionRequested,
                        summary: promptDecision.escalationReason ?? "User decision required",
                        rawText: promptDecision.snapshot.promptText
                    )
                )
            }

            return TerminalTaskReduction(snapshot: snapshot, events: events)
        }

        snapshot.prompt = nil
        return TerminalTaskReduction(snapshot: snapshot, events: events)
    }

    private func riskLevel(for kind: TerminalPromptKind) -> TerminalRiskLevel {
        switch kind {
        case .secret, .destructiveConfirmation:
            return .high
        case .textInput, .pathInput, .singleChoice, .multiChoice, .unknown:
            return .medium
        case .yesNo, .pressEnter:
            return .low
        }
    }

    private func stateChangedEvent(
        taskId: String,
        timestamp: Date,
        status: TerminalTaskStatus
    ) -> TerminalTaskEvent {
        TerminalTaskEvent(
            taskId: taskId,
            timestamp: timestamp,
            kind: .stateChanged,
            summary: "Task state changed to \(status.rawValue)"
        )
    }
}
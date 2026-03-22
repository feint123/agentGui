import Foundation

@MainActor
final class ACPExternalUpdateProjector {
    private struct SessionState {
        var pendingAssistantText = ""
        var pendingThinkingText = ""
        var toolStates: [String: ToolState] = [:]

        var isEmpty: Bool {
            pendingAssistantText.isEmpty
                && pendingThinkingText.isEmpty
                && toolStates.values.allSatisfy(\ .isEmpty)
        }
    }

    private struct ToolState {
        var lastProjectedOutputLength = 0
        var pendingUpdate: PendingToolUpdate?

        var isEmpty: Bool {
            pendingUpdate == nil
        }
    }

    private struct PendingToolUpdate: Equatable {
        let id: String
        var kind: ToolKind?
        var title: String?
        var filePath: String?
        var status: ToolStatus?
        var rawOutput: String?

        mutating func merge(
            kind: ToolKind?,
            title: String?,
            filePath: String?,
            status: ToolStatus?,
            rawOutput: String?
        ) {
            if let kind {
                self.kind = kind
            }
            if let title {
                self.title = title
            }
            if let filePath {
                self.filePath = filePath
            }
            if let status {
                self.status = status
            }
            if let rawOutput {
                self.rawOutput = rawOutput
            }
        }

        var event: ACPExternalAgentNormalizedEvent {
            .toolCallUpdated(
                id: id,
                kind: kind,
                title: title,
                filePath: filePath,
                status: status,
                rawOutput: rawOutput
            )
        }
    }

    private let textThreshold: Int
    private let thinkingThreshold: Int
    private let toolOutputThreshold: Int

    private var sessionStates: [String: SessionState] = [:]

    init(
        textThreshold: Int = 50,
        thinkingThreshold: Int = 50,
        toolOutputThreshold: Int = 80
    ) {
        self.textThreshold = textThreshold
        self.thinkingThreshold = thinkingThreshold
        self.toolOutputThreshold = toolOutputThreshold
    }

    func project(
        events: [ACPExternalAgentNormalizedEvent],
        sessionID: String
    ) -> [ACPExternalAgentNormalizedEvent] {
        var state = sessionStates[sessionID] ?? SessionState()
        var projected: [ACPExternalAgentNormalizedEvent] = []

        for event in events {
            projected.append(contentsOf: project(event: event, state: &state))
        }

        if state.isEmpty {
            sessionStates.removeValue(forKey: sessionID)
        } else {
            sessionStates[sessionID] = state
        }

        return projected
    }

    func flush(sessionID: String) -> [ACPExternalAgentNormalizedEvent] {
        guard var state = sessionStates[sessionID] else {
            return []
        }

        var projected: [ACPExternalAgentNormalizedEvent] = []

        if !state.pendingAssistantText.isEmpty {
            projected.append(.assistantTextDelta(state.pendingAssistantText))
            state.pendingAssistantText = ""
        }

        if !state.pendingThinkingText.isEmpty {
            projected.append(.thinkingDelta(state.pendingThinkingText))
            state.pendingThinkingText = ""
        }

        for toolID in state.toolStates.keys.sorted() {
            guard let pending = state.toolStates[toolID]?.pendingUpdate else {
                continue
            }
            projected.append(pending.event)
            state.toolStates[toolID]?.pendingUpdate = nil
            state.toolStates[toolID]?.lastProjectedOutputLength = pending.rawOutput?.count ?? 0
        }

        sessionStates.removeValue(forKey: sessionID)
        return projected
    }

    func reset(sessionID: String) {
        sessionStates.removeValue(forKey: sessionID)
    }

    private func project(
        event: ACPExternalAgentNormalizedEvent,
        state: inout SessionState
    ) -> [ACPExternalAgentNormalizedEvent] {
        switch event {
        case .assistantTextDelta(let delta):
            state.pendingAssistantText += delta
            guard state.pendingAssistantText.count >= textThreshold else {
                return []
            }
            let projectedText = state.pendingAssistantText
            state.pendingAssistantText = ""
            return [.assistantTextDelta(projectedText)]

        case .thinkingDelta(let delta):
            state.pendingThinkingText += delta
            guard state.pendingThinkingText.count >= thinkingThreshold else {
                return []
            }
            let projectedThinking = state.pendingThinkingText
            state.pendingThinkingText = ""
            return [.thinkingDelta(projectedThinking)]

        case .toolCallStarted:
            return [event]

        case .toolCallUpdated(let id, let kind, let title, let filePath, let status, let rawOutput):
            return projectToolUpdate(
                id: id,
                kind: kind,
                title: title,
                filePath: filePath,
                status: status,
                rawOutput: rawOutput,
                state: &state
            )

        case .permissionRequested:
            return [event]
        }
    }

    private func projectToolUpdate(
        id: String,
        kind: ToolKind?,
        title: String?,
        filePath: String?,
        status: ToolStatus?,
        rawOutput: String?,
        state: inout SessionState
    ) -> [ACPExternalAgentNormalizedEvent] {
        var toolState = state.toolStates[id] ?? ToolState()
        var pending = toolState.pendingUpdate ?? PendingToolUpdate(
            id: id,
            kind: nil,
            title: nil,
            filePath: nil,
            status: nil,
            rawOutput: nil
        )

        pending.merge(
            kind: kind,
            title: title,
            filePath: filePath,
            status: status,
            rawOutput: rawOutput
        )

        if let rawOutput = pending.rawOutput, !rawOutput.isEmpty {
            let isTerminalStatus = pending.status.map { $0 != .inProgress } ?? false
            let outputDelta = rawOutput.count - toolState.lastProjectedOutputLength
            let shouldProject = isTerminalStatus || outputDelta >= toolOutputThreshold

            if shouldProject {
                toolState.pendingUpdate = nil
                toolState.lastProjectedOutputLength = rawOutput.count
                state.toolStates[id] = toolState
                return [pending.event]
            }

            toolState.pendingUpdate = pending
            state.toolStates[id] = toolState
            return []
        }

        toolState.pendingUpdate = nil
        state.toolStates[id] = toolState
        return [pending.event]
    }
}
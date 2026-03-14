import Foundation

enum ToolExecutionBusinessLogger {
    static func emitAudit(
        record: ToolCall,
        context: AgentLoopHookContext,
        sink: BusinessLogSink? = nil
    ) {
        let metadata = auditMetadata(for: record)
        guard !metadata.isEmpty else { return }

        BusinessMonitor.emit(
            .toolAuditRecorded,
            context: BusinessLogContext(
                runID: context.runID,
                sessionID: context.sessionID.isEmpty ? nil : context.sessionID,
                workflowID: context.workflowID,
                roundIndex: context.roundIndex,
                toolName: context.pendingToolName ?? record.title,
                phase: context.phase
            ),
            metadata: metadata,
            sink: sink
        )
    }

    static func auditMetadata(for record: ToolCall) -> [String: Any] {
        var metadata: [String: Any] = [
            "toolCallId": record.toolCallId,
            "toolKind": record.kind.rawValue,
            "toolStatus": record.status.rawValue
        ]

        put(record.title, into: &metadata, key: "toolTitle")
        put(record.toolDefinitionID, into: &metadata, key: "toolDefinitionID")
        put(record.toolSchemaVersion, into: &metadata, key: "toolSchemaVersion")
        put(record.toolExposureSource, into: &metadata, key: "toolExposureSource")
        put(record.toolExecutionContext, into: &metadata, key: "toolExecutionContext")
        put(record.toolPayloadRef, into: &metadata, key: "toolPayloadRef")
        put(record.toolResultSummary, into: &metadata, key: "toolResultSummary")
        put(record.toolResultRawChars, into: &metadata, key: "toolResultRawChars")
        put(record.toolResultInjectedChars, into: &metadata, key: "toolResultInjectedChars")
        put(record.toolResultInjectionMode, into: &metadata, key: "toolResultInjectionMode")
        put(record.toolPayloadReadCount, into: &metadata, key: "toolPayloadReadCount")
        put(record.toolPayloadLastReadRange, into: &metadata, key: "toolPayloadLastReadRange")
        put(record.terminalTaskId, into: &metadata, key: "terminalTaskId")
        put(record.terminalTaskStatus, into: &metadata, key: "terminalTaskStatus")
        put(record.terminalExecutionMode, into: &metadata, key: "terminalExecutionMode")
        put(record.terminalPromptSummary, into: &metadata, key: "terminalPromptSummary")
        put(record.terminalAgentActionsJSON, into: &metadata, key: "terminalAgentActionsJSON")
        put(record.memoryRuntimeSnapshotID, into: &metadata, key: "memoryRuntimeSnapshotID")
        put(record.memoryRuntimeIntentPhase, into: &metadata, key: "memoryRuntimeIntentPhase")
        put(record.memoryRuntimeWorkingSetCost, into: &metadata, key: "memoryRuntimeWorkingSetCost")
        put(record.memoryRuntimeDereferenceCount, into: &metadata, key: "memoryRuntimeDereferenceCount")
        put(joined(record.memoryRuntimeProfiles), into: &metadata, key: "memoryRuntimeProfiles")
        put(joined(record.memoryRuntimeLayers), into: &metadata, key: "memoryRuntimeLayers")
        put(joined(record.memoryRuntimeWarnings), into: &metadata, key: "memoryRuntimeWarnings")
        put(record.memoryBackgroundConsolidationQueued, into: &metadata, key: "memoryBackgroundConsolidationQueued")
        put(joined(record.memoryConflictRecordIDs), into: &metadata, key: "memoryConflictRecordIDs")
        put(joined(record.memoryConfirmationCandidateIDs), into: &metadata, key: "memoryConfirmationCandidateIDs")

        return metadata
    }

    private static func joined(_ values: [String]?) -> String? {
        guard let values else { return nil }
        let filtered = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: ",")
    }

    private static func put(_ value: String?, into metadata: inout [String: Any], key: String) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        metadata[key] = value
    }

    private static func put(_ value: Int?, into metadata: inout [String: Any], key: String) {
        guard let value else { return }
        metadata[key] = value
    }

    private static func put(_ value: Bool?, into metadata: inout [String: Any], key: String) {
        guard let value else { return }
        metadata[key] = value
    }
}
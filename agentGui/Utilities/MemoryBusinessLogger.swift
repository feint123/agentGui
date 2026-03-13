import Foundation

enum MemoryBusinessLogger {
    static func emit(
        _ event: AgentBusinessEvent,
        request: MemoryRuntimeRequest? = nil,
        metadata: [String: Any] = [:],
        sink: BusinessLogSink? = nil
    ) {
        BusinessMonitor.emit(
            event,
            context: BusinessLogContext(
                sessionID: request?.sessionId,
                workflowID: request?.workflowRunId,
                phase: "memory"
            ),
            metadata: metadata,
            sink: sink
        )
    }

    static func emit(
        _ event: AgentBusinessEvent,
        candidate: MemoryCandidate,
        metadata: [String: Any] = [:],
        sink: BusinessLogSink? = nil
    ) {
        var combined = metadata
        combined["candidateID"] = candidate.id
        combined["layer"] = candidate.layer.rawValue
        combined["kind"] = candidate.kind.rawValue
        combined["scope"] = candidate.scope.namespace
        combined["domainProfile"] = candidate.domainProfile
        combined["confidence"] = candidate.confidence
        combined["verificationStatus"] = candidate.verificationStatus.rawValue

        BusinessMonitor.emit(
            event,
            context: BusinessLogContext(
                sessionID: sessionID(from: candidate.scope),
                phase: "memory"
            ),
            metadata: combined,
            sink: sink
        )
    }

    static func emit(
        _ event: AgentBusinessEvent,
        job: MemoryBackgroundJob,
        metadata: [String: Any] = [:],
        sink: BusinessLogSink? = nil
    ) {
        var combined = metadata
        combined["jobID"] = job.id
        combined["jobType"] = job.type.rawValue
        combined["status"] = job.status.rawValue
        combined["attemptCount"] = job.attemptCount
        if let scopeNamespace = job.scopeNamespace {
            combined["scope"] = scopeNamespace
        }

        BusinessMonitor.emit(
            event,
            context: BusinessLogContext(
                sessionID: job.request?.sessionId,
                workflowID: job.request?.workflowRunId,
                phase: "memory"
            ),
            metadata: combined,
            sink: sink
        )
    }

    private static func sessionID(from scope: MemoryScope) -> String? {
        switch scope {
        case let .session(id):
            return id
        default:
            return nil
        }
    }
}
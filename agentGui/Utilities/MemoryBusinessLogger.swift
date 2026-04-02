import Foundation

enum MemoryBusinessLogger {
    static func emit(
        _ event: AgentBusinessEvent,
        metadata: [String: Any] = [:],
        sink: BusinessLogSink? = nil
    ) {
        BusinessMonitor.emit(
            event,
            context: BusinessLogContext(
                sessionID: nil,
                workflowID: nil,
                phase: "memory"
            ),
            metadata: metadata,
            sink: sink
        )
    }
}
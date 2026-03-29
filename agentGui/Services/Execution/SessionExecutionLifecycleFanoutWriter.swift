import Foundation

@MainActor
final class SessionExecutionLifecycleFanoutWriter: SessionExecutionProjectionWriting {
    private let projectionWriter: any SessionExecutionProjectionWriting
    private let runtimeStateWriter: SessionExecutionRuntimeStateStore

    init(
        projectionWriter: any SessionExecutionProjectionWriting,
        runtimeStateWriter: SessionExecutionRuntimeStateStore
    ) {
        self.projectionWriter = projectionWriter
        self.runtimeStateWriter = runtimeStateWriter
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projectionWriter.projection(for: sessionID)
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        projectionWriter.apply(event)
        runtimeStateWriter.apply(event)
    }
}
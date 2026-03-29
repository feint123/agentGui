import Foundation

@MainActor
final class SessionExecutionLifecycleFanoutWriter: SessionExecutionProjectionWriting {
    private let projectionWriter: any SessionExecutionProjectionWriting
    private let runtimeBus: SessionRuntimeBus

    init(
        projectionWriter: any SessionExecutionProjectionWriting,
        runtimeBus: SessionRuntimeBus
    ) {
        self.projectionWriter = projectionWriter
        self.runtimeBus = runtimeBus
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projectionWriter.projection(for: sessionID)
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        guard let runtimeEvent = event.runtimeEvent else {
            projectionWriter.apply(event)
            return
        }

        runtimeBus.publish(runtimeEvent)
        projectionWriter.apply(runtimeSnapshot: runtimeBus.snapshot(for: runtimeEvent.sessionID))
        projectionWriter.apply(event)
    }
}
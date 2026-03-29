import Foundation

actor CodeEditorHighlightScheduler {
    struct ScheduledWork: Sendable {
        let request: CodeEditorHighlightRequest
        let textSnapshot: String
    }

    typealias WorkExecutor = @Sendable (ScheduledWork) async -> CodeEditorHighlightResult?
    typealias ResultHandler = @Sendable (CodeEditorHighlightResult) async -> Void

    private var inFlightTask: Task<Void, Never>?
    private var newestVersion: Int = 0

    func schedule(
        _ work: ScheduledWork,
        debounceNanoseconds: UInt64,
        execute: @escaping WorkExecutor,
        onResult: @escaping ResultHandler
    ) {
        newestVersion = max(newestVersion, work.request.version)
        inFlightTask?.cancel()
        inFlightTask = Task {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else {
                return
            }
            guard let result = await execute(work) else {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            guard await self.shouldPublish(resultVersion: result.version) else {
                return
            }
            await onResult(result)
        }
    }

    func cancel() {
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    private func shouldPublish(resultVersion: Int) -> Bool {
        resultVersion >= newestVersion
    }
}
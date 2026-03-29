import Foundation

actor ChatMessageListProjectionWorker: ChatMessageListProjectionWorking {
    func build(request: ChatMessageListBuildRequest) async throws -> ChatMessageListBuildResult {
        if Task.isCancelled {
            throw CancellationError()
        }

        let result = ChatMessageListSnapshotBuilder.build(request: request)

        if Task.isCancelled {
            throw CancellationError()
        }

        return result
    }
}
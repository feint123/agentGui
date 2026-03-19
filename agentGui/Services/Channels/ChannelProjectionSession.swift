import Foundation

@MainActor
protocol ChannelProjectionSession: AnyObject {
    func ingest(_ event: AgentLoopProjectionEvent) async throws
    func close() async
}

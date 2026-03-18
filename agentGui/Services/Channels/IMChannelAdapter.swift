import Foundation

protocol IMChannelAdapter: AnyObject {
    var kind: IMChannelKind { get }

    func start(configuration: IMChannelConfiguration) async throws
    func stop() async
    func send(_ message: OutboundChannelMessage) async throws -> String
}
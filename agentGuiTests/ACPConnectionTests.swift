import Foundation
import Testing
@testable import agentGui

struct ACPConnectionTests {

    @Test func notificationHandlerErrorsAreReportedToErrorObservers() async throws {
        let incomingPipe = Pipe()
        let outgoingPipe = Pipe()
        let router = ACPMessageRouter()
        let recorder = ACPErrorRecorder()
        let connection = ACPConnection(
            transport: ACPTransport(reader: incomingPipe.fileHandleForReading, writer: outgoingPipe.fileHandleForWriting),
            router: router
        )

        router.onNotification("session/update") { _ in
            throw ACPRequestError.internalError(data: .object(["reason": .string("boom")]))
        }

        await connection.addErrorObserver { error in
            await recorder.record(error)
        }
        await connection.start()

        try incomingPipe.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}\n".utf8))
        try await Task.sleep(for: .milliseconds(100))

        let messages = await recorder.messages
        #expect(messages.count == 1)
        #expect(messages[0].contains("Internal error"))

        await connection.close()
        try? incomingPipe.fileHandleForWriting.close()
        try? outgoingPipe.fileHandleForReading.close()
    }
}

private actor ACPErrorRecorder {
    private(set) var messages: [String] = []

    func record(_ error: Error) {
        messages.append(error.localizedDescription)
    }
}
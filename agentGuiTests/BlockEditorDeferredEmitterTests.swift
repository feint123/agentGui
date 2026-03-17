import Foundation
import Testing
@testable import agentGui

@MainActor
struct BlockEditorDeferredEmitterTests {

    @Test func emitterDefersDeliveryToNextRunLoopTurn() async throws {
        var delivered: [Int] = []
        let emitter = BlockEditorDeferredEmitter<Int> { delivered.append($0) }

        emitter.send(1)
        #expect(delivered.isEmpty)

        await Task.yield()
        #expect(delivered == [1])
    }

    @Test func emitterCoalescesRepeatedValuesBeforeDelivery() async throws {
        var delivered: [Int] = []
        let emitter = BlockEditorDeferredEmitter<Int> { delivered.append($0) }

        emitter.send(1)
        emitter.send(2)
        emitter.send(2)

        await Task.yield()
        #expect(delivered == [2])
    }
}
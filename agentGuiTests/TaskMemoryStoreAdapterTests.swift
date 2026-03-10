import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryStoreAdapterTests {
    @Test func taskMemoryAdapterBuildsTaskLayerRecords() async throws {
        let memory = TaskMemory(sessionId: "session-1")
        let adapter = TaskMemoryStoreAdapter()

        let records = adapter.project(memory: memory)

        #expect(records.allSatisfy { $0.layer == .task })
        #expect(records.allSatisfy { $0.scope == .session(id: "session-1") })
    }

    @Test func taskMemoryAdapterRemainsReadOnlyUnderWriteContract() async throws {
        let adapter = TaskMemoryStoreAdapter()
        let record = MemoryRecord.fixture(scope: .session(id: "session-1"))

        #expect(throws: MemoryStoreError.unsupportedOperation("persist")) {
            try adapter.persist(record: record)
        }
    }
}
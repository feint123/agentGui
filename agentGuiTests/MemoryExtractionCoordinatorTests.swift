import XCTest
@testable import agentGui

@MainActor
final class MemoryExtractionCoordinatorTests: XCTestCase {

    func test_shouldExtract_returnsTrueWhenIdle() async {
        let coordinator = MemoryExtractionCoordinator()
        let result = await coordinator.shouldExtract()
        XCTAssertTrue(result)
    }

    func test_shouldExtract_returnsFalseWhenExtractionInProgress() async {
        let coordinator = MemoryExtractionCoordinator()
        await coordinator.beginExtraction()
        let result = await coordinator.shouldExtract()
        XCTAssertFalse(result)
    }

    func test_beginExtraction_isIdempotentUnderConcurrency() async {
        let coordinator = MemoryExtractionCoordinator()
        var granted = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { await coordinator.beginExtraction() }
            }
            for await ok in group {
                if ok { granted += 1 }
            }
        }
        XCTAssertEqual(granted, 1, "Only one concurrent extraction should be granted")
    }

    func test_finishExtraction_resetsToIdle() async {
        let coordinator = MemoryExtractionCoordinator()
        await coordinator.beginExtraction()
        await coordinator.finishExtraction()
        let result = await coordinator.shouldExtract()
        XCTAssertTrue(result)
    }
}

// agentGuiTests/FSEventObserverTests.swift
import XCTest
@testable import agentGui

final class FSEventObserverTests: XCTestCase {

    // MARK: - MockFSEventObserver

    func testMockObserver_deliversPaths() async {
        let mock = MockFSEventObserver()
        var receivedPaths: [[String]] = []

        await mock.startObserving(directory: URL(fileURLWithPath: "/tmp")) { paths in
            receivedPaths.append(paths)
        }
        await mock.simulateEvents(["/tmp/foo.txt", "/tmp/bar.txt"])

        XCTAssertEqual(receivedPaths.count, 1)
        XCTAssertEqual(Set(receivedPaths[0]), ["/tmp/foo.txt", "/tmp/bar.txt"])
    }

    func testMockObserver_stopObserving_silencesEvents() async {
        let mock = MockFSEventObserver()
        var receivedCount = 0

        await mock.startObserving(directory: URL(fileURLWithPath: "/tmp")) { _ in
            receivedCount += 1
        }
        await mock.stopObserving()
        await mock.simulateEvents(["/tmp/foo.txt"])

        XCTAssertEqual(receivedCount, 0)
    }

    // MARK: - FSEventObserverDebouncer（内部防抖单元测试）

    @MainActor
    func testDebounceAggregator_coalescesPaths() async throws {
        let debouncer = FSEventObserverDebouncer(intervalNanoseconds: 50_000_000) // 50ms

        var received: [[String]] = []
        debouncer.setHandler { paths in
            received.append(paths)
        }

        // 快速推送3批事件，50ms 内
        debouncer.enqueue(["/tmp/a.txt"])
        debouncer.enqueue(["/tmp/b.txt"])
        debouncer.enqueue(["/tmp/a.txt"])  // 重复路径

        // 等待防抖窗口结束（100ms > 50ms）
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(received.count, 1, "3 rapid enqueues should be coalesced into 1 callback")
        XCTAssertEqual(Set(received[0]), ["/tmp/a.txt", "/tmp/b.txt"],
                       "Duplicate paths should be deduplicated")
    }

    @MainActor
    func testDebounceAggregator_cancelPreventsCallback() async throws {
        let debouncer = FSEventObserverDebouncer(intervalNanoseconds: 100_000_000) // 100ms
        var callbackCount = 0
        debouncer.setHandler { _ in callbackCount += 1 }

        debouncer.enqueue(["/tmp/a.txt"])
        debouncer.cancel()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(callbackCount, 0, "Cancelled debouncer should not fire")
    }
}

import XCTest
import SwiftAnthropic
@testable import agentGui

final class MemoryRecallSessionStateTests: XCTestCase {

    func test_initialState_nothingSurfaced() async {
        let state = MemoryRecallSessionState()
        let alreadySurfaced = await state.alreadySurfaced
        XCTAssertTrue(alreadySurfaced.isEmpty)
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 0)
    }

    func test_markSurfaced_accumulates() async {
        let state = MemoryRecallSessionState()
        await state.markSurfaced(path: "/tmp/foo.md", byteCount: 1024)
        await state.markSurfaced(path: "/tmp/bar.md", byteCount: 2048)

        let surfaced = await state.alreadySurfaced
        XCTAssertEqual(surfaced, ["/tmp/foo.md", "/tmp/bar.md"])
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 3072)
    }

    func test_isSessionByteLimitReached_falseBeforeLimit() async {
        let state = MemoryRecallSessionState()
        await state.markSurfaced(path: "/tmp/a.md", byteCount: 1000)
        let reached = await state.isSessionByteLimitReached
        XCTAssertFalse(reached)
    }

    func test_isSessionByteLimitReached_trueAtLimit() async {
        let state = MemoryRecallSessionState()
        // MAX_SESSION_BYTES = 51_200
        await state.markSurfaced(path: "/tmp/big.md", byteCount: 51_200)
        let reached = await state.isSessionByteLimitReached
        XCTAssertTrue(reached)
    }

    func test_syncFrom_rebuildsFromMessages() async {
        let state = MemoryRecallSessionState()
        // 初次注入
        await state.markSurfaced(path: "/tmp/old.md", byteCount: 500)

        // 模拟 AutoCompact：消息被清空，syncFrom 重建（此处传空消息模拟 compact 后状态）
        await state.syncFrom(messagesSnapshot: [])
        let surfaced = await state.alreadySurfaced
        XCTAssertTrue(surfaced.isEmpty, "AutoCompact 后应清空 alreadySurfaced")
        let bytes = await state.totalBytesSurfaced
        XCTAssertEqual(bytes, 0)
    }
}

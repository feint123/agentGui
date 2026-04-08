import Testing
import Foundation
@testable import agentGui

struct StreamChangeKindTests {

    private func makeDigest(id: UUID, status: MessageStatus, textLength: Int) -> ChatMessageListRefreshKey.RowDigest {
        ChatMessageListRefreshKey.RowDigest(
            id: id,
            status: status,
            textLength: textLength,
            workspaceDependency: nil
        )
    }

    @Test
    func identicalKeysYieldNoChange() {
        let id = UUID()
        let a = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 42)])
        let b = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 42)])
        #expect(b.changeKind(from: a) == .noChange)
    }

    @Test
    func textLengthChangeYieldsContentDelta() {
        let id = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 50)])
        let next     = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 120)])
        #expect(next.changeKind(from: previous) == .contentDelta)
    }

    @Test
    func statusChangeYieldsStructural() {
        let id = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .pending, textLength: 100)])
        let next     = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id, status: .completed, textLength: 100)])
        #expect(next.changeKind(from: previous) == .structural)
    }

    @Test
    func rowCountDeltaYieldsStructural() {
        let id1 = UUID()
        let id2 = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [makeDigest(id: id1, status: .completed, textLength: 20)])
        let next     = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id1, status: .completed, textLength: 20),
            makeDigest(id: id2, status: .pending,   textLength: 0)
        ])
        #expect(next.changeKind(from: previous) == .structural)
    }

    @Test
    func rowReorderOrIdSwapYieldsStructural() {
        let id1 = UUID()
        let id2 = UUID()
        let previous = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id1, status: .completed, textLength: 10),
            makeDigest(id: id2, status: .completed, textLength: 10)
        ])
        let next = ChatMessageListRefreshKey(rowDigests: [
            makeDigest(id: id2, status: .completed, textLength: 10),
            makeDigest(id: id1, status: .completed, textLength: 10)
        ])
        #expect(next.changeKind(from: previous) == .structural)
    }
}

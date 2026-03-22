import Foundation
import Testing
@testable import agentGui

struct BlockEditorMutationDriverTests {

    @Test func mutationDriverRecordsBeforeAndAfterSnapshots() {
        var runtime = BlockEditorRuntimeState.fixture(text: "hello")
        var driver = BlockEditorMutationDriver(history: BlockEditorHistoryController())

        driver.applyMutation(kind: .blockStructure, title: "Delete Block", editor: &runtime) { runtime in
            runtime.document.blocks.removeAll()
            runtime.document.blocks = [.empty(.paragraph)]
        }

        #expect(driver.history.past.count == 1)
        #expect(driver.history.past.last?.before.document.blocks.first?.text == "hello")
        #expect(driver.history.past.last?.after.document.blocks.first?.text == "")
    }

    @Test func mutationDriverSkipsHistoryWhenStateDoesNotChange() {
        var runtime = BlockEditorRuntimeState.fixture(text: "hello")
        var driver = BlockEditorMutationDriver(history: BlockEditorHistoryController())

        driver.applyMutation(kind: .blockStructure, title: "Noop", editor: &runtime) { _ in
        }

        #expect(driver.history.past.isEmpty)
    }

    @Test func mutationDriverClearsFutureWhenRecordingNewMutation() {
        var runtime = BlockEditorRuntimeState.fixture(text: "hello")
        var driver = BlockEditorMutationDriver(history: BlockEditorHistoryController())

        driver.applyMutation(kind: .blockStructure, title: "First", editor: &runtime) { runtime in
            runtime.document.blocks[0].text = "hello world"
        }

        let currentSnapshot = try! #require(driver.history.past.last?.after)
        _ = driver.history.undo(current: currentSnapshot)
        #expect(driver.history.future.count == 1)

        driver.applyMutation(kind: .blockStructure, title: "Second", editor: &runtime) { runtime in
            runtime.document.blocks[0].text = "replacement"
        }

        #expect(driver.history.future.isEmpty)
        #expect(driver.history.past.count == 1)
        #expect(driver.history.past.last?.after.document.blocks.first?.text == "replacement")
    }

    @Test func runtimeCanApplyUndoSnapshot() {
        var runtime = BlockEditorRuntimeState.fixture(text: "hello")
        let target = BlockEditorUndoSnapshot.testFixture(text: "restored")

        runtime.apply(snapshot: target)

        #expect(runtime.document.blocks.first?.text == "restored")
        #expect(runtime.activeBlockID == target.presentation.activeBlockID)
    }
}

private extension BlockEditorUndoSnapshot {
    static func testFixture(text: String, activeBlockID: UUID? = nil) -> BlockEditorUndoSnapshot {
        let blockID = activeBlockID ?? UUID()
        return BlockEditorUndoSnapshot(
            document: BlockDocument(blocks: [DocumentBlock(id: blockID, kind: .paragraph, text: text)]),
            presentation: BlockEditorPresentationSnapshot(
                activeBlockID: blockID,
                focus: nil,
                selection: nil,
                blockSelection: .empty
            ),
            serializedText: text
        )
    }
}

private extension BlockEditorRuntimeState {
    static func fixture(text: String, fileURL: URL? = nil) -> BlockEditorRuntimeState {
        let blockID = UUID()
        return BlockEditorRuntimeState(
            document: BlockDocument(blocks: [DocumentBlock(id: blockID, kind: .paragraph, text: text)]),
            fileURL: fileURL,
            activeBlockID: blockID,
            focus: nil,
            selection: nil,
            blockSelection: .empty
        )
    }
}
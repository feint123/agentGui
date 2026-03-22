import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct BlockEditorSelectionCommandRouterTests {

    @Test func duplicateCommandClonesSelectedBlocksAndSelectsCopies() {
        let first = DocumentBlock(kind: .paragraph, text: "Alpha")
        let second = DocumentBlock(kind: .heading1, text: "Beta")
        var runtime = makeRuntime(blocks: [first, second], selectedIDs: [first.id, second.id])

        let result = BlockEditorSelectionCommandRouter.execute(command: .duplicate, runtime: &runtime, fileURL: nil)

        #expect(result.runtime.document.blocks.count == 4)
        #expect(result.runtime.document.blocks.map(\.text) == ["Alpha", "Alpha", "Beta", "Beta"])
        #expect(result.runtime.blockSelection.selectedBlockIDs.count == 2)
        #expect(result.runtime.activeBlockID == result.runtime.blockSelection.primaryBlockID)
    }

    @Test func deleteCommandRemovesSelectedBlocksAndPromotesFallbackSelection() {
        let first = DocumentBlock(kind: .paragraph, text: "Alpha")
        let second = DocumentBlock(kind: .paragraph, text: "Beta")
        let third = DocumentBlock(kind: .paragraph, text: "Gamma")
        var runtime = makeRuntime(blocks: [first, second, third], selectedIDs: [second.id])

        let result = BlockEditorSelectionCommandRouter.execute(command: .delete, runtime: &runtime, fileURL: nil)

        #expect(result.runtime.document.blocks.map(\.text) == ["Alpha", "Gamma"])
        #expect(result.runtime.blockSelection.selectedBlockIDs == [first.id])
        #expect(result.runtime.activeBlockID == first.id)
    }

    @Test func copyCommandSerializesOnlySelectedBlocks() {
        let first = DocumentBlock(kind: .paragraph, text: "Alpha")
        let second = DocumentBlock(kind: .heading2, text: "Beta")
        var runtime = makeRuntime(blocks: [first, second], selectedIDs: [second.id])

        let result = BlockEditorSelectionCommandRouter.execute(command: .copy, runtime: &runtime, fileURL: nil)

        #expect(result.payload?.markdown.contains("## Beta") == true)
        #expect(result.payload?.plainText.contains("Beta") == true)
        #expect(result.payload?.plainText.contains("Alpha") == false)
    }

    @Test func selectAllCommandSelectsEveryBlock() {
        let first = DocumentBlock(kind: .paragraph, text: "Alpha")
        let second = DocumentBlock(kind: .paragraph, text: "Beta")
        var runtime = makeRuntime(blocks: [first, second], selectedIDs: [])

        let result = BlockEditorSelectionCommandRouter.execute(command: .selectAll, runtime: &runtime, fileURL: nil)

        #expect(result.runtime.blockSelection.selectedBlockIDs == [first.id, second.id])
        #expect(result.runtime.blockSelection.primaryBlockID == second.id)
    }

    @Test func keyboardShortcutResolverMapsCoreActions() {
        #expect(BlockEditorSelectionKeyboardShortcut.resolve(keyCode: 8, charactersIgnoringModifiers: "c", modifierFlags: [.command]) == .copy)
        #expect(BlockEditorSelectionKeyboardShortcut.resolve(keyCode: 7, charactersIgnoringModifiers: "x", modifierFlags: [.command]) == .cut)
        #expect(BlockEditorSelectionKeyboardShortcut.resolve(keyCode: 2, charactersIgnoringModifiers: "d", modifierFlags: [.command]) == .duplicate)
        #expect(BlockEditorSelectionKeyboardShortcut.resolve(keyCode: 53, charactersIgnoringModifiers: nil, modifierFlags: []) == .clearSelection)
    }

    private func makeRuntime(blocks: [DocumentBlock], selectedIDs: Set<UUID>) -> BlockEditorRuntimeState {
        BlockEditorRuntimeState(
            document: BlockDocument(blocks: blocks),
            fileURL: nil,
            activeBlockID: blocks.first?.id,
            focus: nil,
            selection: nil,
            blockSelection: BlockEditorBlockSelectionState(
                selectedBlockIDs: selectedIDs,
                primaryBlockID: blocks.first(where: { selectedIDs.contains($0.id) })?.id,
                anchorBlockID: blocks.first(where: { selectedIDs.contains($0.id) })?.id,
                source: .click,
                marqueeSelection: nil
            )
        )
    }
}
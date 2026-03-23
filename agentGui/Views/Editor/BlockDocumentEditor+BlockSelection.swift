import AppKit
import SwiftUI

extension BlockDocumentEditor {
    func clearBlockSelection() {
        applyBlockSelectionState(BlockEditorBlockSelectionState.empty)
        responderActivationToken = UUID()
    }

    func handleBlockTap(_ blockID: UUID) {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]) ?? []
        let orderedBlockIDs = document.blocks.map(\.id)

        if modifiers.contains(.shift), blockSelectionState.anchorBlockID != nil {
            blockSelectionState = BlockEditorBlockSelectionCoordinator.extendRange(
                state: blockSelectionState,
                orderedBlockIDs: orderedBlockIDs,
                targetBlockID: blockID,
                source: .shiftClick
            )
        } else if modifiers.contains(.command) {
            blockSelectionState = BlockEditorBlockSelectionCoordinator.toggleSelection(
                state: blockSelectionState,
                targetBlockID: blockID,
                source: .commandClick
            )
        } else {
            blockSelectionState = BlockEditorBlockSelectionCoordinator.selectSingle(
                targetBlockID: blockID,
                source: .click
            )
        }

        clearInlineSelection()
        slashState.clear()
        applyBlockSelectionState(blockSelectionState)
        setActiveBlock(blockSelectionState.primaryBlockID)
        focusRequest = nil
        runtimeState.focus = nil
        responderActivationToken = UUID()
    }

    func handleSelectionContextMenuCommand(_ command: BlockEditorSelectionCommand, targetBlockID: UUID) {
        if !blockSelectionState.selectedBlockIDs.contains(targetBlockID) {
            applyBlockSelectionState(BlockEditorBlockSelectionState.single(targetBlockID, source: .contextMenu))
            setActiveBlock(targetBlockID)
        }
        executeSelectionCommand(command)
    }

    func executeSelectionCommand(_ command: BlockEditorSelectionCommand) {
        let title: String
        switch command {
        case .cut:
            title = "Cut Blocks"
        case .copy:
            title = "Copy Blocks"
        case .copyAs(let format):
            title = "Copy Blocks As \(format.rawValue)"
        case .duplicate:
            title = "Duplicate Blocks"
        case .delete:
            title = "Delete Blocks"
        case .selectAll:
            title = "Select All Blocks"
        case .clearSelection:
            title = "Clear Block Selection"
        }

        applyStructuralEdit(title: title, kind: .blockStructure) { runtime in
            let result = BlockEditorSelectionCommandRouter.execute(command: command, runtime: &runtime, fileURL: fileURL)
            if let payload = result.payload {
                let preferredFormat: BlockEditorSelectionExportFormat
                switch command {
                case .copyAs(let format):
                    preferredFormat = format
                default:
                    preferredFormat = .plainText
                }
                BlockEditorSelectionClipboardWriter.write(payload, preferredFormat: preferredFormat)
            }
        }

        responderActivationToken = UUID()
    }

    func handleSelectionKeyboardAction(_ action: BlockEditorSelectionKeyboardShortcut) {
        guard blockSelectionState.hasSelection || action == .selectAll || action == .clearSelection else { return }

        switch action {
        case .copy:
            executeSelectionCommand(.copy)
        case .cut:
            executeSelectionCommand(.cut)
        case .delete:
            executeSelectionCommand(.delete)
        case .duplicate:
            executeSelectionCommand(.duplicate)
        case .selectAll:
            executeSelectionCommand(.selectAll)
        case .clearSelection:
            executeSelectionCommand(.clearSelection)
        }
    }

    func remapBlockSelectionToCurrentDocument() {
        let remapped = BlockEditorBlockSelectionCoordinator.remapSelection(
            state: blockSelectionState,
            orderedBlockIDs: document.blocks.map(\.id)
        )
        guard remapped != blockSelectionState else { return }
        applyBlockSelectionState(remapped)
    }

    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(BlockEditorLayoutCoordinateSpace.canvas))
            .onChanged { value in
                let isAdditive = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                if marqueeSelection == nil {
                    marqueeBaseSelectionState = isAdditive ? blockSelectionState : .empty
                    clearInlineSelection()
                    runtimeState.focus = nil
                }

                isCollectingRowFrames = true

                let marquee = BlockEditorMarqueeSelection(
                    startPoint: value.startLocation,
                    currentPoint: value.location,
                    isAdditive: isAdditive
                )
                marqueeSelection = marquee

                guard !rowFrameSnapshot.isEmpty else { return }

                let result = marqueeController.reduce(
                    baseState: marqueeBaseSelectionState,
                    currentState: blockSelectionState,
                    orderedBlockIDs: document.blocks.map(\.id),
                    rowFrames: rowFrameSnapshot,
                    marquee: marquee
                )

                if result.shouldMutateState {
                    applyBlockSelectionState(result.state, syncRuntime: false)
                }
                if result.shouldSyncRuntimeSelection {
                    runtimeState.blockSelection = result.state
                }
                if result.shouldUpdateActiveBlock {
                    setActiveBlock(result.state.primaryBlockID, syncRuntime: false)
                }
            }
            .onEnded { _ in
                marqueeSelection = nil
                isCollectingRowFrames = false
                rowFrameSnapshot = .empty
                runtimeState.blockSelection = blockSelectionState
                responderActivationToken = UUID()
            }
    }

    @ViewBuilder
    func marqueeOverlay(for marquee: BlockEditorMarqueeSelection) -> some View {
        let rect = marquee.rect
        Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}
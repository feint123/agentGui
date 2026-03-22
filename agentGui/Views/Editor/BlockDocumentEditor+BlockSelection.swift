import AppKit
import SwiftUI

extension BlockDocumentEditor {
    func clearBlockSelection() {
        blockSelectionState = .empty
        runtimeState.blockSelection = .empty
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

        selectionState = nil
        slashState.clear()
        activeBlockID = blockSelectionState.primaryBlockID
        focusRequest = nil
        runtimeState.activeBlockID = activeBlockID
        runtimeState.focus = nil
        runtimeState.selection = nil
        runtimeState.blockSelection = blockSelectionState
        responderActivationToken = UUID()
    }

    func handleSelectionContextMenuCommand(_ command: BlockEditorSelectionCommand, targetBlockID: UUID) {
        if !blockSelectionState.selectedBlockIDs.contains(targetBlockID) {
            blockSelectionState = .single(targetBlockID, source: .contextMenu)
            runtimeState.blockSelection = blockSelectionState
            runtimeState.activeBlockID = targetBlockID
            activeBlockID = targetBlockID
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
        blockSelectionState = remapped
        runtimeState.blockSelection = remapped
    }

    var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(BlockEditorLayoutCoordinateSpace.canvas))
            .onChanged { value in
                let isAdditive = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                if blockSelectionState.marqueeSelection == nil {
                    marqueeBaseSelectionState = isAdditive ? blockSelectionState : .empty
                }

                let marquee = BlockEditorMarqueeSelection(
                    startPoint: value.startLocation,
                    currentPoint: value.location,
                    isAdditive: isAdditive
                )

                blockSelectionState = BlockEditorBlockSelectionCoordinator.selectionFromMarquee(
                    state: marqueeBaseSelectionState,
                    orderedBlockIDs: document.blocks.map(\.id),
                    blockFrames: blockFrames,
                    marquee: marquee,
                    source: .marquee
                )
                selectionState = nil
                runtimeState.focus = nil
                runtimeState.selection = nil
                runtimeState.blockSelection = blockSelectionState
                activeBlockID = blockSelectionState.primaryBlockID
            }
            .onEnded { _ in
                blockSelectionState.marqueeSelection = nil
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
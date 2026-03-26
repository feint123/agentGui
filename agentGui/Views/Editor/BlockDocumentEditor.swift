//
//  BlockDocumentEditor.swift
//  agentGui
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OSLog

// MARK: - Performance Monitor

private let perfEditor = PerformanceMonitor.self

struct BlockDocumentEditor: View {
    @Binding var text: String
    let fileURL: URL
    var persistedText: String? = nil
    /// Called whenever the editor selection changes; passes the selected text and file line range.
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State var document = BlockDocument.empty
    @State private var isApplyingInternalChange = false
    @State var slashState = BlockEditorSlashState()
    @State private var draggedBlockID: UUID?
    @State private var dropTargetBlockID: UUID?
    @State private var dragOriginBlocks: [DocumentBlock]?
    @State var focusRequest: BlockEditorFocusRequest?
    @State var activeBlockID: UUID?
    @State private var editorResidency = BlockEditorResidency(maxMountedEditors: 1)
    @State var selectionState: InlineSelectionState?
    @State var blockSelectionState = BlockEditorBlockSelectionState.empty
    @State var rowFrameSnapshot = BlockEditorRowFrameSnapshot.empty
    @State var isCollectingRowFrames = false
    @State var marqueeSelection: BlockEditorMarqueeSelection?
    @State var marqueeBaseSelectionState = BlockEditorBlockSelectionState.empty
    @State private var pendingFormats: [UUID: InlineFormatRequest] = [:]
    @State private var syncGate = BlockDocumentSyncGate()
    @State private var historyController = BlockEditorHistoryController()
    @State var runtimeState = BlockEditorRuntimeState(document: .empty, fileURL: nil, activeBlockID: nil, focus: nil, selection: nil, blockSelection: .empty)
    @State private var textEditSession: BlockEditorTextEditSession?
    @State var responderActivationToken = UUID()

    private let slashRegistry = BlockSlashCommandRegistry()
    private let textEditCoalescingWindow: TimeInterval = 1.0
    let marqueeController = BlockEditorMarqueeSelectionController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrollContent
                .simultaneousGesture(TapGesture().onEnded {
                    if selectionState?.hasSelection == true || slashState.isPresented {
                        dismissFloatingOverlays()
                    }
                })
            if let marquee = marqueeSelection {
                marqueeOverlay(for: marquee)
                    .zIndex(5)
            }
            GeometryReader { geo in
                if let state = selectionState, state.hasSelection {
                    InlineStyleToolbarView(
                        activeActions: state.activeActions,
                        onAction: { action in applyFormat(action, blockID: state.blockID) }
                    )
                    .position(toolbarPosition(for: state, geo: geo))
                    .transition(.inlineToolbar)
                    .zIndex(10)
                }
                if let context = slashState.context {
                    SlashCommandMenu(
                        query: context.query,
                        categories: slashState.categories,
                        highlightedCategoryID: slashState.highlightedCategoryID,
                        selectedCategoryID: slashState.selectedCategoryID,
                        highlightedItemID: slashState.selectedItem?.id,
                        scrollTargetItemID: slashState.scrollTargetItemID,
                        onScrollTargetConsumed: {
                            _ = slashState.consumeScrollTargetItemID()
                        },
                        onSelectCategory: { categoryID in
                            withAnimation(.snappy(duration: 0.24, extraBounce: 0.04)) {
                                slashState.selectCategory(categoryID)
                            }
                        },
                        onSelect: { item in
                            applySlashCommand(item.action, to: context.blockID, tokenRange: context.tokenRange)
                        }
                    )
                    .position(slashMenuPosition(for: geo, anchorRect: context.anchorRect))
                    .transition(.editorFloatingMenu)
                    .zIndex(10)
                }
            }
            BlockEditorCommandResponder(
                activationToken: responderActivationToken,
                onUndo: undo,
                onRedo: redo,
                onCopy: { handleSelectionKeyboardAction(.copy) },
                onCut: { handleSelectionKeyboardAction(.cut) },
                onDeleteSelection: { handleSelectionKeyboardAction(.delete) },
                onDuplicate: { handleSelectionKeyboardAction(.duplicate) },
                onSelectAll: { handleSelectionKeyboardAction(.selectAll) },
                onClearSelection: { handleSelectionKeyboardAction(.clearSelection) }
            )
            .frame(width: 0, height: 0)
        }
    }

    private var scrollContent: some View {
        let orderedListIndices = BlockListIndexMap.make(for: document.blocks)

        return VStack(alignment: .leading, spacing: 0) {
            ChatReadableWidthContainer {
                List {
                    ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                        blockRow(for: block, at: index, orderedListIndices: orderedListIndices)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden) // 隐藏默认背景
            }
        }
        .frame(maxWidth:.infinity)
        .coordinateSpace(name: BlockEditorLayoutCoordinateSpace.canvas)
        .background(editorBackground)
        .onAppear {
            initializeEditorState(from: text, resetHistory: true)
        }
        .onChange(of: text) { _, newValue in
            guard !isApplyingInternalChange else { return }
            handleExternalTextChange(newValue)
        }
        .onChange(of: persistedText) { _, newValue in
            handlePersistedTextChange(newValue)
        }
        .onChange(of: document.blocks) { _, _ in
            pruneEditorResidency()
            remapBlockSelectionToCurrentDocument()
            let prunedSnapshot = rowFrameSnapshot.pruned(to: document.blocks.map(\.id))
            if prunedSnapshot != rowFrameSnapshot {
                rowFrameSnapshot = prunedSnapshot
            }
            if syncGate.consumeAutomaticSyncRequest() {
                syncText()
            }
        }
        .onPreferenceChange(BlockEditorRowFramePreferenceKey.self) { frames in
            guard isCollectingRowFrames else { return }
            let nextSnapshot = BlockEditorRowFrameSnapshot(frames: frames)
                .pruned(to: document.blocks.map(\.id))
            guard nextSnapshot != rowFrameSnapshot else { return }
            rowFrameSnapshot = nextSnapshot
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleExternalFileDrop(providers)
        }
        .simultaneousGesture(marqueeGesture)
    }

    private func blockRow(for block: DocumentBlock, at index: Int, orderedListIndices: [UUID: Int]) -> some View {
        BlockRowView(
            block: $document.blocks[index],
            focusRequest: focusRequest,
            isActive: activeBlockID == block.id,
            isBlockSelected: blockSelectionState.selectedBlockIDs.contains(block.id),
            reportsFrameForSelection: isCollectingRowFrames,
            mountHeavyEditor: editorResidency.shouldMountEditor(for: block.id),
            listIndex: orderedListIndices[block.id],
            onTextChange: { newValue in
                handleTextChange(newValue, for: block.id)
            },
            onEditorCommand: { command in
                handleEditorCommand(command, for: block.id)
            },
            onFocusChange: { isFocused in
                if isFocused {
                    clearBlockSelection()
                    activateBlock(block.id)
                } else {
                    flushTextEditSession()
                }
            },
            onConvert: { kind in
                convertBlock(id: block.id, to: kind)
            },
            onEditRequest: { edit in
                handleRowEdit(edit, for: block.id)
            },
            onReadOnlyActivate: { offset in
                activateBlock(block.id, focusPosition: .offset(offset))
            },
            onDragRequest: {
                draggedBlockID = block.id
                return NSItemProvider(object: block.id.uuidString as NSString)
            },
            onFileDrop: { urls in
                addResources(urls, after: block.id)
            },
            onBlockTap: {
                handleBlockTap(block.id)
            },
            onContextMenuCommand: { command in
                handleSelectionContextMenuCommand(command, targetBlockID: block.id)
            },
            onSelectionChange: { state in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    if state.hasSelection {
                        clearBlockSelection()
                        setInlineSelection(state)
                    } else if selectionState?.blockID == block.id {
                        clearInlineSelection()
                    }
                }
                onSelectionChange?(selectionSnapshot(for: state))
            },
            onSlashContextChange: { context in
                handleSlashContextChange(context, for: block.id)
            },
            pendingFormatRequest: pendingFormats[block.id]
        )
        .overlay(alignment: .top) {
            if dropTargetBlockID == block.id {
                RoundedRectangle(cornerRadius: BlockEditorTheme.blockCornerRadius)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .onDrop(
            of: [.text],
            delegate: BlockReorderDropDelegate(
                targetID: block.id,
                blocks: $document.blocks,
                draggedBlockID: $draggedBlockID,
                dragOriginBlocks: $dragOriginBlocks,
                dropTargetBlockID: $dropTargetBlockID,
                onCommit: { beforeBlocks, draggedBlockID in
                    commitReorderedBlocks(beforeBlocks: beforeBlocks, draggedBlockID: draggedBlockID)
                }
            )
        )
    }

    private func applyFormat(_ action: InlineStyleAction, blockID: UUID) {
        pendingFormats[blockID] = InlineFormatRequest(action: action)
    }

    private func toolbarPosition(for state: InlineSelectionState, geo: GeometryProxy) -> CGPoint {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return CGPoint(x: 120, y: 40) }
        let contentHeight = contentView.frame.height
        // Convert from screen coords to window coords
        let windowRect = window.convertFromScreen(state.selectionRect)
        // Flip Y: AppKit is bottom-origin, SwiftUI is top-origin
        let flippedY = contentHeight - windowRect.maxY
        let viewFrame = geo.frame(in: .global)
        let rawX = windowRect.midX - viewFrame.minX
        let rawY = flippedY - 32 - viewFrame.minY
        // Clamp so toolbar stays within editor bounds
        let clampedX = max(120, min(rawX, geo.size.width - 120))
        let clampedY = max(8, rawY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func slashMenuPosition(for geo: GeometryProxy, anchorRect: CGRect) -> CGPoint {
        let viewFrame = geo.frame(in: .global)
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return CGPoint(x: 130, y: 80) }
        let menuSize = BlockEditorFloatingOverlayLayout.slashMenuSize(
            categoryCount: slashState.categories.count,
            selectedItemCount: slashState.selectedCategory?.items.count ?? 0,
            isExpanded: slashState.selectedCategoryID != nil
        )
        let windowRect = window.convertFromScreen(anchorRect)
        return BlockEditorFloatingOverlayLayout.menuCenter(
            anchorRect: windowRect,
            viewportFrame: viewFrame,
            contentHeight: contentView.frame.height,
            menuSize: menuSize
        )
    }

    private var editorBackground: some View {
        Rectangle().fill(BlockEditorTheme.pageBackground(for: colorScheme))
    }

    private func handleEditorCommand(_ command: BlockEditorCommand, for blockID: UUID) {
        switch command {
        case .split(let selectedRange):
            splitBlock(id: blockID, selectedRange: selectedRange)
        case .mergeBackward:
            mergeBlockBackward(id: blockID)
        case .indent:
            adjustIndentation(for: blockID, delta: 1)
        case .outdent:
            adjustIndentation(for: blockID, delta: -1)
        case .undo:
            undo()
        case .redo:
            redo()
        case .moveFocusUp:
            moveFocus(from: blockID, delta: -1)
        case .moveFocusDown:
            moveFocus(from: blockID, delta: 1)
        case .slashMoveUp:
            moveSlashSelection(delta: -1, for: blockID)
        case .slashMoveDown:
            moveSlashSelection(delta: 1, for: blockID)
        case .slashMoveLeft:
            moveSlashHierarchy(delta: -1, for: blockID)
        case .slashMoveRight:
            moveSlashHierarchy(delta: 1, for: blockID)
        case .slashCommit:
            commitSlashSelection(for: blockID)
        case .slashDismiss:
            dismissSlash(blockID: blockID)
        case .dismissFloatingOverlays:
            dismissFloatingOverlays()
        }
    }

    private func handleRowEdit(_ edit: BlockRowEdit, for blockID: UUID) {
        applyStructuralEdit(title: historyTitle(for: edit)) { runtime in
            runtime.applyRowEdit(id: blockID, edit: edit)
        }
    }

    private func convertBlock(id: UUID, to kind: DocumentBlockKind, removingSlashRange: NSRange? = nil) {
        applyStructuralEdit(title: "Convert Block") { runtime in
            runtime.convertBlock(id: id, to: kind, removingSlashRange: removingSlashRange)
        }
    }

    private func splitBlock(id: UUID, selectedRange: NSRange) {
        let span = perfEditor.startSpan("BlockEditor.splitBlock", category: "Editor", level: .normal)
        defer { span.end() }
        applyStructuralEdit(title: "Split Block") { runtime in
            runtime.splitBlock(id: id, selectedRange: selectedRange)
        }
    }

    private func mergeBlockBackward(id: UUID) {
        let span = perfEditor.startSpan("BlockEditor.mergeBlockBackward", category: "Editor", level: .normal)
        defer { span.end() }
        applyStructuralEdit(title: "Merge Block") { runtime in
            runtime.mergeBlockBackward(id: id)
        }
    }

    private func insertBlock(after blockID: UUID) {
        let span = perfEditor.startSpan("BlockEditor.insertBlock", category: "Editor", level: .normal)
        defer { span.end() }
        applyStructuralEdit(title: "Insert Block") { runtime in
            runtime.insertBlock(after: blockID)
        }
    }

    private func deleteBlock(id: UUID, removingSlashRange: NSRange? = nil) {
        let span = perfEditor.startSpan("BlockEditor.deleteBlock", category: "Editor", level: .normal)
        defer { span.end() }
        applyStructuralEdit(title: "Delete Block") { runtime in
            runtime.deleteBlock(id: id)
        }
    }

    private func duplicateBlock(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = document.blocks[index]
        copy.id = UUID()
        applyStructuralEdit(title: "Duplicate Block") { runtime in
            runtime.document.blocks.insert(copy, at: index + 1)
            runtime.activeBlockID = copy.id
            runtime.focus = BlockEditorFocusSnapshot(blockID: copy.id, caretUTF16Offset: copy.text.utf16.count)
            runtime.selection = nil
        }
    }

    private func addResources(_ urls: [URL], after blockID: UUID?) {
        applyStructuralEdit(title: "Insert Resource") { runtime in
            runtime.addResources(urls, after: blockID)
        }
    }

    private func adjustIndentation(for blockID: UUID, delta: Int) {
        applyStructuralEdit(title: delta > 0 ? "Indent Block" : "Outdent Block") { runtime in
            runtime.adjustIndentation(for: blockID, delta: delta)
        }
    }

    private func moveFocus(from blockID: UUID, delta: Int) {
        flushTextEditSession()
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let targetIndex = index + delta
        guard document.blocks.indices.contains(targetIndex) else { return }
        let targetID = document.blocks[targetIndex].id
        activateBlock(targetID, focusPosition: delta < 0 ? .end : .start)
    }

    private func activateBlock(_ blockID: UUID, focusPosition: BlockEditorFocusPosition? = nil) {
        setActiveBlock(blockID)
        editorResidency.recordInteraction(with: blockID)
        clearInlineSelection()
        applyBlockSelectionState(.empty)
        if let focusPosition {
            focusRequest = BlockEditorFocusRequest(blockID: blockID, position: focusPosition)
            runtimeState.focus = focusSnapshot(for: blockID, position: focusPosition)
        } else {
            runtimeState.focus = nil
        }
    }

    private func initializeEditorState(from sourceText: String, resetHistory: Bool) {
        flushTextEditSession()
        document = BlockMarkdownCodec.parse(sourceText, fileURL: fileURL)
        blockSelectionState = .empty
        selectionState = nil
        if let firstBlockID = document.blocks.first?.id {
            activeBlockID = firstBlockID
            focusRequest = nil
            editorResidency.recordInteraction(with: firstBlockID)
        }
        runtimeState = makeRuntimeState()
        if resetHistory {
            historyController.reset()
        }
        if persistedText == sourceText {
            historyController.markClean(at: runtimeState.snapshot(serializedText: sourceText))
        }
    }

    private func handleExternalTextChange(_ newValue: String) {
        let span = perfEditor.startSpan("BlockDocumentEditor.textChange", category: "Editor", level: .verbose)
        defer { span.end() }

        let serialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        guard serialized != newValue else { return }
        span.addMetadata("parseNeeded", value: true)
        initializeEditorState(from: newValue, resetHistory: true)
        pruneEditorResidency()
    }

    private func handlePersistedTextChange(_ newValue: String?) {
        guard let newValue else { return }
        flushTextEditSession()
        let currentSerialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        if currentSerialized == newValue {
            historyController.markClean(at: makeRuntimeState().snapshot(serializedText: newValue))
        }
    }

    func applyStructuralEdit(
        title: String,
        kind: BlockEditorHistoryEntry.Kind = .blockStructure,
        mergePolicy: BlockEditorHistoryEntry.MergePolicy = .never,
        mutation: (inout BlockEditorRuntimeState) -> Void
    ) {
        flushTextEditSession()
        var runtime = makeRuntimeState()
        var driver = BlockEditorMutationDriver(history: historyController)
        let changed = driver.applyMutation(
            kind: kind,
            title: title,
            mergePolicy: mergePolicy,
            editor: &runtime,
            mutation: mutation
        )
        historyController = driver.history
        guard changed else { return }
        applyRuntimeState(runtime, manualCommit: true)
    }

    private func commitReorderedBlocks(beforeBlocks: [DocumentBlock], draggedBlockID: UUID?) {
        flushTextEditSession()

        let afterBlocks = document.blocks
        guard beforeBlocks != afterBlocks else {
            syncText(manualCommit: true)
            return
        }

        var beforeRuntime = makeRuntimeState()
        beforeRuntime.document = BlockDocument(blocks: beforeBlocks)
        beforeRuntime.activeBlockID = draggedBlockID ?? beforeRuntime.activeBlockID
        beforeRuntime.focus = nil
        beforeRuntime.selection = nil

        var afterRuntime = makeRuntimeState()
        afterRuntime.activeBlockID = draggedBlockID ?? afterRuntime.activeBlockID
        afterRuntime.focus = nil
        afterRuntime.selection = nil

        historyController.record(
            BlockEditorHistoryEntry(
                id: UUID(),
                kind: .blockStructure,
                title: "Reorder Blocks",
                before: beforeRuntime.snapshot(),
                after: afterRuntime.snapshot(),
                mergePolicy: .never,
                timestamp: Date()
            )
        )

        runtimeState = afterRuntime
        activeBlockID = afterRuntime.activeBlockID
        focusRequest = nil
        selectionState = nil
        blockSelectionState = afterRuntime.blockSelection
        syncText(manualCommit: true)
    }

    private func handleTextChange(_ newValue: String, for blockID: UUID) {
        let previousRuntime = runtimeState
        var updatedRuntime = makeRuntimeState()
        updatedRuntime.activeBlockID = blockID

        let now = Date()
        let latestSnapshot = updatedRuntime.snapshot()

        if var session = textEditSession,
           session.canCoalesce(with: blockID, at: now, timeout: textEditCoalescingWindow) {
            session.latest = latestSnapshot
            session.lastEditedAt = now
            textEditSession = session
        } else {
            flushTextEditSession()
            textEditSession = BlockEditorTextEditSession(
                blockID: blockID,
                baseline: previousRuntime.snapshot(),
                latest: latestSnapshot,
                startedAt: now,
                lastEditedAt: now
            )
        }

        runtimeState = updatedRuntime
        activeBlockID = blockID
    }

    private func flushTextEditSession() {
        guard let session = textEditSession else { return }
        defer { textEditSession = nil }
        guard session.baseline != session.latest else { return }
        historyController.record(
            BlockEditorHistoryEntry(
                id: UUID(),
                kind: .textInput(blockID: session.blockID),
                title: "Text Input",
                before: session.baseline,
                after: session.latest,
                mergePolicy: .never,
                timestamp: session.lastEditedAt
            )
        )
    }

    private func undo() {
        flushTextEditSession()
        guard let snapshot = historyController.undo(current: makeRuntimeState().snapshot()) else { return }
        applyHistorySnapshot(snapshot)
    }

    private func redo() {
        flushTextEditSession()
        guard let snapshot = historyController.redo(current: makeRuntimeState().snapshot()) else { return }
        applyHistorySnapshot(snapshot)
    }

    private func applyHistorySnapshot(_ snapshot: BlockEditorUndoSnapshot) {
        var runtime = makeRuntimeState()
        runtime.apply(snapshot: snapshot)
        applyRuntimeState(runtime, manualCommit: true)
    }

    private func applyRuntimeState(_ runtime: BlockEditorRuntimeState, manualCommit: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            document = runtime.document
        }
        runtimeState = runtime
        selectionState = nil
        blockSelectionState = runtime.blockSelection
        slashState.clear()
        pendingFormats.removeAll()
        activeBlockID = runtime.activeBlockID ?? runtime.document.blocks.first?.id
        if let activeBlockID {
            editorResidency.recordInteraction(with: activeBlockID)
        }
        if let focus = runtime.focus {
            focusRequest = BlockEditorFocusRequest(blockID: focus.blockID, position: .offset(focus.caretUTF16Offset))
        } else {
            focusRequest = nil
            responderActivationToken = UUID()
        }
        syncText(manualCommit: manualCommit)
    }

    private func makeRuntimeState() -> BlockEditorRuntimeState {
        BlockEditorRuntimeState(
            document: document,
            fileURL: fileURL,
            activeBlockID: activeBlockID,
            focus: runtimeState.focus,
            selection: runtimeState.selection,
            blockSelection: blockSelectionState
        )
    }

    private func updateRuntimeSelection(from state: InlineSelectionState) {
        runtimeState.selection = state.hasSelection ? BlockEditorSelectionSnapshot(blockID: state.blockID, range: state.selectedRange) : nil
    }

    func applyBlockSelectionState(_ newState: BlockEditorBlockSelectionState, syncRuntime: Bool = true) {
        blockSelectionState = newState
        if syncRuntime {
            runtimeState.blockSelection = newState
        }
    }

    func clearInlineSelection(syncRuntime: Bool = true) {
        selectionState = nil
        if syncRuntime {
            runtimeState.selection = nil
        }
    }

    func setInlineSelection(_ state: InlineSelectionState, syncRuntime: Bool = true) {
        selectionState = state
        if syncRuntime {
            updateRuntimeSelection(from: state)
        }
    }

    func setActiveBlock(_ blockID: UUID?, syncRuntime: Bool = true) {
        activeBlockID = blockID
        if syncRuntime {
            runtimeState.activeBlockID = blockID
        }
    }

    private func focusSnapshot(for blockID: UUID, position: BlockEditorFocusPosition) -> BlockEditorFocusSnapshot {
        let textLength = document.blocks.first(where: { $0.id == blockID })?.text.utf16.count ?? 0
        let projection = BlockInlineMarkdownProjection(sourceText: document.blocks.first(where: { $0.id == blockID })?.text ?? "")
        let offset: Int
        switch position {
        case .start:
            offset = 0
        case .end:
            offset = projection.normalizedSourceOffset(for: textLength)
        case .offset(let requestedOffset):
            offset = projection.normalizedSourceOffset(for: max(0, min(requestedOffset, textLength)))
        }
        return BlockEditorFocusSnapshot(blockID: blockID, caretUTF16Offset: offset)
    }

    private func historyTitle(for edit: BlockRowEdit) -> String {
        switch edit {
        case .setText:
            return "Edit Block Text"
        case .setChecked:
            return "Toggle Check State"
        case .setLanguage:
            return "Edit Language"
        case .setResource:
            return "Edit Resource"
        case .setSecondaryText:
            return "Edit Title"
        case .setTone:
            return "Edit Tone"
        case .setCollapsed:
            return "Toggle Collapse"
        }
    }

    private func pruneEditorResidency() {
        editorResidency.retain(document.blocks.map(\.id))
        if let activeBlockID,
           document.blocks.contains(where: { $0.id == activeBlockID }) == false {
            self.activeBlockID = editorResidency.mountedEditorIDs.first ?? document.blocks.first?.id
        }
    }

    private func moveSlashSelection(delta: Int, for blockID: UUID) {
        guard slashState.context?.blockID == blockID else { return }
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
            slashState.moveSelection(delta: delta)
        }
    }

    private func moveSlashHierarchy(delta: Int, for blockID: UUID) {
        guard slashState.context?.blockID == blockID else { return }
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
            if delta > 0 {
                _ = slashState.openHighlightedCategoryIfNeeded()
            } else {
                _ = slashState.collapseCategorySelection()
            }
        }
    }

    private func commitSlashSelection(for blockID: UUID) {
        guard slashState.context?.blockID == blockID else {
            insertBlock(after: blockID)
            return
        }
        if slashState.selectedCategoryID == nil {
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.04)) {
                _ = slashState.openFirstCategoryIfNeeded()
            }
            return
        }
        guard let selectedItem = slashState.selectedItem,
              let tokenRange = slashState.context?.tokenRange else {
            dismissSlash(blockID: blockID)
            return
        }
        applySlashCommand(selectedItem.action, to: blockID, tokenRange: tokenRange)
    }

    private func dismissSlash(blockID: UUID) {
        guard slashState.context?.blockID == blockID else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            slashState.clear()
        }
    }

    private func dismissFloatingOverlays() {
        withAnimation(.smooth(duration: 0.16)) {
            selectionState = nil
            slashState.clear()
        }
        onSelectionChange?(nil)
    }

    private func handleExternalFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                } else if let url = item as? URL {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            addResources(urls, after: document.blocks.last?.id)
        }

        return true
    }

    private func syncText(manualCommit: Bool = false) {
        let span = perfEditor.startSpan("BlockDocumentEditor.syncText", category: "Editor", level: .verbose)
        defer { span.end() }

        let serialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        guard serialized != text else { return }
        span.addMetadata("length", value: serialized.count)
        if manualCommit {
            syncGate.markManualSyncCommitted()
        }
        isApplyingInternalChange = true
        text = serialized
        DispatchQueue.main.async {
            isApplyingInternalChange = false
        }
    }

    private func handleSlashContextChange(_ context: BlockEditorSlashContext?, for blockID: UUID) {
        if let context {
            guard let currentBlock = document.blocks.first(where: { $0.id == context.blockID }) else { return }
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.03)) {
                slashState.update(context: context, currentBlock: currentBlock, registry: slashRegistry)
            }
            return
        }

        guard slashState.context?.blockID == blockID else { return }
        withAnimation(.smooth(duration: 0.16)) {
            slashState.clear()
        }
    }

    private func applySlashCommand(_ action: BlockSlashCommandAction, to blockID: UUID, tokenRange: NSRange) {
        switch action {
        case .convertCurrent(let kind):
            convertBlock(id: blockID, to: kind, removingSlashRange: tokenRange)
        case .toggleTodoCompletion:
            mutateBlock(id: blockID, removingSlashRange: tokenRange) { block in
                block.metadata.checked.toggle()
            }
        case .collapseToggle:
            mutateBlock(id: blockID, removingSlashRange: tokenRange) { block in
                block.metadata.isCollapsed = true
            }
        case .expandToggle:
            mutateBlock(id: blockID, removingSlashRange: tokenRange) { block in
                block.metadata.isCollapsed = false
            }
        case .clearFormatting:
            clearFormatting(for: blockID, tokenRange: tokenRange)
        case .deleteBlock:
            deleteBlock(id: blockID, removingSlashRange: tokenRange)
        case .outdentBlock:
            mutateBlock(id: blockID, removingSlashRange: tokenRange) { block in
                block.metadata.indentLevel = max(0, block.metadata.indentLevel - 1)
            }
        case .indentBlock:
            mutateBlock(id: blockID, removingSlashRange: tokenRange) { block in
                block.metadata.indentLevel += 1
            }
        case .createTablePreset(let rows, let columns):
            createTablePreset(rows: rows, columns: columns, for: blockID, tokenRange: tokenRange)
        }
    }

    private func clearFormatting(for blockID: UUID, tokenRange: NSRange) {
        applyStructuralEdit(title: "Clear Formatting") { runtime in
            runtime.clearFormatting(for: blockID, tokenRange: tokenRange)
        }
    }

    private func createTablePreset(rows: Int, columns: Int, for blockID: UUID, tokenRange: NSRange) {
        applyStructuralEdit(title: "Create Table") { runtime in
            runtime.createTablePreset(rows: rows, columns: columns, for: blockID, tokenRange: tokenRange)
        }
    }

    private func mutateBlock(id: UUID, removingSlashRange: NSRange? = nil, _ update: (inout DocumentBlock) -> Void) {
        applyStructuralEdit(title: "Mutate Block") { runtime in
            guard let index = runtime.document.blocks.firstIndex(where: { $0.id == id }) else { return }
            var block = runtime.document.blocks[index]
            if let removingSlashRange {
                block.text = BlockEditorSlashQueryParser.removingToken(in: block.text, tokenRange: removingSlashRange)
            }
            update(&block)
            runtime.document.blocks[index] = block
            runtime.activeBlockID = id
            runtime.focus = BlockEditorFocusSnapshot(blockID: id, caretUTF16Offset: 0)
            runtime.selection = nil
        }
    }
}

private extension BlockDocumentEditor {
    func selectionSnapshot(for state: InlineSelectionState) -> EditorSelectionSnapshot? {
        guard state.hasSelection else { return nil }
        return EditorSelectionSnapshot(
            text: state.selectedText,
            lineRange: lineRange(for: state)
        )
    }

    func lineRange(for state: InlineSelectionState) -> FileLineRange? {
        guard let blockIndex = document.blocks.firstIndex(where: { $0.id == state.blockID }) else {
            return nil
        }

        let block = document.blocks[blockIndex]
        guard !block.text.isEmpty else { return nil }

        let serializedPrefix = BlockMarkdownCodec.serialize(
            BlockDocument(blocks: Array(document.blocks.prefix(blockIndex + 1))),
            fileURL: fileURL
        )
        guard let blockTextRange = serializedPrefix.range(of: block.text, options: .backwards) else {
            return nil
        }

        let source = block.text as NSString
        let safeLocation = max(0, min(state.selectedRange.location, source.length))
        let safeLength = max(0, min(state.selectedRange.length, source.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        guard safeRange.length > 0 else { return nil }

        let linesBeforeBlock = newlineCount(in: String(serializedPrefix[..<blockTextRange.lowerBound]))
        let textBeforeSelection = source.substring(to: safeRange.location)
        let selectedText = source.substring(with: safeRange)
        let startLine = linesBeforeBlock + 1 + newlineCount(in: textBeforeSelection)
        let endLine = startLine + newlineCount(in: selectedText)

        return FileLineRange(startLine: startLine, endLine: endLine)
    }

    func newlineCount(in text: String) -> Int {
        text.reduce(into: 0) { partialResult, character in
            if character == "\n" {
                partialResult += 1
            }
        }
    }
}

private extension DocumentBlockKind {
    var textSeparatorForMerge: String {
        switch self {
        case .code, .source, .table:
            return "\n"
        default:
            return textNeedsSpaceSeparator ? " " : "\n"
        }
    }

    private var textNeedsSpaceSeparator: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .bulletedList, .numberedList, .todo, .callout, .toggle, .quote:
            return true
        default:
            return false
        }
    }
}

private struct BlockReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var blocks: [DocumentBlock]
    @Binding var draggedBlockID: UUID?
    @Binding var dragOriginBlocks: [DocumentBlock]?
    @Binding var dropTargetBlockID: UUID?
    let onCommit: ([DocumentBlock], UUID?) -> Void

    func dropEntered(info: DropInfo) {
        dropTargetBlockID = targetID
        if dragOriginBlocks == nil {
            dragOriginBlocks = blocks
        }
        guard let draggedBlockID,
              draggedBlockID != targetID,
              let from = blocks.firstIndex(where: { $0.id == draggedBlockID }),
              let to = blocks.firstIndex(where: { $0.id == targetID }) else { return }

        withAnimation(.spring(duration: 0.2)) {
            let block = blocks.remove(at: from)
            let destination = to > from ? max(to - 1, 0) : to
            blocks.insert(block, at: destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let beforeBlocks = dragOriginBlocks ?? blocks
        let committedDraggedBlockID = draggedBlockID
        dropTargetBlockID = nil
        dragOriginBlocks = nil
        draggedBlockID = nil
        onCommit(beforeBlocks, committedDraggedBlockID)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropTargetBlockID = nil
    }
}

private struct BlockEditorCommandResponder: NSViewRepresentable {
    let activationToken: UUID
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onDeleteSelection: () -> Void
    let onDuplicate: () -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void

    func makeNSView(context: Context) -> BlockEditorCommandResponderView {
        let view = BlockEditorCommandResponderView()
        view.onUndo = onUndo
        view.onRedo = onRedo
        view.onCopy = onCopy
        view.onCut = onCut
        view.onDeleteSelection = onDeleteSelection
        view.onDuplicate = onDuplicate
        view.onSelectAll = onSelectAll
        view.onClearSelection = onClearSelection
        return view
    }

    func updateNSView(_ nsView: BlockEditorCommandResponderView, context: Context) {
        nsView.onUndo = onUndo
        nsView.onRedo = onRedo
        nsView.onCopy = onCopy
        nsView.onCut = onCut
        nsView.onDeleteSelection = onDeleteSelection
        nsView.onDuplicate = onDuplicate
        nsView.onSelectAll = onSelectAll
        nsView.onClearSelection = onClearSelection
        guard nsView.lastActivationToken != activationToken else { return }
        nsView.lastActivationToken = activationToken
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class BlockEditorCommandResponderView: NSView {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onClearSelection: (() -> Void)?
    var lastActivationToken: UUID?

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    @objc func undo(_ sender: Any?) {
        onUndo?()
    }

    @objc func redo(_ sender: Any?) {
        onRedo?()
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc func cut(_ sender: Any?) {
        onCut?()
    }

    @objc func delete(_ sender: Any?) {
        onDeleteSelection?()
    }

    @objc override func deleteBackward(_ sender: Any?) {
        onDeleteSelection?()
    }

    @objc override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    @objc override func cancelOperation(_ sender: Any?) {
        onClearSelection?()
    }

    override func keyDown(with event: NSEvent) {
        guard let shortcut = BlockEditorSelectionKeyboardShortcut.resolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) else {
            super.keyDown(with: event)
            return
        }

        switch shortcut {
        case .copy:
            onCopy?()
        case .cut:
            onCut?()
        case .delete:
            onDeleteSelection?()
        case .duplicate:
            onDuplicate?()
        case .selectAll:
            onSelectAll?()
        case .clearSelection:
            onClearSelection?()
        }
    }
}

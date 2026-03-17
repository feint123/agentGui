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
    /// Called whenever the editor selection changes; passes the selected text and file line range.
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var document = BlockDocument.empty
    @State private var isApplyingInternalChange = false
    @State private var slashState = BlockEditorSlashState()
    @State private var draggedBlockID: UUID?
    @State private var dropTargetBlockID: UUID?
    @State private var focusRequest: BlockEditorFocusRequest?
    @State private var activeBlockID: UUID?
    @State private var editorResidency = BlockEditorResidency(maxMountedEditors: 1)
    @State private var selectionState: InlineSelectionState?
    @State private var pendingFormats: [UUID: InlineFormatRequest] = [:]
    @State private var syncGate = BlockDocumentSyncGate()

    private let slashRegistry = BlockSlashCommandRegistry()

    var body: some View {
        ZStack(alignment: .topLeading) {
            scrollContent
                .simultaneousGesture(TapGesture().onEnded {
                    if selectionState?.hasSelection == true || slashState.isPresented {
                        dismissFloatingOverlays()
                    }
                })
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
        }
    }

    private var scrollContent: some View {
        let orderedListIndices = BlockListIndexMap.make(for: document.blocks)

        return ScrollView {
            VStack(alignment: .center, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                        blockRow(for: block, at: index, orderedListIndices: orderedListIndices)
                    }
                }
                .frame(maxWidth: BlockEditorTheme.contentWidth, alignment: .leading)
                .padding(.horizontal, BlockEditorTheme.contentPadding)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity)
        }
        .background(editorBackground)
        .onAppear {
            document = BlockMarkdownCodec.parse(text, fileURL: fileURL)
            if let firstBlockID = document.blocks.first?.id {
                activateBlock(firstBlockID)
            }
        }
        .onChange(of: text) { _, newValue in
            guard !isApplyingInternalChange else { return }
            let span = perfEditor.startSpan("BlockDocumentEditor.textChange", category: "Editor", level: .verbose)
            let serialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
            if serialized != newValue {
                span.addMetadata("parseNeeded", value: true)
                document = BlockMarkdownCodec.parse(newValue, fileURL: fileURL)
                pruneEditorResidency()
                if activeBlockID == nil,
                   let firstBlockID = document.blocks.first?.id {
                    activateBlock(firstBlockID)
                }
            }
            span.end()
        }
        .onChange(of: document.blocks) { _, _ in
            pruneEditorResidency()
            if syncGate.consumeAutomaticSyncRequest() {
                syncText()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleExternalFileDrop(providers)
        }
    }

    private func blockRow(for block: DocumentBlock, at index: Int, orderedListIndices: [UUID: Int]) -> some View {
        BlockRowView(
            block: $document.blocks[index],
            focusRequest: focusRequest,
            isActive: activeBlockID == block.id,
            mountHeavyEditor: editorResidency.shouldMountEditor(for: block.id),
            listIndex: orderedListIndices[block.id],
            onTextChange: { newValue in
                activateBlock(block.id)
            },
            onEditorCommand: { command in
                handleEditorCommand(command, for: block.id)
            },
            onFocusChange: { isFocused in
                if isFocused {
                    activateBlock(block.id)
                }
            },
            onConvert: { kind in
                convertBlock(id: block.id, to: kind)
            },
            onFileDrop: { urls in
                addResources(urls, after: block.id)
            },
            onSelectionChange: { state in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    if state.hasSelection {
                        selectionState = state
                    } else if selectionState?.blockID == block.id {
                        selectionState = nil
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
        .contentShape(Rectangle())
        .onTapGesture {
            activateBlock(block.id, focusPosition: .end)
        }
        .onDrag {
            draggedBlockID = block.id
            return NSItemProvider(object: block.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: BlockReorderDropDelegate(
                targetID: block.id,
                blocks: $document.blocks,
                draggedBlockID: $draggedBlockID,
                dropTargetBlockID: $dropTargetBlockID,
                onCommit: { syncText() }
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

    private func convertBlock(id: UUID, to kind: DocumentBlockKind, removingSlashRange: NSRange? = nil) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = document.blocks[index]
        if let removingSlashRange {
            block.text = BlockEditorSlashQueryParser.removingToken(in: block.text, tokenRange: removingSlashRange)
        }
        block.kind = kind
        block.applyDefaults(for: kind)
        if kind == .divider {
            block.text = ""
        }
        if kind == .image || kind == .url || kind == .file {
            block.metadata.resource = ""
        }
        if kind != .bulletedList && kind != .numberedList && kind != .todo && kind != .quote {
            block.metadata.indentLevel = 0
        }
        document.blocks[index] = block
        dismissSlash(blockID: id)
        activateBlock(id, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func splitBlock(id: UUID, selectedRange: NSRange) {
        let span = perfEditor.startSpan("BlockEditor.splitBlock", category: "Editor", level: .normal)
        defer { span.end() }

        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let currentBlock = document.blocks[index]

        if currentBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           currentBlock.kind == .bulletedList || currentBlock.kind == .numberedList || currentBlock.kind == .todo {
            convertBlock(id: id, to: .paragraph)
            return
        }

        let source = currentBlock.text as NSString
        let safeLocation = max(0, min(selectedRange.location, source.length))
        let safeLength = max(0, min(selectedRange.length, source.length - safeLocation))
        let before = source.substring(to: safeLocation)
        let after = source.substring(from: safeLocation + safeLength)

        var updatedCurrent = currentBlock
        updatedCurrent.text = before

        var next = DocumentBlock.empty(followUpKind(for: currentBlock.kind))
        next.text = after
        next.metadata.indentLevel = currentBlock.metadata.indentLevel
        if currentBlock.kind == .todo {
            next.metadata.checked = false
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            document.blocks[index] = updatedCurrent
            document.blocks.insert(next, at: index + 1)
        }
        activateBlock(next.id, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func mergeBlockBackward(id: UUID) {
        let span = perfEditor.startSpan("BlockEditor.mergeBlockBackward", category: "Editor", level: .normal)
        defer { span.end() }

        guard let index = document.blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = document.blocks[index]
        let previous = document.blocks[index - 1]

        if current.text.isEmpty {
            _ = withAnimation(.easeInOut(duration: 0.18)) {
                document.blocks.remove(at: index)
            }
            activateBlock(previous.id, focusPosition: .end)
            syncText(manualCommit: true)
            return
        }

        guard previous.kind.acceptsRichBody, current.kind.acceptsRichBody else { return }

        var merged = previous
        let separator = mergeSeparator(previous: previous.kind, current: current.kind)
        merged.text += separator + current.text

        withAnimation(.easeInOut(duration: 0.18)) {
            document.blocks[index - 1] = merged
            document.blocks.remove(at: index)
        }
        activateBlock(merged.id, focusPosition: .end)
        syncText(manualCommit: true)
    }

    private func insertBlock(after blockID: UUID) {
        let span = perfEditor.startSpan("BlockEditor.insertBlock", category: "Editor", level: .normal)
        defer { span.end() }

        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let insertAfter = document.blocks[index]
        var next = DocumentBlock.empty(.paragraph)
        if insertAfter.kind == .bulletedList || insertAfter.kind == .numberedList || insertAfter.kind == .todo || insertAfter.kind == .quote {
            next.kind = followUpKind(for: insertAfter.kind)
            next.metadata.indentLevel = insertAfter.metadata.indentLevel
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.insert(next, at: index + 1)
        }
        activateBlock(next.id, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func deleteBlock(id: UUID, removingSlashRange: NSRange? = nil) {
        let span = perfEditor.startSpan("BlockEditor.deleteBlock", category: "Editor", level: .normal)
        defer { span.end() }

        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let fallbackID = document.blocks.indices.contains(max(0, index - 1)) ? document.blocks[max(0, index - 1)].id : nil
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.remove(at: index)
            if document.blocks.isEmpty {
                document.blocks = [.empty(.paragraph)]
            }
        }
        if let fallbackID {
            activateBlock(fallbackID)
        } else if let firstBlockID = document.blocks.first?.id {
            activateBlock(firstBlockID)
        }
        syncText(manualCommit: true)
    }

    private func duplicateBlock(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = document.blocks[index]
        copy.id = UUID()
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.insert(copy, at: index + 1)
        }
        activateBlock(copy.id, focusPosition: .end)
        syncText(manualCommit: true)
    }

    private func addResources(_ urls: [URL], after blockID: UUID?) {
        let newBlocks = urls.map(makeResourceBlock)
        guard !newBlocks.isEmpty else { return }
        let insertIndex: Int
        if let blockID, let index = document.blocks.firstIndex(where: { $0.id == blockID }) {
            insertIndex = index + 1
        } else {
            insertIndex = document.blocks.count
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            document.blocks.insert(contentsOf: newBlocks, at: insertIndex)
        }
        if let first = newBlocks.first {
            activateBlock(first.id, focusPosition: .end)
        }
        syncText(manualCommit: true)
    }

    private func adjustIndentation(for blockID: UUID, delta: Int) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        guard supportsIndentation(document.blocks[index].kind) else { return }
        document.blocks[index].metadata.indentLevel = max(0, document.blocks[index].metadata.indentLevel + delta)
        activateBlock(blockID)
        syncText(manualCommit: true)
    }

    private func moveFocus(from blockID: UUID, delta: Int) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let targetIndex = index + delta
        guard document.blocks.indices.contains(targetIndex) else { return }
        let targetID = document.blocks[targetIndex].id
        activateBlock(targetID, focusPosition: delta < 0 ? .end : .start)
    }

    private func activateBlock(_ blockID: UUID, focusPosition: BlockEditorFocusPosition? = nil) {
        activeBlockID = blockID
        editorResidency.recordInteraction(with: blockID)
        if let focusPosition {
            focusRequest = BlockEditorFocusRequest(blockID: blockID, position: focusPosition)
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

    private func makeResourceBlock(_ url: URL) -> DocumentBlock {
        if AttachedFile.pathIsImage(url.path) {
            var block = DocumentBlock.empty(.image)
            block.metadata.resource = url.path
            block.metadata.secondaryText = url.lastPathComponent
            return block
        }
        var block = DocumentBlock.empty(.file)
        block.text = url.lastPathComponent
        block.metadata.secondaryText = url.lastPathComponent
        block.metadata.resource = url.path
        return block
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
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let cleanedText = BlockEditorSlashQueryParser.removingToken(in: document.blocks[index].text, tokenRange: tokenRange)
        var block = DocumentBlock.empty(.paragraph)
        block.id = document.blocks[index].id
        block.text = cleanedText
        document.blocks[index] = block
        dismissSlash(blockID: blockID)
        activateBlock(blockID, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func createTablePreset(rows: Int, columns: Int, for blockID: UUID, tokenRange: NSRange) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        var block = document.blocks[index]
        block.kind = .table
        block.text = makeTablePresetMarkdown(rows: rows, columns: columns)
        block.metadata = DocumentBlockMetadata()
        document.blocks[index] = block
        dismissSlash(blockID: blockID)
        activateBlock(blockID, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func makeTablePresetMarkdown(rows: Int, columns: Int) -> String {
        let safeRows = max(rows, 1)
        let safeColumns = max(columns, 1)
        let header = (1...safeColumns).map { "列 \($0)" }
        let body = (1...max(safeRows - 1, 1)).map { row in
            (1...safeColumns).map { column in "值 \(row)-\(column)" }
        }
        return BlockMarkdownCodec.serializeTableContent([header] + body)
    }

    private func mutateBlock(id: UUID, removingSlashRange: NSRange? = nil, _ update: (inout DocumentBlock) -> Void) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = document.blocks[index]
        if let removingSlashRange {
            block.text = BlockEditorSlashQueryParser.removingToken(in: block.text, tokenRange: removingSlashRange)
        }
        update(&block)
        document.blocks[index] = block
        dismissSlash(blockID: id)
        activateBlock(id, focusPosition: .start)
        syncText(manualCommit: true)
    }

    private func followUpKind(for kind: DocumentBlockKind) -> DocumentBlockKind {
        switch kind {
        case .bulletedList, .numberedList, .todo, .quote:
            return kind
        default:
            return .paragraph
        }
    }

    private func mergeSeparator(previous: DocumentBlockKind, current: DocumentBlockKind) -> String {
        if previous == .code || previous == .source || previous == .table {
            return "\n"
        }
        if current == .quote || previous == .quote {
            return previous.textSeparatorForMerge
        }
        return previous.textSeparatorForMerge
    }

    private func supportsIndentation(_ kind: DocumentBlockKind) -> Bool {
        kind == .bulletedList || kind == .numberedList || kind == .todo || kind == .quote
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
    @Binding var dropTargetBlockID: UUID?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        dropTargetBlockID = targetID
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
        dropTargetBlockID = nil
        draggedBlockID = nil
        onCommit()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropTargetBlockID = nil
    }
}

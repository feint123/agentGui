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
    @State private var activeSlashBlockID: UUID?
    @State private var slashQuery = ""
    @State private var slashSelectionIndex = 0
    @State private var slashMenuPosition: CGRect = .zero
    @State private var draggedBlockID: UUID?
    @State private var dropTargetBlockID: UUID?
    @State private var focusRequest: BlockEditorFocusRequest?
    @State private var activeBlockID: UUID?
    @State private var editorResidency = BlockEditorResidency(maxMountedEditors: 3)
    @State private var selectionState: InlineSelectionState?
    @State private var pendingFormats: [UUID: InlineFormatRequest] = [:]
    @State private var syncGate = BlockDocumentSyncGate()

    var body: some View {
        ZStack(alignment: .topLeading) {
        scrollContent
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
            // Floating slash menu
            if let blockID = activeSlashBlockID, !slashMenuPosition.isEmpty {
                SlashCommandMenu(
                    query: slashQuery,
                    selectedKind: selectedSlashItem?.kind,
                    onSelect: { kind in convertBlock(id: blockID, to: kind) }
                )
                .position(slashMenuPosition(for: geo))
                .transition(.editorFloatingMenu)
                .zIndex(10)
            }
        }
        .allowsHitTesting(selectionState?.hasSelection == true || activeSlashBlockID != nil)
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
            isSlashPresented: activeSlashBlockID == block.id,
            slashQuery: activeSlashBlockID == block.id ? slashQuery : "",
            selectedSlashKind: activeSlashBlockID == block.id ? selectedSlashItem?.kind : nil,
            listIndex: orderedListIndices[block.id],
            onTextChange: { newValue in
                activateBlock(block.id)
                handleTextChange(for: block.id, text: newValue)
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
            onSlashMenuPositionChange: { rect in
                slashMenuPosition = rect
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

    private func slashMenuPosition(for geo: GeometryProxy) -> CGPoint {
        let viewFrame = geo.frame(in: .global)
        // slashMenuPosition is in screen coordinates, convert to view-local
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return CGPoint(x: 130, y: 80) }
        let contentHeight = contentView.frame.height
        let windowRect = window.convertFromScreen(slashMenuPosition)
        let flippedY = contentHeight - windowRect.maxY
        let rawX = windowRect.midX - viewFrame.minX
        let rawY = flippedY - viewFrame.minY
        // Center horizontally, position below the cursor point
        let clampedX = max(130, min(rawX, geo.size.width - 130))
        let clampedY = max(8, rawY + 8)
        return CGPoint(x: clampedX, y: clampedY)
    }

    private var editorBackground: some View {
        Rectangle().fill(BlockEditorTheme.pageBackground(for: colorScheme))
    }

    private func handleTextChange(for blockID: UUID, text newValue: String) {
        if let query = slashQueryIfNeeded(for: newValue) {
            withAnimation(.easeInOut(duration: 0.16)) {
                activeSlashBlockID = blockID
                slashQuery = query
                slashSelectionIndex = 0
            }
        } else if activeSlashBlockID == blockID {
            withAnimation(.easeInOut(duration: 0.12)) {
                activeSlashBlockID = nil
                slashQuery = ""
                slashSelectionIndex = 0
            }
        }
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
        case .slashCommit:
            commitSlashSelection(for: blockID)
        case .slashDismiss:
            dismissSlash(blockID: blockID)
        }
    }

    private func slashQueryIfNeeded(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        guard !trimmed.contains("\n") else { return nil }
        return String(trimmed.dropFirst())
    }

    private func convertBlock(id: UUID, to kind: DocumentBlockKind) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = document.blocks[index]
        let slashText = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if slashText.hasPrefix("/") {
            block.text = ""
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

    private func deleteBlock(id: UUID) {
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
        guard activeSlashBlockID == blockID else { return }
        let items = slashItems
        guard !items.isEmpty else { return }
        slashSelectionIndex = min(max(slashSelectionIndex + delta, 0), items.count - 1)
    }

    private func commitSlashSelection(for blockID: UUID) {
        guard activeSlashBlockID == blockID else {
            insertBlock(after: blockID)
            return
        }
        let items = slashItems
        guard !items.isEmpty else {
            dismissSlash(blockID: blockID)
            return
        }
        let item = items[min(max(slashSelectionIndex, 0), items.count - 1)]
        convertBlock(id: blockID, to: item.kind)
    }

    private func dismissSlash(blockID: UUID) {
        guard activeSlashBlockID == blockID else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            activeSlashBlockID = nil
            slashQuery = ""
            slashSelectionIndex = 0
        }
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

    private var slashItems: [SlashCommandItem] {
        SlashCommandItem.filtered(matching: slashQuery)
    }

    private var selectedSlashItem: SlashCommandItem? {
        let items = slashItems
        guard !items.isEmpty else { return nil }
        let index = min(max(slashSelectionIndex, 0), items.count - 1)
        return items[index]
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

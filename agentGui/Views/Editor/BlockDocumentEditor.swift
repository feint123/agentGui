//
//  BlockDocumentEditor.swift
//  agentGui
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BlockDocumentEditor: View {
    @Binding var text: String
    let fileURL: URL

    @State private var document = BlockDocument.empty
    @State private var isApplyingInternalChange = false
    @State private var activeSlashBlockID: UUID?
    @State private var slashQuery = ""
    @State private var slashSelectionIndex = 0
    @State private var draggedBlockID: UUID?
    @State private var dropTargetBlockID: UUID?
    @State private var focusRequest: BlockEditorFocusRequest?
    @State private var activeBlockID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                        BlockRowView(
                            block: $document.blocks[index],
                            focusRequest: focusRequest,
                            isActive: activeBlockID == block.id,
                            isSlashPresented: activeSlashBlockID == block.id,
                            slashQuery: activeSlashBlockID == block.id ? slashQuery : "",
                            selectedSlashKind: activeSlashBlockID == block.id ? selectedSlashItem?.kind : nil,
                            listIndex: orderedListIndex(at: index),
                            onTextChange: { newValue in
                                handleTextChange(for: block.id, text: newValue)
                            },
                            onEditorCommand: { command in
                                handleEditorCommand(command, for: block.id)
                            },
                            onFocusChange: { isFocused in
                                if isFocused {
                                    activeBlockID = block.id
                                } else if activeBlockID == block.id {
                                    activeBlockID = nil
                                }
                            },
                            onConvert: { kind in
                                convertBlock(id: block.id, to: kind)
                            },
                            onFileDrop: { urls in
                                addResources(urls, after: block.id)
                            }
                        )
                        .overlay(alignment: .top) {
                            if dropTargetBlockID == block.id {
                                RoundedRectangle(cornerRadius: BlockEditorTheme.blockCornerRadius)
                                    .fill(Color.accentColor.opacity(0.08))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activeBlockID = block.id
                            focusRequest = BlockEditorFocusRequest(blockID: block.id, position: .end)
                        }
                        .onDrag {
                            draggedBlockID = block.id
                            return NSItemProvider(object: block.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: BlockReorderDropDelegate(targetID: block.id, blocks: $document.blocks, draggedBlockID: $draggedBlockID, dropTargetBlockID: $dropTargetBlockID, onCommit: syncText))
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
            activeBlockID = document.blocks.first?.id
        }
        .onChange(of: text) { _, newValue in
            guard !isApplyingInternalChange else { return }
            let serialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
            if serialized != newValue {
                document = BlockMarkdownCodec.parse(newValue, fileURL: fileURL)
                if activeBlockID == nil {
                    activeBlockID = document.blocks.first?.id
                }
            }
        }
        .onChange(of: document.blocks) { _, _ in
            syncText()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleExternalFileDrop(providers)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    document.blocks.append(.empty(.paragraph))
                    syncText()
                } label: {
                    Label("插入正文", systemImage: "plus")
                }
                Button {
                    document.blocks.append(.empty(.divider))
                    syncText()
                } label: {
                    Label("插入分割线", systemImage: "minus")
                }
            }
        }
    }

    private var editorBackground: some View {
        BlockEditorTheme.pageBackground
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
        syncText()
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
        activeBlockID = id
        focusRequest = BlockEditorFocusRequest(blockID: id, position: .start)
        syncText()
    }

    private func splitBlock(id: UUID, selectedRange: NSRange) {
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
        activeBlockID = next.id
        focusRequest = BlockEditorFocusRequest(blockID: next.id, position: .start)
        syncText()
    }

    private func mergeBlockBackward(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = document.blocks[index]
        let previous = document.blocks[index - 1]

        if current.text.isEmpty {
            _ = withAnimation(.easeInOut(duration: 0.18)) {
                document.blocks.remove(at: index)
            }
            activeBlockID = previous.id
            focusRequest = BlockEditorFocusRequest(blockID: previous.id, position: .end)
            syncText()
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
        activeBlockID = merged.id
        focusRequest = BlockEditorFocusRequest(blockID: merged.id, position: .end)
        syncText()
    }

    private func insertBlock(after blockID: UUID) {
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
        activeBlockID = next.id
        focusRequest = BlockEditorFocusRequest(blockID: next.id, position: .start)
        syncText()
    }

    private func deleteBlock(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let fallbackID = document.blocks.indices.contains(max(0, index - 1)) ? document.blocks[max(0, index - 1)].id : nil
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.remove(at: index)
            if document.blocks.isEmpty {
                document.blocks = [.empty(.paragraph)]
            }
        }
        activeBlockID = fallbackID ?? document.blocks.first?.id
        syncText()
    }

    private func duplicateBlock(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = document.blocks[index]
        copy.id = UUID()
        withAnimation(.easeInOut(duration: 0.2)) {
            document.blocks.insert(copy, at: index + 1)
        }
        activeBlockID = copy.id
        focusRequest = BlockEditorFocusRequest(blockID: copy.id, position: .end)
        syncText()
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
        activeBlockID = newBlocks.first?.id
        if let first = newBlocks.first {
            focusRequest = BlockEditorFocusRequest(blockID: first.id, position: .end)
        }
        syncText()
    }

    private func adjustIndentation(for blockID: UUID, delta: Int) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        guard supportsIndentation(document.blocks[index].kind) else { return }
        document.blocks[index].metadata.indentLevel = max(0, document.blocks[index].metadata.indentLevel + delta)
        activeBlockID = blockID
        syncText()
    }

    private func moveFocus(from blockID: UUID, delta: Int) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let targetIndex = index + delta
        guard document.blocks.indices.contains(targetIndex) else { return }
        let targetID = document.blocks[targetIndex].id
        activeBlockID = targetID
        focusRequest = BlockEditorFocusRequest(blockID: targetID, position: delta < 0 ? .end : .start)
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

    private func syncText() {
        let serialized = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        guard serialized != text else { return }
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

    private func orderedListIndex(at index: Int) -> Int? {
        guard document.blocks.indices.contains(index) else { return nil }
        let current = document.blocks[index]
        guard current.kind == .numberedList else { return nil }

        let indentLevel = current.metadata.indentLevel
        var listIndex = 1
        var cursor = index - 1

        while cursor >= 0 {
            let previous = document.blocks[cursor]

            if previous.metadata.indentLevel > indentLevel {
                cursor -= 1
                continue
            }

            guard previous.metadata.indentLevel == indentLevel, previous.kind == .numberedList else {
                break
            }

            listIndex += 1
            cursor -= 1
        }

        return listIndex
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

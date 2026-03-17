import Foundation

struct BlockEditorMutationDriver {
    var history: BlockEditorHistoryController

    @discardableResult
    mutating func applyMutation(
        kind: BlockEditorHistoryEntry.Kind,
        title: String,
        mergePolicy: BlockEditorHistoryEntry.MergePolicy = .never,
        timestamp: Date = .init(),
        editor: inout BlockEditorRuntimeState,
        mutation: (inout BlockEditorRuntimeState) -> Void
    ) -> Bool {
        let before = editor.snapshot()
        mutation(&editor)
        let after = editor.snapshot()

        guard before != after else { return false }

        history.record(
            BlockEditorHistoryEntry(
                id: UUID(),
                kind: kind,
                title: title,
                before: before,
                after: after,
                mergePolicy: mergePolicy,
                timestamp: timestamp
            )
        )
        return true
    }
}

extension BlockEditorRuntimeState {
    mutating func reorderBlock(from sourceIndex: Int, to destinationIndex: Int) {
        guard document.blocks.indices.contains(sourceIndex),
              document.blocks.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }

        let block = document.blocks.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? max(destinationIndex - 1, 0) : destinationIndex
        document.blocks.insert(block, at: adjustedDestination)
        activateBlock(block.id, caretOffset: block.text.utf16.count)
    }

    mutating func applyRowEdit(id: UUID, edit: BlockRowEdit) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = document.blocks[index]

        switch edit {
        case .setText(let text):
            block.text = text
        case .setChecked(let checked):
            block.metadata.checked = checked
        case .setLanguage(let language):
            block.metadata.language = language
        case .setResource(let resource):
            block.metadata.resource = resource
        case .setSecondaryText(let secondaryText):
            block.metadata.secondaryText = secondaryText
        case .setTone(let tone):
            block.metadata.tone = tone
        case .setCollapsed(let isCollapsed):
            block.metadata.isCollapsed = isCollapsed
        }

        document.blocks[index] = block
        let caretOffset = min(block.text.utf16.count, focus?.blockID == id ? focus?.caretUTF16Offset ?? block.text.utf16.count : block.text.utf16.count)
        activateBlock(id, caretOffset: caretOffset)
    }

    mutating func updateToggleMetadata(id: UUID, title: String, isCollapsed: Bool) {
        applyRowEdit(id: id, edit: .setSecondaryText(title))
        applyRowEdit(id: id, edit: .setCollapsed(isCollapsed))
    }

    mutating func updateCalloutMetadata(id: UUID, tone: String, title: String) {
        applyRowEdit(id: id, edit: .setTone(tone))
        applyRowEdit(id: id, edit: .setSecondaryText(title))
    }

    mutating func convertBlock(id: UUID, to kind: DocumentBlockKind, removingSlashRange: NSRange? = nil) {
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
        if supportsIndentation(kind) == false {
            block.metadata.indentLevel = 0
        }
        document.blocks[index] = block
        activateBlock(id, caretOffset: 0)
    }

    mutating func splitBlock(id: UUID, selectedRange: NSRange) {
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

        document.blocks[index] = updatedCurrent
        document.blocks.insert(next, at: index + 1)
        activateBlock(next.id, caretOffset: 0)
    }

    mutating func mergeBlockBackward(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let current = document.blocks[index]
        let previous = document.blocks[index - 1]

        if current.text.isEmpty {
            document.blocks.remove(at: index)
            activateBlock(previous.id, caretOffset: previous.text.utf16.count)
            ensureDocumentNotEmpty()
            return
        }

        guard previous.kind.acceptsRichBody, current.kind.acceptsRichBody else { return }

        var merged = previous
        let separator = mergeSeparator(previous: previous.kind, current: current.kind)
        merged.text += separator + current.text

        document.blocks[index - 1] = merged
        document.blocks.remove(at: index)
        activateBlock(merged.id, caretOffset: merged.text.utf16.count)
        ensureDocumentNotEmpty()
    }

    mutating func deleteBlock(id: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let fallbackID = document.blocks.indices.contains(max(0, index - 1)) ? document.blocks[max(0, index - 1)].id : nil
        document.blocks.remove(at: index)
        ensureDocumentNotEmpty()
        if let fallbackID {
            let fallbackLength = document.blocks.first(where: { $0.id == fallbackID })?.text.utf16.count ?? 0
            activateBlock(fallbackID, caretOffset: fallbackLength)
        } else if let firstBlockID = document.blocks.first?.id {
            let firstLength = document.blocks.first?.text.utf16.count ?? 0
            activateBlock(firstBlockID, caretOffset: firstLength)
        }
    }

    mutating func adjustIndentation(for blockID: UUID, delta: Int) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        guard supportsIndentation(document.blocks[index].kind) else { return }
        document.blocks[index].metadata.indentLevel = max(0, document.blocks[index].metadata.indentLevel + delta)
        let caretOffset = min(document.blocks[index].text.utf16.count, focus?.blockID == blockID ? focus?.caretUTF16Offset ?? document.blocks[index].text.utf16.count : document.blocks[index].text.utf16.count)
        activateBlock(blockID, caretOffset: caretOffset)
    }

    mutating func clearFormatting(for blockID: UUID, tokenRange: NSRange) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let cleanedText = BlockEditorSlashQueryParser
            .removingToken(in: document.blocks[index].text, tokenRange: tokenRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var block = DocumentBlock.empty(.paragraph)
        block.id = document.blocks[index].id
        block.text = cleanedText
        document.blocks[index] = block
        activateBlock(blockID, caretOffset: 0)
    }

    mutating func createTablePreset(rows: Int, columns: Int, for blockID: UUID, tokenRange: NSRange) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        var block = document.blocks[index]
        block.kind = .table
        block.text = makeTablePresetMarkdown(rows: rows, columns: columns)
        block.metadata = DocumentBlockMetadata()
        document.blocks[index] = block
        activateBlock(blockID, caretOffset: 0)
    }

    mutating func insertBlock(after blockID: UUID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let insertAfter = document.blocks[index]
        var next = DocumentBlock.empty(.paragraph)
        if insertAfter.kind == .bulletedList || insertAfter.kind == .numberedList || insertAfter.kind == .todo || insertAfter.kind == .quote {
            next.kind = followUpKind(for: insertAfter.kind)
            next.metadata.indentLevel = insertAfter.metadata.indentLevel
        }
        document.blocks.insert(next, at: index + 1)
        activateBlock(next.id, caretOffset: 0)
    }

    mutating func addResources(_ urls: [URL], after blockID: UUID?) {
        let newBlocks = urls.map(makeResourceBlock)
        guard !newBlocks.isEmpty else { return }
        let insertIndex: Int
        if let blockID, let index = document.blocks.firstIndex(where: { $0.id == blockID }) {
            insertIndex = index + 1
        } else {
            insertIndex = document.blocks.count
        }
        document.blocks.insert(contentsOf: newBlocks, at: insertIndex)
        if let first = newBlocks.first {
            activateBlock(first.id, caretOffset: first.text.utf16.count)
        }
    }

    private mutating func activateBlock(_ blockID: UUID, caretOffset: Int?) {
        activeBlockID = blockID
        selection = nil
        if let caretOffset {
            focus = BlockEditorFocusSnapshot(blockID: blockID, caretUTF16Offset: caretOffset)
        } else {
            focus = nil
        }
    }

    private mutating func ensureDocumentNotEmpty() {
        if document.blocks.isEmpty {
            document.blocks = [.empty(.paragraph)]
        }
    }

    private func followUpKind(for kind: DocumentBlockKind) -> DocumentBlockKind {
        switch kind {
        case .bulletedList, .numberedList, .todo, .quote:
            return kind
        default:
            return .paragraph
        }
    }

    private func supportsIndentation(_ kind: DocumentBlockKind) -> Bool {
        kind == .bulletedList || kind == .numberedList || kind == .todo || kind == .quote
    }

    private func mergeSeparator(previous: DocumentBlockKind, current: DocumentBlockKind) -> String {
        if previous == .code || previous == .source || previous == .table {
            return "\n"
        }
        return previous.textSeparatorForMerge
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

    var textNeedsSpaceSeparator: Bool {
        switch self {
        case .paragraph, .heading1, .heading2, .heading3, .bulletedList, .numberedList, .todo, .callout, .toggle, .quote:
            return true
        default:
            return false
        }
    }
}
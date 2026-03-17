//
//  BlockTableEditor.swift
//  agentGui
//

import AppKit
import SwiftUI

struct BlockTableCellID: Hashable {
    let row: Int
    let column: Int
}

struct BlockTableCellResidency: Equatable {
    private(set) var mountedCellIDs: [BlockTableCellID] = []
    let maxMountedEditors: Int

    init(maxMountedEditors: Int = 1) {
        self.maxMountedEditors = max(1, maxMountedEditors)
    }

    mutating func recordInteraction(with cellID: BlockTableCellID) {
        mountedCellIDs.removeAll { $0 == cellID }
        mountedCellIDs.insert(cellID, at: 0)
        if mountedCellIDs.count > maxMountedEditors {
            mountedCellIDs.removeSubrange(maxMountedEditors...)
        }
    }

    mutating func retain(in rows: [[String]]) {
        let validCellIDs = Set(
            rows.enumerated().flatMap { rowIndex, row in
                row.indices.map { columnIndex in
                    BlockTableCellID(row: rowIndex, column: columnIndex)
                }
            }
        )
        mountedCellIDs.removeAll { !validCellIDs.contains($0) }
    }

    func shouldMountEditor(for cellID: BlockTableCellID) -> Bool {
        mountedCellIDs.contains(cellID)
    }
}

struct BlockTableEditor: View {
    @Binding var markdown: String

    @State private var rows: [[String]] = []
    @State private var isApplyingInternalChange = false
    @State private var residency = BlockTableCellResidency(maxMountedEditors: 1)
    @State private var focusedCellID: BlockTableCellID?
    @State private var focusedCellRequest: BlockEditorFocusRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("表格", systemImage: "tablecells")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BlockEditorTheme.subtleText)
                Spacer(minLength: 0)
                Button("加列") { addColumn() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(BlockEditorTheme.subtleText)
                Button("加行") { addRow() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(BlockEditorTheme.subtleText)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, _ in
                                cellView(row: rowIndex, column: columnIndex)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear {
            rows = BlockMarkdownCodec.parseTableContent(markdown)
            pruneCellResidency()
        }
        .onChange(of: markdown) { _, newValue in
            guard !isApplyingInternalChange else { return }
            rows = BlockMarkdownCodec.parseTableContent(newValue)
            pruneCellResidency()
        }
    }

    private func cellView(row: Int, column: Int) -> some View {
        let cellID = BlockTableCellID(row: row, column: column)
        let isMounted = residency.shouldMountEditor(for: cellID)

        return Group {
            if isMounted {
                BlockTableCellTextEditor(
                    blockID: blockID(for: cellID),
                    text: bindingForCell(row: row, column: column),
                    placeholder: cellPlaceholder(forRow: row),
                    focusRequest: focusedCellID == cellID ? focusedCellRequest : nil,
                    onFocusChange: { isFocused in
                        if isFocused {
                            focusedCellID = cellID
                        } else if focusedCellID == cellID {
                            focusedCellID = nil
                        }
                    }
                )
            } else {
                Button {
                    activateCell(cellID)
                } label: {
                    Group {
                        if cellTextIsPlaceholder(row: row, column: column) {
                            Text(cellPlaceholder(forRow: row))
                                .foregroundStyle(BlockEditorTheme.subtleText)
                        } else {
                            InlineMarkdownText(text: rows[row][column], font: .system(size: 14), color: .primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 140, alignment: .leading)
        .background(row == 0 ? Color.primary.opacity(0.04) : Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(.rect)
        .onTapGesture {
            activateCell(cellID)
        }
    }

    private func bindingForCell(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: {
                guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
                return rows[row][column]
            },
            set: { newValue in
                guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
                rows[row][column] = newValue
                syncMarkdown()
            }
        )
    }

    private func addRow() {
        let columnCount = max(rows.first?.count ?? 0, 2)
        rows.append(Array(repeating: "", count: columnCount))
        activateCell(BlockTableCellID(row: rows.count - 1, column: 0))
        syncMarkdown()
    }

    private func addColumn() {
        if rows.isEmpty {
            rows = Array(repeating: Array(repeating: "", count: 2), count: 2)
        } else {
            for index in rows.indices {
                rows[index].append("")
            }
        }
        activateCell(BlockTableCellID(row: 0, column: max((rows.first?.count ?? 1) - 1, 0)))
        syncMarkdown()
    }

    private func activateCell(_ cellID: BlockTableCellID) {
        guard isValidCell(cellID) else { return }
        residency.recordInteraction(with: cellID)
        focusedCellID = cellID
        focusedCellRequest = BlockEditorFocusRequest(blockID: blockID(for: cellID), position: .end)
    }

    private func pruneCellResidency() {
        residency.retain(in: rows)
        if let focusedCellID, !isValidCell(focusedCellID) {
            self.focusedCellID = nil
            focusedCellRequest = nil
        }
    }

    private func blockID(for cellID: BlockTableCellID) -> UUID {
        let source = "table-cell-\(cellID.row)-\(cellID.column)"
        let utf8 = Array(source.utf8)
        let bytes = (utf8 + Array(repeating: UInt8(0), count: 16)).prefix(16)
        let tuple = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

    private func isValidCell(_ cellID: BlockTableCellID) -> Bool {
        rows.indices.contains(cellID.row) && rows[cellID.row].indices.contains(cellID.column)
    }

    private func cellPlaceholder(forRow row: Int) -> String {
        row == 0 ? "表头" : "内容"
    }

    private func cellDisplayText(row: Int, column: Int) -> String {
        let value = rows[row][column].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? cellPlaceholder(forRow: row) : rows[row][column]
    }

    private func cellTextIsPlaceholder(row: Int, column: Int) -> Bool {
        rows[row][column].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncMarkdown() {
        let serialized = BlockMarkdownCodec.serializeTableContent(rows)
        guard serialized != markdown else { return }
        isApplyingInternalChange = true
        markdown = serialized
        DispatchQueue.main.async {
            isApplyingInternalChange = false
        }
    }
}

private struct BlockTableCellTextEditor: NSViewRepresentable {
    let blockID: UUID
    @Binding var text: String
    let placeholder: String
    let focusRequest: BlockEditorFocusRequest?
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = BlockEditorTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.interceptsEditorCommands = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.textContainer?.maximumNumberOfLines = 1
        textView.layoutManager?.delegate = textView
        textView.string = text
        textView.placeholder = placeholder
        textView.blockKind = .paragraph
        textView.onFocusChange = onFocusChange
        textView.setAccessibilityIdentifier("blockTable.cellTextView")
        BlockInlineMarkdownStyler.apply(to: textView, kind: .paragraph)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BlockEditorTextView else { return }
        context.coordinator.parent = self
        textView.placeholder = placeholder

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        BlockInlineMarkdownStyler.apply(to: textView, kind: .paragraph)

        if let focusRequest, focusRequest.blockID == blockID, textView.lastAppliedFocusToken != focusRequest.token {
            textView.lastAppliedFocusToken = focusRequest.token
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                let projection = BlockInlineMarkdownProjection(sourceText: textView.string)
                let location: Int
                switch focusRequest.position {
                case .start:
                    location = 0
                case .end:
                    location = projection.normalizedSourceOffset(for: textView.string.utf16.count)
                case .offset(let offset):
                    location = projection.normalizedSourceOffset(for: max(0, min(offset, textView.string.utf16.count)))
                }
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTableCellTextEditor

        init(_ parent: BlockTableCellTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? BlockEditorTextView else { return }
            parent.text = textView.string
            BlockInlineMarkdownStyler.apply(to: textView, kind: .paragraph)
        }
    }
}
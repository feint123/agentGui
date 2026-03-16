//
//  BlockTableEditor.swift
//  agentGui
//

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
    @FocusState private var focusedCellID: BlockTableCellID?

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
                TextField(cellPlaceholder(forRow: row), text: bindingForCell(row: row, column: column))
                    .textFieldStyle(.plain)
                    .focused($focusedCellID, equals: cellID)
                    .onAppear {
                        guard focusedCellID != cellID else { return }
                        DispatchQueue.main.async {
                            focusedCellID = cellID
                        }
                    }
            } else {
                Button {
                    activateCell(cellID)
                } label: {
                    Text(cellDisplayText(row: row, column: column))
                        .foregroundStyle(cellTextIsPlaceholder(row: row, column: column) ? BlockEditorTheme.subtleText : .primary)
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
        if focusedCellID != cellID {
            DispatchQueue.main.async {
                focusedCellID = cellID
            }
        }
    }

    private func pruneCellResidency() {
        residency.retain(in: rows)
        if let focusedCellID, !isValidCell(focusedCellID) {
            self.focusedCellID = nil
        }
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
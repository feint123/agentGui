//
//  BlockTableEditor.swift
//  agentGui
//

import SwiftUI

struct BlockTableEditor: View {
    @Binding var markdown: String

    @State private var rows: [[String]] = []
    @State private var isApplyingInternalChange = false

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
                                TextField(rowIndex == 0 ? "表头" : "内容", text: bindingForCell(row: rowIndex, column: columnIndex))
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(minWidth: 140, alignment: .leading)
                                    .background(rowIndex == 0 ? Color.primary.opacity(0.04) : Color.white.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                                    )
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
        }
        .onChange(of: markdown) { _, newValue in
            guard !isApplyingInternalChange else { return }
            rows = BlockMarkdownCodec.parseTableContent(newValue)
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
        syncMarkdown()
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
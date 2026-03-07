//
//  TodoListView.swift
//  agentGui
//

import SwiftUI

// MARK: - TodoListView

/// 折叠式任务列表，显示 agent 的 update_todo_list 工具调用结果
struct TodoListView: View {

    let items: [TodoItem]
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    TodoRowView(item: item)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("任务列表")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(doneCount)/\(items.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var doneCount: Int {
        items.filter { $0.status == .done }.count
    }
}

// MARK: - TodoRowView

private struct TodoRowView: View {

    let item: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.status.icon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(item.status == .done ? .tertiary : .primary)
                    .strikethrough(item.status == .done || item.status == .cancelled)
                    .lineLimit(3)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var statusColor: Color {
        switch item.status {
        case .pending:    return .secondary
        case .inProgress: return .accentColor
        case .done:       return .green
        case .cancelled:  return .secondary
        }
    }
}

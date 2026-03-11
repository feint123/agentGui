//
//  TodoListView.swift
//  agentGui
//

import SwiftUI

struct TodoRowContentView: View {
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

//
//  TodoItem.swift
//  agentGui
//

import Foundation

// MARK: - TodoStatus

enum TodoStatus: String, Codable, CaseIterable {
    case pending      = "pending"
    case inProgress   = "in_progress"
    case done         = "done"
    case cancelled    = "cancelled"

    var icon: String {
        switch self {
        case .pending:    return "circle"
        case .inProgress: return "arrow.trianglehead.2.clockwise"
        case .done:       return "checkmark.circle.fill"
        case .cancelled:  return "xmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .pending:    return "待处理"
        case .inProgress: return "进行中"
        case .done:       return "已完成"
        case .cancelled:  return "已取消"
        }
    }
}

// MARK: - TodoItem

struct TodoItem: Codable, Identifiable {
    var id: String
    var title: String
    var status: TodoStatus
    var notes: String?

    init(id: String = UUID().uuidString, title: String, status: TodoStatus = .pending, notes: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.notes = notes
    }
}

// agentGui/Models/GitSummary.swift
import Foundation

/// Git 状态优先级（Comparable：值越小优先级越高）。
/// 对应 Zed `git::status::GitSummary` 的聚合优先级概念。
enum GitSummary: Int, Comparable, Sendable, CaseIterable {
    case conflict   = 0   // 冲突（最高优先级）
    case untracked  = 1   // 未跟踪
    case deleted    = 2   // 已删除
    case modified   = 3   // 已修改（未暂存）
    case staged     = 4   // 已暂存
    case added      = 5   // 新增（最低优先级）

    static func < (lhs: GitSummary, rhs: GitSummary) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

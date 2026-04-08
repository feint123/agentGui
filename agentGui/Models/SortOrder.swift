// agentGui/Models/SortOrder.swift
import Foundation

/// 文件树排序方式。对应 VSCode `explorer.sortOrder` 配置项。
enum SortOrder: Sendable, CaseIterable {
    case nameAsc          // 名称升序（默认：目录优先）
    case nameDesc         // 名称降序
    case directoriesFirst // 等同 nameAsc，目录永远排在文件前
    case mixed            // 目录和文件混排（VSCode `mixed` 模式）
}

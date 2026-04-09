// agentGui/Views/Skills/SkillRowPresentation.swift
import Foundation

/// 纯值类型，封装 SkillsView 中单行的所有 UI 显示决策。
/// 不依赖 SwiftUI，便于单元测试。
struct SkillRowPresentation {
    let skill: Skill

    /// 是否展示启用/禁用开关（内置技能不展示）
    var toggleIsVisible: Bool {
        skill.loadedFrom != .bundled
    }

    /// 技能来源的展示标签
    var sourceLabel: String {
        switch skill.loadedFrom {
        case .user:    return "用户"
        case .project: return "项目"
        case .managed: return "管理"
        case .bundled: return "内置"
        }
    }

    /// 是否展示 fork 执行模式徽章（inline 为默认，不展示）
    var showForkBadge: Bool {
        skill.executionContext == .fork
    }

    /// 版本文本（加 "v" 前缀），nil 则不展示版本徽章
    var versionText: String? {
        guard let version = skill.version, !version.isEmpty else { return nil }
        return "v\(version)"
    }

    /// 是否展示"接受参数"标签（argumentHint 非空时展示）
    var showArgumentHintTag: Bool {
        guard let hint = skill.argumentHint else { return false }
        return !hint.isEmpty
    }

    /// 是否展示"按路径激活"徽章（paths 非空时展示）
    var showConditionalPathsBadge: Bool {
        skill.paths != nil
    }

    /// 是否展示 whenToUse 折叠区域
    var showWhenToUseDisclosure: Bool {
        guard let text = skill.whenToUse else { return false }
        return !text.isEmpty
    }
}

import Foundation
import SwiftUI

enum WorkbenchLSPStatusTone: Equatable {
    case positive
    case warning
    case negative
    case neutral

    static func tone(for statusText: String) -> WorkbenchLSPStatusTone {
        let normalized = statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("running") || normalized.contains("运行中") {
            return .positive
        }

        if normalized.contains("starting") || normalized.contains("启动中") {
            return .warning
        }

        if normalized.contains("failed")
            || normalized.contains("crashed")
            || normalized.contains("未安装")
            || normalized.contains("启动失败")
            || normalized.contains("运行崩溃")
            || normalized.contains("配置异常")
            || normalized.contains("无匹配") {
            return .negative
        }

        return .neutral
    }

    var color: Color {
        switch self {
        case .positive:
            return .green
        case .warning:
            return .orange
        case .negative:
            return .red
        case .neutral:
            return .secondary
        }
    }
}

struct WorkbenchLSPDiagnosticRowPresentation: Equatable {
    let severity: LSPDiagnosticSeverity
    let severityText: String
    let pathText: String
    let messageText: String
    let metadataText: String?

    static func make(_ item: LSPProjectDiagnosticsSummary.DiagnosticItem) -> WorkbenchLSPDiagnosticRowPresentation {
        var metadataParts: [String] = []
        if let source = item.source, !source.isEmpty {
            metadataParts.append(source)
        }
        if let line = item.line, let character = item.character {
            metadataParts.append("L\(line + 1):C\(character + 1)")
        }

        return WorkbenchLSPDiagnosticRowPresentation(
            severity: item.severity,
            severityText: item.severity.rawValue,
            pathText: URL(string: item.uri)?.lastPathComponent ?? item.uri,
            messageText: item.message,
            metadataText: metadataParts.isEmpty ? nil : metadataParts.joined(separator: " · ")
        )
    }

    var severityColor: Color {
        switch severity {
        case .error:
            return .red
        case .warning:
            return .orange
        case .information:
            return .blue
        case .hint:
            return .secondary
        }
    }
}

enum WorkbenchLSPServiceActionPresentation {
    private static let priority: [LSPManagementAction: Int] = [
        .install: 0,
        .repair: 1,
        .start: 2,
        .stop: 3,
        .restart: 4,
        .recheck: 5,
    ]

    static func primaryActions(from actions: [LSPManagementAction], limit: Int = 2) -> [LSPManagementAction] {
        Array(sorted(actions).prefix(limit))
    }

    static func secondaryActions(from actions: [LSPManagementAction], limit: Int = 2) -> [LSPManagementAction] {
        Array(sorted(actions).dropFirst(limit))
    }

    static func title(for action: LSPManagementAction) -> String {
        switch action {
        case .install:
            return "安装"
        case .recheck:
            return "重检"
        case .start:
            return "启动"
        case .stop:
            return "停止"
        case .restart:
            return "重启"
        case .repair:
            return "修复"
        }
    }

    private static func sorted(_ actions: [LSPManagementAction]) -> [LSPManagementAction] {
        actions.sorted { lhs, rhs in
            let left = priority[lhs, default: .max]
            let right = priority[rhs, default: .max]
            if left == right {
                return title(for: lhs) < title(for: rhs)
            }
            return left < right
        }
    }
}
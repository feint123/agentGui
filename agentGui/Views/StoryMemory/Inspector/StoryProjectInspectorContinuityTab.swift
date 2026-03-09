import SwiftUI

struct StoryProjectInspectorContinuityTab: View {
    let groups: [StoryProjectContinuityGroup]

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("连续性问题", count: groups.reduce(0) { $0 + $1.items.count }) {
                if groups.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无连续性问题", systemImage: "exclamationmark.triangle")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            StoryProjectInspectorSection(displayStatus(group.status), count: group.items.count) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(group.items) { item in
                                        StoryProjectInspectorCard {
                                            VStack(alignment: .leading, spacing: 10) {
                                                HStack(alignment: .top) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(item.issueKind)
                                                            .font(.headline)
                                                        Text(item.detail)
                                                            .font(.subheadline)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    Spacer(minLength: 0)
                                                    Text(displaySeverity(item.severity))
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(item.severity == "critical" ? .red : .orange)
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 6)
                                                        .background(.thinMaterial, in: Capsule())
                                                }
                                                StoryProjectInspectorDetailGrid(items: [
                                                    ("状态", displayStatus(group.status)),
                                                    ("章节", item.chapterNumber > 0 ? "第 \(item.chapterNumber) 章" : "未标记"),
                                                    ("场景", item.sceneIndex > 0 ? "场景 \(item.sceneIndex)" : "未标记"),
                                                    ("严重级别", displaySeverity(item.severity))
                                                ])
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func displayStatus(_ value: String) -> String {
        switch value {
        case "open":
            return "待处理"
        case "accepted":
            return "已接受"
        case "wont_fix":
            return "不修复"
        case "resolved":
            return "已解决"
        default:
            return value
        }
    }

    private func displaySeverity(_ value: String) -> String {
        switch value {
        case "critical", "error", "high":
            return "严重"
        case "warning", "medium":
            return "警告"
        case "info", "low":
            return "提示"
        default:
            return value
        }
    }
}
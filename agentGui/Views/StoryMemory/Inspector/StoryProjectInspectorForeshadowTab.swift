import SwiftUI

struct StoryProjectInspectorForeshadowTab: View {
    let groups: [StoryProjectForeshadowGroup]

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("伏笔追踪", count: groups.reduce(0) { $0 + $1.items.count }) {
                if groups.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无伏笔记录", systemImage: "lightbulb")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            StoryProjectInspectorSection(displayStatus(group.status), count: group.items.count) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(group.items) { item in
                                        StoryProjectInspectorCard {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Text(item.tag)
                                                    .font(.headline)
                                                Text(item.detail)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                StoryProjectInspectorDetailGrid(items: [
                                                    ("引入章节", item.introducedInChapter > 0 ? "第 \(item.introducedInChapter) 章" : "未标记"),
                                                    ("解决章节", item.resolvedInChapter > 0 ? "第 \(item.resolvedInChapter) 章" : "未解决"),
                                                    ("关联事件", "\(item.relatedEventCount)"),
                                                    ("状态", displayStatus(group.status))
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
            return "未解决"
        case "planned":
            return "计划中"
        case "payoff":
            return "回收中"
        case "resolved":
            return "已解决"
        default:
            return value
        }
    }
}
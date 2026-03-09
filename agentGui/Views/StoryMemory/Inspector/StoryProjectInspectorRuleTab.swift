import SwiftUI

struct StoryProjectInspectorRuleTab: View {
    let sections: [StoryProjectWorldRuleSection]
    let onJump: (StoryProjectInspectorJumpTarget) -> Void

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("世界规则", count: sections.reduce(0) { $0 + $1.rules.count }) {
                if sections.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无世界规则", systemImage: "scroll")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections) { section in
                            StoryProjectInspectorSection(section.category, count: section.rules.count) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(section.rules) { rule in
                                        StoryProjectInspectorCard {
                                            VStack(alignment: .leading, spacing: 10) {
                                                HStack(alignment: .top) {
                                                    Text(rule.title)
                                                        .font(.headline)
                                                    Spacer(minLength: 0)
                                                    StoryProjectInspectorChipButton(title: rule.mutablePolicy, action: nil)
                                                }
                                                Text(rule.detail)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                StoryProjectInspectorDetailGrid(items: [
                                                    ("适用范围", rule.scope),
                                                    ("建立章节", rule.establishedInChapter > 0 ? "第 \(rule.establishedInChapter) 章" : "未标记")
                                                ])
                                                if !rule.exceptions.isEmpty {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("例外")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                        StoryProjectInspectorChipCloud(rule.exceptions)
                                                    }
                                                }
                                                if !rule.relatedEntities.isEmpty {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("相关实体")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                        StoryProjectInspectorChipCloud(rule.relatedEntities) { value in
                                                            onJump(.init(tab: .locations, anchorID: value))
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
            }
        }
    }
}
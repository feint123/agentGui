import SwiftUI

struct StoryProjectInspectorLocationTab: View {
    let cards: [StoryProjectLocationCard]
    let onJump: (StoryProjectInspectorJumpTarget) -> Void

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("地点档案", count: cards.count) {
                if cards.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无地点档案", systemImage: "map")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(cards) { location in
                            StoryProjectInspectorCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(location.name)
                                        .font(.title3.bold())
                                    Text(location.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                    if !location.traits.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("特征")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(location.traits)
                                        }
                                    }
                                    if !location.relatedRules.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("相关规则")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(location.relatedRules) { value in
                                                onJump(.init(tab: .rules, anchorID: value))
                                            }
                                        }
                                    }
                                    if !location.occupants.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("常驻角色")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(location.occupants) { value in
                                                onJump(.init(tab: .characters, anchorID: value))
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
import SwiftUI

struct StoryProjectInspectorCharacterTab: View {
    let cards: [StoryProjectCharacterCard]

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("角色档案", count: cards.count) {
                if cards.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无角色档案", systemImage: "person.2")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(cards) { character in
                            StoryProjectInspectorCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(character.name)
                                        .font(.title3.bold())
                                    Text(character.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(4)
                                    StoryProjectInspectorDetailGrid(items: [
                                        ("说话风格", character.speechStyle),
                                        ("角色弧线", character.arcStage),
                                        ("最近出场", character.lastSeenChapter > 0 ? "第 \(character.lastSeenChapter) 章" : "未记录"),
                                        ("当前位置", character.lastKnownLocation)
                                    ])
                                    if !character.traits.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("性格特征")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(character.traits)
                                        }
                                    }
                                    if !character.goals.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("目标")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(character.goals)
                                        }
                                    }
                                    if !character.relationshipSummary.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("关系")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            StoryProjectInspectorChipCloud(character.relationshipSummary)
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
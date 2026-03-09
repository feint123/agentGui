import SwiftUI

struct StoryProjectInspectorStyleTab: View {
    let card: StoryProjectStyleCard?

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("风格档案") {
                if let card {
                    VStack(alignment: .leading, spacing: 18) {
                        StoryProjectInspectorCard {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                                GridRow {
                                    metric(title: "叙事声音", value: card.narrativeVoice)
                                    metric(title: "作者偏好", value: card.authorPreferences)
                                }
                                GridRow {
                                    metric(title: "平均句长", value: card.sentenceLengthMean.formatted(.number.precision(.fractionLength(0))))
                                    metric(title: "对话占比", value: card.dialogueRatio.formatted(.percent.precision(.fractionLength(0))))
                                }
                                GridRow {
                                    metric(title: "意象密度", value: card.imageryDensity.formatted(.number.precision(.fractionLength(2))))
                                    Color.clear
                                }
                            }
                        }
                        StoryProjectInspectorCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("示例段落")
                                    .font(.headline)
                                if card.samplePassages.isEmpty {
                                    Text("暂无")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(card.samplePassages, id: \.self) { sample in
                                        Text(sample)
                                            .font(.body)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                        StoryProjectInspectorCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("反模式")
                                    .font(.headline)
                                if card.antiPatterns.isEmpty {
                                    Text("暂无")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    StoryProjectInspectorChipCloud(card.antiPatterns)
                                }
                            }
                        }
                    }
                } else {
                    StoryProjectInspectorEmptyState(title: "暂无风格档案", systemImage: "text.book.closed")
                }
            }
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
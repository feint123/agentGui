import SwiftUI

struct StoryProjectInspectorOverviewTab: View {
    let snapshot: StoryProjectInspectorSnapshot
    let onJumpToTab: (StoryProjectInspectorTab) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summaryGrid
                compactSection("最近章节", tab: .structure) {
                    if snapshot.overviewTab.recentChapters.isEmpty {
                        emptyState("暂无章节结构")
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.overviewTab.recentChapters) { chapter in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("第 \(chapter.number) 章 · \(chapter.title)")
                                        .font(.headline)
                                    Text(chapter.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }

                compactSection("最近事件", tab: .timeline) {
                    if snapshot.overviewTab.recentEvents.isEmpty {
                        emptyState("暂无时间线事件")
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(snapshot.overviewTab.recentEvents) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Ch\(event.chapterNumber) Sc\(event.sceneIndex) · \(event.title)")
                                        .font(.headline)
                                    Text(event.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }

                compactSection("未解决伏笔", tab: .foreshadows) {
                    if snapshot.overviewTab.unresolvedForeshadowTags.isEmpty {
                        emptyState("暂无未解决伏笔")
                    } else {
                        chipFlow(snapshot.overviewTab.unresolvedForeshadowTags)
                    }
                }

                compactSection("开放连续性问题", tab: .continuity) {
                    if snapshot.overviewTab.openContinuityIssueKinds.isEmpty {
                        emptyState("暂无开放连续性问题")
                    } else {
                        chipFlow(snapshot.overviewTab.openContinuityIssueKinds)
                    }
                }

                compactSection("风格摘要", tab: .style, showsJump: snapshot.styleTab.card != nil) {
                    if snapshot.overviewTab.styleSummary.isEmpty {
                        emptyState("暂无风格档案")
                    } else {
                        Text(snapshot.overviewTab.styleSummary)
                            .font(.headline)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                metricCard(title: "角色", value: "\(snapshot.stats.characterCount)", symbol: "person.2")
                metricCard(title: "章节", value: "\(snapshot.stats.chapterCount)", symbol: "text.append")
                metricCard(title: "场景", value: "\(snapshot.stats.sceneCount)", symbol: "text.alignleft")
                metricCard(title: "地点", value: "\(snapshot.stats.locationCount)", symbol: "map")
            }
            GridRow {
                metricCard(title: "规则", value: "\(snapshot.stats.worldRuleCount)", symbol: "scroll")
                metricCard(title: "事件", value: "\(snapshot.stats.timelineEventCount)", symbol: "timeline.selection")
                metricCard(title: "未解伏笔", value: "\(snapshot.stats.unresolvedForeshadowCount)", symbol: "lightbulb")
                metricCard(title: "开放问题", value: "\(snapshot.stats.openContinuityIssueCount)", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func compactSection<Content: View>(_ title: String, tab: StoryProjectInspectorTab, showsJump: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
                if showsJump {
                    Button("查看全部") {
                        onJumpToTab(tab)
                    }
                    .buttonStyle(.borderless)
                }
            }
            content()
        }
    }

    private func metricCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func chipFlow(_ values: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 10) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private func emptyState(_ title: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
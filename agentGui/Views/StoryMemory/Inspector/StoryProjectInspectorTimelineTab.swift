import SwiftUI

struct StoryProjectInspectorTimelineTab: View {
    let events: [StoryProjectTimelineCard]
    let onJump: (StoryProjectInspectorJumpTarget) -> Void

    var body: some View {
        ScrollView {
            StoryProjectInspectorSection("时间线", count: events.count) {
                if events.isEmpty {
                    StoryProjectInspectorEmptyState(title: "暂无时间线事件", systemImage: "timeline.selection")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            HStack(alignment: .top, spacing: 14) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(event.isSuperseded ? Color.secondary : Color.accentColor)
                                        .frame(width: 12, height: 12)
                                    if index < events.count - 1 {
                                        Rectangle()
                                            .fill(.quaternary)
                                            .frame(width: 2)
                                            .frame(maxHeight: .infinity)
                                    }
                                }
                                StoryProjectInspectorCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Ch\(event.chapterNumber) Sc\(event.sceneIndex) · \(event.title)")
                                                    .font(.headline)
                                                Text(event.summary)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                            StoryProjectInspectorChipButton(title: event.isResolved ? "已解决" : "未解决", action: nil)
                                        }
                                        HStack(spacing: 8) {
                                            StoryProjectInspectorChipButton(title: "地点：\(event.locationName)") {
                                                onJump(.init(tab: .locations, anchorID: event.locationName))
                                            }
                                            StoryProjectInspectorChipButton(title: "时间：\(event.timeMarker)", action: nil)
                                            StoryProjectInspectorChipButton(title: "类型：\(event.eventType)", action: nil)
                                            if event.isSuperseded {
                                                StoryProjectInspectorChipButton(title: "已被覆盖", action: nil)
                                            }
                                        }
                                        if !event.participantNames.isEmpty {
                                            StoryProjectInspectorChipCloud(event.participantNames) { value in
                                                onJump(.init(tab: .characters, anchorID: value))
                                            }
                                        }
                                        if !event.foreshadowTags.isEmpty {
                                            StoryProjectInspectorChipCloud(event.foreshadowTags) { value in
                                                onJump(.init(tab: .foreshadows, anchorID: value))
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
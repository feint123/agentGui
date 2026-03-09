import SwiftUI

struct StoryProjectInspectorStructureTab: View {
    let snapshot: StoryProjectInspectorSnapshot
    let onJump: (StoryProjectInspectorJumpTarget) -> Void

    @State private var selectedChapterNumber: Int?

    private var selectedChapter: StoryProjectChapterSection? {
        let number = selectedChapterNumber ?? snapshot.structureTab.defaultChapterNumber
        return snapshot.structureTab.chapters.first(where: { $0.number == number })
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width > 900 {
                    HStack(alignment: .top, spacing: 16) {
                        chapterSidebar
                            .frame(width: 240)
                        chapterDetail
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            chapterSidebar
                            chapterDetail
                        }
                    }
                }
            }
        }
        .onAppear {
            if selectedChapterNumber == nil {
                selectedChapterNumber = snapshot.structureTab.defaultChapterNumber
            }
        }
    }

    private var chapterSidebar: some View {
        StoryProjectInspectorSection("章节目录", count: snapshot.structureTab.chapterNavigation.count) {
            if snapshot.structureTab.chapterNavigation.isEmpty {
                StoryProjectInspectorEmptyState(title: "暂无章节结构", systemImage: "list.bullet.rectangle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.structureTab.chapterNavigation) { item in
                            Button {
                                selectedChapterNumber = item.number
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("第 \(item.number) 章 · \(item.title)")
                                            .font(.headline)
                                        Text("\(item.sceneCount) 个场景")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if item.isLocked {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedChapterNumber == item.number ? .regularMaterial : .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var chapterDetail: some View {
        StoryProjectInspectorSection("章节详情") {
            if let chapter = selectedChapter {
                StoryProjectInspectorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(chapter.number) 章 · \(chapter.title)")
                                    .font(.title3.bold())
                                HStack(spacing: 8) {
                                    StoryProjectInspectorChipButton(title: "\(chapter.sceneCount) 个场景", action: nil)
                                    if chapter.isLocked {
                                        StoryProjectInspectorChipButton(title: "已锁定", action: nil)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("摘要")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(chapter.summary)
                                .font(.subheadline)
                        }
                        StoryProjectInspectorDetailGrid(items: [("大纲", chapter.outline), ("语气", chapter.toneDirective)])
                        StoryProjectInspectorSection("场景", count: chapter.scenes.count) {
                            if chapter.scenes.isEmpty {
                                StoryProjectInspectorEmptyState(title: "本章暂无场景记录", systemImage: "rectangle.stack")
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(chapter.scenes) { scene in
                                        StoryProjectInspectorCard {
                                            VStack(alignment: .leading, spacing: 10) {
                                                HStack(alignment: .top) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text("场景 \(scene.sceneIndex) · \(scene.title)")
                                                            .font(.headline)
                                                        Text(scene.summary)
                                                            .font(.subheadline)
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(3)
                                                    }
                                                    Spacer(minLength: 0)
                                                    StoryProjectInspectorChipButton(title: scene.contentStatus, action: nil)
                                                }
                                                HStack(spacing: 8) {
                                                    StoryProjectInspectorChipButton(title: "POV：\(scene.povCharacterName)") {
                                                        onJump(.init(tab: .characters, anchorID: scene.povCharacterName))
                                                    }
                                                    StoryProjectInspectorChipButton(title: "地点：\(scene.locationName)") {
                                                        onJump(.init(tab: .locations, anchorID: scene.locationName))
                                                    }
                                                }
                                                HStack(spacing: 8) {
                                                    StoryProjectInspectorChipButton(title: scene.hasTimelineEventReference ? "已关联事件" : "未关联事件") {
                                                        onJump(.init(tab: .timeline))
                                                    }
                                                    StoryProjectInspectorChipButton(title: scene.hasPreviousSceneReference ? "有前序引用" : "无前序引用", action: nil)
                                                }
                                                if !scene.participantNames.isEmpty {
                                                    StoryProjectInspectorChipCloud(scene.participantNames) { value in
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
            } else {
                StoryProjectInspectorEmptyState(title: "暂无章节结构", systemImage: "list.bullet.rectangle")
            }
        }
    }
}
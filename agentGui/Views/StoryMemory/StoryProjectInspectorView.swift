import SwiftUI
import SwiftData

struct StoryProjectInspectorView: View {
    @Environment(\.modelContext) private var modelContext

    let project: WritingProject
    let session: Session?

    @State private var navigationState = StoryProjectInspectorNavigationState()

    private var snapshot: StoryProjectInspectorSnapshot {
        StoryProjectPresentation.inspectorSnapshot(for: project)
    }

    private var isAttachedToSession: Bool {
        session?.activeWritingProjectId == project.id.uuidString
    }

    private var selectedTab: StoryProjectInspectorTab {
        navigationState.selectedTab(for: project.id)
    }

    private func jump(to target: StoryProjectInspectorJumpTarget) {
        navigationState.select(target.tab, for: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerCard
            StoryProjectInspectorTabBar(
                items: snapshot.tabs,
                selectedTab: selectedTab,
                onSelect: { navigationState.select($0, for: project.id) }
            )
            selectedTabView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .navigationTitle(snapshot.overview.title)
        .onAppear {
            if navigationState.selectedTab(for: project.id) != .overview {
                return
            }
            navigationState.select(.overview, for: project.id)
        }
    }

    @ViewBuilder
    private var selectedTabView: some View {
        switch selectedTab {
        case .overview:
            StoryProjectInspectorOverviewTab(snapshot: snapshot) { tab in
                navigationState.select(tab, for: project.id)
            }
        case .structure:
            StoryProjectInspectorStructureTab(snapshot: snapshot, onJump: jump)
        case .characters:
            StoryProjectInspectorCharacterTab(cards: snapshot.charactersTab.cards)
        case .locations:
            StoryProjectInspectorLocationTab(cards: snapshot.locationsTab.cards, onJump: jump)
        case .rules:
            StoryProjectInspectorRuleTab(sections: snapshot.rulesTab.sections, onJump: jump)
        case .timeline:
            StoryProjectInspectorTimelineTab(events: snapshot.timelineTab.events, onJump: jump)
        case .foreshadows:
            StoryProjectInspectorForeshadowTab(groups: snapshot.foreshadowsTab.groups)
        case .continuity:
            StoryProjectInspectorContinuityTab(groups: snapshot.continuityTab.groups)
        case .style:
            StoryProjectInspectorStyleTab(card: snapshot.styleTab.card)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.overview.title)
                        .font(.title2.bold())
                    if !snapshot.overview.synopsis.isEmpty {
                        Text(snapshot.overview.synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if !snapshot.overview.styleSummary.isEmpty {
                        Label(snapshot.overview.styleSummary, systemImage: "text.book.closed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    statusBadge(snapshot.overview.isArchived ? "已归档" : "进行中", systemImage: snapshot.overview.isArchived ? "archivebox.fill" : "book.closed")
                    statusBadge(isAttachedToSession ? "当前会话已绑定" : "当前会话未绑定", systemImage: isAttachedToSession ? "link.circle.fill" : "link.circle")
                }
            }

            metaGrid
            statsStrip

            if let session {
                HStack(spacing: 10) {
                    Button(isAttachedToSession ? "已绑定当前会话" : "绑定到当前会话") {
                        session.activeWritingProjectId = project.id.uuidString
                        session.updatedAt = Date()
                        try? modelContext.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAttachedToSession)

                    if isAttachedToSession {
                        Button("解除绑定") {
                            session.activeWritingProjectId = ""
                            session.updatedAt = Date()
                            try? modelContext.save()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var metaGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                detailPair(title: "创建时间", value: snapshot.overview.createdAt.formatted(date: .abbreviated, time: .shortened))
                detailPair(title: "更新时间", value: snapshot.overview.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 8) {
            headerMetric("角色 \(snapshot.stats.characterCount)")
            headerMetric("章节 \(snapshot.stats.chapterCount)")
            headerMetric("未解伏笔 \(snapshot.stats.unresolvedForeshadowCount)")
            headerMetric("开放问题 \(snapshot.stats.openContinuityIssueCount)")
        }
    }

    private func statusBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func detailPair(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerMetric(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
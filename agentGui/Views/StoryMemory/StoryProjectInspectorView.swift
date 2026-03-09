import SwiftUI
import SwiftData

struct StoryProjectInspectorView: View {
    @Environment(\ .modelContext) private var modelContext

    let project: WritingProject
    let session: Session?

    private var snapshot: StoryProjectInspectorSnapshot {
        StoryProjectPresentation.inspectorSnapshot(for: project)
    }

    private var isAttachedToSession: Bool {
        session?.activeWritingProjectId == project.id.uuidString
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                headerCard
                summaryGrid
                groupedSection("章节与场景", count: snapshot.chapterSections.count) {
                    if snapshot.chapterSections.isEmpty {
                        emptyState("暂无章节结构")
                    } else {
                        ForEach(snapshot.chapterSections) { chapter in
                            chapterCard(chapter)
                        }
                    }
                }
                groupedSection("角色档案", count: snapshot.characterCards.count) {
                    if snapshot.characterCards.isEmpty {
                        emptyState("暂无角色档案")
                    } else {
                        ForEach(snapshot.characterCards) { character in
                            characterCard(character)
                        }
                    }
                }
                groupedSection("地点档案", count: snapshot.locationCards.count) {
                    if snapshot.locationCards.isEmpty {
                        emptyState("暂无地点档案")
                    } else {
                        ForEach(snapshot.locationCards) { location in
                            locationCard(location)
                        }
                    }
                }
                groupedSection("世界规则", count: snapshot.worldRuleSections.reduce(0) { $0 + $1.rules.count }) {
                    if snapshot.worldRuleSections.isEmpty {
                        emptyState("暂无世界规则")
                    } else {
                        ForEach(snapshot.worldRuleSections) { section in
                            worldRuleSection(section)
                        }
                    }
                }
                groupedSection("时间线", count: snapshot.timelineEvents.count) {
                    if snapshot.timelineEvents.isEmpty {
                        emptyState("暂无时间线事件")
                    } else {
                        ForEach(snapshot.timelineEvents) { event in
                            timelineEventCard(event)
                        }
                    }
                }
                groupedSection("伏笔追踪", count: snapshot.foreshadowGroups.reduce(0) { $0 + $1.items.count }) {
                    if snapshot.foreshadowGroups.isEmpty {
                        emptyState("暂无伏笔记录")
                    } else {
                        ForEach(snapshot.foreshadowGroups) { group in
                            foreshadowGroup(group)
                        }
                    }
                }
                groupedSection("连续性问题", count: snapshot.continuityGroups.reduce(0) { $0 + $1.items.count }) {
                    if snapshot.continuityGroups.isEmpty {
                        emptyState("暂无连续性问题")
                    } else {
                        ForEach(snapshot.continuityGroups) { group in
                            continuityGroup(group)
                        }
                    }
                }
                groupedSection("风格档案") {
                    if let styleCard = snapshot.styleCard {
                        styleCardView(styleCard)
                    } else {
                        emptyState("暂无风格档案")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(snapshot.overview.title)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.overview.title)
                        .font(.title2.bold())
                    ExpandableText(text: snapshot.overview.synopsis)
                    if !snapshot.overview.styleSummary.isEmpty {
                        Label(snapshot.overview.styleSummary, systemImage: "text.book.closed")
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

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                metricCard(title: "角色", value: "\(snapshot.stats.characterCount)", symbol: "person.2")
                metricCard(title: "章节", value: "\(snapshot.stats.chapterCount)", symbol: "text.append")
                metricCard(title: "场景", value: "\(snapshot.stats.sceneCount)", symbol: "text.alignleft")
                metricCard(title: "地点", value: "\(snapshot.stats.locationCount)", symbol: "map")
            }
            GridRow {
                metricCard(title: "规则", value: "\(snapshot.stats.worldRuleCount)", symbol: "globe.asia.australia")
                metricCard(title: "事件", value: "\(snapshot.stats.timelineEventCount)", symbol: "timeline.selection")
                metricCard(title: "未解伏笔", value: "\(snapshot.stats.unresolvedForeshadowCount)", symbol: "lightbulb")
                metricCard(title: "开放问题", value: "\(snapshot.stats.openContinuityIssueCount)", symbol: "exclamationmark.triangle")
            }
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

    private func groupedSection<Content: View>(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            content()
        }
    }

    private func chapterCard(_ chapter: StoryProjectChapterSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(chapter.number) 章 · \(chapter.title)")
                        .font(.headline)
                    HStack(spacing: 8) {
                        statusBadge("\(chapter.sceneCount) 个场景", systemImage: "square.stack.3d.down.right")
                        if chapter.isLocked {
                            statusBadge("已锁定", systemImage: "lock.fill")
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            labeledText("摘要", chapter.summary)
            labeledText("大纲", chapter.outline)
            labeledText("语气", chapter.toneDirective)

            if chapter.scenes.isEmpty {
                emptyState("本章暂无场景记录")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(chapter.scenes) { scene in
                        sceneCard(scene)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sceneCard(_ scene: StoryProjectSceneCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("场景 \(scene.sceneIndex) · \(scene.title)")
                        .font(.subheadline.weight(.semibold))
                    Text(scene.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(scene.contentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            detailChips([
                "POV：\(scene.povCharacterName)",
                "地点：\(scene.locationName)",
                scene.hasTimelineEventReference ? "已关联事件" : "未关联事件",
                scene.hasPreviousSceneReference ? "有前序引用" : "无前序引用"
            ])

            if !scene.participantNames.isEmpty {
                detailChips(scene.participantNames.map { "角色：\($0)" })
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func characterCard(_ character: StoryProjectCharacterCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(character.name)
                .font(.headline)
            ExpandableText(text: character.summary)
            detailGrid([
                ("说话风格", character.speechStyle),
                ("角色弧线", character.arcStage),
                ("最近出场", chapterLabel(character.lastSeenChapter)),
                ("当前位置", character.lastKnownLocation)
            ])
            labeledChipBlock("性格特征", values: character.traits)
            labeledChipBlock("目标", values: character.goals)
            labeledChipBlock("关系", values: character.relationshipSummary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func locationCard(_ location: StoryProjectLocationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(location.name)
                .font(.headline)
            ExpandableText(text: location.summary)
            labeledChipBlock("特征", values: location.traits)
            labeledChipBlock("相关规则", values: location.relatedRules)
            labeledChipBlock("常驻角色", values: location.occupants)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func worldRuleSection(_ section: StoryProjectWorldRuleSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.category)
                .font(.headline)
            ForEach(section.rules) { rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(rule.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        statusBadge(rule.mutablePolicy, systemImage: "slider.horizontal.3")
                    }
                    ExpandableText(text: rule.detail)
                    detailGrid([
                        ("适用范围", rule.scope),
                        ("建立章节", chapterLabel(rule.establishedInChapter))
                    ])
                    labeledChipBlock("例外", values: rule.exceptions)
                    labeledChipBlock("相关实体", values: rule.relatedEntities)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func timelineEventCard(_ event: StoryProjectTimelineCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ch\(event.chapterNumber) Sc\(event.sceneIndex) · \(event.title)")
                        .font(.headline)
                    ExpandableText(text: event.summary)
                }
                Spacer(minLength: 0)
            }
            detailChips([
                "地点：\(event.locationName)",
                "时间：\(event.timeMarker)",
                "类型：\(event.eventType)",
                event.isResolved ? "已解决" : "未解决",
                event.isSuperseded ? "已被后续事件覆盖" : "当前有效"
            ])
            labeledChipBlock("参与者", values: event.participantNames)
            labeledChipBlock("关联伏笔", values: event.foreshadowTags)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func foreshadowGroup(_ group: StoryProjectForeshadowGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(displayForeshadowStatus(group.status))
                    .font(.headline)
                Text("\(group.items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.tag)
                        .font(.subheadline.weight(.semibold))
                    ExpandableText(text: item.detail)
                    detailGrid([
                        ("引入章节", chapterLabel(item.introducedInChapter)),
                        ("解决章节", item.resolvedInChapter > 0 ? chapterLabel(item.resolvedInChapter) : "未解决"),
                        ("关联事件", "\(item.relatedEventCount)")
                    ])
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func continuityGroup(_ group: StoryProjectContinuityGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(displayContinuityStatus(group.status))
                    .font(.headline)
                Text("\(group.items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.issueKind)
                                .font(.subheadline.weight(.semibold))
                            ExpandableText(text: item.detail)
                        }
                        Spacer(minLength: 0)
                        severityBadge(item.severity)
                    }
                    detailGrid([
                        ("章节", chapterLabel(item.chapterNumber)),
                        ("场景", item.sceneIndex > 0 ? "场景 \(item.sceneIndex)" : "未标记")
                    ])
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func styleCardView(_ style: StoryProjectStyleCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailGrid([
                ("叙事声音", style.narrativeVoice),
                ("作者偏好", style.authorPreferences),
                ("平均句长", style.sentenceLengthMean.formatted(.number.precision(.fractionLength(0)))),
                ("对话占比", style.dialogueRatio.formatted(.percent.precision(.fractionLength(0)))),
                ("意象密度", style.imageryDensity.formatted(.number.precision(.fractionLength(2))))
            ])
            labeledChipBlock("示例段落", values: style.samplePassages)
            labeledChipBlock("反模式", values: style.antiPatterns)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func labeledText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ExpandableText(text: value)
        }
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

    private func detailGrid(_ items: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index.isMultiple(of: 2) {
                    GridRow {
                        detailPair(title: item.0, value: item.1)
                        if index + 1 < items.count {
                            detailPair(title: items[index + 1].0, value: items[index + 1].1)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func labeledChipBlock(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("暂无")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                tagCloud(values)
            }
        }
    }

    private func detailChips(_ values: [String]) -> some View {
        FlowLayout(values) { value in
            Text(value)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func tagCloud(_ values: [String]) -> some View {
        FlowLayout(values) { value in
            Text(value)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func statusBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func severityBadge(_ severity: String) -> some View {
        Text(displaySeverity(severity))
            .font(.caption.weight(.semibold))
            .foregroundStyle(severity == "critical" ? .red : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func chapterLabel(_ chapterNumber: Int) -> String {
        chapterNumber > 0 ? "第 \(chapterNumber) 章" : "未标记"
    }

    private func displayForeshadowStatus(_ status: String) -> String {
        switch status {
        case "open":
            return "未解决"
        case "planned":
            return "已规划"
        case "payoff":
            return "回收中"
        case "resolved":
            return "已解决"
        default:
            return status
        }
    }

    private func displayContinuityStatus(_ status: String) -> String {
        switch status {
        case "open":
            return "开放问题"
        case "accepted":
            return "已接受"
        case "wont_fix":
            return "不修复"
        case "resolved":
            return "已解决"
        default:
            return status
        }
    }

    private func displaySeverity(_ severity: String) -> String {
        switch severity {
        case "critical", "error", "high":
            return "高风险"
        case "warning", "medium":
            return "警告"
        case "info", "low":
            return "提示"
        default:
            return severity
        }
    }
}

private struct ExpandableText: View {
    @State private var isExpanded = false

    let text: String
    var lineLimit: Int = 3

    var body: some View {
        let shouldCollapse = text.count > 60

        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded || !shouldCollapse ? nil : lineLimit)

            if shouldCollapse {
                Button(isExpanded ? "收起" : "展开") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
            }
        }
    }
}

private struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    private let data: Data
    private let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            self.generateContent(in: geometry)
        }
        .frame(minHeight: 32)
    }

    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(Array(data), id: \ .self) { item in
                content(item)
                    .padding(4)
                    .alignmentGuide(.leading) { dimension in
                        if abs(width - dimension.width) > geometry.size.width {
                            width = 0
                            height -= dimension.height
                        }
                        let result = width
                        if item == data.last {
                            width = 0
                        } else {
                            width -= dimension.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == data.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
    }
}
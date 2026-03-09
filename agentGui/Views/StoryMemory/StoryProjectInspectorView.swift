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
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                summaryGrid
                groupedSection("角色") {
                    tagCloud(snapshot.characterNames)
                }
                groupedSection("章节") {
                    textList(snapshot.chapterTitles)
                }
                groupedSection("未解决伏笔") {
                    textList(snapshot.unresolvedForeshadowTags)
                }
                groupedSection("连续性问题") {
                    textList(snapshot.openContinuityIssues)
                }
                groupedSection("时间线") {
                    StoryTimelineView(timelineTitles: snapshot.timelineTitles)
                        .frame(minHeight: 180)
                }
            }
            .padding(20)
        }
        .navigationTitle(project.title)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.title)
                .font(.title2.bold())
            if !project.synopsis.isEmpty {
                Text(project.synopsis)
                    .foregroundStyle(.secondary)
            }
            if !snapshot.styleSummary.isEmpty {
                Label(snapshot.styleSummary, systemImage: "text.book.closed")
                    .foregroundStyle(.secondary)
            }
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

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                metricCard(title: "角色", value: "\(project.characters.count)", symbol: "person.2")
                metricCard(title: "章节", value: "\(project.chapters.count)", symbol: "text.append")
                metricCard(title: "伏笔", value: "\(snapshot.unresolvedForeshadowTags.count)", symbol: "lightbulb")
                metricCard(title: "连续性", value: "\(snapshot.openContinuityIssues.count)", symbol: "exclamationmark.triangle")
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

    private func groupedSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func textList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if lines.isEmpty {
                Text("暂无")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines, id: \ .self) { line in
                    Label(line, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.primary, .tertiary)
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
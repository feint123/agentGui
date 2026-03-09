import SwiftUI
import SwiftData

struct StoryProjectListView: View {
    @Environment(\ .modelContext) private var modelContext

    @Query(sort: \WritingProject.updatedAt, order: .reverse)
    private var projects: [WritingProject]

    let session: Session?

    @State private var selectedProjectID: UUID?
    @State private var draftTitle = ""
    @State private var draftSynopsis = ""

    private var activeProjectID: UUID? {
        if let session, let id = UUID(uuidString: session.activeWritingProjectId) {
            return id
        }
        return nil
    }

    private var projectSummaries: [StoryProjectSummary] {
        StoryProjectPresentation.summaries(projects: projects, activeProjectId: activeProjectID)
    }

    private var selectedProject: WritingProject? {
        if let selectedProjectID,
           let selected = projects.first(where: { $0.id == selectedProjectID }) {
            return selected
        }
        return projects.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selectedProject {
                StoryProjectInspectorView(project: selectedProject, session: session)
            } else {
                ContentUnavailableView("暂无创作项目", systemImage: "books.vertical")
            }
        }
        .navigationTitle("创作项目")
        .onAppear {
            if selectedProjectID == nil {
                selectedProjectID = activeProjectID ?? projects.first?.id
            }
        }
        .onChange(of: projects) { _, newProjects in
            if selectedProjectID == nil || !newProjects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = activeProjectID ?? newProjects.first?.id
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedProjectID) {
            createProjectSection

            Section("项目") {
                ForEach(projectSummaries) { summary in
                    Button {
                        selectedProjectID = summary.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(summary.title)
                                    .font(.headline)
                                if summary.isActive {
                                    Text("当前会话")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.green.opacity(0.15), in: Capsule())
                                }
                            }
                            if !summary.synopsis.isEmpty {
                                Text(summary.synopsis)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text("角色 \(summary.characterCount) · 伏笔 \(summary.unresolvedForeshadowCount) · 连续性 \(summary.openContinuityIssueCount)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .tag(summary.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var createProjectSection: some View {
        Section("新建项目") {
            TextField("项目标题", text: $draftTitle)
            TextField("一句话梗概", text: $draftSynopsis, axis: .vertical)
                .lineLimit(2...4)
            Button("创建项目") {
                createProject()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func createProject() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let project = WritingProject(title: title, synopsis: draftSynopsis.trimmingCharacters(in: .whitespacesAndNewlines))
        modelContext.insert(project)
        try? modelContext.save()

        if session?.activeWritingProjectId.isEmpty != false {
            session?.activeWritingProjectId = project.id.uuidString
            session?.updatedAt = Date()
            try? modelContext.save()
        }

        selectedProjectID = project.id
        draftTitle = ""
        draftSynopsis = ""
    }
}
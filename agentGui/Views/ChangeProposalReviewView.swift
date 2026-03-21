import SwiftUI

struct ChangeProposalReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore

    let proposalID: UUID

    @State private var actionError: String?

    private var applyEngine: ApplyEngine {
        ApplyEngine(modelContext: modelContext, projectionStore: changeReviewProjectionStore)
    }

    private var revertService: DraftRevertService {
        DraftRevertService(modelContext: modelContext, projectionStore: changeReviewProjectionStore)
    }

    private var snapshot: ChangeProposalReviewSnapshot? {
        changeReviewProjectionStore.snapshot(for: proposalID)
    }

    private var selectedFilePathBinding: Binding<String?> {
        Binding(
            get: { workspaceState.selectedChangeProposalFilePath },
            set: { workspaceState.selectedChangeProposalFilePath = $0 }
        )
    }

    private var selectedFileChange: ProposedFileChangeSnapshot? {
        guard let snapshot else { return nil }
        if let selectedPath = workspaceState.selectedChangeProposalFilePath,
           let matchingChange = snapshot.fileChanges.first(where: { $0.relativePath == selectedPath }) {
            return matchingChange
        }
        return snapshot.fileChanges.first
    }

    var body: some View {
        Group {
            if let snapshot {
                HSplitView {
                    fileList(snapshot)
                        .frame(minWidth: 200, idealWidth: 232, maxWidth: 280)

                    VStack(spacing: 0) {
                        if let selectedFileChange {
                            GitDiffView(
                                title: selectedFileChange.relativePath,
                                diffText: selectedFileChange.unifiedDiff,
                                backButtonTitle: "返回聊天",
                                sourceLabel: "变更提案",
                                onBack: {
                                    workspaceState.clearChangeProposalSelection()
                                }
                            )
                        } else {
                            ContentUnavailableView(
                                "无可审查文件",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("当前变更提案没有可显示的文件差异。")
                            )
                        }

                        Divider()
                        actionBar(snapshot: snapshot, selectedFileChange: selectedFileChange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.thinMaterial)
                    }
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .layoutPriority(1)
                }
                .onAppear {
                    if workspaceState.selectedChangeProposalFilePath == nil {
                        workspaceState.selectedChangeProposalFilePath = snapshot.fileChanges.first?.relativePath
                    }
                }
            } else {
                ContentUnavailableView(
                    "未找到变更提案",
                    systemImage: "exclamationmark.bubble",
                    description: Text("当前提案可能已被应用、丢弃，或尚未恢复到审查投影中。")
                )
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .accessibilityIdentifier("changeReview.screen")
    }

    private func actionBar(
        snapshot: ChangeProposalReviewSnapshot,
        selectedFileChange: ProposedFileChangeSnapshot?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                primaryActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                destructiveActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                Spacer(minLength: 0)
                proposalStateBadge(snapshot)
            }

            VStack(alignment: .leading, spacing: 10) {
                primaryActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                destructiveActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                HStack {
                    proposalStateBadge(snapshot)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryActionGroup(
        selectedFileChange: ProposedFileChangeSnapshot?,
        snapshot: ChangeProposalReviewSnapshot
    ) -> some View {
        HStack(spacing: 10) {
            Button("Apply All") {
                Task { await applyAll(snapshot: snapshot) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("changeReview.applyAll")

            Button("Apply Selected") {
                guard let selectedFileChange else { return }
                Task { await applySelected(path: selectedFileChange.relativePath) }
            }
            .buttonStyle(.bordered)
            .disabled(selectedFileChange == nil)
            .accessibilityIdentifier("changeReview.applySelected")
        }
    }

    private func destructiveActionGroup(
        selectedFileChange: ProposedFileChangeSnapshot?,
        snapshot: ChangeProposalReviewSnapshot
    ) -> some View {
        HStack(spacing: 10) {
            Button("Discard File", role: .destructive) {
                guard let selectedFileChange else { return }
                Task { await discardFiles(paths: [selectedFileChange.relativePath]) }
            }
            .buttonStyle(.bordered)
            .disabled(selectedFileChange == nil)
            .accessibilityIdentifier("changeReview.discardFile")

            Button("Discard Proposal", role: .destructive) {
                Task { await discardFiles(paths: snapshot.fileChanges.map(\.relativePath)) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("changeReview.discardProposal")
        }
    }

    private func proposalStateBadge(_ snapshot: ChangeProposalReviewSnapshot) -> some View {
        Text(snapshot.proposal.state.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func applyAll(snapshot: ChangeProposalReviewSnapshot) async {
        do {
            try await applyEngine.apply(
                proposalID: snapshot.proposal.id,
                approvedPaths: snapshot.fileChanges.filter { $0.state.isPendingReview }.map(\.relativePath)
            )
            closeReviewIfResolved()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func applySelected(path: String) async {
        do {
            try await applyEngine.apply(proposalID: proposalID, approvedPaths: [path])
            closeReviewIfResolved()
            selectNextPendingFileIfNeeded()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func discardFiles(paths: [String]) async {
        do {
            try await revertService.revertFiles(proposalID: proposalID, relativePaths: paths)
            closeReviewIfResolved()
            selectNextPendingFileIfNeeded()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func closeReviewIfResolved() {
        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID) else {
            workspaceState.clearChangeProposalSelection()
            return
        }
        if !snapshot.proposal.state.isPendingReview {
            workspaceState.clearChangeProposalSelection()
        }
    }

    private func selectNextPendingFileIfNeeded() {
        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID) else {
            workspaceState.selectedChangeProposalFilePath = nil
            return
        }

        if let selectedPath = workspaceState.selectedChangeProposalFilePath,
           snapshot.fileChanges.contains(where: { $0.relativePath == selectedPath && $0.state.isPendingReview }) {
            return
        }

        workspaceState.selectedChangeProposalFilePath = snapshot.fileChanges.first(where: { $0.state.isPendingReview })?.relativePath
    }

    private func fileList(_ snapshot: ChangeProposalReviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("待审查文件")
                    .font(.headline)
                Text("剩余 \(snapshot.fileChanges.filter { $0.state.isPendingReview }.count) / 总计 \(snapshot.fileChanges.count) 个文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: selectedFilePathBinding) {
                ForEach(snapshot.fileChanges) { change in
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: change.changeKind))
                            .foregroundStyle(iconTint(for: change.changeKind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.relativePath)
                                .lineLimit(1)
                            Text("\(change.changeKind.rawValue) · \(change.state.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(Optional(change.relativePath))
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityIdentifier("changeReview.fileList")
    }

    private func iconName(for kind: ProposedFileChangeKind) -> String {
        switch kind {
        case .add:
            return "plus.square"
        case .modify:
            return "square.and.pencil"
        case .delete:
            return "trash"
        case .rename:
            return "arrow.left.arrow.right.square"
        }
    }

    private func iconTint(for kind: ProposedFileChangeKind) -> Color {
        switch kind {
        case .add:
            return .green
        case .modify:
            return .blue
        case .delete:
            return .red
        case .rename:
            return .orange
        }
    }
}
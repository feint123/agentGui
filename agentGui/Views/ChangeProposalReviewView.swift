import SwiftUI

struct ChangeProposalReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore

    let proposalID: UUID
    private let externalSelectedFilePath: Binding<String?>?
    private let onClose: (() -> Void)?

    @State private var actionError: String?

    init(
        proposalID: UUID,
        selectedFilePath: Binding<String?>? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.proposalID = proposalID
        self.externalSelectedFilePath = selectedFilePath
        self.onClose = onClose
    }

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
        if let externalSelectedFilePath {
            return externalSelectedFilePath
        }

        return Binding(
            get: { workspaceState.selectedChangeProposalFilePath },
            set: { workspaceState.selectedChangeProposalFilePath = $0 }
        )
    }

    private var selectedFileChange: ProposedFileChangeSnapshot? {
        guard let snapshot else { return nil }
        return ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: selectedFilePathBinding.wrappedValue
        )
    }

    var body: some View {
        Group {
            if let snapshot {
                VStack(spacing: 0) {
                    if let selectedFileChange {
                        GitDiffView(
                            title: selectedFileChange.relativePath,
                            diffText: selectedFileChange.unifiedDiff,
                            backButtonTitle: onClose == nil ? "返回聊天" : "关闭标签页",
                            sourceLabel: "变更提案",
                            onBack: {
                                closeReview()
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
                .onAppear {
                    syncSelectedFilePathIfNeeded(snapshot)
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
                fileSelectionSummary(snapshot: snapshot, selectedFileChange: selectedFileChange)
                primaryActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                destructiveActionGroup(selectedFileChange: selectedFileChange, snapshot: snapshot)
                Spacer(minLength: 0)
                proposalStateBadge(snapshot)
            }

            VStack(alignment: .leading, spacing: 10) {
                fileSelectionSummary(snapshot: snapshot, selectedFileChange: selectedFileChange)
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

    private func fileSelectionSummary(
        snapshot: ChangeProposalReviewSnapshot,
        selectedFileChange: ProposedFileChangeSnapshot?
    ) -> some View {
        let pendingCount = snapshot.fileChanges.filter { $0.state.isPendingReview }.count

        return VStack(alignment: .leading, spacing: 2) {
            Text(selectedFileChange?.relativePath ?? "当前没有选中文件")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("剩余 \(pendingCount) / 共 \(snapshot.fileChanges.count) 个文件")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
            closeReview()
            return
        }
        if !snapshot.proposal.state.isPendingReview {
            closeReview()
        }
    }

    private func selectNextPendingFileIfNeeded() {
        guard let snapshot = changeReviewProjectionStore.snapshot(for: proposalID) else {
            selectedFilePathBinding.wrappedValue = nil
            return
        }

        selectedFilePathBinding.wrappedValue = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: selectedFilePathBinding.wrappedValue
        )?.relativePath
    }

    private func syncSelectedFilePathIfNeeded(_ snapshot: ChangeProposalReviewSnapshot) {
        let resolvedPath = ChangeProposalReviewSelectionResolver.resolve(
            in: snapshot,
            selectedFilePath: selectedFilePathBinding.wrappedValue
        )?.relativePath

        if selectedFilePathBinding.wrappedValue != resolvedPath {
            selectedFilePathBinding.wrappedValue = resolvedPath
        }
    }

    private func closeReview() {
        if let onClose {
            onClose()
        } else {
            workspaceState.clearChangeProposalSelection()
        }
    }
}
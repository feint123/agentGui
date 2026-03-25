import SwiftUI
import SwiftData

enum WorkbenchContextWindowScene {
    static let id = "workbench-context-window"
}

struct WorkbenchContextWindowView: View {
    @Environment(ChangeReviewProjectionStore.self) private var changeReviewProjectionStore
    @Environment(WorkspaceState.self) private var workspaceState
    @Environment(WorkbenchState.self) private var workbenchState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: WorkbenchContextSceneValue?

    private let diffSnapshotStore = WorkbenchDiffSnapshotStore.shared

    var body: some View {
        Group {
            if let resolvedSelection {
                content(for: resolvedSelection)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .navigationTitle(selectionPresentation.title)
        .navigationSubtitle(selectionPresentation.subtitle)
        .background(
            WorkbenchContextWindowConfigurator(
                presentation: selectionPresentation
            )
        )
        .focusedSceneValue(\.appCommandContext, commandContext)
    }

    @ViewBuilder
    private func content(for selection: WorkbenchDetailSelection) -> some View {
        switch selection {
        case .none:
            emptyState

        case .file(let fileURL):
            FileEditorView(fileURL: fileURL)

        case .gitDiff(let title, let diffText):
            GitDiffView(
                title: title,
                diffText: diffText,
                backButtonTitle: "关闭窗口",
                onBack: {
                    dismiss()
                }
            )

        case .changeProposal(let proposalID, _):
            ChangeProposalReviewView(
                proposalID: proposalID,
                selectedFilePath: selectedProposalFilePathBinding,
                onClose: {
                    dismiss()
                }
            )
        }
    }

    private var selectedProposalFilePathBinding: Binding<String?> {
        Binding(
            get: {
                guard case .changeProposal(_, let filePath)? = selection else {
                    return nil
                }

                return filePath
            },
            set: { newValue in
                guard case .changeProposal(let proposalID, _) = selection else {
                    return
                }

                selection = .changeProposal(proposalID: proposalID, filePath: newValue)

                if workspaceState.selectedChangeProposalID == proposalID {
                    workspaceState.selectedChangeProposalFilePath = newValue
                }
            }
        )
    }

    private var commandContext: AppCommandContext {
        AppCommandContext(
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: .contextWindow,
            openWindowByID: { windowID in
                openWindow(id: windowID)
            }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有打开的上下文", systemImage: "rectangle.stack")
        } description: {
            Text("从工作区、Git 或提案入口打开内容后，这里会在独立窗口中展示。")
        }
    }

    private var resolvedSelection: WorkbenchDetailSelection? {
        guard let selection else { return nil }
        switch selection {
        case .file(let path):
            return .file(URL(fileURLWithPath: path).standardizedFileURL)
        case .gitDiff(let title, let snapshotID):
            guard let snapshot = diffSnapshotStore.snapshot(for: snapshotID) else {
                return nil
            }
            return .gitDiff(title: title, diffText: snapshot.diffText)
        case .changeProposal(let proposalID, let filePath):
            return .changeProposal(proposalID: proposalID, filePath: filePath)
        }
    }

    private var selectionPresentation: WorkbenchTitlePresentation {
        guard let resolvedSelection else {
            return WorkbenchTitlePresentation(
                title: "上下文",
                subtitle: "在这里查看文件、Diff 和变更提案。",
                representedURL: nil
            )
        }

        return WorkbenchTitlePresentation.make(
            contextSelection: resolvedSelection,
            changeReviewProjectionStore: changeReviewProjectionStore
        )
    }
}

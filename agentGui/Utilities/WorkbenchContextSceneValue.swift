import Foundation

struct WorkbenchDiffSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let diffText: String
}

@MainActor
final class WorkbenchDiffSnapshotStore {
    static let shared = WorkbenchDiffSnapshotStore()

    static var inMemory: WorkbenchDiffSnapshotStore {
        WorkbenchDiffSnapshotStore()
    }

    private var snapshotsByID: [String: WorkbenchDiffSnapshot] = [:]

    func store(title: String, diffText: String) -> String {
        if let existing = snapshotsByID.values.first(where: {
            $0.title == title && $0.diffText == diffText
        }) {
            return existing.id
        }

        let snapshot = WorkbenchDiffSnapshot(
            id: UUID().uuidString,
            title: title,
            diffText: diffText
        )
        snapshotsByID[snapshot.id] = snapshot
        return snapshot.id
    }

    func snapshot(for id: String) -> WorkbenchDiffSnapshot? {
        snapshotsByID[id]
    }
}

enum WorkbenchContextSceneValue: Hashable, Codable, Sendable {
    case file(path: String)
    case gitDiff(title: String, snapshotID: String)
    case changeProposal(proposalID: UUID, filePath: String?)
}

@MainActor
extension WorkbenchContextSceneValue {
    init?(
        selection: WorkbenchDetailSelection,
        diffSnapshotStore: WorkbenchDiffSnapshotStore
    ) {
        switch selection {
        case .none:
            return nil
        case .file(let fileURL):
            self = .file(path: fileURL.standardizedFileURL.path)
        case .gitDiff(let title, let diffText):
            self = .gitDiff(
                title: title,
                snapshotID: diffSnapshotStore.store(title: title, diffText: diffText)
            )
        case .changeProposal(let proposalID, let filePath):
            self = .changeProposal(proposalID: proposalID, filePath: filePath)
        }
    }
}
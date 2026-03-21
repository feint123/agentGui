import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SessionCatalogViewModel {
    struct Item: Identifiable, Equatable {
        let session: Session
        let canRename: Bool
        let canDelete: Bool

        var id: String {
            session.sessionId
        }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.session.sessionId == rhs.session.sessionId &&
            lhs.canRename == rhs.canRename &&
            lhs.canDelete == rhs.canDelete
        }
    }

    struct Section: Identifiable, Equatable {
        let kind: SessionKind
        let title: String
        let items: [Item]

        var id: String {
            kind.rawValue
        }
    }

    enum ValidationError: LocalizedError {
        case readOnlySession
        case emptyTitle
        case missingModelContext

        var errorDescription: String? {
            switch self {
            case .readOnlySession:
                return "只允许重命名本地会话。"
            case .emptyTitle:
                return "会话名称不能为空。"
            case .missingModelContext:
                return "会话目录尚未绑定持久化上下文。"
            }
        }
    }

    var searchText: String = "" {
        didSet {
            rebuildVisibleSections()
        }
    }

    private(set) var visibleSections: [Section] = []

    private var allSessions: [Session] = []
    private var modelContext: ModelContext?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
        if modelContext != nil {
            reload()
        }
    }

    func bind(modelContext: ModelContext) {
        self.modelContext = modelContext
        if allSessions.isEmpty {
            reload()
        }
    }

    func reload() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        let fetchedSessions = (try? modelContext.fetch(descriptor)) ?? []
        setSessions(fetchedSessions)
    }

    func setSessions(_ sessions: [Session]) {
        allSessions = sessions.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        rebuildVisibleSections()
    }

    func rename(session: Session, to newTitle: String) throws {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            throw ValidationError.emptyTitle
        }

        let policy = SessionInteractionPolicy(session: session)
        guard policy.canRename else {
            throw ValidationError.readOnlySession
        }
        guard let modelContext else {
            throw ValidationError.missingModelContext
        }

        session.title = trimmedTitle
        session.updatedAt = Date()
        try modelContext.save()
        reload()
    }

    private func rebuildVisibleSections() {
        let filteredSessions = filtered(allSessions, searchText: searchText)
        visibleSections = SessionKind.allCases.compactMap { kind in
            let items = filteredSessions
                .filter { $0.kind == kind }
                .map { session in
                    let policy = SessionInteractionPolicy(session: session)
                    return Item(
                        session: session,
                        canRename: policy.canRename,
                        canDelete: policy.canDelete
                    )
                }

            guard items.isEmpty == false else { return nil }
            return Section(kind: kind, title: kind.displayName, items: items)
        }
    }

    private func filtered(_ sessions: [Session], searchText: String) -> [Session] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSearchText.isEmpty == false else { return sessions }

        return sessions.filter { session in
            session.title.localizedStandardContains(trimmedSearchText) ||
            session.lastMessagePreview.localizedStandardContains(trimmedSearchText) ||
            session.displaySourceTitle.localizedStandardContains(trimmedSearchText)
        }
    }
}
import Foundation
import SwiftData

@MainActor
struct RecentSessionProvider {
    enum Direction {
        case previous
        case next
    }

    private let fetchSessions: @MainActor (ModelContext) -> [Session]

    init(fetchSessions: @escaping @MainActor (ModelContext) -> [Session] = RecentSessionProvider.defaultFetchSessions) {
        self.fetchSessions = fetchSessions
    }

    func recentSessions(modelContext: ModelContext?, limit: Int = 8) -> [Session] {
        guard let modelContext else { return [] }
        return Array(fetchSessions(modelContext).prefix(limit))
    }

    func adjacentSession(
        from current: Session?,
        direction: Direction,
        modelContext: ModelContext?
    ) -> Session? {
        let sessions = recentSessions(modelContext: modelContext, limit: Int.max)
        guard !sessions.isEmpty else { return nil }
        guard let current,
              let currentIndex = sessions.firstIndex(where: { $0.persistentModelID == current.persistentModelID }) else {
            return sessions.first
        }

        switch direction {
        case .next:
            return sessions[(currentIndex + 1) % sessions.count]
        case .previous:
            return sessions[(currentIndex - 1 + sessions.count) % sessions.count]
        }
    }

    private static func defaultFetchSessions(modelContext: ModelContext) -> [Session] {
        let descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        return SessionCatalogViewModel.sortSessions((try? modelContext.fetch(descriptor)) ?? [])
    }
}
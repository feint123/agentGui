import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RecentSessionProviderTests {
    @Test func providerReturnsSessionsSortedByRecentUpdate() throws {
        let container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)

        let older = Session.fixture(sessionId: "older", title: "Older")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = Session.fixture(sessionId: "newer", title: "Newer")
        newer.updatedAt = Date(timeIntervalSince1970: 200)

        modelContext.insert(older)
        modelContext.insert(newer)
        try modelContext.save()

        let provider = RecentSessionProvider()

        #expect(provider.recentSessions(modelContext: modelContext).map(\.sessionId) == ["newer", "older"])
        #expect(provider.adjacentSession(from: newer, direction: .next, modelContext: modelContext)?.sessionId == "older")
        #expect(provider.adjacentSession(from: older, direction: .previous, modelContext: modelContext)?.sessionId == "newer")
    }
}
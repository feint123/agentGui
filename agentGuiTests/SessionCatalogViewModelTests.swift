import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionCatalogViewModelTests {
    @Test func viewModelGroupsSessionsByKindAndSearchesAcrossSourceDisplay() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: configuration)
        let context = ModelContext(container)

        let local = Session.fixture(sessionId: "local-1", title: "本地修复")
        local.updatedAt = Date(timeIntervalSince1970: 100)

        let channel = Session.fixture(
            sessionId: "channel-1",
            title: "Feishu",
            kind: .channel,
            sourceDisplayName: "飞书 · 团队群"
        )
        channel.updatedAt = Date(timeIntervalSince1970: 200)

        let background = Session.fixture(
            sessionId: "background-1",
            title: "日报任务",
            kind: .backgroundTask,
            sourceDisplayName: "后台任务 · 日报"
        )
        background.updatedAt = Date(timeIntervalSince1970: 300)

        context.insert(local)
        context.insert(channel)
        context.insert(background)
        try context.save()

        let viewModel = SessionCatalogViewModel(modelContext: context)

        #expect(viewModel.visibleSections.map(\.kind) == [.local, .channel, .backgroundTask])

        viewModel.searchText = "团队群"

        #expect(viewModel.visibleSections.count == 1)
        #expect(viewModel.visibleSections.first?.kind == .channel)
        #expect(viewModel.visibleSections.first?.items.map(\.id) == ["channel-1"])
    }

    @Test func readOnlySessionsRemainVisibleButCannotRename() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: configuration)
        let context = ModelContext(container)

        let local = Session.fixture(sessionId: "local-1", title: "可编辑")
        let channel = Session.fixture(sessionId: "channel-1", title: "只读渠道", kind: .channel)
        context.insert(local)
        context.insert(channel)
        try context.save()

        let viewModel = SessionCatalogViewModel(modelContext: context)

        let localItem = try #require(viewModel.visibleSections.first(where: { $0.kind == .local })?.items.first)
        let channelItem = try #require(viewModel.visibleSections.first(where: { $0.kind == .channel })?.items.first)

        #expect(localItem.canRename)
        #expect(channelItem.canRename == false)
    }
}
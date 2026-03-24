import AppKit
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct AppCommandRegistryTests {
    @Test func registryIncludesExistingApplicationCommands() {
        let ids = Set(AppCommandRegistry().descriptors.map(\.id))

        #expect(ids.contains(.showSettings))
        #expect(ids.contains(.showOnboarding))
        #expect(ids.contains(.openWorkspaceChooser))
        #expect(ids.contains(.showAgentStudio))
    }

    @Test func registryExposesStableCommandMetadataForNavigation() throws {
        let descriptor = try #require(AppCommandRegistry().descriptor(for: .showWorkspacePanel))

        #expect(descriptor.title == "切换到工作区")
        #expect(descriptor.category == .navigation)
        #expect(descriptor.keywords.contains("面板"))
        #expect(descriptor.shortcut?.key == "2")
        #expect(descriptor.shortcut?.modifiers == [.command])
    }
}
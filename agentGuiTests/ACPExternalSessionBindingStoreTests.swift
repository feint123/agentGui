import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ACPExternalSessionBindingStoreTests {
    @Test func storePersistsCapabilitiesByLocalSessionAndProvider() throws {
        let modelContext = try makeModelContext()
        let store = ACPExternalSessionBindingStore(modelContext: modelContext)

        let binding = try store.upsert(
            sessionID: "local-1",
            providerID: .openCodeCLI,
            remoteSessionID: "remote-1",
            agentVersion: "0.4.0",
            capabilities: .init(loadSession: false, supportsSessionModelOverride: false, agentVersion: "0.4.0"),
            selectedModel: nil,
            selectedAgentName: nil
        )

        #expect(binding.providerID == .openCodeCLI)
        #expect(binding.negotiatedCapabilities?.loadSession == false)

        let storedBinding = try store.binding(for: "local-1", providerID: .openCodeCLI)
        let resolved = try #require(storedBinding)
        #expect(resolved.remoteSessionID == "remote-1")
        #expect(resolved.agentVersion == "0.4.0")
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ACPExternalSessionBinding.self,
            configurations: config
        )
        return ModelContext(container)
    }
}
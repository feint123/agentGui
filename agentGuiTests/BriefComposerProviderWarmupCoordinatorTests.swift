import Testing
@testable import agentGui

@MainActor
struct BriefComposerProviderWarmupCoordinatorTests {
    @Test
    func initialStateIsIdleForAllProviders() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        #expect(coord.warmupState(for: ref) == .idle)
    }

    @Test
    func markReadyStoresModesAndModelOptions() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let modes = [ExecutionOptionItem(id: "code", title: "Code")]
        let models = [ExecutionOptionItem(id: "model-a", title: "Model A")]
        coord.markReady(ref, modes: modes, modelOptions: models)
        if case .ready(let m, let mo) = coord.warmupState(for: ref) {
            #expect(m == modes)
            #expect(mo == models)
        } else {
            Issue.record("Expected .ready state")
        }
    }

    @Test
    func markFailedSetsFailedState() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        coord.markFailed(ref)
        #expect(coord.warmupState(for: ref) == .failed)
    }

    @Test
    func isWarmingReturnsTrueOnlyWhenAtLeastOneProviderWarming() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        #expect(coord.isWarmingAny == false)
        coord.markWarming(ref)
        #expect(coord.isWarmingAny == true)
        coord.markFailed(ref)
        #expect(coord.isWarmingAny == false)
    }

    @Test
    func fallbackModelOptionsReturnedWhenFailed() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        coord.markFailed(ref)
        let options = coord.modelOptions(for: ref)
        // fallback 应为 non-empty curated list
        #expect(!options.isEmpty)
    }
}

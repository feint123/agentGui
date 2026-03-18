import Testing
@testable import agentGui

struct ToolAuthorizationPolicyTests {
    @Test func defaultPolicyUsesObserveOnlyPreset() {
        let policy = ToolAuthorizationPolicy()

        #expect(policy.preset == .observeOnly)
        #expect(policy.level(for: .fileSystem) == .disabled)
        #expect(policy.level(for: .shell) == .disabled)
        #expect(policy.level(for: .network) == .observe)
        #expect(policy.level(for: .memory) == .disabled)
    }

    @Test func maintainPresetEnablesMemoryButNotFileWriteOrShell() {
        let policy = ToolAuthorizationPolicy(preset: .maintain)

        #expect(policy.level(for: .fileSystem) == .disabled)
        #expect(policy.level(for: .shell) == .disabled)
        #expect(policy.level(for: .network) == .observe)
        #expect(policy.level(for: .memory) == .mutate)
    }

    @Test func editingCapabilityLevelsTurnsPolicyIntoCustomPreset() {
        var policy = ToolAuthorizationPolicy(preset: .observeOnly)

        policy.setLevel(.mutate, for: .fileSystem)

        #expect(policy.preset == .custom)
        #expect(policy.level(for: .fileSystem) == .mutate)
    }
}

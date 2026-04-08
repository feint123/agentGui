import Testing
@testable import agentGui

@MainActor
struct FileEditorViewRuntimeOptionsTests {
    @Test
    func lspAvailabilityEnablesCompletionAndInlayHintsTogether() {
        let options = FileEditorCodeEditorRuntimeOptions.from(hasLSPCoordinator: true)

        #expect(options.isCompletionEnabled == true)
        #expect(options.isInlayHintsEnabled == true)
    }

    @Test
    func noLSPDisablesCompletionAndInlayHintsTogether() {
        let options = FileEditorCodeEditorRuntimeOptions.from(hasLSPCoordinator: false)

        #expect(options.isCompletionEnabled == false)
        #expect(options.isInlayHintsEnabled == false)
    }
}
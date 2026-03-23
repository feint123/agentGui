import Testing
@testable import agentGui

struct InlineRenameStateTests {
    @Test func beginRenameSeedsDraftForTarget() {
        var state = InlineRenameState<String>()

        state.begin(id: "session-1", text: "原始标题")

        #expect(state.isEditing("session-1"))
        #expect(state.draft?.text == "原始标题")
        #expect(state.draft?.originalText == "原始标题")
    }

    @Test func commitCandidateTrimsWhitespaceAndTracksMeaningfulChange() {
        var state = InlineRenameState<String>()
        state.begin(id: "session-1", text: "原始标题")

        state.update(text: "  新标题  ")

        let candidate = state.commitCandidate
        #expect(candidate?.id == "session-1")
        #expect(candidate?.trimmedText == "新标题")
        #expect(candidate?.hasChanges == true)
    }

    @Test func blankDraftHasNoCommitCandidate() {
        var state = InlineRenameState<String>()
        state.begin(id: "session-1", text: "原始标题")

        state.update(text: "   \n  ")

        #expect(state.commitCandidate == nil)
    }

    @Test func cancelClearsDraft() {
        var state = InlineRenameState<String>()
        state.begin(id: "session-1", text: "原始标题")

        state.cancel()

        #expect(state.draft == nil)
        #expect(state.isEditing("session-1") == false)
    }
}
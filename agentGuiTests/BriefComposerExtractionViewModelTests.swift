import Foundation
import Testing
@testable import agentGui

@MainActor
struct BriefComposerExtractionViewModelTests {

    struct ImmediateSuccessExtractionService: MissionBriefExtractionService {
        let result: MissionBriefExtractionResult
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult { result }
    }

    struct ImmediateFailExtractionService: MissionBriefExtractionService {
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            throw URLError(.timedOut)
        }
    }

    @Test
    func extractPopulatesDraftFields() async {
        let expected = MissionBriefExtractionResult(
            objective: "修复 ACP 并发问题",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["tests 全通过"],
            suggestedMode: .executionDelivery
        )
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "修复 ACP 并发问题"

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateSuccessExtractionService(result: expected)
        )
        await vm.triggerExtraction(draft: &draft)

        #expect(draft.objective == "修复 ACP 并发问题")
        #expect(draft.constraintsText == "仅修改 Swift 文件")
        #expect(draft.acceptanceCriteriaText == "tests 全通过")
        #expect(draft.mode == .executionDelivery)
        #expect(draft.extractionState == .done)
    }

    @Test
    func extractSetsFailedStateOnError() async {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "测试输入"

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateFailExtractionService()
        )
        await vm.triggerExtraction(draft: &draft)

        if case .failed = draft.extractionState {
            // pass
        } else {
            #expect(Bool(false), "应当进入 failed 状态，实际：\(draft.extractionState)")
        }
    }

    @Test
    func extractDoesNothingWhenRawInputIsEmpty() async {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "   "
        draft.objective = ""

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateSuccessExtractionService(
                result: MissionBriefExtractionResult(
                    objective: "不应出现",
                    constraints: [],
                    acceptanceCriteria: [],
                    suggestedMode: .executionDelivery
                )
            )
        )
        await vm.triggerExtraction(draft: &draft)

        #expect(draft.extractionState == .idle)
        #expect(draft.objective == "")
    }
}

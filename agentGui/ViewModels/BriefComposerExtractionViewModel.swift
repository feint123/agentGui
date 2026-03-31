import Foundation
import SwiftUI

@Observable
@MainActor
final class BriefComposerExtractionViewModel {

    private let extractionService: any MissionBriefExtractionService
    private var debounceTask: Task<Void, Never>?

    init(extractionService: any MissionBriefExtractionService) {
        self.extractionService = extractionService
    }

    // MARK: - Public API

    /// 立即触发提取（点击按钮路径）
    func triggerExtraction(draft: inout AgentTeamMissionBriefDraft) async {
        let trimmedInput = draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }

        draft.extractionState = .extracting
        do {
            let result = try await extractionService.extract(from: trimmedInput)
            applyResult(result, to: &draft)
            draft.extractionState = .done
        } catch {
            draft.extractionState = .failed(error.localizedDescription)
        }
    }

    /// 启动防抖提取（输入停止 1.5s 后触发），供 onChange 调用
    func scheduleDebounceExtraction(draft: Binding<AgentTeamMissionBriefDraft>) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let trimmedInput = draft.wrappedValue.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty else {
                draft.wrappedValue.extractionState = .idle
                return
            }
            draft.wrappedValue.extractionState = .extracting
            do {
                let result = try await self.extractionService.extract(from: trimmedInput)
                if !Task.isCancelled {
                    self.applyResult(result, to: &draft.wrappedValue)
                    draft.wrappedValue.extractionState = .done
                }
            } catch {
                if !Task.isCancelled {
                    draft.wrappedValue.extractionState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Private

    private func applyResult(
        _ result: MissionBriefExtractionResult,
        to draft: inout AgentTeamMissionBriefDraft
    ) {
        draft.objective = result.objective
        draft.constraintsText = result.constraints.joined(separator: "\n")
        draft.acceptanceCriteriaText = result.acceptanceCriteria.joined(separator: "\n")
        draft.mode = result.suggestedMode
    }
}

import Foundation

struct TerminalInteractionPlanner: Sendable {
    typealias PlanningBlock = @Sendable (
        String,
        String,
        TerminalSurfaceSnapshot,
        String
    ) async throws -> TerminalInteractionPlan

    private let planningBlock: PlanningBlock

    nonisolated init(planningBlock: @escaping PlanningBlock) {
        self.planningBlock = planningBlock
    }

    nonisolated func plan(
        goal: String,
        command: String,
        surface: TerminalSurfaceSnapshot,
        recentOutput: String
    ) async throws -> TerminalInteractionPlan {
        try await planningBlock(goal, command, surface, recentOutput)
    }

    nonisolated static func deterministicFallback() -> TerminalInteractionPlanner {
        TerminalInteractionPlanner { goal, command, surface, _ in
            let normalizedGoal = goal.lowercased()
            print("[bash-planner] deterministic planner invoked command=\(command) goal=\(goal) selectionMode=\(surface.selectionMode.rawValue) optionCount=\(surface.visibleOptions.count)")
            let interactionType: String = {
                if surface.inputHint == "viewer_navigation" {
                    return "viewer_navigation"
                }
                switch surface.selectionMode {
                case .multiSelect:
                    return "multi_select_menu"
                case .singleSelect:
                    return "single_select_menu"
                case .textInput:
                    return "text_input"
                case .none, .unknown:
                    return "unknown"
                }
            }()

            let actions: [TerminalInteractionAction]
            let confidence: Double
            let requiresUserConfirmation: Bool
            let reasoningSummary: String

            if surface.inputHint == "viewer_navigation" {
                actions = []
                confidence = 0.58
                requiresUserConfirmation = true
                reasoningSummary = "Detected a viewer-style terminal surface that likely needs manual navigation or explicit user approval instead of automatic prompt replies"
            } else {
                switch surface.selectionMode {
            case .multiSelect:
                let targetIndices = matchingOptionIndices(in: surface, normalizedGoal: normalizedGoal)
                print("[bash-planner] multi-select target indices command=\(command) indices=\(targetIndices.map(String.init).joined(separator: ","))")
                if targetIndices.isEmpty {
                    actions = [.key(.enter)]
                    confidence = 0.34
                    requiresUserConfirmation = true
                    reasoningSummary = "The command does not specify which optional create-vue features should be selected, so the planner is deferring to user approval"
                } else {
                    actions = buildMultiSelectActions(surface: surface, targetIndices: targetIndices)
                    confidence = 0.89
                    requiresUserConfirmation = false
                    reasoningSummary = "Mapped explicit feature intent onto the visible create-vue options"
                }
            case .singleSelect:
                actions = [.key(.enter)]
                confidence = 0.76
                requiresUserConfirmation = false
                reasoningSummary = "Single-choice screen with a deterministic default submit action"
            case .textInput:
                actions = [.text(goal), .key(.enter)]
                confidence = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.41 : 0.84
                requiresUserConfirmation = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                reasoningSummary = requiresUserConfirmation
                    ? "No explicit text input was provided, so planner is deferring to user approval"
                    : "Filled the text input directly from the provided goal"
            case .none, .unknown:
                actions = []
                confidence = 0.0
                requiresUserConfirmation = true
                reasoningSummary = "Unable to infer a safe interaction plan from the current terminal surface"
                }
            }

            print("[bash-planner] deterministic planner result command=\(command) interactionType=\(interactionType) confidence=\(confidence) requiresConfirmation=\(requiresUserConfirmation) actions=\(actions.map(actionLabel).joined(separator: ", "))")

            return TerminalInteractionPlan(
                interactionType: interactionType,
                intentSummary: "Plan actions for terminal interaction",
                confidence: confidence,
                nextActions: actions,
                requiresUserConfirmation: requiresUserConfirmation,
                reasoningSummary: reasoningSummary
            )
        }
    }

    nonisolated static func stubForTests() -> TerminalInteractionPlanner {
        deterministicFallback()
    }

    private nonisolated static func matchingOptionIndices(in surface: TerminalSurfaceSnapshot, normalizedGoal: String) -> [Int] {
        let explicitKeywords: [[String]] = [
            ["jsx"],
            ["router", "路由"],
            ["pinia"],
            ["vitest", "单元测试"],
            ["端到端", "e2e"],
            ["linter", "lint"],
            ["prettier"]
        ]

        return surface.visibleOptions.enumerated().compactMap { index, option in
            let normalizedLabel = option.label.lowercased()
            let matchesGoal = explicitKeywords.contains { keywords in
                keywords.contains(where: { keyword in
                    normalizedLabel.contains(keyword) && normalizedGoal.contains(keyword)
                })
            }
            return matchesGoal ? index : nil
        }
    }

    private nonisolated static func buildMultiSelectActions(
        surface: TerminalSurfaceSnapshot,
        targetIndices: [Int]
    ) -> [TerminalInteractionAction] {
        guard !targetIndices.isEmpty else { return [.key(.enter)] }

        var actions: [TerminalInteractionAction] = []
        var currentIndex = surface.focusedOptionIndex ?? 0

        for targetIndex in targetIndices.sorted() {
            while currentIndex < targetIndex {
                actions.append(.key(.down))
                currentIndex += 1
            }

            while currentIndex > targetIndex {
                actions.append(.key(.up))
                currentIndex -= 1
            }

            if surface.visibleOptions.indices.contains(targetIndex), !surface.visibleOptions[targetIndex].isSelected {
                actions.append(.key(.space))
            }
        }

        actions.append(.key(.enter))
        return actions
    }

    private nonisolated static func actionLabel(_ action: TerminalInteractionAction) -> String {
        switch action {
        case .key(let key):
            return key.rawValue
        case .text(let text):
            return "text:\(text)"
        case .wait(let milliseconds):
            return "wait:\(milliseconds)ms"
        case .signal(let signal):
            return signal.rawValue
        }
    }
}
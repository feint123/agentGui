import Foundation
import Observation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case connection
    case workspace

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:
            return "欢迎使用 agentGui"
        case .connection:
            return "连接 Claude"
        case .workspace:
            return "准备工作区"
        }
    }

    var accessibilityTitleID: String {
        switch self {
        case .welcome:
            return "onboarding.step.welcome.title"
        case .connection:
            return "onboarding.step.connection.title"
        case .workspace:
            return "onboarding.step.workspace.title"
        }
    }
}

@MainActor
@Observable
final class OnboardingFlowState {
    var currentStep: OnboardingStep = .welcome

    var canGoBack: Bool {
        currentStep.rawValue > 0
    }

    var canAdvance: Bool {
        currentStep.rawValue < OnboardingStep.allCases.count - 1
    }

    var progressText: String {
        "步骤 \(currentStep.rawValue + 1) / \(OnboardingStep.allCases.count)"
    }

    func advance() {
        guard canAdvance,
              let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func goBack() {
        guard canGoBack,
              let previous = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
    }
}
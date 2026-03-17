import Foundation
import Testing
@testable import agentGui

struct TerminalInteractionPlannerTests {

    @Test func deterministicPlannerCanRunOffMainActor() async throws {
        let planner = TerminalInteractionPlanner.stubForTests()
        let surface = TerminalSurfaceSnapshot(
            plainTextFrame: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            rawANSISnippet: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            visibleOptions: [
                .init(label: "JSX 支持", isSelected: false, isFocused: true),
                .init(label: "Router（单页面应用开发）", isSelected: false, isFocused: false),
                .init(label: "Pinia（状态管理）", isSelected: false, isFocused: false),
                .init(label: "Vitest（单元测试）", isSelected: false, isFocused: false)
            ],
            focusedOptionIndex: 0,
            selectionMode: .multiSelect,
            isAlternateScreen: true
        )

        let plan = try await Task.detached {
            try await planner.plan(
                goal: "Create a Vue app with TypeScript, JSX, Router, Pinia, Vitest",
                command: "npm create vue@latest vue3-demo",
                surface: surface,
                recentOutput: surface.plainTextFrame
            )
        }.value

        #expect(plan.interactionType == "multi_select_menu")
        #expect(!plan.nextActions.isEmpty)
    }

    @Test func plannerConsumesProjectedSurfaceFromScreenSnapshot() async throws {
        let planner = TerminalInteractionPlanner.stubForTests()
        let screenSnapshot = TerminalScreenSnapshot(
            plainTextLines: TerminalInteractiveFixtures.createVueFeatureSelectionScreen
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init),
            activeBuffer: .alternate,
            cursor: .init(row: 4, column: 0),
            width: 80,
            height: 24
        )
        let surface = TerminalSurfaceProjector().project(screenSnapshot)

        let plan = try await planner.plan(
            goal: "Create a Vue app with TypeScript, JSX, Router, Pinia, Vitest",
            command: "npm create vue@latest vue3-demo",
            surface: surface,
            recentOutput: surface.plainTextFrame
        )

        #expect(plan.interactionType == "multi_select_menu")
        #expect(plan.requiresUserConfirmation == false)
        #expect(!plan.nextActions.isEmpty)
    }

    @Test func stubPlannerRequestsApprovalForBareCreateVueCommand() async throws {
        let planner = TerminalInteractionPlanner.stubForTests()
        let surface = TerminalSurfaceSnapshot(
            plainTextFrame: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            rawANSISnippet: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            visibleOptions: [
                .init(label: "JSX 支持", isSelected: false, isFocused: true),
                .init(label: "Router（单页面应用开发）", isSelected: false, isFocused: false),
                .init(label: "Pinia（状态管理）", isSelected: false, isFocused: false),
                .init(label: "Vitest（单元测试）", isSelected: false, isFocused: false)
            ],
            focusedOptionIndex: 0,
            selectionMode: .multiSelect,
            isAlternateScreen: true
        )

        let plan = try await planner.plan(
            goal: "npm create vue@latest vue3-demo",
            command: "npm create vue@latest vue3-demo",
            surface: surface,
            recentOutput: surface.plainTextFrame
        )

        #expect(plan.requiresUserConfirmation)
        #expect(plan.confidence < AgentLoopToolExecutionCoordinatorBuilder.terminalPlannerAutoExecuteThreshold)
    }

    @Test func stubPlannerProducesFeatureSelectionActionsForCreateVueSurface() async throws {
        let planner = TerminalInteractionPlanner.stubForTests()
        let surface = TerminalSurfaceSnapshot(
            plainTextFrame: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            rawANSISnippet: TerminalInteractiveFixtures.createVueFeatureSelectionScreen,
            visibleOptions: [
                .init(label: "JSX 支持", isSelected: false, isFocused: true),
                .init(label: "Router（单页面应用开发）", isSelected: false, isFocused: false),
                .init(label: "Pinia（状态管理）", isSelected: false, isFocused: false),
                .init(label: "Vitest（单元测试）", isSelected: false, isFocused: false)
            ],
            focusedOptionIndex: 0,
            selectionMode: .multiSelect,
            isAlternateScreen: true
        )

        let plan = try await planner.plan(
            goal: "Create a Vue app with TypeScript, JSX, Router, Pinia, Vitest",
            command: "npm create vue@latest vue3-demo",
            surface: surface,
            recentOutput: surface.plainTextFrame
        )

        #expect(plan.interactionType == "multi_select_menu")
        #expect(!plan.nextActions.isEmpty)
        #expect(plan.requiresUserConfirmation == false)
    }
}
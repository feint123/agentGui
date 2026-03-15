import Foundation
import CoreGraphics
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct RMSPopoverPresentationTests {

    @Test func presentationMarksStateAsNeedsAttentionWhenFrontiersOrDebtExist() {
        let state = RMSState.fixture(
            summary: "Need tool confirmation before applying patch",
            frontiers: [
                .init(
                    id: "frontier-1",
                    goal: "Verify fix",
                    openClaim: "Patch is not validated yet",
                    suggestedProbe: "Run Quality Smoke",
                    stopCondition: "Smoke passes"
                )
            ],
            verificationDebts: [
                .init(id: "debt-1", claim: "UI matches LSP popover", reason: "No visual confirmation yet")
            ],
            candidateActions: ["Run Quality Smoke"]
        )

        let presentation = RMSPopoverPresentation.make(state)

        #expect(presentation.stateText == "需处理")
        #expect(presentation.summaryText == "Need tool confirmation before applying patch")
        #expect(presentation.frontierCount == 1)
        #expect(presentation.verificationDebtCount == 1)
        #expect(presentation.sections.map(\.title) == ["前沿", "验证债务", "建议动作"])
        #expect(presentation.sections.first?.rows.first?.title == "Verify fix")
        #expect(presentation.sections.first?.rows.first?.detail == "Patch is not validated yet")
    }

    @Test func presentationUsesStableStateAndFallbackSummaryWhenOpenItemsAreEmpty() {
        let state = RMSState.fixture(summary: "   ")

        let presentation = RMSPopoverPresentation.make(state)

        #expect(presentation.stateText == "稳定")
        #expect(presentation.summaryText == "当前没有显著未决前沿或验证债务。")
        #expect(presentation.sections.isEmpty)
    }

    @Test func scrollAreaHeightUsesMinimumVisibleHeightWhenSectionsExist() {
        let sections = [
            RMSPopoverPresentation.Section(
                id: "frontiers",
                title: "前沿",
                rowTint: .orange,
                rows: [
                    .init(id: "row-1", title: "Verify fix", detail: "Need evidence", metadata: nil)
                ]
            )
        ]

        let height = RMSPopoverLayout.scrollAreaHeight(for: sections)

        #expect(height == RMSPopoverLayout.minimumScrollHeight)
    }

    @Test func scrollAreaHeightCapsLargeContentAtMaximumHeight() {
        let sections = (0..<4).map { index in
            RMSPopoverPresentation.Section(
                id: "section-\(index)",
                title: "Section \(index)",
                rowTint: .blue,
                rows: (0..<5).map { rowIndex in
                    .init(id: "row-\(index)-\(rowIndex)", title: "Row \(rowIndex)", detail: "Detail", metadata: nil)
                }
            )
        }

        let height = RMSPopoverLayout.scrollAreaHeight(for: sections)

        #expect(height == RMSPopoverLayout.maximumScrollHeight)
    }

    @Test func presentationDropsExactDuplicateRowsWithinSection() {
        let state = RMSState.fixture(
            counterexamples: [
                .init(id: "counterexample-0-llm-0", summary: "Avoid force push", replacementAction: "Use revert"),
                .init(id: "counterexample-0-llm-0", summary: "Avoid force push", replacementAction: "Use revert")
            ]
        )

        let presentation = RMSPopoverPresentation.make(state)
        let rows = presentation.sections.first(where: { $0.id == "counterexamples" })?.rows

        #expect(rows?.count == 1)
        #expect(rows?.first?.id == "counterexample-0-llm-0")
    }

    @Test func presentationStabilizesDuplicateRowIDsWhenContentDiffers() {
        let state = RMSState.fixture(
            counterexamples: [
                .init(id: "counterexample-0-llm-0", summary: "Avoid force push", replacementAction: "Use revert"),
                .init(id: "counterexample-0-llm-0", summary: "Avoid reset --hard", replacementAction: "Use selective checkout")
            ]
        )

        let presentation = RMSPopoverPresentation.make(state)
        let rows = presentation.sections.first(where: { $0.id == "counterexamples" })?.rows ?? []

        #expect(rows.count == 2)
        #expect(Set(rows.map(\ .id)).count == 2)
        #expect(rows.map(\ .id) == ["counterexample-0-llm-0", "counterexample-0-llm-0-2"])
    }
}
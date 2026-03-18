import Foundation
import Testing
@testable import agentGui

@MainActor
struct FeishuInteractiveCardPlannerTests {
    @Test func interactiveCardPlanPreservesSectionOrder() {
        let plan = FeishuInteractiveCardPlan(
            title: "Agent Reply",
            sections: [
                .markdown("第一段"),
                .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"),
                .codeBlock(markdown: "```swift\nprint(1)\n```"),
                .callout(markdown: "> [!NOTE] 提示\n> body"),
                .divider(markdown: "---"),
                .markdown("结尾")
            ]
        )

        #expect(plan.title == "Agent Reply")
        #expect(plan.sections.count == 6)
        #expect(plan.sections[0] == .markdown("第一段"))
        #expect(plan.sections[1] == .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"))
        #expect(plan.sections[2] == .codeBlock(markdown: "```swift\nprint(1)\n```"))
        #expect(plan.sections[3] == .callout(markdown: "> [!NOTE] 提示\n> body"))
        #expect(plan.sections[4] == .divider(markdown: "---"))
        #expect(plan.sections[5] == .markdown("结尾"))
    }

    @Test func plannerBuildsSingleMarkdownSectionForPlainContent() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: "第一段\n\n第二段",
            title: "飞书 Bot"
        )

        #expect(plan.title == "飞书 Bot")
        #expect(plan.sections.count == 1)
        #expect(plan.sections[0] == .markdown("第一段\n\n第二段"))
    }

    @Test func plannerSeparatesTableFromSurroundingMarkdown() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: """
            第一段

            | A | B |
            | --- | --- |
            | 1 | 2 |

            第二段
            """,
            title: "Agent Reply"
        )

        #expect(plan.sections.count == 3)
        #expect(plan.sections[0] == .markdown("第一段"))
        #expect(plan.sections[1] == .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"))
        #expect(plan.sections[2] == .markdown("第二段"))
    }

    @Test func plannerMergesAdjacentNonTableBlocksIntoSingleMarkdownSection() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: """
            # 标题

            第一段

            - 条目一
            - 条目二
            """,
            title: nil
        )

        #expect(plan.sections.count == 1)
        switch plan.sections[0] {
        case .markdown(let text):
            #expect(text.contains("# 标题"))
            #expect(text.contains("第一段"))
            #expect(text.contains("- 条目一"))
            #expect(text.contains("- 条目二"))
        case .table, .codeBlock, .callout, .divider:
            Issue.record("Expected markdown section")
        }
    }

    @Test func plannerPreservesMultipleIsolatedTables() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: """
            表一前文

            | A | B |
            | --- | --- |
            | 1 | 2 |

            表间说明

            | C | D |
            | --- | --- |
            | 3 | 4 |
            """,
            title: nil
        )

        #expect(plan.sections.count == 4)
        #expect(plan.sections[0] == .markdown("表一前文"))
        #expect(plan.sections[1] == .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"))
        #expect(plan.sections[2] == .markdown("表间说明"))
        #expect(plan.sections[3] == .table(markdown: "| C | D |\n| --- | --- |\n| 3 | 4 |"))
    }

    @Test func plannerSeparatesCodeBlockCalloutAndDividerFromMarkdown() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: """
            前文

            ```swift
            print("hello")
            ```

            > [!WARNING] 注意
            > 第二行

            ---

            后文
            """,
            title: nil
        )

        #expect(plan.sections.count == 5)
        #expect(plan.sections[0] == .markdown("前文"))
        #expect(plan.sections[1] == .codeBlock(markdown: "```swift\nprint(\"hello\")\n```"))
        #expect(plan.sections[2] == .callout(markdown: "> [!WARNING] 注意\n> 第二行"))
        #expect(plan.sections[3] == .divider(markdown: "---"))
        #expect(plan.sections[4] == .markdown("后文"))
    }

    @Test func plannerKeepsAdjacentDedicatedBlocksAsIndependentSections() {
        let plan = FeishuInteractiveCardPlanner().makePlan(
            text: """
            ```json
            {"ok":true}
            ```

            ---

            > [!NOTE] Heads up
            > body
            """,
            title: nil
        )

        #expect(plan.sections.count == 3)
        #expect(plan.sections[0] == .codeBlock(markdown: "```json\n{\"ok\":true}\n```"))
        #expect(plan.sections[1] == .divider(markdown: "---"))
        #expect(plan.sections[2] == .callout(markdown: "> [!NOTE] Heads up\n> body"))
    }
}
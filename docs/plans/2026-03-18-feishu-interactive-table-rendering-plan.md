# Feishu Interactive Table Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade Feishu `interactive` rendering so it uses `BlockMarkdownCodec` to isolate Markdown table blocks and render them as dedicated card sections, while keeping non-table content modular, extensible, and stable.

**Architecture:** Keep the runtime contract unchanged: upstream still emits plain Markdown text, and Feishu-specific structure is built only inside the Feishu outbound renderer. Introduce a Foundation-only interactive planning layer that parses Markdown with `BlockMarkdownCodec`, groups contiguous non-table blocks into markdown sections, isolates `.table` blocks into dedicated sections, then composes a Feishu Card JSON 2.0 body from that intermediate plan. Avoid coupling the renderer to SwiftUI view models such as `MarkdownMessageRenderBlock`; this path should stay transport-facing and reusable.

**Tech Stack:** Swift 6, Foundation, Swift Testing, existing `BlockMarkdownCodec`, existing Feishu outbound renderer/client/adapter pipeline, Feishu Card JSON 2.0 markdown component docs.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. Design constraints

- Strict TDD. Every behavior change starts with a failing test.
- Do not change the upstream outbound contract. `OutboundChannelMessage.text` remains the only input to Feishu rendering.
- Keep Feishu-specific logic out of generic Markdown view models and out of `ChannelAccountBinding`.
- Reuse `BlockMarkdownCodec.parse` as the source of truth for block segmentation.
- Reuse `BlockMarkdownCodec.serialize` when reconstructing non-table markdown chunks instead of inventing a second markdown serializer.
- Do not reuse `MarkdownMessageBlockPresentation` directly. It is `@MainActor`, SwiftUI-facing, and optimized for in-app display rather than outbound transport.
- Prefer Feishu Card JSON 2.0 for `interactive` so table markdown support is explicit and future card layout work has a stable base.
- Treat tables as isolated rendering units in interactive cards. The first version does not need a native grid-like column layout if dedicated markdown components already render tables correctly.
- Preserve current `text` and `post` behavior unless directly required by the new interactive plan.
- Do not expand this work into card callbacks, template cards, images-in-table, or streaming card updates.

## 1. Current codebase anchors

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuOutboundMessageRendererTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MarkdownMessageBlockPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-18-feishu-channel-usage-manual.md`

## 2. Recommended approach

### Option A: Build table extraction directly inside `FeishuOutboundMessageRenderer`

Fastest, but not good enough. It would entangle parsing, segmentation, and card JSON composition inside one file that already handles three message formats.

### Option B: Reuse `MarkdownMessageBlockPresentation` and map its output to Feishu card elements

Better than A, but still the wrong boundary. That presentation model is view-oriented, imports SwiftUI, and carries UI-centric alignment metadata not needed by transport code.

### Option C: Introduce a dedicated Feishu interactive planning layer based on `BlockMarkdownCodec`

Recommended.

Use a Foundation-only intermediate model such as:

- `FeishuInteractiveSection.markdown(String)`
- `FeishuInteractiveSection.table(markdown: String)`
- `FeishuInteractiveCardPlan(title: String?, sections: [...])`

The planner parses the full Markdown into `DocumentBlock`s, isolates `.table` blocks, groups adjacent non-table blocks, and serializes grouped blocks back into markdown chunks with `BlockMarkdownCodec.serialize`. The card composer then turns these sections into JSON 2.0 body elements, using one markdown component per section. This keeps parsing, planning, and Feishu JSON composition independently testable.

## 3. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuInteractiveCardPlannerTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuOutboundMessageRendererTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-18-feishu-channel-usage-manual.md`

## 4. Delivery strategy

Deliver in four milestones:

1. Introduce a transport-facing interactive card planning model and lock its segmentation behavior with tests.
2. Upgrade the interactive renderer to build Card JSON 2.0 from that plan.
3. Update downstream Feishu client and adapter tests to assert the new interactive payload shape still flows through create/reply paths.
4. Update docs to reflect that interactive cards now isolate Markdown tables into dedicated sections.

Do not start by editing the client or adapter. First prove the planner behavior with pure tests, then wire the renderer, then verify transport integration.

## 5. Task breakdown

### Task 1: Add a Foundation-only interactive card plan model

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlan.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuInteractiveCardPlannerTests.swift`

**Step 1: Write the failing test**

Add tests that lock the plan model shape and equality.

Required expectations:

1. A plan can represent ordered `markdown` and `table` sections.
2. A section can carry stable markdown text.
3. The model stays Foundation-only and does not import SwiftUI.

Example test shape:

```swift
@Test func interactiveCardPlanPreservesSectionOrder() {
		let plan = FeishuInteractiveCardPlan(
				title: "Agent Reply",
				sections: [
						.markdown("第一段"),
						.table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"),
						.markdown("结尾")
				]
		)

		#expect(plan.sections.count == 3)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/FeishuInteractiveCardPlannerTests
```

Expected: FAIL because the plan model does not exist.

**Step 3: Write minimal implementation**

Implement:

1. `FeishuInteractiveCardPlan`
2. `FeishuInteractiveSection`
3. Any minimal helper state needed by the later planner

Keep the model small. No JSON code yet.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlan.swift agentGuiTests/FeishuInteractiveCardPlannerTests.swift
git commit -m "feat: add feishu interactive card plan model"
```

### Task 2: Add a planner that isolates table blocks using `BlockMarkdownCodec`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlanner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuInteractiveCardPlannerTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`

**Step 1: Write the failing tests**

Add planner tests that prove:

1. Pure non-table markdown becomes a single `.markdown` section.
2. A markdown table becomes a single `.table` section.
3. Markdown before and after a table is split into separate `.markdown` sections around the `.table` section.
4. Multiple adjacent non-table blocks are merged back into one markdown section using `BlockMarkdownCodec.serialize`.
5. Multiple tables remain isolated as multiple `.table` sections.

Example test shape:

```swift
@Test func plannerSeparatesTableFromSurroundingMarkdown() {
		let source = """
		第一段

		| A | B |
		| --- | --- |
		| 1 | 2 |

		第二段
		"""

		let plan = FeishuInteractiveCardPlanner().makePlan(text: source, title: "Agent Reply")

		#expect(plan.sections.count == 3)
		#expect(plan.sections[1] == .table(markdown: "| A | B |\n| --- | --- |\n| 1 | 2 |"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/FeishuInteractiveCardPlannerTests
```

Expected: FAIL because the planner does not exist.

**Step 3: Write minimal implementation**

Implement:

1. `FeishuInteractiveCardPlanner.makePlan(text:title:)`
2. `BlockMarkdownCodec.parse(text, fileURL: nil)` for segmentation
3. Group contiguous non-table blocks into a temporary `BlockDocument` and reserialize with `BlockMarkdownCodec.serialize(..., fileURL: nil)`
4. Emit `.table(markdown:)` directly from `DocumentBlock(kind: .table, text: ...)`

Do not build card JSON in this step.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuInteractiveCardPlanner.swift agentGuiTests/FeishuInteractiveCardPlannerTests.swift
git commit -m "feat: add feishu interactive table extraction planner"
```

### Task 3: Upgrade interactive rendering to Card JSON 2.0 with isolated table sections

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuOutboundMessageRendererTests.swift`

**Step 1: Write the failing tests**

Add renderer tests that prove:

1. `interactive` payload is upgraded to Card JSON 2.0 with `schema: "2.0"`.
2. Pure non-table content renders as a markdown body element.
3. A table in the source becomes a separate markdown body element instead of being fused into one giant markdown blob with surrounding paragraphs.
4. Title still uses the configured title fallback behavior.
5. Multiple tables become multiple isolated markdown elements in card body order.

Example test shape:

```swift
@Test func rendererBuildsInteractiveCardWithDedicatedTableSection() throws {
		let payload = try FeishuOutboundMessageRenderer().render(
				text: """
				简介

				| A | B |
				| --- | --- |
				| 1 | 2 |
				""",
				format: .interactive,
				title: "飞书 Bot"
		)

		#expect(payload.msgType == "interactive")
		#expect(payload.content.contains("\"schema\":\"2.0\""))
		#expect(payload.content.contains("| A | B |"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/FeishuOutboundMessageRendererTests
```

Expected: FAIL because the renderer still emits the old simple interactive payload.

**Step 3: Write minimal implementation**

Implement:

1. Inject or initialize `FeishuInteractiveCardPlanner` inside `FeishuOutboundMessageRenderer`
2. Replace the old simple `InteractiveCard` JSON shape with a Card JSON 2.0 structure
3. Map each `FeishuInteractiveSection` to one body element:
	 - `.markdown(text)` -> `{ "tag": "markdown", "content": text }`
	 - `.table(markdown)` -> `{ "tag": "markdown", "content": markdown }`
4. Keep header title fallback behavior intact
5. Keep body ordering identical to the planner output

Suggested JSON 2.0 structure:

```json
{
	"schema": "2.0",
	"config": {
		"update_multi": true,
		"width_mode": "fill"
	},
	"header": {
		"title": {
			"tag": "plain_text",
			"content": "Agent Reply"
		}
	},
	"body": {
		"direction": "vertical",
		"elements": [
			{ "tag": "markdown", "content": "简介" },
			{ "tag": "markdown", "content": "| A | B |\n| --- | --- |\n| 1 | 2 |" }
		]
	}
}
```

Do not add action buttons, callbacks, or per-table custom colors in this step.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift agentGuiTests/FeishuOutboundMessageRendererTests.swift
git commit -m "feat: isolate markdown tables in feishu interactive cards"
```

### Task 4: Verify transport integration and update docs

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-18-feishu-channel-usage-manual.md`

**Step 1: Write the failing tests**

Adjust downstream tests to lock the new interactive payload shape.

Required assertions:

1. Client tests expect `interactive` payload content to include `schema: 2.0` and `body.elements`.
2. Adapter tests verify markdown-with-table input still produces `msgType == interactive` and includes isolated table markdown content.

Example assertions:

```swift
#expect(replyBody.contains("\"schema\":\"2.0\""))
#expect(replyBody.contains("\"body\""))
#expect(replyBody.contains("| A | B |"))
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/FeishuClientLiveTests \
	-only-testing:agentGuiTests/FeishuChannelAdapterTests
```

Expected: FAIL because downstream fixtures still assert the old interactive JSON shape.

**Step 3: Write minimal implementation**

Implement:

1. Update tests to assert the new card payload shape.
2. Update the usage manual to document that interactive mode now:
	 - parses markdown through `BlockMarkdownCodec`
	 - isolates table blocks into dedicated card markdown sections
	 - still uses static, non-interactive card layout

**Step 4: Run tests to verify they pass**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/FeishuInteractiveCardPlannerTests \
	-only-testing:agentGuiTests/FeishuOutboundMessageRendererTests \
	-only-testing:agentGuiTests/FeishuClientLiveTests \
	-only-testing:agentGuiTests/FeishuChannelAdapterTests
```

Expected: PASS.

If the repo is stable enough, optionally run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
	-parallel-testing-enabled NO \
	-only-testing:agentGuiTests/ChannelRuntimeBootstrapTests
```

**Step 5: Commit**

```bash
git add agentGuiTests/FeishuClientLiveTests.swift agentGuiTests/FeishuChannelAdapterTests.swift docs/spec/2026-03-18-feishu-channel-usage-manual.md
git commit -m "docs: describe interactive table extraction for feishu cards"
```

## 6. Testing notes

- Keep planner tests pure and synchronous. They should not depend on networking, SwiftUI, or ModelContext.
- Prefer block-order assertions over giant raw JSON string assertions when testing the planner.
- In renderer tests, assert for stable fragments such as `schema`, `header`, `body`, `markdown`, and table markdown text.
- In client tests, continue asserting only that `content` is a stringified JSON payload in the outgoing HTTP body.
- For manual verification in a real Feishu environment, validate three cases:
	1. no table: one markdown section
	2. one table: markdown + table split
	3. two tables with text between: five ordered sections

## 7. Risks and guardrails

- `BlockMarkdownCodec.serialize` may normalize markdown formatting when regrouping non-table blocks. Tests should lock acceptable normalization rather than exact original whitespace everywhere.
- Card JSON 2.0 only renders fully on Feishu 7.20+. Document this client-version risk.
- Table markdown support lives inside the card markdown component. If Feishu rendering differs by client, keep planner and renderer separated so a future native row/column card layout can replace only the composition layer.
- Avoid overfitting the planner to tables only. The section enum should remain open for future section kinds such as code blocks or callouts if they later need dedicated card rendering.

## 8. Acceptance checklist

- `interactive` rendering uses `BlockMarkdownCodec.parse` to detect table blocks.
- Table blocks are isolated into dedicated interactive card sections.
- Non-table blocks are regrouped into markdown sections without introducing SwiftUI dependencies into transport code.
- Interactive card payload uses Card JSON 2.0.
- Renderer, client, and adapter focused tests pass.
- Docs reflect the new interactive table rendering behavior and version caveat.

Plan complete and saved to `docs/plans/2026-03-18-feishu-interactive-table-rendering-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?

# MarkdownMessageView Markdown 解析与增量渲染修正 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `MarkdownMessageView` reuse `BlockMarkdownCodec` as the single block-level Markdown parser and fix streaming incremental rendering so tables, code fences, quotes, and lists converge to the same structure as full-document parsing.

**Architecture:** Split the work into three layers: a pure `BlockDocument -> message render block` adapter, a pure incremental reconciliation layer that reuses stable prefixes and reparses only the unstable tail, and a thin SwiftUI `MarkdownMessageView` that renders those blocks with stable identity. Keep parser semantics in `BlockMarkdownCodec`; message-specific logic should only handle presentation mapping and incremental cache reuse.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Swift Testing, existing `BlockMarkdownCodec`, existing `MarkdownMessageView` special views such as Mermaid and table rendering.

---

## Implementation Notes

- This plan implements the requirements in [docs/spec/2026-03-10-markdown-message-view-requirements.md](/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-markdown-message-view-requirements.md).
- Keep the first delivery conservative: correctness first, then incremental reuse. Do not try to optimize every append case before the full-parse parity tests are green.
- Avoid keeping two block parser implementations alive. Once the adapter path is in place, the old `CachedBlock` parser should be removed rather than partially retained.
- Prefer pure, testable types for mapping and incremental reconciliation before touching SwiftUI view code.
- Use TDD for adapter mapping and incremental tail reparse behavior.
- Commit after each task.

## Proposed File Layout

**Create pure presentation and incremental logic:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MarkdownMessageBlockPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MarkdownMessageIncrementalParser.swift`

**Modify rendering layer:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageResultBlockView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTimelineView.swift`

**Reference existing parser/model files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`

**Create tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageBlockPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageIncrementalParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageViewRenderingTests.swift`

## Task 1: Add a Pure BlockDocument Adapter

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MarkdownMessageBlockPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageBlockPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockEditorModels.swift`

**Step 1: Write the failing tests**

Add tests that pin the mapping contract from `BlockDocument` to renderable message blocks.

```swift
import Testing
@testable import agentGui

struct MarkdownMessageBlockPresentationTests {
    @Test func mapsParagraphHeadingQuoteAndListBlocks() async throws {
        let source = """
        # Title

        > quoted

        - one
        - two
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)
        let blocks = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(blocks.map(\.kind) == [.heading(level: 1), .quote, .bulletedList, .bulletedList])
    }

    @Test func mapsMermaidCodeBlockAsCodeKindWithLanguage() async throws {
        let source = """
        ```mermaid
        graph TD
        A-->B
        ```
        """

        let document = BlockMarkdownCodec.parse(source, fileURL: nil)
        let blocks = MarkdownMessageBlockPresentation.makeBlocks(from: document)

        #expect(blocks.count == 1)
        #expect(blocks.first?.language == "mermaid")
    }
}
```

Also add tests for table, todo, callout, toggle, image, and url mapping.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MarkdownMessageBlockPresentationTests
```

Expected: FAIL because the presentation type does not exist.

**Step 3: Write minimal implementation**

Create a pure presentation layer with stable, view-oriented block metadata.

```swift
struct MarkdownMessageRenderBlock: Identifiable, Equatable {
    let id: String
    let kind: MarkdownMessageRenderKind
    let text: String
    let metadata: MarkdownMessageRenderMetadata
}

enum MarkdownMessageRenderKind: Equatable {
    case paragraph
    case heading(level: Int)
    case quote
    case bulletedList
    case numberedList
    case todo
    case code
    case divider
    case table
    case image
    case url
    case callout
    case toggle
}
```

The adapter should:

- consume `BlockDocument`
- map `DocumentBlockKind` into render kinds
- keep source text and needed metadata
- assign deterministic ids derived from block kind, text range proxy, and content hash

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MarkdownMessageBlockPresentation.swift agentGuiTests/MarkdownMessageBlockPresentationTests.swift
git commit -m "feat: add markdown message block presentation adapter"
```

## Task 2: Build a Conservative Incremental Reconciler

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MarkdownMessageIncrementalParser.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageIncrementalParserTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MarkdownMessageBlockPresentation.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Editor/BlockMarkdownCodec.swift`

**Step 1: Write the failing tests**

Add tests for append-only reconciliation and tail reparse behavior.

```swift
import Testing
@testable import agentGui

struct MarkdownMessageIncrementalParserTests {
    @Test func tableStreamConvergesToSingleTableBlock() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let step1 = parser.reconcile(oldText: "", newText: "| A | B |\n")
        let step2 = parser.reconcile(oldText: "| A | B |\n", newText: "| A | B |\n| --- | --- |\n")
        let step3 = parser.reconcile(oldText: "| A | B |\n| --- | --- |\n", newText: "| A | B |\n| --- | --- |\n| 1 | 2 |\n")

        #expect(step3.blocks.count == 1)
        #expect(step3.blocks.first?.kind == .table)
    }

    @Test func finalAppendMatchesFullParseForCodeFence() async throws {
        let parser = MarkdownMessageIncrementalParser()
        let full = """
        ```swift
        print(1)
        ```
        """

        _ = parser.reconcile(oldText: "", newText: "```swift\n")
        _ = parser.reconcile(oldText: "```swift\n", newText: "```swift\nprint(1)\n")
        let final = parser.reconcile(oldText: "```swift\nprint(1)\n", newText: full)

        #expect(final.blocks == parser.fullParse(full))
    }
}
```

Also add tests for quote growth, bulleted list growth, todo growth, and non-append fallback.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MarkdownMessageIncrementalParserTests
```

Expected: FAIL because the incremental parser does not exist.

**Step 3: Write minimal implementation**

Create a pure reconciler that:

- uses `BlockMarkdownCodec.parse` for full parsing
- detects non-append updates and falls back to full parse
- on append updates, keeps a stable prefix of previously parsed blocks
- reparses a conservative unstable tail and appended text together
- returns render blocks with reused prefix identities and replaced tail identities

Suggested shape:

```swift
struct MarkdownIncrementalSnapshot: Equatable {
    let sourceText: String
    let blocks: [MarkdownMessageRenderBlock]
}

struct MarkdownMessageIncrementalParser {
    func fullParse(_ text: String) -> [MarkdownMessageRenderBlock]
    func reconcile(oldText: String, newText: String, previous: MarkdownIncrementalSnapshot? = nil) -> MarkdownIncrementalSnapshot
}
```

Keep the first version deliberately simple:

- treat paragraph, quote, list, todo, callout, toggle, code, and table as unstable when they are near the tail
- find the last stable prefix index
- reparse the suffix from the original source text instead of reparsing only the appended substring

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MarkdownMessageIncrementalParser.swift agentGuiTests/MarkdownMessageIncrementalParserTests.swift agentGui/ViewModels/MarkdownMessageBlockPresentation.swift
git commit -m "feat: add markdown message incremental reconciler"
```

## Task 3: Refactor MarkdownMessageView to Use the New Pipeline

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MarkdownMessageBlockPresentation.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MarkdownMessageIncrementalParser.swift`

**Step 1: Run build to verify the current baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 2: Write minimal implementation**

Refactor `MarkdownMessageView` so it:

- removes the old `CachedBlock`, `MarkdownBlockCache`, and custom `parseBlocksImpl` main path
- owns a `MarkdownMessageIncrementalParser` snapshot instead of a custom parser cache
- renders `MarkdownMessageRenderBlock` values from the adapter
- keeps Mermaid and table rendering as specialized block views
- adds rendering branches for quote, list, todo, url, image, callout, and toggle, using safe lightweight styles where no custom UI exists yet

The view should remain thin. Parsing and reconciliation must stay outside the view.

**Step 3: Run build to verify it compiles**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke test**

Open the app and verify:

- long plain-text streaming still updates smoothly
- a streamed table no longer lingers as multiple text fragments after the separator row arrives
- a streamed fenced code block converges to a single code block after closing fence arrives
- list and quote content preserves block boundaries rather than flattening into one paragraph

**Step 5: Commit**

```bash
git add agentGui/Views/MarkdownMessageView.swift
git commit -m "refactor: route markdown message rendering through shared parser"
```

## Task 4: Add Rendering and Regression Tests Around the View Contract

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MarkdownMessageViewRenderingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift`

**Step 1: Write the failing tests**

Add tests for the message-view contract at the block-list level.

```swift
import Testing
@testable import agentGui

struct MarkdownMessageViewRenderingTests {
    @Test func finalStreamedTableMatchesFullParseProjection() async throws {
        let parser = MarkdownMessageIncrementalParser()
        let full = """
        | Name | Value |
        | --- | --- |
        | A | 1 |
        """

        _ = parser.reconcile(oldText: "", newText: "| Name | Value |\n")
        _ = parser.reconcile(oldText: "| Name | Value |\n", newText: "| Name | Value |\n| --- | --- |\n")
        let final = parser.reconcile(oldText: "| Name | Value |\n| --- | --- |\n", newText: full)

        #expect(final.blocks == parser.fullParse(full))
    }

    @Test func nonAppendEditFallsBackToFullParse() async throws {
        let parser = MarkdownMessageIncrementalParser()

        let original = parser.reconcile(oldText: "", newText: "- one\n- two\n")
        let edited = parser.reconcile(oldText: original.sourceText, newText: "- zero\n- one\n- two\n", previous: original)

        #expect(edited.blocks == parser.fullParse("- zero\n- one\n- two\n"))
    }
}
```

Also add cases for quote growth, todo growth, and Mermaid code blocks.

**Step 2: Run test to verify it fails if coverage is missing**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MarkdownMessageViewRenderingTests
```

Expected: FAIL until all view-facing invariants are represented.

**Step 3: Write minimal implementation**

Add any missing helper APIs needed for tests, such as a small internal projection function from source text to render blocks. Do not reintroduce parser logic into the view.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/MarkdownMessageViewRenderingTests.swift agentGui/Views/MarkdownMessageView.swift
git commit -m "test: add markdown message rendering regression coverage"
```

## Task 5: Wire Message Call Sites and Run Full Validation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageResultBlockView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MarkdownMessageView.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageResultBlockView.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTimelineView.swift`

**Step 1: Run focused test suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MarkdownMessageBlockPresentationTests -only-testing:agentGuiTests/MarkdownMessageIncrementalParserTests -only-testing:agentGuiTests/MarkdownMessageViewRenderingTests
```

Expected: PASS.

**Step 2: Run full project build**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 3: Manual smoke test in app**

Verify the following in the running app:

- agent result messages still render existing plain markdown correctly
- subagent timeline messages still render markdown without layout regressions
- streamed table and code fence cases converge correctly
- no obvious scroll jump or flicker appears when long messages append

**Step 4: Update docs if needed**

If the implementation introduces a reusable incremental markdown layer or changes renderer responsibilities, add a short note to:

- `/Volumes/T7/文稿/Projects/agentGui/docs/markdown-render-review-2026-03-08.md`

Only update docs if the shipped architecture differs materially from the current review notes.

**Step 5: Commit**

```bash
git add agentGui/Views/AgentMessageResultBlockView.swift agentGui/Views/SubagentTimelineView.swift agentGui/Views/MarkdownMessageView.swift docs/markdown-render-review-2026-03-08.md
git commit -m "fix: stabilize markdown message incremental rendering"
```

## Risks and Guardrails

- Do not move Markdown block semantics into SwiftUI view bodies.
- Do not try to make every block perfectly styled in the first pass; safe structural rendering is enough.
- Do not overfit the unstable-tail detector to tables only; code fences, quotes, and lists need the same mechanism.
- If deterministic block ids prove difficult using only content hash, include prior-snapshot reuse logic rather than falling back to random UUIDs.
- If `BlockMarkdownCodec` lacks one edge case needed for parity, fix that parser in one place instead of adding a message-only exception.

## Suggested Test Order

1. `MarkdownMessageBlockPresentationTests`
2. `MarkdownMessageIncrementalParserTests`
3. `MarkdownMessageViewRenderingTests`
4. Full build

## Execution Handoff

Plan complete and saved to `docs/plans/2026-03-10-markdown-message-view.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
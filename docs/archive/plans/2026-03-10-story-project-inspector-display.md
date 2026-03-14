# Story Project Inspector Display Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expand StoryProjectInspectorView from a lightweight highlight panel into a complete read-only story project browser that covers the existing story-memory models.

**Architecture:** Keep the display logic split across two layers. Put sorting, grouping, JSON decoding, fallback strings, and display-specific shaping into `StoryProjectPresentation`, then keep `StoryProjectInspectorView` focused on rendering grouped read-only sections. Use tests to pin the presentation contract first so the UI rewrite can stay mechanical and low-risk.

**Tech Stack:** Swift 6, SwiftUI, SwiftData models already in the repo, Swift Testing, existing story-memory presentation/view code.

---

## Implementation Notes

- Do not add editing controls beyond the existing session binding buttons.
- Do not mutate or normalize persisted story-memory data in this feature; only reshape it for display.
- Prefer adding inspector-specific display structs instead of making the SwiftUI view decode JSON or construct business strings inline.
- Put most assertions in `StoryProjectPresentationTests.swift`; view behavior should remain thin and mostly deterministic from the snapshot.
- Keep scope aligned with the requirement doc: no CRUD UI, no drag reorder, no inline status edits.

## Proposed File Layout

**Modify presentation layer:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`

**Modify inspector UI:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`

**Modify tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-09-story-project-inspector-display-requirements.md`

### Task 1: Pin the Expanded Inspector Snapshot Contract

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-09-story-project-inspector-display-requirements.md`

**Step 1: Write the failing tests**

Replace the current narrow inspector assertions with coverage for the full read-only snapshot shape:

- `inspectorSnapshotCollectsProjectOverviewAndStats()`
- `inspectorSnapshotBuildsChapterSceneHierarchy()`
- `inspectorSnapshotBuildsCharacterLocationRuleAndStyleSections()`
- `inspectorSnapshotGroupsForeshadowsAndContinuityIssuesByStatus()`
- `inspectorSnapshotDecodesJSONFieldsIntoReadableLists()`

Use a richly populated `WritingProject` fixture in the test so the snapshot contract is explicit.

```swift
@Test func inspectorSnapshotBuildsChapterSceneHierarchy() async throws {
    let project = WritingProject(title: "北塔之冬", synopsis: "王都迷雾中的权力阴影")

    let chapter = StoryChapterRecord(
        number: 2,
        title: "北塔夜访",
        outline: "潜入北塔，确认档案去向",
        summary: "林澈第一次进入北塔内部",
        toneDirective: "压抑、克制",
        isLocked: true
    )
    chapter.scenes.append(
        StorySceneRecord(
            title: "入塔",
            sceneIndex: 1,
            povCharacterName: "林澈",
            locationName: "北塔",
            characterNamesJSON: "[\"林澈\",\"守卫\"]",
            summary: "林澈伪装潜入",
            previousSceneId: "prev-scene",
            timelineEventId: "event-1"
        )
    )
    project.chapters.append(chapter)

    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

    #expect(snapshot.chapterSections.count == 1)
    #expect(snapshot.chapterSections[0].isLocked == true)
    #expect(snapshot.chapterSections[0].scenes[0].participantNames == ["林澈", "守卫"])
    #expect(snapshot.chapterSections[0].scenes[0].hasPreviousSceneReference == true)
    #expect(snapshot.chapterSections[0].scenes[0].hasTimelineEventReference == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: FAIL because the current snapshot only exposes simple title arrays.

**Step 3: Write minimal implementation**

In `StoryProjectPresentation.swift`, add explicit display models for the inspector instead of growing the current snapshot with raw arrays only.

```swift
struct StoryProjectInspectorSnapshot: Equatable {
    let overview: StoryProjectOverviewSection
    let stats: StoryProjectStatsSection
    let chapterSections: [StoryProjectChapterSection]
    let characterCards: [StoryProjectCharacterCard]
    let locationCards: [StoryProjectLocationCard]
    let worldRuleSections: [StoryProjectWorldRuleSection]
    let timelineEvents: [StoryProjectTimelineCard]
    let foreshadowGroups: [StoryProjectForeshadowGroup]
    let continuityGroups: [StoryProjectContinuityGroup]
    let styleCard: StoryProjectStyleCard?
}
```

Add local helpers to decode stored JSON arrays or dictionaries into readable values and normalize empty values into UI-friendly placeholders.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: expand story project inspector snapshot"
```

### Task 2: Add Presentation Helpers for Sorting, Grouping, and Empty-State Fallbacks

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Step 1: Write the failing tests**

Add focused tests that lock the grouping and ordering rules from the spec:

- chapters sorted by `number`
- scenes sorted by `sceneIndex`
- world rules grouped by `category`
- foreshadows grouped by status with unresolved groups first
- continuity issues grouped by resolution status, then severity, then newest chapter first
- missing text fields rendered as placeholders instead of empty strings

```swift
@Test func inspectorSnapshotOrdersContinuityIssuesByOpenSeverityAndRecency() async throws {
    let project = WritingProject(title: "北塔之冬")
    project.continuityIssues = [
        StoryContinuityIssue(issueKind: "locationConflict", severity: "warning", chapterNumber: 1, sceneIndex: 1, detail: "A", resolutionStatus: "open"),
        StoryContinuityIssue(issueKind: "worldRuleConflict", severity: "critical", chapterNumber: 3, sceneIndex: 2, detail: "B", resolutionStatus: "open"),
        StoryContinuityIssue(issueKind: "characterDrift", severity: "warning", chapterNumber: 2, sceneIndex: 1, detail: "C", resolutionStatus: "accepted")
    ]

    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

    #expect(snapshot.continuityGroups.map(\.status) == ["open", "accepted"])
    #expect(snapshot.continuityGroups[0].items.map(\.issueKind) == ["worldRuleConflict", "locationConflict"])
}
```

**Step 2: Run test to verify it fails**

Run the same focused `xcodebuild` command for `StoryProjectPresentationTests`.

Expected: FAIL until the ordering and fallback helpers are implemented.

**Step 3: Write minimal implementation**

In `StoryProjectPresentation.swift`:

- add private helper functions for JSON decoding
- add fallback formatting helpers such as `displayText(_:)`
- centralize severity and status ranking in small lookup helpers
- compute stats like scene count, location count, world-rule count, and event count in one place

Example helper shape:

```swift
private static func decodedStringArray(from json: String) -> [String] { ... }
private static func displayText(_ value: String, fallback: String = "暂无") -> String { ... }
private static func continuitySeverityRank(_ value: String) -> Int { ... }
private static func foreshadowStatusRank(_ value: String) -> Int { ... }
```

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add inspector presentation grouping rules"
```

### Task 3: Rebuild StoryProjectInspectorView Around the New Snapshot

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`

**Step 1: Write the failing test or compile target**

This view currently depends on the old snapshot fields, so once Task 1 lands the file should fail to compile. Use that as the failure gate.

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD FAIL in `StoryProjectInspectorView.swift` because properties like `characterNames` and `timelineTitles` no longer match the new snapshot.

**Step 2: Write minimal implementation**

Refactor the view to render grouped read-only sections in this order:

- overview header
- stats grid
- chapter and scene structure
- character cards
- location cards
- world rule groups
- timeline cards
- foreshadow groups
- continuity groups
- style card

Use compact helper views inside the same file if possible. Only extract subviews if the file becomes difficult to read.

Target structure:

```swift
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            overviewCard
            statsGrid
            chapterSection
            characterSection
            locationSection
            worldRuleSection
            timelineSection
            foreshadowSection
            continuitySection
            styleSection
        }
        .padding(20)
    }
    .navigationTitle(snapshot.overview.title)
}
```

Keep the existing attach and detach buttons in the header. Do not add `TextField`, `Menu`, `SwipeActions`, or edit affordances.

**Step 3: Run build to verify it succeeds**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke review**

Open a project with at least one populated `WritingProject` and verify:

- empty modules show placeholder text
- long text truncates by default
- chapter and scene hierarchy is readable
- unresolved foreshadows and open continuity issues appear above resolved groups
- no new edit controls were introduced

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectInspectorView.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift
git commit -m "feat: redesign story project inspector display"
```

### Task 4: Final Regression Pass for Story Presentation Behavior

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectListView.swift`

**Step 1: Re-run summary tests**

Make sure the list-page summary contract still behaves as before and the expanded inspector work did not regress existing project list behavior.

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: PASS for both summary tests and new inspector tests.

**Step 2: Run the broader story-memory test slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/StoryProjectPresentationTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests
```

Expected: PASS. If unrelated failures appear, document them and confirm they are pre-existing before proceeding.

**Step 3: Update docs if implementation deviates from the spec**

Only if needed, adjust:

- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-09-story-project-inspector-display-requirements.md`

Keep changes minimal and only for implementation-validated deviations.

**Step 4: Commit**

```bash
git add agentGuiTests/StoryProjectPresentationTests.swift docs/spec/2026-03-09-story-project-inspector-display-requirements.md
git commit -m "test: validate story project inspector presentation"
```

## Done Criteria

- `StoryProjectInspectorView` shows grouped read-only sections for overview, stats, chapters and scenes, characters, locations, world rules, timeline, foreshadows, continuity issues, and style.
- `StoryProjectPresentation.inspectorSnapshot(for:)` returns UI-ready data with ordering, grouping, decoded JSON fields, and empty-state fallbacks.
- Existing summary behavior for the project list remains unchanged.
- No edit, create, delete, or status mutation controls are added to the inspector.
- Focused presentation tests pass.

## Risks to Watch

- The snapshot can become too wide if raw model details leak through. Prefer small display-specific types.
- `FlowLayout` may no longer be sufficient once most sections move to card-based layouts. Remove it if it becomes dead code.
- Very large projects can make one giant `ScrollView` noisy. Keep sections collapsible or visually chunked, but do not introduce navigation complexity in this iteration.

## Execution Handoff

Plan complete and saved to `docs/plans/2026-03-10-story-project-inspector-display.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
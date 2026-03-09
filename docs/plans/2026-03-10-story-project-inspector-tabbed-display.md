# Story Project Inspector Tabbed Display Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild StoryProjectInspectorView into a tabbed story-memory browser with a fixed project overview area, differentiated layouts per memory domain, and lightweight cross-tab navigation.

**Architecture:** Keep display shaping in the presentation layer and make the inspector UI a thin composition shell. Split the feature into a stable inspector shell, tab-specific snapshot models, and tab-specific SwiftUI views so overview, structure, character, timeline, foreshadow, continuity, and style pages can evolve independently without turning StoryProjectInspectorView into another monolith.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing story-memory models and StoryProjectPresentation pipeline.

---

## Implementation Notes

- This plan supersedes the older single-page plan in [docs/plans/2026-03-10-story-project-inspector-display.md](/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-story-project-inspector-display.md).
- Keep the feature read-only except for the existing session binding actions in the overview header.
- Do not decode JSON or derive business strings in SwiftUI view bodies; keep that in presentation helpers.
- Prefer small view files per tab instead of growing StoryProjectInspectorView further.
- Follow TDD where it is practical: presentation contracts and navigation state should be pinned by tests first; visual layout tasks can use compile plus manual smoke review.
- Do not redesign StoryProjectListView in this plan.

## Proposed File Layout

**Modify presentation layer:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`

**Modify inspector shell:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`

**Create tab infrastructure:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTabBar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorNavigationState.swift`

**Create tab views:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStructureTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorCharacterTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorLocationTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorRuleTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTimelineTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorForeshadowTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorContinuityTab.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStyleTab.swift`

**Modify tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-09-story-project-inspector-display-requirements.md`

## Task 1: Pin the Tabbed Inspector Snapshot Contract

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md`

**Step 1: Write the failing tests**

Add tests that pin the new tabbed inspector contract instead of only the old single-page sections:

- `inspectorSnapshotExposesTabbedCountsInExpectedOrder()`
- `inspectorSnapshotBuildsOverviewHighlights()`
- `inspectorSnapshotBuildsStructureNavigationItems()`
- `inspectorSnapshotBuildsTimelineForeshadowAndContinuityHighlights()`
- `inspectorSnapshotUsesEmptySnapshotsWhenDomainHasNoData()`

Example assertion shape:

```swift
@Test func inspectorSnapshotExposesTabbedCountsInExpectedOrder() async throws {
    let project = makeRichProject()

    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

    #expect(snapshot.tabs.map(\.id) == [.overview, .structure, .characters, .locations, .rules, .timeline, .foreshadows, .continuity, .style])
    #expect(snapshot.tabs.map(\.count) == [nil, 2, 2, 2, 2, 2, 3, 3, 1])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: FAIL because `StoryProjectInspectorSnapshot` does not yet expose tab metadata or tab-specific summary slices.

**Step 3: Write minimal implementation**

In `StoryProjectPresentation.swift`, reshape the snapshot around tabbed browsing. Keep existing display cards where useful, but add tab-oriented containers such as:

```swift
struct StoryProjectInspectorSnapshot: Equatable {
    let overview: StoryProjectOverviewSection
    let stats: StoryProjectStatsSection
    let tabs: [StoryProjectInspectorTabItem]
    let overviewTab: StoryProjectOverviewTabSnapshot
    let structureTab: StoryProjectStructureTabSnapshot
    let charactersTab: StoryProjectCharacterTabSnapshot
    let locationsTab: StoryProjectLocationTabSnapshot
    let rulesTab: StoryProjectRuleTabSnapshot
    let timelineTab: StoryProjectTimelineTabSnapshot
    let foreshadowsTab: StoryProjectForeshadowTabSnapshot
    let continuityTab: StoryProjectContinuityTabSnapshot
    let styleTab: StoryProjectStyleTabSnapshot
}
```

Reuse existing card models where possible. Do not introduce view-driven formatting here.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add tabbed story project inspector snapshot"
```

## Task 2: Add Inspector Tab Infrastructure and Navigation State

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTabBar.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorNavigationState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Step 1: Write the failing test**

Add tests for stable tab identity and navigation state behavior:

- `inspectorTabOrderMatchesSpec()`
- `navigationStateDefaultsToOverview()`
- `navigationStateRemembersLastTabPerProject()`

Example:

```swift
@Test func navigationStateDefaultsToOverview() async throws {
    let state = StoryProjectInspectorNavigationState()
    let projectID = UUID()

    #expect(state.selectedTab(for: projectID) == .overview)
}
```

**Step 2: Run test to verify it fails**

Run the same `StoryProjectPresentationTests` command, or split the tests into a dedicated file if that improves readability.

Expected: FAIL because the tab enum and navigation state do not exist.

**Step 3: Write minimal implementation**

Create a stable enum for tabs:

```swift
enum StoryProjectInspectorTab: String, CaseIterable, Identifiable {
    case overview
    case structure
    case characters
    case locations
    case rules
    case timeline
    case foreshadows
    case continuity
    case style

    var id: String { rawValue }
}
```

Create a small navigation state store that remembers the most recent tab per project in memory. Keep it simple and app-session scoped; do not add persistence beyond the current runtime in this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTabBar.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorNavigationState.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add story project inspector tab infrastructure"
```

## Task 3: Rebuild StoryProjectInspectorView as Shell + Fixed Overview Header

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTabBar.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift`

**Step 1: Run build to establish the current compile baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS before the shell rewrite starts.

**Step 2: Write minimal implementation**

Refactor `StoryProjectInspectorView` into a shell with three layers:

- fixed overview header card
- tab bar
- selected tab content

Target shape:

```swift
var body: some View {
    VStack(spacing: 16) {
        overviewHeader
        StoryProjectInspectorTabBar(...)
        selectedTabView
    }
    .navigationTitle(snapshot.overview.title)
}
```

Keep the existing bind and unbind buttons in the header. Do not pull domain-specific content back into this file.

**Step 3: Run build to verify it succeeds**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke review**

Open a populated project and verify:

- the overview header remains stable during tab switches
- tab labels and counts are visible
- switching tabs does not change the binding controls or header height dramatically

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectInspectorView.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTabBar.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift
git commit -m "feat: add tabbed story project inspector shell"
```

## Task 4: Implement the Overview Tab with Summary Cards and Jump Actions

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests for overview-specific summary slices:

- `overviewTabContainsRecentChaptersAndRecentEvents()`
- `overviewTabContainsOpenForeshadowAndContinuityHighlights()`
- `overviewTabContainsStyleSummaryWhenAvailable()`

Example:

```swift
@Test func overviewTabContainsRecentChaptersAndRecentEvents() async throws {
    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: makeRichProject())

    #expect(snapshot.overviewTab.recentChapters.map(\.number) == [2, 1])
    #expect(snapshot.overviewTab.recentEvents.map(\.title) == ["潜入北塔", "进入王都"])
}
```

**Step 2: Run test to verify it fails**

Run the focused `StoryProjectPresentationTests` command.

Expected: FAIL until overview slices are added.

**Step 3: Write minimal implementation**

Build the overview tab using summary-only content:

- metric cards
- recent chapters summary list
- recent timeline events summary list
- unresolved foreshadow summary block
- open continuity summary block
- style summary card

Provide a simple callback like `onJumpToTab(StoryProjectInspectorTab)` for the “查看全部” actions.

**Step 4: Run tests and build to verify they pass**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryProjectPresentationTests
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: PASS and BUILD SUCCESS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add story project overview tab"
```

## Task 5: Implement the Structure Tab with Chapter Navigation and Scene Details

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStructureTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests that pin a structure-specific navigation model:

- `structureTabBuildsChapterNavigationItems()`
- `structureTabDefaultsToFirstChapterWhenAvailable()`
- `structureTabPreservesSceneOrderingAndStatusBadges()`

Example:

```swift
@Test func structureTabDefaultsToFirstChapterWhenAvailable() async throws {
    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: makeRichProject())

    #expect(snapshot.structureTab.chapterNavigation.first?.number == 1)
    #expect(snapshot.structureTab.chapterNavigation.first?.isLocked == false)
}
```

**Step 2: Run test to verify it fails**

Run the focused tests.

Expected: FAIL until the structure tab snapshot exists.

**Step 3: Write minimal implementation**

Implement a two-pane layout where width allows it:

- left pane: chapter navigation list
- right pane: selected chapter detail and scene cards

For compact widths, fall back to a single-column grouped list. Use local view state for the selected chapter number.

**Step 4: Run tests and build to verify they pass**

Run the presentation tests and a build.

Expected: PASS and BUILD SUCCESS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStructureTab.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add story project structure tab"
```

## Task 6: Implement Characters, Locations, Rules, and Style Tabs with Differentiated Layouts

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorCharacterTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorLocationTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorRuleTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStyleTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`

**Step 1: Write the failing tests**

Add tests for the domain-specific tab slices:

- `characterTabSupportsDisplaySortedCards()`
- `locationTabBuildsEnvironmentFocusedCards()`
- `ruleTabGroupsRulesByCategory()`
- `styleTabSeparatesMetricsSamplesAndAntiPatterns()`

Example:

```swift
@Test func ruleTabGroupsRulesByCategory() async throws {
    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: makeRichProject())

    #expect(snapshot.rulesTab.sections.map(\.category) == ["社会秩序", "能力约束"])
}
```

**Step 2: Run test to verify it fails**

Run the same focused test command.

Expected: FAIL until the domain tab snapshots are exposed.

**Step 3: Write minimal implementation**

Implement each tab with its intended layout language:

- characters: adaptive card grid
- locations: environment-oriented grid or two-column list
- rules: grouped manual with category sections and exception blocks
- style: metrics header plus samples and anti-pattern sections

Do not add full filtering logic yet; reserve space for a future toolbar only where it helps layout.

**Step 4: Run tests and build to verify they pass**

Run the focused presentation tests and a build.

Expected: PASS and BUILD SUCCESS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorCharacterTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorLocationTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorRuleTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStyleTab.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift
git commit -m "feat: add story project domain tabs"
```

## Task 7: Implement Timeline, Foreshadow, and Continuity Tabs with Status-Oriented Layouts

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTimelineTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorForeshadowTab.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorContinuityTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests for specialized risk and status layouts:

- `timelineTabBuildsOrderedEventNodes()`
- `foreshadowTabGroupsItemsByStatusWithUnresolvedFirst()`
- `continuityTabGroupsIssuesByResolutionStatusAndSeverity()`
- `continuityTabPreservesProblemCountsForBadges()`

Example:

```swift
@Test func foreshadowTabGroupsItemsByStatusWithUnresolvedFirst() async throws {
    let snapshot = StoryProjectPresentation.inspectorSnapshot(for: makeRichProject())

    #expect(snapshot.foreshadowsTab.groups.map(\.status) == ["open", "planned", "resolved"])
}
```

**Step 2: Run test to verify it fails**

Run the focused tests.

Expected: FAIL until the new tab snapshots are exposed.

**Step 3: Write minimal implementation**

Implement:

- timeline as a vertical timeline with chapter and scene anchors
- foreshadows as status-grouped sections with unresolved emphasis
- continuity as a risk inbox list grouped by resolution state and sorted by severity

Keep entity chips visually distinct, but do not implement deep-link navigation inside this task yet.

**Step 4: Run tests and build to verify they pass**

Run the focused tests and a build.

Expected: PASS and BUILD SUCCESS.

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTimelineTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorForeshadowTab.swift agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorContinuityTab.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift agentGuiTests/StoryProjectPresentationTests.swift
git commit -m "feat: add story project status tabs"
```

## Task 8: Add Cross-Tab Jumping and Lightweight Entity Linking

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorOverviewTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorStructureTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorLocationTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorRuleTab.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/Inspector/StoryProjectInspectorTimelineTab.swift`

**Step 1: Write the failing test or compile target**

For jump behavior, use a small state-driven unit test if convenient; otherwise use a manual verification gate plus build validation.

Target interactions to support:

- overview summary “查看全部” buttons switch to the relevant tab
- scene character chip can switch to the character tab
- location rule chip can switch to the rules tab
- timeline location chip can switch to the locations tab

If you add a testable router object, pin it with tests before wiring it to the views.

**Step 2: Run build to verify the pre-change baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 3: Write minimal implementation**

Add a small routing surface in the inspector shell, for example:

```swift
struct StoryProjectInspectorJumpTarget: Equatable {
    let tab: StoryProjectInspectorTab
    let anchorID: String?
}
```

Use it to change tabs immediately. Anchor scrolling can be best-effort in this phase; if a clean anchor implementation is too expensive, support tab switching first and leave exact in-tab scrolling as follow-up.

**Step 4: Run build and manual smoke review**

Run the build command, then verify manually:

- overview “查看全部” switches tabs
- representative chips switch to the intended tab
- no tab-switch loop or stale state appears

**Step 5: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryProjectInspectorView.swift agentGui/Views/StoryMemory/Inspector/*.swift
git commit -m "feat: add story project inspector cross-tab jumps"
```

## Task 9: Final Regression Pass and Documentation Alignment

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-09-story-project-inspector-display-requirements.md`

**Step 1: Run the focused story-project test slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: PASS.

**Step 2: Run the broader story-memory regression slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/StoryProjectPresentationTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests \
  -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: PASS. If unrelated failures appear, confirm they are pre-existing before making any extra code changes.

**Step 3: Run a final build**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 4: Manual UX smoke review**

Verify all of the following against the new spec:

- overview header stays visually stable across tabs
- tab bar shows all tabs even when a domain is empty
- each tab uses a meaningfully different layout from the others
- timeline reads like a timeline, not a generic card list
- foreshadow and continuity read like tracking views, not generic detail pages
- base materials, corners, chips, and typography still feel native to the rest of the app

**Step 5: Update docs only if the implementation intentionally diverges**

If implementation decisions differ from the spec, update:

- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md`

Otherwise, leave the spec unchanged.

**Step 6: Commit**

```bash
git add agentGui/Views/StoryMemory agentGuiTests/StoryProjectPresentationTests.swift docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md
git commit -m "feat: finish tabbed story project inspector"
```

## Execution Notes

- Recommended order: Task 1 -> Task 2 -> Task 3 -> Task 4 -> Task 5 -> Task 6 -> Task 7 -> Task 8 -> Task 9
- If the view split feels too granular during execution, it is acceptable to merge low-complexity tabs into fewer files, but keep the shell and tab infrastructure separate.
- If there is no practical way to test a specific SwiftUI layout with unit tests, prefer presentation tests plus explicit manual verification steps instead of inventing brittle UI internals.

Plan complete and saved to `docs/plans/2026-03-10-story-project-inspector-tabbed-display.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
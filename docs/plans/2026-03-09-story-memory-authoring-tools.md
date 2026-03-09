# Story Memory Authoring Tools Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fill the missing story-memory authoring tools so agentGui can write, query, and maintain chapter, scene, foreshadow, world-rule, location, style, and continuity canon as structured project memory.

**Architecture:** Reuse the existing SwiftData story-memory models and the current Claude tool pipeline. Implement the gap in three layers: `StoryMemoryService` for idempotent writes, `StoryMemoryRetrievalService` for stable reads, and `ClaudeService` tool registration/dispatch/execution for model-facing APIs. Keep prompt assembly and project presentation as downstream consumers, changing them only if tests reveal a mismatch.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, existing ClaudeService ToolBuilder/ToolDispatch pipeline.

---

## Implementation Notes

- Do not create new SwiftData models for this feature. `StoryChapterRecord`, `StorySceneRecord`, `StoryWorldRule`, `StoryLocationProfile`, `StoryForeshadowItem`, `StoryStyleProfile`, and `StoryContinuityIssue` already exist.
- Keep the write path idempotent. Repeated writes must update the existing entity instead of appending duplicates.
- For `story_memory_upsert_scene`, use a strict first pass: if the target chapter does not exist, return a readable error instead of auto-creating a blank chapter. This is smaller, safer, and keeps canon structure explicit.
- Keep `StoryStyleProfile` as a per-project singleton.
- Preserve current prompt-assembler behavior. The main deliverable is tool-first authoring, not a new editing UI.
- Ship in this order: service drafts and tests -> write methods -> retrieval methods -> tool exposure -> consumer verification -> docs.

## Proposed File Layout

**Modify core services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+StoryMemoryTools.swift`

**Modify Claude tool plumbing:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`

**Modify tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`

**Modify docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/story-memory-usage-2026-03-09.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/novel-memory-architecture-2026-03-09.md`

### Task 1: Add Failing Tests for Authoring Service Contracts

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`

**Step 1: Write the failing test**

Add tests that pin the write contracts for the missing authoring operations:

- `storyMemoryServiceUpsertsChapters()`
- `storyMemoryServiceUpsertsScenesWithinExistingChapter()`
- `storyMemoryServiceRejectsSceneWithoutChapter()`
- `storyMemoryServiceUpsertsWorldRules()`
- `storyMemoryServiceUpsertsLocations()`
- `storyMemoryServiceUpsertsForeshadowsAndResolvesThem()`
- `storyMemoryServiceUpsertsStyleProfileAsSingleton()`
- `storyMemoryServiceUpdatesContinuityIssueStatus()`

Use the same in-memory container pattern already used in this file.

```swift
@Test func storyMemoryServiceUpsertsChapters() async throws {
    let container = try makeStoryContainer()
    let context = ModelContext(container)
    let service = StoryMemoryService(modelContext: context)
    let project = try service.createProject(title: "北塔之冬", synopsis: "")

    _ = try service.upsertChapter(
        projectId: project.id,
        payload: StoryChapterDraft(chapterNumber: 3, title: "北塔夜访", summary: "林澈第一次进入北塔")
    )
    _ = try service.upsertChapter(
        projectId: project.id,
        payload: StoryChapterDraft(chapterNumber: 3, title: "北塔夜访", summary: "林澈与顾沉首次正面对峙")
    )

    #expect(project.chapters.count == 1)
    #expect(project.chapters.first?.summary == "林澈与顾沉首次正面对峙")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests
```

Expected: FAIL because the new draft types and service methods do not exist.

**Step 3: Write minimal implementation**

Add draft types to `StoryMemoryService.swift`:

```swift
struct StoryChapterDraft { ... }
struct StorySceneDraft { ... }
struct StoryWorldRuleDraft { ... }
struct StoryLocationDraft { ... }
struct StoryForeshadowDraft { ... }
struct StoryStyleProfileDraft { ... }
struct StoryContinuityIssueUpdateDraft { ... }
```

Add service method signatures:

```swift
func upsertChapter(projectId: UUID, payload: StoryChapterDraft) throws -> StoryChapterRecord
func upsertScene(projectId: UUID, payload: StorySceneDraft) throws -> StorySceneRecord
func upsertWorldRule(projectId: UUID, payload: StoryWorldRuleDraft) throws -> StoryWorldRule
func upsertLocation(projectId: UUID, payload: StoryLocationDraft) throws -> StoryLocationProfile
func upsertForeshadow(projectId: UUID, payload: StoryForeshadowDraft) throws -> StoryForeshadowItem
func upsertStyleProfile(projectId: UUID, payload: StoryStyleProfileDraft) throws -> StoryStyleProfile
func updateContinuityIssue(projectId: UUID, issueId: UUID, payload: StoryContinuityIssueUpdateDraft) throws -> StoryContinuityIssue
```

Keep lookup keys aligned with the requirement doc:

- chapter: `chapterNumber`
- scene: `chapterNumber + sceneIndex`
- world rule: `title`
- location: `name`
- foreshadow: `tag`
- style profile: project singleton

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryService.swift agentGuiTests/StoryMemoryRetrievalServiceTests.swift
git commit -m "feat: add story memory authoring service methods"
```

### Task 2: Add Retrieval Coverage for New Query Kinds

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`

**Step 1: Write the failing test**

Add retrieval tests for the new query surface:

- `retrievalServiceReturnsChapters()`
- `retrievalServiceReturnsScenesFilteredByChapter()`
- `retrievalServiceReturnsWorldRules()`
- `retrievalServiceReturnsLocations()`
- `retrievalServiceReturnsStyleProfile()`
- `retrievalServiceReturnsContinuityIssuesByStatus()`

Example:

```swift
@Test func retrievalServiceReturnsScenesFilteredByChapter() async throws {
    let container = try makeStoryContainer()
    let context = ModelContext(container)
    let service = StoryMemoryService(modelContext: context)
    let retrieval = StoryMemoryRetrievalService(modelContext: context)
    let project = try service.createProject(title: "北塔之冬", synopsis: "")

    _ = try service.upsertChapter(projectId: project.id, payload: .init(chapterNumber: 2, title: "北塔夜访"))
    _ = try service.upsertScene(projectId: project.id, payload: .init(chapterNumber: 2, sceneIndex: 1, title: "入塔"))
    _ = try service.upsertScene(projectId: project.id, payload: .init(chapterNumber: 2, sceneIndex: 2, title: "对峙"))

    let scenes = try retrieval.scenes(projectId: project.id, chapterNumber: 2)
    #expect(scenes.map(\.sceneIndex) == [1, 2])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests
```

Expected: FAIL because the new retrieval methods do not exist.

**Step 3: Write minimal implementation**

Add these methods in `StoryMemoryRetrievalService.swift`:

```swift
func chapters(projectId: UUID) throws -> [StoryChapterRecord]
func scenes(projectId: UUID, chapterNumber: Int?) throws -> [StorySceneRecord]
func worldRules(projectId: UUID) throws -> [StoryWorldRule]
func locations(projectId: UUID) throws -> [StoryLocationProfile]
func styleProfile(projectId: UUID) throws -> StoryStyleProfile?
func continuityIssues(projectId: UUID, resolutionStatus: String?) throws -> [StoryContinuityIssue]
```

Return stable sort order:

- chapters by `number`
- scenes by `chapter.number`, then `sceneIndex`
- world rules by `title`
- locations by `name`
- continuity issues by unresolved first, then chapter, then scene

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryRetrievalService.swift agentGuiTests/StoryMemoryRetrievalServiceTests.swift
git commit -m "feat: add story memory retrieval coverage"
```

### Task 3: Expand Tool Execution for New Writes and Queries

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+StoryMemoryTools.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: Write the failing test**

Extend the tool-level tests so they cover:

- `story_memory_upsert_chapter`
- `story_memory_upsert_scene`
- `story_memory_upsert_world_rule`
- `story_memory_upsert_location`
- `story_memory_upsert_foreshadow`
- `story_memory_upsert_style_profile`
- `story_memory_update_continuity_issue`
- extended `story_memory_query` kinds

Add at least one tool-path test that verifies the response includes project scope, object identity, and created or updated status.

```swift
@Test func storyMemoryToolUpsertsChapter() async throws {
    let container = try makeStoryContainer()
    let context = ModelContext(container)
    let settings = AppSettings()
    settings.enableStoryMemory = true

    let service = StoryMemoryService(modelContext: context)
    let project = try service.createProject(title: "北塔之冬", synopsis: "")
    let session = Session(title: "写作会话")
    context.insert(session)
    try service.attachProject(to: session, projectId: project.id)

    let result = await ClaudeService().executeTool(
        name: "story_memory_upsert_chapter",
        input: [
            "chapter_number": .integer(3),
            "title": .string("北塔夜访"),
            "summary": .string("林澈夜探北塔")
        ],
        settings: settings,
        session: session,
        modelContext: context
    )

    #expect(result.status == .success)
    #expect(result.text.contains("created"))
    #expect(result.text.contains("北塔之冬"))
    #expect(result.text.contains("chapter 3"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: FAIL because the tool names and execution methods do not exist.

**Step 3: Write minimal implementation**

In `ClaudeService+StoryMemoryTools.swift`:

- add paired execution methods for session-bound and `sessionId`-bound entry points
- validate required keys before calling `StoryMemoryService`
- reuse `resolveStoryProjectId`, `parseUUIDParameter`, and JSON decode helpers
- format output as stable text with:
  - object type
  - project title
  - `created` or `updated`
  - locator fields
  - changed-field summary

Expand `executeStoryMemoryQuery` to support:

- `chapters`
- `scenes`
- `world_rules`
- `locations`
- `style`
- `continuity_issues`

Recommended output pattern:

```text
Story memory query: chapters
Project: 北塔之冬
Filters: none
- Chapter 3 | 北塔夜访 | scenes: 2 | locked: false
```

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+StoryMemoryTools.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: add story memory authoring tools"
```

### Task 4: Register, Dispatch, and Record the New Tool Surface

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: Write the failing test**

Extend `toolBuilderIncludesStoryMemoryTools()` to require the new names:

```swift
#expect(names.contains("story_memory_upsert_chapter"))
#expect(names.contains("story_memory_upsert_scene"))
#expect(names.contains("story_memory_upsert_world_rule"))
#expect(names.contains("story_memory_upsert_location"))
#expect(names.contains("story_memory_upsert_foreshadow"))
#expect(names.contains("story_memory_upsert_style_profile"))
#expect(names.contains("story_memory_update_continuity_issue"))
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests/toolBuilderIncludesStoryMemoryTools
```

Expected: FAIL because the tool list and dispatch switch are incomplete.

**Step 3: Write minimal implementation**

In `ClaudeService+ToolBuilder.swift`, add `.function` schemas for the new tools with explicit required keys.

In `ClaudeService+ToolDispatch.swift`, add cases for both overloads:

```swift
case "story_memory_upsert_chapter":
case "story_memory_upsert_scene":
case "story_memory_upsert_world_rule":
case "story_memory_upsert_location":
case "story_memory_upsert_foreshadow":
case "story_memory_upsert_style_profile":
case "story_memory_update_continuity_issue":
```

In `ClaudeService+ToolCallRecord.swift`, add the same names to the recorder so the timeline UI and tool history remain accurate.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: expose story memory authoring tool surface"
```

### Task 5: Verify Prompt and Project Presentation Consumers

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryProjectPresentationTests.swift`
- Modify if needed: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- Modify if needed: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectPresentation.swift`

**Step 1: Write the failing test**

Add focused tests for the downstream guarantees required by the spec:

- new world-rule and style writes are visible in prompt assembly
- resolved foreshadows leave the unresolved slice
- continuity issue status changes update the project summary counts

Example:

```swift
@Test func projectPresentationCountsOnlyUnresolvedContinuityIssues() async throws {
    let project = WritingProject(title: "北塔之冬", synopsis: "")
    project.continuityIssues = [
        StoryContinuityIssue(issueKind: "locationConflict", severity: "high", chapterNumber: 3, sceneIndex: 1, detail: "...", resolutionStatus: "open"),
        StoryContinuityIssue(issueKind: "worldRuleConflict", severity: "medium", chapterNumber: 3, sceneIndex: 2, detail: "...", resolutionStatus: "resolved")
    ]

    let summary = StoryProjectPresentation.makeSnapshot(project)
    #expect(summary.openContinuityIssueCount == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests -only-testing:agentGuiTests/StoryProjectPresentationTests
```

Expected: FAIL only if a consumer mismatch exists. If all tests already pass, keep code unchanged and keep the tests.

**Step 3: Write minimal implementation**

Only if tests fail:

- adjust prompt assembly formatting in `StoryMemoryPromptAssembler.swift`
- adjust open-issue or unresolved-foreshadow counting in `StoryProjectPresentation.swift`

Do not add new UI features in this task.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGuiTests/StoryProjectPresentationTests.swift agentGui/Services/StoryMemoryPromptAssembler.swift agentGui/Views/StoryMemory/StoryProjectPresentation.swift
git commit -m "test: lock story memory consumer behavior"
```

### Task 6: Update Story Memory Documentation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/story-memory-usage-2026-03-09.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/novel-memory-architecture-2026-03-09.md`

**Step 1: Write the failing doc checklist**

Create a short checklist in the commit or task notes and verify the docs cover:

- all new tool names
- the expanded `story_memory_query` kinds
- the rule that scenes require an existing chapter
- the new continuity issue lifecycle
- the authoring-tool-first scope of this release

**Step 2: Review docs to verify they are outdated**

Read the current sections around the tool list and architecture notes.

Expected: the docs still describe only the original 6 tools and an outdated query surface.

**Step 3: Write minimal implementation**

Update `story-memory-usage-2026-03-09.md`:

- replace the old 6-tool list with the full tool surface
- document the new query kinds
- add a short example authoring workflow for chapter -> scene -> foreshadow -> continuity follow-up

Update `novel-memory-architecture-2026-03-09.md`:

- replace the outdated tool inventory
- note that the authoring layer now covers canon writes beyond characters and events

**Step 4: Verify docs are consistent with implementation**

Run:

```bash
rg "story_memory_(create_project|attach_project|upsert_character|append_event|query|verify_continuity|upsert_chapter|upsert_scene|upsert_world_rule|upsert_location|upsert_foreshadow|upsert_style_profile|update_continuity_issue)" docs agentGui
```

Expected: the tool names in docs match the tool names in code.

**Step 5: Commit**

```bash
git add docs/story-memory-usage-2026-03-09.md docs/novel-memory-architecture-2026-03-09.md
git commit -m "docs: update story memory authoring tool docs"
```

## Acceptance Checklist

- Agent can write chapters, scenes, world rules, locations, foreshadows, style profile, and continuity issue statuses through explicit tools.
- `story_memory_query` supports `characters`, `events`, `foreshadows`, `chapters`, `scenes`, `world_rules`, `locations`, `style`, and `continuity_issues`.
- Repeated writes update existing objects instead of duplicating them.
- Prompt assembly reflects newly written world rules, unresolved foreshadows, previous scene context, and style profile data.
- Project presentation counts remain correct for unresolved foreshadows and open continuity issues.
- Docs match the real tool surface and query behavior.

## Recommended Execution Order

1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5
6. Task 6

Plan complete and saved to `docs/plans/2026-03-09-story-memory-authoring-tools.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration.

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints.

Which approach?
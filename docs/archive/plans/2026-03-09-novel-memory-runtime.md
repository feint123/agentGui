# Novel Memory Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a project-scoped story memory runtime for agentGui that supports structured novel-writing memory across SwiftData models, retrieval services, Claude tool APIs, and first-party UI entry points.

**Architecture:** Keep the existing `memory.md` + `ContextMemory` + `TaskMemory` stack, but add a new story-memory layer backed by SwiftData. The runtime should treat story memory as project-scoped structured state, assemble prompt slices dynamically for the current writing task, and expose explicit tools instead of routing everything through `memory_write`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing ClaudeService ToolBuilder/ToolDispatch pipeline.

---

## Implementation Notes

- Reuse the existing SwiftData container in `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift` instead of creating a second container.
- Do not overload `TaskMemory` with novel-domain entities. Keep it as session/task durable state and add a separate project memory domain.
- Keep `memory.md` for global user preferences only. Story facts belong in SwiftData models and retrieval services.
- Ship the vertical slice in this order: models -> services -> prompt assembly -> tools -> UI.
- Prefer pure Swift services with deterministic tests before wiring them into Claude calls.

## Proposed File Layout

**Create models:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WritingProject.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryCharacterProfile.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryWorldRule.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryLocationProfile.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryChapterRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StorySceneRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryTimelineEvent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryForeshadowItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryStyleProfile.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryContinuityIssue.swift`

**Create services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryContinuityService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryExtractionService.swift`

**Create views:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryCharacterInspectorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryTimelineView.swift`

**Modify existing files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`

**Create tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryContinuityServiceTests.swift`

### Task 1: Add Story Memory App Configuration

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryModelTests.swift`

**Step 1: Write the failing test**

Add a settings/bootstrap test that expects story-memory settings to exist with stable defaults.

```swift
import Testing
import SwiftData
@testable import agentGui

struct StoryMemoryModelTests {
    @Test func appSettingsExposeStoryMemoryDefaults() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppSettings.self, configurations: config)
        let context = ModelContext(container)

        let settings = AppSettings.getOrCreate(in: context)

        #expect(settings.enableStoryMemory == false)
        #expect(settings.storyMemoryAutoExtract == true)
        #expect(settings.storyMemoryPromptBudget == 6)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryModelTests
```

Expected: FAIL because the new AppSettings fields do not exist.

**Step 3: Write minimal implementation**

Add these fields to `AppSettings`:

```swift
var enableStoryMemory: Bool
var storyMemoryAutoExtract: Bool
var storyMemoryPromptBudget: Int
var storyMemoryProjectMode: String
```

Use defaults:

```swift
self.enableStoryMemory = false
self.storyMemoryAutoExtract = true
self.storyMemoryPromptBudget = 6
self.storyMemoryProjectMode = "manual"
```

Then register all new story SwiftData models in the schema array inside `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift agentGui/agentGuiApp.swift agentGuiTests/StoryMemoryModelTests.swift
git commit -m "feat: add story memory app settings"
```

### Task 2: Add Core SwiftData Story Models

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WritingProject.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryCharacterProfile.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryWorldRule.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryLocationProfile.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryStyleProfile.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryModelTests.swift`

**Step 1: Write the failing test**

Add a relationship test that creates a `WritingProject` with one character, one rule, one location, and one style profile.

```swift
@Test func writingProjectOwnsCoreStoryEntities() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: WritingProject.self,
        StoryCharacterProfile.self,
        StoryWorldRule.self,
        StoryLocationProfile.self,
        StoryStyleProfile.self,
        configurations: config
    )
    let context = ModelContext(container)

    let project = WritingProject(title: "北塔之冬")
    let character = StoryCharacterProfile(name: "林澈")
    project.characters.append(character)
    context.insert(project)
    try context.save()

    let fetched = try context.fetch(FetchDescriptor<WritingProject>())
    #expect(fetched.count == 1)
    #expect(fetched.first?.characters.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run the same `xcodebuild` test command.

Expected: FAIL because the models do not exist.

**Step 3: Write minimal implementation**

Implement the core models with these minimum fields:

```swift
@Model final class WritingProject {
    var id: UUID
    var title: String
    var synopsis: String
    var createdAt: Date
    var updatedAt: Date
    var isArchived: Bool
    @Relationship(deleteRule: .cascade) var characters: [StoryCharacterProfile]
    @Relationship(deleteRule: .cascade) var worldRules: [StoryWorldRule]
    @Relationship(deleteRule: .cascade) var locations: [StoryLocationProfile]
    var styleProfile: StoryStyleProfile?
}
```

```swift
@Model final class StoryCharacterProfile {
    var id: UUID
    var name: String
    var summary: String
    var traitsJSON: String
    var goalsJSON: String
    var speechStyle: String
    var relationshipMapJSON: String
    var arcStage: String
    var lastSeenChapter: Int
    var lastKnownLocation: String
    var project: WritingProject?
}
```

Create matching minimal models for world rules, locations, and style profile using JSON strings for array/dictionary fields initially. Do not over-engineer Codable wrappers in the first pass.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/WritingProject.swift agentGui/Models/StoryCharacterProfile.swift agentGui/Models/StoryWorldRule.swift agentGui/Models/StoryLocationProfile.swift agentGui/Models/StoryStyleProfile.swift agentGuiTests/StoryMemoryModelTests.swift
git commit -m "feat: add core story memory models"
```

### Task 3: Add Operational Story Models for Chapters, Scenes, Timeline, Foreshadow, Continuity

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryChapterRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StorySceneRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryTimelineEvent.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryForeshadowItem.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryContinuityIssue.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryModelTests.swift`

**Step 1: Write the failing test**

Add a test that verifies a project can own chapters, chapters can own scenes, scenes can point to timeline events, and a session can optionally point to an active writing project.

```swift
@Test func chapterSceneTimelineGraphPersists() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: WritingProject.self,
        StoryChapterRecord.self,
        StorySceneRecord.self,
        StoryTimelineEvent.self,
        Session.self,
        configurations: config
    )
    let context = ModelContext(container)

    let project = WritingProject(title: "北塔之冬")
    let chapter = StoryChapterRecord(number: 1, title: "雾中的灯")
    let scene = StorySceneRecord(title: "抵达王都")
    chapter.scenes.append(scene)
    project.chapters.append(chapter)
    context.insert(project)

    let session = Session(title: "写作会话")
    session.activeWritingProjectId = project.id.uuidString
    context.insert(session)
    try context.save()

    #expect(try context.fetch(FetchDescriptor<StoryChapterRecord>()).first?.scenes.count == 1)
    #expect(try context.fetch(FetchDescriptor<Session>()).first?.activeWritingProjectId == project.id.uuidString)
}
```

**Step 2: Run test to verify it fails**

Run the same `xcodebuild` command.

Expected: FAIL because the models and session linkage do not exist.

**Step 3: Write minimal implementation**

Implement these minimum fields:

```swift
@Model final class StoryChapterRecord {
    var id: UUID
    var number: Int
    var title: String
    var outline: String
    var summary: String
    var toneDirective: String
    var isLocked: Bool
    @Relationship(deleteRule: .cascade) var scenes: [StorySceneRecord]
    var project: WritingProject?
}
```

```swift
@Model final class StorySceneRecord {
    var id: UUID
    var title: String
    var content: String
    var sceneIndex: Int
    var povCharacterName: String
    var locationName: String
    var characterNamesJSON: String
    var summary: String
    var previousSceneId: String
    var chapter: StoryChapterRecord?
}
```

```swift
@Model final class StoryTimelineEvent {
    var id: UUID
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var summary: String
    var participantNamesJSON: String
    var locationName: String
    var timeMarker: String
    var eventType: String
    var foreshadowTagsJSON: String
    var isResolved: Bool
    var supersededByEventId: String
    var project: WritingProject?
}
```

Add to `Session`:

```swift
var activeWritingProjectId: String = ""
```

Keep project linkage string-based for the first iteration. Avoid optional cross-store complexity until retrieval is stable.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/StoryChapterRecord.swift agentGui/Models/StorySceneRecord.swift agentGui/Models/StoryTimelineEvent.swift agentGui/Models/StoryForeshadowItem.swift agentGui/Models/StoryContinuityIssue.swift agentGui/Models/Session.swift agentGuiTests/StoryMemoryModelTests.swift
git commit -m "feat: add operational story memory models"
```

### Task 4: Build Story Memory Service and Retrieval Layer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`

**Step 1: Write the failing test**

Add a retrieval test that creates a project with two characters, three timeline events, and one unresolved foreshadow item, then queries:

- active character cards for a scene
- unresolved foreshadow items for a chapter
- recent timeline events by character name

```swift
@Test func retrievalServiceBuildsStorySlices() async throws {
    let service = StoryMemoryRetrievalService(modelContext: context)

    let cards = try service.activeCharacterCards(projectId: project.id, names: ["林澈", "顾沉"])
    let foreshadows = try service.unresolvedForeshadows(projectId: project.id, upToChapter: 3)
    let events = try service.recentEvents(projectId: project.id, involving: ["林澈"], limit: 5)

    #expect(cards.count == 2)
    #expect(foreshadows.count == 1)
    #expect(events.count == 3)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests
```

Expected: FAIL because the services do not exist.

**Step 3: Write minimal implementation**

Implement `StoryMemoryService` as the write-side facade with methods such as:

```swift
func createProject(title: String, synopsis: String) throws -> WritingProject
func upsertCharacter(projectId: UUID, payload: StoryCharacterDraft) throws -> StoryCharacterProfile
func appendTimelineEvent(projectId: UUID, payload: StoryTimelineEventDraft) throws -> StoryTimelineEvent
func resolveForeshadow(projectId: UUID, foreshadowId: UUID, chapter: Int) throws
func attachProject(to session: Session, projectId: UUID) throws
```

Implement `StoryMemoryRetrievalService` as the read-side query layer with methods such as:

```swift
func activeCharacterCards(projectId: UUID, names: [String]) throws -> [StoryCharacterCard]
func recentEvents(projectId: UUID, involving names: [String], limit: Int) throws -> [StoryTimelineEvent]
func unresolvedForeshadows(projectId: UUID, upToChapter: Int) throws -> [StoryForeshadowItem]
func worldRules(projectId: UUID, tags: [String]) throws -> [StoryWorldRule]
func sceneBridge(projectId: UUID, chapterNumber: Int, previousSceneId: UUID?) throws -> StorySceneBridge?
```

Use simple `FetchDescriptor` queries and JSON decoding helpers. Do not add embeddings in this phase.

**Step 4: Run test to verify it passes**

Run the targeted `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryService.swift agentGui/Services/StoryMemoryRetrievalService.swift agentGuiTests/StoryMemoryRetrievalServiceTests.swift
git commit -m "feat: add story memory retrieval services"
```

### Task 5: Build Prompt Assembler and Continuity Checker

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryContinuityService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryExtractionService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryContinuityServiceTests.swift`

**Step 1: Write the failing tests**

Add one test for prompt slice assembly and one for continuity checks.

```swift
@Test func promptAssemblerBuildsCompactWritingContext() async throws {
    let assembler = StoryMemoryPromptAssembler(retrievalService: retrieval)
    let slice = try assembler.buildWritingSlice(
        projectId: project.id,
        chapterNumber: 3,
        currentSceneGoal: "写出林澈第一次怀疑顾沉的瞬间",
        activeCharacters: ["林澈", "顾沉"]
    )

    #expect(slice.contains("当前写作目标"))
    #expect(slice.contains("活跃角色"))
    #expect(slice.contains("未解决伏笔"))
}
```

```swift
@Test func continuityServiceFlagsLocationTeleportation() async throws {
    let service = StoryContinuityService()
    let warnings = service.evaluateSceneDraft(
        draft: currentDraft,
        previousScene: previousScene,
        activeCharacterCards: cards,
        worldRules: rules
    )

    #expect(warnings.contains { $0.kind == .locationConflict })
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests -only-testing:agentGuiTests/StoryContinuityServiceTests
```

Expected: FAIL because the services do not exist.

**Step 3: Write minimal implementation**

Implement `StoryMemoryPromptAssembler` to produce a deterministic string with this section order:

```swift
enum StoryPromptSection: String {
    case goal = "当前写作目标"
    case previousScene = "上一场景衔接"
    case activeCharacters = "活跃角色"
    case worldRules = "适用规则"
    case recentEvents = "相关事件"
    case unresolvedForeshadow = "未解决伏笔"
    case styleDirective = "风格指令"
}
```

Implement `StoryContinuityService` with first-pass rule checks only:

- character last-known location conflict
- chapter order regression
- resolved foreshadow reused as unresolved
- world rule keyword contradiction check

Implement `StoryMemoryExtractionService` with pure parsing entry points, but keep the Claude-backed extraction call stubbed to Phase 2. The first pass only needs the API surface:

```swift
func makeTimelineExtractionPrompt(scene: StorySceneRecord) -> String
func makeCharacterStateExtractionPrompt(scene: StorySceneRecord) -> String
```

Finally, in `ACPClientService.buildSystemPrompt(...)`, append story-memory instructions only when `AppSettings.enableStoryMemory == true` and the current session has `activeWritingProjectId`.

In `ClaudeService+AgenticLoop.swift`, inject the prompt slice near the existing task memory bootstrapping path, not inside `ContextCompression` yet.

**Step 4: Run tests to verify they pass**

Run the targeted `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryPromptAssembler.swift agentGui/Services/StoryContinuityService.swift agentGui/Services/StoryMemoryExtractionService.swift agentGui/Services/ACPClientService.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGuiTests/StoryContinuityServiceTests.swift
git commit -m "feat: add story memory prompt assembly and continuity checks"
```

### Task 6: Add Story Tool APIs to ToolBuilder and ToolDispatch

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: Write the failing test**

Add a tool-shape test that verifies the tool list contains story memory tools when story memory is enabled.

```swift
@Test func toolBuilderIncludesStoryMemoryTools() async throws {
    let settings = AppSettings()
    settings.enableStoryMemory = true

    let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
    let names = Set(tools.compactMap(\._name))

    #expect(names.contains("story_memory_upsert_character"))
    #expect(names.contains("story_memory_append_event"))
    #expect(names.contains("story_memory_query"))
    #expect(names.contains("story_memory_verify_continuity"))
}
```

**Step 2: Run test to verify it fails**

Run the targeted `xcodebuild` command.

Expected: FAIL because the tools do not exist.

**Step 3: Write minimal implementation**

Add these tools to `ClaudeService+ToolBuilder.swift` behind `settings.enableStoryMemory`:

- `story_memory_create_project`
- `story_memory_attach_project`
- `story_memory_upsert_character`
- `story_memory_append_event`
- `story_memory_query`
- `story_memory_verify_continuity`

Use schemas like:

```swift
name: "story_memory_upsert_character",
properties: [
    "project_id": .init(type: .string, description: "UUID string"),
    "name": .init(type: .string, description: "Character name"),
    "summary": .init(type: .string, description: "Short profile summary"),
    "speech_style": .init(type: .string, description: "Voice and dialogue notes"),
    "goals": .init(type: .array, items: .init(type: .string), description: "Current goals")
]
```

In `ClaudeService+ToolDispatch.swift`, route the tools to `StoryMemoryService`, `StoryMemoryRetrievalService`, and `StoryContinuityService`.

Return structured human-readable summaries, for example:

```text
Character '林澈' updated in project 北塔之冬.
Tracked fields: summary, speech_style, goals.
Continuity warnings: none.
```

Do not write any novel-domain data to `memory.md` from these tools.

**Step 4: Run test to verify it passes**

Run the targeted `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: add story memory tool APIs"
```

### Task 7: Add UI Entry Points for Story Memory

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectListView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryProjectInspectorView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryCharacterInspectorView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`

**Step 1: Write the failing test or manual verification checklist**

There is no UI test harness for these views today, so add a manual verification block to the plan and keep the view logic thin.

Manual verification targets:

- Settings shows a `创作记忆` section with enable toggle and prompt budget controls.
- User can create a `WritingProject` from UI.
- User can attach the active session to a project.
- Project inspector shows characters, chapters, unresolved foreshadow items, and recent continuity issues.
- Timeline view renders events in chapter order.

**Step 2: Implement the settings entry**

Create a reusable `StoryMemorySettingsSection` and embed it into `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift` adjacent to the existing `memorySection`.

Use fields:

```swift
Toggle("启用创作记忆", isOn: ...)
Toggle("自动抽取剧情事件", isOn: ...)
Stepper("Prompt 记忆预算", value: ..., in: 2...12)
```

**Step 3: Implement the project browser**

Use a simple master-detail layout:

- `StoryProjectListView`: list all `WritingProject`
- `StoryProjectInspectorView`: summary, chapters, foreshadow, continuity
- `StoryCharacterInspectorView`: editable character card
- `StoryTimelineView`: timeline event list grouped by chapter

Do not build a full block-editor experience in this pass. Reuse `List`, `Form`, and `DisclosureGroup`.

**Step 4: Wire session attachment UI**

Expose a control in the story inspector or active chat context that sets `Session.activeWritingProjectId`.

The first iteration can be a button:

```swift
Button("绑定到当前会话") { ... }
```

**Step 5: Manual verification**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Then launch in Xcode and verify the checklist above.

**Step 6: Commit**

```bash
git add agentGui/Views/StoryMemory agentGui/ContentView.swift
git commit -m "feat: add story memory ui entry points"
```

### Task 8: Final Integration and Docs

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/novel-memory-architecture-2026-03-09.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/docs/story-memory-usage-2026-03-09.md`

**Step 1: Update docs**

Document:

- what story memory is
- how it differs from `memory.md`
- how to enable it
- how to create/attach a writing project
- which story tools Claude can call

**Step 2: Run the full test suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

Expected: PASS, or only pre-existing unrelated failures remain.

**Step 3: Build the app**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add README.md docs/novel-memory-architecture-2026-03-09.md docs/story-memory-usage-2026-03-09.md
git commit -m "docs: document story memory runtime"
```

## API Contract Summary

### SwiftData Domain Boundary

- `WritingProject` is the root aggregate.
- `StoryCharacterProfile`, `StoryWorldRule`, `StoryLocationProfile`, `StoryStyleProfile` are semantic memory.
- `StoryChapterRecord`, `StorySceneRecord`, `StoryTimelineEvent`, `StoryForeshadowItem` are episodic and operational memory.
- `StoryContinuityIssue` is diagnostics memory.
- `Session.activeWritingProjectId` is the runtime bridge between chat and project memory.

### Service Boundary

- `StoryMemoryService`: create/update/attach operations
- `StoryMemoryRetrievalService`: deterministic reads and filters
- `StoryMemoryPromptAssembler`: converts structured memory into prompt slices
- `StoryContinuityService`: validates scene drafts and state transitions
- `StoryMemoryExtractionService`: future Claude-powered extraction helpers

### Tool Boundary

- Story memory tools are explicit and project-scoped.
- `memory_write` remains reserved for global user preferences or cross-session notes, not story canon.
- Tool outputs should always mention the affected project title and the number of objects updated or returned.

### UI Boundary

- Settings owns global enablement.
- Story project browser owns project-level CRUD.
- Chat/session owns active project binding.
- Prompt assembly remains invisible to the user unless a diagnostics view is opened.

## Non-Goals for This Plan

- No vector embeddings in Phase 1.
- No automatic retcon resolution UI.
- No multi-user collaboration.
- No full document editor replacement for chapter drafting.
- No background extraction jobs before the write/read path is stable.

## Rollout Sequence

1. Land settings and schema.
2. Land models.
3. Land retrieval service.
4. Land prompt assembly.
5. Land tool APIs.
6. Land UI entry points.
7. Land documentation and full validation.

Plan complete and saved to `docs/plans/2026-03-09-novel-memory-runtime.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
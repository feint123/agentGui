# Human-Like Memory System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a unified human-like layered memory runtime for agentGui that can orchestrate short-term, task-level, episodic, semantic, and procedural memory across coding and creative workflows.

**Architecture:** Keep the existing `ContextMemory` + `TaskMemory` + `StoryMemory` implementations working, but introduce a thin unified runtime above them. Land the feature as adapters and orchestration first, then migrate prompt assembly, writeback, governance, and UI visibility incrementally so the current app remains functional throughout.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `ClaudeService` agent loop extensions, existing `TaskMemoryService`, existing StoryMemory services.

---

## Implementation Notes

- Start with read-path unification before write-path unification. The first milestone is “one coordinator reads existing memory systems and assembles one prompt slice”.
- Do not rewrite `TaskMemoryService` or `StoryMemoryService` in the first pass. Wrap them with adapters.
- Keep global `memory_write` working during migration. Deprecation or narrowing happens only after the new runtime proves stable.
- Reuse the existing story-memory SwiftData models. Do not create a second project-memory schema.
- Prefer pure Swift value types and protocol-based adapters for the runtime core so tests stay deterministic.
- Land Creative and Coding domain profiles first. Other domains can follow the same protocol later.
- Add observability early: every runtime read or write decision should be inspectable in logs and UI metadata before the system becomes more autonomous.

## Proposed File Layout

**Create core model types:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryLayer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryScope.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceTypes.swift`

**Create runtime services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryDomainProfileRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`

**Create adapter services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryStoreAdapter.swift`

**Modify existing services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`

**Modify UI surfaces:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`

**Create tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryDomainProfileTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryStoreAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryPromptAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-human-like-memory-system-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-human-like-memory-system-architecture.md`

### Task 1: Add Memory Core Types and Runtime Enums

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryLayer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryKind.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryScope.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoreTests.swift`

**Step 1: Write the failing test**

Add tests that pin the runtime vocabulary before any adapter or service code exists.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryRuntimeCoreTests {
    @Test func memoryLayerOrderMatchesArchitecture() async throws {
        #expect(MemoryLayer.allCases == [.instant, .working, .task, .episodic, .semantic, .proceduralArchive])
    }

    @Test func memoryScopeSupportsProjectAndSessionNamespaces() async throws {
        #expect(MemoryScope.project(id: "p1").namespace == "project:p1")
        #expect(MemoryScope.session(id: "s1").namespace == "session:s1")
    }

    @Test func memoryRecordCarriesRuntimeMetadata() async throws {
        let record = MemoryRecord(
            id: "rec_1",
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            scope: .session(id: "s1"),
            title: "Build failure",
            summary: "xcodebuild fails in agentGuiTests",
            payload: .text("Build failure"),
            source: .tool(name: "xcodebuild"),
            sourceRefs: [],
            confidence: 1.0,
            verificationStatus: .verified,
            retentionPolicy: .sessionBound,
            createdAt: Date(),
            updatedAt: Date(),
            lastAccessedAt: nil,
            supersededBy: nil,
            tags: ["build"]
        )

        #expect(record.layer == .task)
        #expect(record.kind == .working)
        #expect(record.scope.namespace == "session:s1")
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoreTests
```

Expected: FAIL because the new runtime types do not exist.

**Step 3: Write minimal implementation**

Add the new enums and structs with only the cases and fields required by the tests.

Example shape:

```swift
enum MemoryLayer: String, CaseIterable, Sendable {
    case instant
    case working
    case task
    case episodic
    case semantic
    case proceduralArchive
}
```

```swift
enum MemoryKind: String, Sendable {
    case working
    case episodic
    case semantic
    case procedural
    case archive
}
```

```swift
enum MemoryScope: Equatable, Sendable {
    case user
    case workspace(id: String)
    case project(id: String)
    case session(id: String)
    case thread(id: String)
    case workflowRun(id: String)

    var namespace: String { ... }
}
```

Keep `MemoryRecord.Payload` minimal at first: `.text(String)` and `.structured([String: String])` are enough for the first red-green cycle.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryLayer.swift agentGui/Models/MemoryKind.swift agentGui/Models/MemoryScope.swift agentGui/Models/MemoryRecord.swift agentGui/Models/MemoryRuntimeTypes.swift agentGuiTests/MemoryRuntimeCoreTests.swift
git commit -m "feat: add memory runtime core types"
```

### Task 2: Add Domain Profiles and Registry

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryDomainProfileRegistry.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryDomainProfileTests.swift`

**Step 1: Write the failing test**

Add tests that pin the first three supported profiles and their selection behavior.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryDomainProfileTests {
    @Test func registryExposesCreativeCodingAndUserPreferenceProfiles() async throws {
        let registry = MemoryDomainProfileRegistry()
        let ids = registry.allProfiles.map(\.id)

        #expect(ids.contains("creative-writing"))
        #expect(ids.contains("coding-task"))
        #expect(ids.contains("user-preferences"))
    }

    @Test func codingRequestSelectsCodingAndUserPreferenceProfiles() async throws {
        let registry = MemoryDomainProfileRegistry()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build and rerun tests",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 6000
        )

        let selected = registry.profiles(for: request).map(\.id)
        #expect(selected == ["coding-task", "user-preferences"])
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryDomainProfileTests
```

Expected: FAIL because the registry and task kinds do not exist.

**Step 3: Write minimal implementation**

Create a small registry with three profile structs conforming to a shared `MemoryDomainProfiling` protocol.

Keep the first selection heuristic simple:

- `.creativeWriting` returns `creative-writing` + `user-preferences`
- `.coding` returns `coding-task` + `user-preferences`
- `.generalAssistant` returns `user-preferences`

Do not add model-driven task classification in this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryDomainProfileRegistry.swift agentGuiTests/MemoryDomainProfileTests.swift agentGui/Models/MemoryRuntimeTypes.swift
git commit -m "feat: add memory domain profile registry"
```

### Task 3: Add Store Adapter Protocol and TaskMemory Adapter

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryStoreAdapter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemory.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`

**Step 1: Write the failing test**

Add tests that verify `TaskMemory` can be projected into runtime `MemoryRecord` items without changing its persistence logic.

```swift
import Foundation
import Testing
@testable import agentGui

struct TaskMemoryStoreAdapterTests {
    @Test func taskMemoryAdapterBuildsTaskLayerRecords() async throws {
        let memory = TaskMemory(sessionId: "session-1")
        let adapter = TaskMemoryStoreAdapter()

        let records = adapter.project(memory: memory)

        #expect(records.allSatisfy { $0.layer == .task })
        #expect(records.allSatisfy { $0.scope == .session(id: "session-1") })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests
```

Expected: FAIL because the adapter protocol and adapter implementation do not exist.

**Step 3: Write minimal implementation**

Define a `MemoryStoreAdapter` protocol for runtime queries and a simpler projection helper in `TaskMemoryStoreAdapter`.

The first pass only needs read-side projection methods such as:

```swift
struct TaskMemoryStoreAdapter {
    func load(sessionId: String) -> TaskMemory? { ... }
    func project(memory: TaskMemory) -> [MemoryRecord] { ... }
}
```

Map fields as follows:

- `confirmedFacts` -> verified task records
- `attemptedActions` -> task records tagged `attempt`
- `failedAttempts` -> episodic or task records tagged `failed-attempt`
- `pendingQuestions` -> task records tagged `pending`

Do not write back through the adapter yet.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryStoreAdapter.swift agentGui/Services/TaskMemoryStoreAdapter.swift agentGuiTests/TaskMemoryStoreAdapterTests.swift
git commit -m "feat: add task memory store adapter"
```

### Task 4: Add StoryMemory Adapter for Creative Profile Reads

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryStoreAdapter.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryStoreAdapterTests.swift`

**Step 1: Write the failing test**

Add tests that verify project-scoped story memory can be exposed as semantic and episodic runtime records.

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct StoryMemoryStoreAdapterTests {
    @Test func storyMemoryAdapterMapsCharactersAndRulesToSemanticLayer() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        _ = try service.upsertCharacter(projectId: project.id, payload: StoryCharacterDraft(name: "林澈"))

        let adapter = StoryMemoryStoreAdapter(modelContext: context)
        let records = try adapter.semanticRecords(projectId: project.id)

        #expect(records.contains { $0.layer == .semantic && $0.title == "林澈" })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryStoreAdapterTests
```

Expected: FAIL because the adapter does not exist.

**Step 3: Write minimal implementation**

Create a read-only adapter that wraps existing story retrieval logic.

The first pass should expose methods such as:

```swift
@MainActor
struct StoryMemoryStoreAdapter {
    let modelContext: ModelContext

    func semanticRecords(projectId: UUID) throws -> [MemoryRecord] { ... }
    func episodicRecords(projectId: UUID) throws -> [MemoryRecord] { ... }
}
```

Map:

- characters / rules / locations / style -> `.semantic`
- events / scenes / continuity issues -> `.episodic`

Do not change `StoryMemoryService` or `StoryMemoryPromptAssembler` in this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryStoreAdapter.swift agentGuiTests/StoryMemoryStoreAdapterTests.swift
git commit -m "feat: add story memory store adapter"
```

### Task 5: Add Retrieval Planner and Budgeted Read Plan

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`

**Step 1: Write the failing test**

Add tests that pin the read order and budget behavior for creative and coding requests.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryRetrievalPlannerTests {
    @Test func creativePlanPrefersWorkingThenSemanticThenEpisodic() async throws {
        let planner = MemoryRetrievalPlanner()
        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "继续写这一章，先确认顾沉状态和北塔规则",
            taskKind: .creativeWriting,
            projectId: "project-1",
            workspaceRoot: nil,
            contextBudget: 3000
        )

        let plan = planner.makePlan(request: request, profiles: [.creativeWriting(), .userPreferences()])
        #expect(plan.orderedLayers.prefix(3) == [.working, .semantic, .episodic])
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRetrievalPlannerTests
```

Expected: FAIL because the planner does not exist.

**Step 3: Write minimal implementation**

Implement a planner that returns a small `MemoryRetrievalPlan` value type.

The first version only needs:

- ordered layers
- per-layer item budget
- optional profile tags

Suggested first-pass priorities:

- creative: working -> semantic -> episodic -> proceduralArchive
- coding: working -> task -> semantic -> episodic -> proceduralArchive
- general: working -> semantic

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRetrievalPlanner.swift agentGuiTests/MemoryRetrievalPlannerTests.swift
git commit -m "feat: add memory retrieval planner"
```

### Task 6: Add Prompt Assembler for Unified Memory Slice

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryPromptAssemblerTests.swift`

**Step 1: Write the failing test**

Add tests that verify records are grouped into stable prompt sections instead of raw dumps.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryPromptAssemblerTests {
    @Test func assemblerGroupsFactsEventsAndRisks() async throws {
        let assembler = MemoryPromptAssembler()
        let context = MemoryRuntimeContext(
            profiles: ["coding-task"],
            records: [
                MemoryRecord.fixture(title: "Build failed", layer: .task, kind: .working),
                MemoryRecord.fixture(title: "TaskMemory fact", layer: .semantic, kind: .semantic)
            ],
            writePolicy: .readMostly,
            warnings: ["Symbol still unresolved"]
        )

        let text = assembler.render(context: context)

        #expect(text.contains("## 当前工作记忆"))
        #expect(text.contains("## 已验证事实"))
        #expect(text.contains("## 风险与待确认项"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryPromptAssemblerTests
```

Expected: FAIL because the assembler does not exist.

**Step 3: Write minimal implementation**

Implement a string renderer that groups by `MemoryLayer` and warning state.

The first version only needs these sections:

- `## 当前工作记忆`
- `## 当前任务状态`
- `## 已验证事实`
- `## 相关事件`
- `## 风险与待确认项`

Keep the rendering deterministic so future tests can safely pin exact headings.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryPromptAssembler.swift agentGuiTests/MemoryPromptAssemblerTests.swift
git commit -m "feat: add memory prompt assembler"
```

### Task 7: Add Coordinator and Wire Unified Read Path into Agent Loop

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing test**

Add tests that verify the coordinator produces a single prompt slice from both `TaskMemory` and creative project memory.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryRuntimeCoordinatorTests {
    @Test func coordinatorBuildsUnifiedSliceForCodingRequest() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            taskRecords: [MemoryRecord.fixture(title: "Known failure", layer: .task, kind: .working)],
            storyRecords: []
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        #expect(context.records.contains { $0.title == "Known failure" })
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because the coordinator does not exist.

**Step 3: Write minimal implementation**

Create the coordinator and give it dependencies on:

- profile registry
- retrieval planner
- task adapter
- story adapter
- prompt assembler

Then update `ClaudeService+AgenticLoop.swift` so the startup memory injection becomes:

- build a `MemoryRuntimeRequest`
- ask `MemoryRuntimeCoordinator` for a `MemoryRuntimeContext`
- inject one unified prompt slice instead of separate task-memory and story-memory bootstrap text blocks

Do not remove the old helper functions yet. Keep them available as fallback during migration, but stop using them in the happy path.

**Step 4: Run test to verify it passes**

Run the focused coordinator test, then run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: wire unified memory read path"
```

### Task 8: Add Governance and Writeback Decision Layer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`

**Step 1: Write the failing test**

Add tests for the first governance rules: verified coding facts may write hot-path into task memory, speculative creative facts require confirmation.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryGovernanceServiceTests {
    @Test func verifiedCodingCandidateIsAcceptedForHotPathWrite() async throws {
        let service = MemoryGovernanceService()
        let candidate = MemoryCandidate.fixture(
            layer: .task,
            kind: .working,
            domainProfile: "coding-task",
            confidence: 1.0,
            verificationStatus: .verified
        )

        #expect(service.evaluate(candidate) == .acceptHotPath)
    }

    @Test func speculativeCreativeSemanticCandidateNeedsConfirmation() async throws {
        let service = MemoryGovernanceService()
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: "creative-writing",
            confidence: 0.45,
            verificationStatus: .unverified
        )

        #expect(service.evaluate(candidate) == .needsUserConfirmation)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryGovernanceServiceTests
```

Expected: FAIL because governance and candidate types do not exist.

**Step 3: Write minimal implementation**

Implement:

- `MemoryCandidate`
- `MemoryGovernanceDecision`
- `MemoryGovernanceService.evaluate(_:)`
- a thin `MemoryConsolidationEngine` stub that can return zero or more candidates from an outcome

Do not connect model-driven memory extraction yet. Start with static decision rules so the runtime has a controlled write gate before more automation is added.

**Step 4: Run test to verify it passes**

Run the same focused command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryGovernanceService.swift agentGui/Services/MemoryConsolidationEngine.swift agentGuiTests/MemoryGovernanceServiceTests.swift agentGui/Models/MemoryGovernanceTypes.swift
git commit -m "feat: add memory governance service"
```

### Task 9: Add Runtime Metadata to Tool Calls and Settings Surface

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`

**Step 1: Write the failing test**

Add a settings/model test that pins the first runtime toggles and tool-call metadata fields.

```swift
import Testing
@testable import agentGui

struct MemoryRuntimeSettingsTests {
    @Test func appSettingsExposeUnifiedMemoryRuntimeDefaults() async throws {
        let settings = AppSettings()

        #expect(settings.enableUnifiedMemoryRuntime == false)
        #expect(settings.unifiedMemoryContextBudget == 8)
        #expect(settings.enableMemoryGovernance == true)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeSettingsTests
```

Expected: FAIL because the new settings and metadata fields do not exist.

**Step 3: Write minimal implementation**

Add settings such as:

- `enableUnifiedMemoryRuntime`
- `unifiedMemoryContextBudget`
- `enableMemoryGovernance`

Add tool-call metadata such as:

- `memoryRuntimeProfiles`
- `memoryRuntimeLayers`
- `memoryRuntimeWarnings`

Update the settings UI and chat details UI so a user can see whether the unified runtime was used and which profiles/layers it activated.

Do not build a full memory management panel in this task.

**Step 4: Run test to verify it passes**

Run the focused settings test, then compile the app target:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: PASS / BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift agentGui/Models/ToolCall.swift agentGui/ContentView.swift agentGui/Views/ChatView.swift agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift agentGuiTests/MemoryRuntimeSettingsTests.swift
git commit -m "feat: add unified memory runtime settings and metadata"
```

### Task 10: Add End-to-End Migration Checks and Documentation Updates

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-human-like-memory-system-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-human-like-memory-system-architecture.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing test**

Add an integration test that exercises the unified read path without needing the full UI.

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryRuntimeIntegrationTests {
    @Test func codingRequestProducesSingleUnifiedMemorySlice() async throws {
        let coordinator = MemoryRuntimeCoordinator.makeForTests(
            taskRecords: [MemoryRecord.fixture(title: "Known task fact", layer: .task, kind: .working)],
            storyRecords: []
        )

        let request = MemoryRuntimeRequest(
            sessionId: "s1",
            threadId: "t1",
            workflowRunId: nil,
            userRequest: "Fix the failing build",
            taskKind: .coding,
            projectId: nil,
            workspaceRoot: "/tmp/repo",
            contextBudget: 4000
        )

        let context = try await coordinator.prepareContext(for: request)
        #expect(context.renderedPrompt.contains("Known task fact"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL until the coordinator exposes its rendered output and the test helper is complete.

**Step 3: Write minimal implementation**

Finish any missing glue so the coordinator returns both records and rendered prompt text.

Then update docs to explain:

- unified runtime toggle behavior
- migration status from old memory paths
- how Creative and Coding profiles map to existing `StoryMemory` and `TaskMemory`

Keep documentation honest about what is still adapter-based and what is not yet migrated.

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeCoreTests \
  -only-testing:agentGuiTests/MemoryDomainProfileTests \
  -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests \
  -only-testing:agentGuiTests/StoryMemoryStoreAdapterTests \
  -only-testing:agentGuiTests/MemoryRetrievalPlannerTests \
  -only-testing:agentGuiTests/MemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/MemoryGovernanceServiceTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add README.md docs/spec/2026-03-10-human-like-memory-system-requirements.md docs/plans/2026-03-10-human-like-memory-system-architecture.md agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "docs: finalize unified memory runtime migration plan"
```

## Recommended Execution Order

Execute tasks strictly in order.

- Tasks 1-2 define vocabulary and profile selection.
- Tasks 3-4 wrap the two existing memory backends.
- Tasks 5-7 land the first useful runtime read path.
- Task 8 adds controlled writeback governance.
- Task 9 exposes runtime behavior to the user.
- Task 10 closes the loop with integration verification and documentation.

## Stopping Points

If schedule is tight, the safest shippable checkpoints are:

- After Task 4: adapters exist, architecture can be validated in tests.
- After Task 7: unified read path works for production use.
- After Task 9: runtime is user-visible and configurable.

## Risks To Watch During Execution

- `ClaudeService+AgenticLoop.swift` already contains separate task-memory and story-memory injection paths. Do not remove both at once; migrate behind a setting flag first.
- `StoryMemoryPromptAssembler` already solves part of creative prompt assembly. Reuse or wrap it where possible; do not fork creative logic unnecessarily.
- `ContextMemory` compression currently also writes to `TaskMemory`. Be careful not to duplicate writes when the coordinator starts owning outcome recording.
- `memory_write` remains globally available. Until migration is complete, document clear precedence between legacy memory writes and unified runtime decisions.

Plan complete and saved to `docs/plans/2026-03-10-human-like-memory-system-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
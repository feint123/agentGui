# Creative Memory Subagent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split story-memory responsibilities out of the main writing agent into a dedicated memory subagent with explicit delegation, structured outputs, visible audit state, and safe fallback behavior.

**Architecture:** Reuse the existing story-memory domain services and current subagent/runtime infrastructure rather than inventing a parallel stack. Introduce a memory-specific delegation contract at the boundary between the main agent and story-memory services, then route retrieval, write decisions, continuity review, and project-binding checks through a dedicated role whose executions are persisted and rendered as visible delegated-task steps.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, SwiftAnthropic, existing `WorkflowRoleDefinition`, `ClaudeService` agent loop, story-memory services, and existing subagent / workflow timeline UI.

---

## Implementation Notes

- This plan is based on `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-creative-memory-subagent-requirements.md`.
- Keep the current `WritingProject`, `StoryMemoryService`, `StoryMemoryRetrievalService`, `StoryMemoryPromptAssembler`, and `StoryContinuityService` as the domain backbone.
- Do not keep the current dual mode where full story-memory tools are permanently exposed to both the main agent and the new memory subagent, except behind an explicit migration flag.
- Prefer a single delegation entry from the main agent perspective: the main agent decides whether it needs memory help, then delegates to one memory-specific subagent task.
- The memory subagent must return structured results that distinguish canon facts, inferences, and unresolved risks.
- Follow TDD where the contract is stable: tool exposure, delegation routing, structured outputs, runtime state, and presentation logic should all be pinned by tests before refactors.
- UI work should build on existing `SubagentTaskCardView`, `WorkflowTimelineView`, and `AgentMessageFlowPresentation` rather than introducing a second visualization system.
- Fallback behavior must be explicit in state, logs, and UI. Silent success is not acceptable.

## Proposed File Layout

**Modify agent prompt and tool exposure:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Add memory delegation contract and orchestration:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryMemoryDelegation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryDelegationService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemorySubagentPromptBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`

**Keep domain services reusable but memory-subagent oriented:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryContinuityService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+StoryMemoryTools.swift`

**Add runtime observability state:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryMemoryTaskRecord.swift`
- Possibly modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Wire UI presentation:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTaskCardView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`

**Tests:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryContinuityServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryDelegationServiceTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemorySubagentContractTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryObservabilityPresentationTests.swift`

## Task 1: Pin the Main-Agent Shrink Contract

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-creative-memory-subagent-requirements.md`

**Step 1: Write the failing tests**

Add tests that pin the new exposure rules:

- `toolBuilderOmitsRawStoryMemoryToolsFromMainAgentByDefault()`
- `toolBuilderKeepsRunSubagentAvailableForMemoryDelegation()`
- `systemPromptUsesDelegationProtocolInsteadOfPermanentStoryMemoryRules()`

Example assertion shape:

```swift
@Test func toolBuilderOmitsRawStoryMemoryToolsFromMainAgentByDefault() async throws {
    let settings = AppSettings()
    settings.enableStoryMemory = true

    let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
    let names = toolNames(from: tools)

    #expect(names.contains("run_subagent"))
    #expect(!names.contains("story_memory_query"))
    #expect(!names.contains("story_memory_upsert_character"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: FAIL because the main agent still exposes raw story-memory tools and still carries story-memory rules in its long-lived system prompt.

**Step 3: Write minimal implementation**

Refactor the main-agent tool builder and system prompt so that:

- raw `story_memory_*` tools are no longer exposed to the main agent by default
- story-memory access is described as a delegated capability
- `run_subagent` remains available so the main agent can invoke the dedicated memory role
- an explicit temporary migration flag can keep the old path available during rollout if needed

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ACPClientService.swift
git commit -m "refactor: remove raw story memory tools from main agent"
```

## Task 2: Introduce the Memory Delegation Contract

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryMemoryDelegation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryDelegationService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemorySubagentPromptBuilder.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemorySubagentContractTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryDelegationServiceTests.swift`

**Step 1: Write the failing tests**

Add tests for the new protocol and routing decisions:

- `delegationClassifierMarksWritingTasksThatNeedMemoryHelp()`
- `delegationRequestIncludesBoundProjectIdentityAndTaskType()`
- `delegationResponseSeparatesFactsInferenceAndRisks()`
- `delegationServiceReturnsBindingErrorWhenSessionProjectIsMissing()`

Example response shape:

```swift
struct StoryMemoryDelegationResponse: Codable, Equatable {
    var status: StoryMemoryDelegationStatus
    var taskType: StoryMemoryTaskType
    var facts: [StoryMemoryFactSlice]
    var inferences: [String]
    var risks: [StoryMemoryRiskItem]
    var writeDecision: StoryMemoryWriteDecision?
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemorySubagentContractTests -only-testing:agentGuiTests/StoryMemoryDelegationServiceTests
```

Expected: FAIL because the delegation models and classifier do not exist.

**Step 3: Write minimal implementation**

Introduce a boundary package that defines:

- task types such as `retrieveContext`, `evaluateWriteback`, `verifyContinuity`, `resolveProjectBinding`
- routing status such as `ready`, `projectNotBound`, `ambiguousProject`, `fallbackOnly`, `failed`
- response sections for facts, inferences, risks, write decision, continuity issues, and fallback notes
- a delegation service that builds a self-contained subagent task payload from the current session, request, and optional draft output

Keep the models UI-friendly and storage-agnostic. Do not leak raw SwiftData entities across this boundary.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/StoryMemoryDelegation.swift agentGui/Services/StoryMemoryDelegationService.swift agentGui/Services/StoryMemorySubagentPromptBuilder.swift agentGuiTests/StoryMemorySubagentContractTests.swift agentGuiTests/StoryMemoryDelegationServiceTests.swift
git commit -m "feat: add creative memory delegation contract"
```

## Task 3: Add a Dedicated Memory Role and Restrict Its Tool Domain

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+StoryMemoryTools.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: Write the failing tests**

Add tests that pin the new role behavior:

- `workflowRoleRegistryIncludesCreativeMemoryManager()`
- `memoryRoleBuildsSubagentToolsWithStoryMemoryCapabilities()`
- `memoryRoleDoesNotExposeGeneralWriteCodeToolsByDefault()`

Example assertion shape:

```swift
@Test func workflowRoleRegistryIncludesCreativeMemoryManager() async throws {
    let role = try #require(WorkflowRoleDefinition.find(named: "creative_memory_manager"))
    #expect(role.enableTextEditor == false)
    #expect(role.enableBash == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: FAIL because no dedicated memory role exists and subagent tool construction has no story-memory-specific restriction path.

**Step 3: Write minimal implementation**

Add a dedicated `creative_memory_manager` role with:

- a memory-only system prompt
- structured output requirements tied to `StoryMemoryDelegationResponse`
- story-memory tool access plus only the minimal read helpers it needs
- no bash, no general editor mutation path, and no recursive subagent access

Refactor subagent tool building so that the memory role gets its story-memory domain tools while regular roles do not inherit them accidentally.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/WorkflowRoleDefinition.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+StoryMemoryTools.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: add dedicated creative memory subagent role"
```

## Task 4: Replace Permanent Writing-Slice Injection With On-Demand Delegation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryPromptAssembler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryDelegationServiceTests.swift`

**Step 1: Write the failing tests**

Add tests that pin the new bootstrap rule:

- `agentLoopDoesNotInjectStoryMemoryBootstrapForNonMemoryTasks()`
- `agentLoopBuildsDelegationRequestForContinuitySensitiveWritingTask()`
- `promptAssemblerCanFormatMinimalTaskScopedSliceFromDelegationResponse()`

Example assertion shape:

```swift
@Test func agentLoopDoesNotInjectStoryMemoryBootstrapForNonMemoryTasks() async throws {
    let bootstrap = try service.buildStoryMemoryBootstrap(
        settings: settings,
        sessionId: session.sessionId,
        messages: [plainChatRequest],
        modelContext: context
    )

    #expect(bootstrap == nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests -only-testing:agentGuiTests/StoryMemoryDelegationServiceTests
```

Expected: FAIL because the main loop still auto-injects a story-memory writing slice whenever story memory is enabled and a project is bound.

**Step 3: Write minimal implementation**

Refactor the bootstrap path so that:

- story-memory context is no longer pre-injected into every writing loop
- the main agent gets only a concise delegation protocol in its system prompt
- when a task needs story memory, the main agent delegates and receives a task-scoped minimal slice derived from the subagent response
- the existing assembler becomes a formatter for the delegated minimal slice rather than a permanent main-loop bootstrap dependency

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/StoryMemoryPromptAssembler.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGuiTests/StoryMemoryDelegationServiceTests.swift
git commit -m "refactor: move story memory context to on-demand delegation"
```

## Task 5: Move Write Decisions and Continuity Review Behind the Memory Subagent

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryMemoryRetrievalService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/StoryContinuityService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+StoryMemoryTools.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryRetrievalServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryContinuityServiceTests.swift`

**Step 1: Write the failing tests**

Add tests that pin governance behavior:

- `memorySubagentCanReturnIdempotentWriteDecisionForStructuredFacts()`
- `memorySubagentFlagsCandidateWritebackThatNeedsUserConfirmation()`
- `continuityReviewReturnsStructuredIssueStates()`
- `retrievalServiceSupportsTaskScopedMinimalSlicesInsteadOfWholeProjectDump()`

Example assertion shape:

```swift
@Test func continuityReviewReturnsStructuredIssueStates() async throws {
    let issues = service.evaluateCandidateCanonUpdate(...)

    #expect(issues.map(\.status) == [.open])
    #expect(issues.first?.detail.contains("时间回退") == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests -only-testing:agentGuiTests/StoryContinuityServiceTests
```

Expected: FAIL because retrieval and continuity services are still shaped around direct tool use and do not yet expose explicit governance or minimal-slice semantics.

**Step 3: Write minimal implementation**

Adapt the existing services so the memory role can:

- request only the facts relevant to the current task type
- generate structured write recommendations instead of immediately mutating canon in ambiguous cases
- classify updates into direct-write, confirm-first, and do-not-persist buckets
- create or update continuity issues with explicit lifecycle states such as `open`, `accepted`, and `resolved`

Keep raw persistence operations in `StoryMemoryService`, but move decision policy into the delegation layer and memory-role prompt contract.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/StoryMemoryService.swift agentGui/Services/StoryMemoryRetrievalService.swift agentGui/Services/StoryContinuityService.swift agentGui/Services/ClaudeService+StoryMemoryTools.swift agentGuiTests/StoryMemoryRetrievalServiceTests.swift agentGuiTests/StoryContinuityServiceTests.swift
git commit -m "feat: route canon updates and continuity review through memory governance"
```

## Task 6: Persist Runtime State for Audit, Failure, and Fallback

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/StoryMemoryTaskRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Possibly modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryObservabilityPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests that pin the new runtime record:

- `memoryDelegationRecordCapturesTaskTypeAndProjectBinding()`
- `memoryDelegationRecordCapturesWriteOutcomeAndFallbackReason()`
- `memoryDelegationRecordDistinguishesNoTriggerFromRejectedWrite()`

Example field shape:

```swift
@Model
final class StoryMemoryTaskRecord {
    var sessionId: String
    var projectId: String
    var taskType: String
    var triggerReason: String
    var resultStatus: String
    var didWrite: Bool
    var foundContinuityRisk: Bool
    var fallbackReason: String
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryObservabilityPresentationTests
```

Expected: FAIL because no dedicated runtime record exists for memory delegation outcomes.

**Step 3: Write minimal implementation**

Persist enough state to answer:

- whether memory delegation was triggered this turn
- why it was triggered
- which project was targeted
- which slices were returned
- whether writeback happened
- whether continuity issues were found
- whether fallback occurred and why

Attach the record to either the relevant `ToolCall` or message/session graph in a way that can be rendered without reparsing model text blobs.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/StoryMemoryTaskRecord.swift agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/agentGuiApp.swift agentGuiTests/StoryMemoryObservabilityPresentationTests.swift
git commit -m "feat: persist creative memory delegation audit state"
```

## Task 7: Surface the Memory Subagent as a Visible Delegated Task in UI

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTaskCardView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkflowTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryObservabilityPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests that pin visible audit behavior:

- `flowSnapshotShowsCreativeMemoryDelegationAsDedicatedStep()`
- `subagentRowShowsTriggerReasonAndWriteOutcomeSummary()`
- `memoryDelegationFailureRowShowsExplicitFailureReason()`
- `memoryDelegationWithoutWriteShowsNotTriggeredOrRejectedLabel()`

Example assertion shape:

```swift
@Test func memoryDelegationFailureRowShowsExplicitFailureReason() async throws {
    let row = ToolCallRowPresentation.make(for: tool)

    #expect(row.primaryText == "创作记忆管理员")
    #expect(row.secondaryText?.contains("未绑定项目") == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests -only-testing:agentGuiTests/StoryMemoryObservabilityPresentationTests
```

Expected: FAIL because existing subagent presentation only shows generic agent/task/result information.

**Step 3: Write minimal implementation**

Extend the current delegated-task card so the memory subagent can display:

- trigger reason such as query, write review, continuity check, or binding resolution
- returned result summary
- whether writeback occurred
- whether continuity risk was found
- explicit fallback or failure reason

Reuse the current subagent card and workflow timeline style. Do not create a separate standalone memory panel for this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/Views/SubagentTaskCardView.swift agentGui/Views/WorkflowTimelineView.swift agentGuiTests/AgentMessageFlowPresentationTests.swift agentGuiTests/StoryMemoryObservabilityPresentationTests.swift
git commit -m "feat: expose creative memory delegation state in chat timeline"
```

## Task 8: Add Fallback Controls, Settings, and Regression Verification

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryDelegationServiceTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-creative-memory-subagent-requirements.md`

**Step 1: Write the failing tests**

Add tests that pin fallback visibility:

- `fallbackSkipsWritebackWhenMemorySubagentCallFails()`
- `fallbackResponseMarksOutputAsNotPersisted()`
- `manualMemoryRecoveryPathRemainsAvailableFromSettings()`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryDelegationServiceTests -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: FAIL because fallback is not yet modeled as an explicit, user-visible path.

**Step 3: Write minimal implementation**

Add an explicit fallback policy that:

- lets the writing turn continue without updating project memory
- records and surfaces that no memory writeback occurred
- preserves a manual recovery action or setting entry point for retrying memory processing later

If a migration flag is needed, keep it temporary and document its removal conditions.

**Step 4: Run targeted regression suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/StoryMemoryDelegationServiceTests \
  -only-testing:agentGuiTests/StoryMemorySubagentContractTests \
  -only-testing:agentGuiTests/StoryMemoryRetrievalServiceTests \
  -only-testing:agentGuiTests/StoryContinuityServiceTests \
  -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: PASS.

**Step 5: Run app build and smoke review**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Manual smoke review checklist:

- ordinary chat or polish turns do not trigger the memory subagent
- project-bound writing tasks that mention character state, world rules, timeline, or continuity do trigger the memory subagent
- the chat timeline shows a delegated memory task card with trigger reason and outcome
- writeback failures and fallback states are visible and not mislabeled as success
- switching projects changes the target project used by the memory subagent

**Step 6: Commit**

```bash
git add agentGui/Views/StoryMemory/StoryMemorySettingsSection.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/StoryMemoryDelegationServiceTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: add creative memory fallback and settings recovery path"
```

## Rollout Notes

- Ship behind a temporary migration toggle if the main-agent story-memory tool removal could block existing authoring flows.
- During rollout, log both trigger frequency and fallback frequency for the memory subagent so the team can see whether the main agent is over-delegating or the memory role is underperforming.
- Remove the migration flag once the dedicated memory role passes the regression suite and interactive smoke checks.

## Acceptance Mapping

- **P0:** Task 1, Task 2, Task 3, Task 4, Task 6, Task 8 cover dedicated memory subagent, main-agent tool shrink, on-demand delegation, visible failure, and fallback.
- **P1:** Task 2, Task 4, Task 5, Task 7 cover minimal structured slice return, write governance, continuity review isolation, and UI result detail.
- **P2:** Task 6 and Task 7 lay the persistence and presentation groundwork for richer replay and workflow-runtime integration later.

Plan complete and saved to `docs/plans/2026-03-10-creative-memory-subagent.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
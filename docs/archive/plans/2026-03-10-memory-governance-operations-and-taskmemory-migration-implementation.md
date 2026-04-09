# Memory Governance Operations And TaskMemory Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add actionable approve/reject governance flows, persistent periodic background scheduling for consolidation and TTL sweep, and migrate `TaskMemory` from legacy JSON into a new unified schema before removing the old code paths.

**Architecture:** Build this in three layers. First, turn pending confirmations into a mutable audited workflow without changing the existing governed-write contract. Second, add a persistent background job system that owns consolidation and TTL work rather than relying on in-process fire-and-forget tasks. Third, introduce a new `TaskMemory` schema and migration path, run the app in a measured transition state, then remove legacy `TaskMemoryService` and adapter code after parity is proven.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation file persistence, Swift Testing, existing unified memory runtime services, existing TaskMemory JSON persistence.

---

## Implementation Notes

- Start with state models and tests before wiring UI actions.
- Keep the currently passing memory suite green; expand it rather than replacing it.
- Do not remove `TaskMemoryService` or `TaskMemoryStoreAdapter` until the migration tasks in this plan are complete.
- Prefer a persistent queue model for background work. In-process actors alone are not enough because the app must survive restarts.
- Treat migration as a product feature, not a one-off script. It needs status, audit output, failure recovery, and cutover conditions.
- Every task here should land with focused tests first, then minimal code, then a narrow verification command.

## Proposed File Layout

**Create governance action models and services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConfirmationStatus.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceAuditEntry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConfirmationWorkflowService.swift`

**Create scheduler and job models:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBackgroundJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemorySweepReport.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundJobStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`

**Create new TaskMemory schema and migration services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryRecordV2.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryStateV2.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryMigrationReport.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryV2Store.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryMigrationService.swift`

**Modify existing runtime and UI files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConfirmationCandidate.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryConfirmationList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Create or extend tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetentionServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryMigrationServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryV2StoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryMigrationIntegrationTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-data-reliability-and-recovery-requirements.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-human-like-memory-system-architecture.md`

### Task 1: Expand Pending Confirmation State Model

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConfirmationCandidate.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryConfirmationStatus.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceAuditEntry.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift`

**Step 1: Write the failing test**

Add tests that pin the required lifecycle fields before touching UI or persistence.

```swift
@MainActor
struct MemoryConfirmationWorkflowServiceTests {
    @Test func confirmationCandidateSupportsPendingApprovedAndRejectedStates() async throws {
        let candidate = MemoryConfirmationCandidate(
            candidateID: "cand-1",
            domainProfile: "creative-writing",
            scope: .project(id: "p1"),
            title: "Possible canon",
            summary: "Speculative summary",
            proposedRecord: UnifiedMemoryStoredRecord(record: MemoryRecord.fixture(id: "r1")),
            reason: "Needs confirmation"
        )

        #expect(candidate.status == .pending)
        #expect(candidate.finalRecordID == nil)
        #expect(candidate.rejectionReason == nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryConfirmationWorkflowServiceTests
```

Expected: FAIL because the new status and audit fields do not exist.

**Step 3: Write minimal implementation**

Add:

- `MemoryConfirmationStatus` enum with `pending`, `approved`, `rejected`, `failedToApply`
- `MemoryGovernanceAuditEntry` with timestamp, action, candidate ID, optional final record ID, optional rejection reason
- new fields on `MemoryConfirmationCandidate`: `status`, `resolvedAt`, `finalRecordID`, `rejectionReason`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryConfirmationCandidate.swift agentGui/Models/MemoryConfirmationStatus.swift agentGui/Models/MemoryGovernanceAuditEntry.swift agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift
git commit -m "feat: add confirmation workflow state model"
```

### Task 2: Make Confirmation Store Mutable And Audited

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConfirmationWorkflowService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift`

**Step 1: Write the failing test**

Add tests for approve and reject transitions.

```swift
    @Test func approvingConfirmationPersistsRecordAndMarksCandidateApproved() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let service = MemoryConfirmationWorkflowService(baseDirectory: baseDirectory)
        let candidate = try service.seedPendingCandidate()

        let result = try await service.approve(candidateID: candidate.id)

        #expect(result.status == .approved)
        #expect(result.finalRecordID != nil)
    }

    @Test func rejectingConfirmationDoesNotPersistLiveRecord() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let service = MemoryConfirmationWorkflowService(baseDirectory: baseDirectory)
        let candidate = try service.seedPendingCandidate()

        let result = try service.reject(candidateID: candidate.id, reason: "User rejected")

        #expect(result.status == .rejected)
        #expect(result.rejectionReason == "User rejected")
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryConfirmationWorkflowServiceTests
```

Expected: FAIL because approve/reject operations do not exist.

**Step 3: Write minimal implementation**

Implement `MemoryConfirmationWorkflowService` with:

- `loadPending()`
- `approve(candidateID:)`
- `reject(candidateID:reason:)`
- `loadAuditTrail()`

On approve, use `UnifiedMemoryFileStoreAdapter` plus `MemoryGovernanceService.detectConflicts` to persist the proposed record through the unified write path. On reject, update candidate state and append an audit entry without writing a live record.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryConfirmationWorkflowService.swift agentGui/Services/MemoryGovernanceService.swift agentGuiTests/MemoryConfirmationWorkflowServiceTests.swift
git commit -m "feat: add confirmation approve and reject workflow"
```

### Task 3: Wire Approval Actions Into The Management Panel

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryConfirmationList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`

**Step 1: Write the failing test**

Extend the view model test to require action methods.

```swift
    @Test func viewModelApproveAndRejectRefreshCounts() async throws {
        let harness = try MemoryManagementHarness()
        let viewModel = harness.makeViewModel()
        try viewModel.reload()

        let pendingID = try #require(viewModel.pendingConfirmations.first?.id)
        try await viewModel.approve(candidateID: pendingID)
        #expect(viewModel.pendingConfirmationCount == 0)
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryManagementViewModelTests
```

Expected: FAIL because the view model has no action methods.

**Step 3: Write minimal implementation**

Add to `MemoryManagementViewModel`:

- injected `MemoryConfirmationWorkflowService`
- `approve(candidateID:) async throws`
- `reject(candidateID:reason:) throws`
- reload of pending counts, archived counts, and audit summaries after each action

Update the SwiftUI list to surface buttons and confirmation dialogs.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/Views/Memory/MemoryConfirmationList.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/MemoryManagementViewModelTests.swift
git commit -m "feat: add confirmation actions to memory management panel"
```

### Task 4: Introduce Persistent Background Job Model

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBackgroundJob.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemorySweepReport.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundJobStore.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing test**

Pin a persistent job queue model before writing the scheduler.

```swift
@MainActor
struct MemoryBackgroundSchedulerTests {
    @Test func backgroundJobStorePersistsQueuedJobsAcrossReload() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        try store.enqueue(.consolidation(sessionID: "s1", recordIDs: ["r1"]))

        let reloaded = MemoryBackgroundJobStore(baseDirectory: baseDirectory)
        #expect(try reloaded.allJobs().count == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because no persistent background job model exists.

**Step 3: Write minimal implementation**

Implement:

- `MemoryBackgroundJob` with state enum `queued/running/completed/failed/cancelled`
- `MemoryBackgroundJobStore` backed by one JSON file in the unified memory directory
- queue operations: `enqueue`, `load`, `markRunning`, `markCompleted`, `markFailed`

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryBackgroundJob.swift agentGui/Models/MemorySweepReport.swift agentGui/Services/MemoryBackgroundJobStore.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: add persistent memory background job store"
```

### Task 5: Implement Periodic Background Scheduler

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing test**

Add a scheduler test that executes queued consolidation jobs.

```swift
    @Test func schedulerConsumesQueuedConsolidationJobs() async throws {
        let harness = try MemorySchedulerHarness()
        try harness.jobStore.enqueue(.consolidation(sessionID: "s1", recordIDs: ["r1"]))

        await harness.scheduler.runOnce()

        let jobs = try harness.jobStore.allJobs()
        #expect(jobs.allSatisfy { $0.status == .completed })
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because no scheduler exists.

**Step 3: Write minimal implementation**

Implement `MemoryBackgroundScheduler` as an actor or `@MainActor` service with:

- `runOnce()` for deterministic tests
- `start()` and `stop()` for app lifecycle
- polling interval from `AppSettings`
- processing logic for consolidation jobs and background write jobs
- failure recording via `MemoryBackgroundJobStore`

Wire the scheduler startup from `agentGuiApp.swift` only when memory runtime and background scheduling are enabled.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/agentGuiApp.swift agentGui/Models/AppSettings.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: add periodic memory background scheduler"
```

### Task 6: Schedule Periodic TTL Sweep And Revalidation Queue

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetentionServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing tests**

Add one retention test for sweep reporting and one scheduler test for periodic TTL work.

```swift
    @Test func retentionServiceProducesSweepReport() async throws {
        let report = try harness.retentionService.sweep(store: harness.store, asOf: harness.now, ttl: 0)
        #expect(report.archivedCount == 1)
        #expect(report.revalidationCount >= 0)
    }
```

```swift
    @Test func schedulerRunsTTLJobsAndStoresLatestSweepReport() async throws {
        try harness.jobStore.enqueue(.ttlSweep)
        await harness.scheduler.runOnce()
        #expect(try harness.jobStore.latestSweepReport() != nil)
    }
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRetentionServiceTests -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because there is no sweep report and no scheduled TTL job execution.

**Step 3: Write minimal implementation**

Refactor `MemoryRetentionService` so it returns a `MemorySweepReport` that includes archived count, revalidation count, skipped count, and timestamp. Add TTL job handling to the scheduler and surface the latest report in the management view model.

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRetentionService.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGuiTests/MemoryRetentionServiceTests.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: add periodic ttl sweep reporting"
```

### Task 7: Define TaskMemory V2 Schema

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryRecordV2.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryStateV2.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryV2StoreTests.swift`

**Step 1: Write the failing test**

Add tests that pin the new schema shape without involving migration yet.

```swift
@MainActor
struct TaskMemoryV2StoreTests {
    @Test func taskMemoryV2SupportsStructuredFactsAttemptsAndFailures() async throws {
        let state = TaskMemoryStateV2(sessionID: "s1")
        #expect(state.sessionID == "s1")
        #expect(state.records.isEmpty)
        #expect(state.migrationState == .fresh)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryV2StoreTests
```

Expected: FAIL because the V2 schema does not exist.

**Step 3: Write minimal implementation**

Implement V2 types with:

- session/thread/workflow scope metadata
- `records: [TaskMemoryRecordV2]`
- `stateIndex` or equivalent for confirmed facts, failed attempts, open questions, attempted actions
- `migrationState`
- version field

Keep the first iteration Codable and file-backed unless there is a strong reason to switch to SwiftData immediately.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TaskMemoryRecordV2.swift agentGui/Models/TaskMemoryStateV2.swift agentGuiTests/TaskMemoryV2StoreTests.swift
git commit -m "feat: define task memory v2 schema"
```

### Task 8: Add TaskMemory V2 Store And Migration Report

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemoryMigrationReport.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryV2Store.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryMigrationService.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryMigrationServiceTests.swift`

**Step 1: Write the failing test**

Add a migration test for one legacy `TaskMemory` file.

```swift
@MainActor
struct TaskMemoryMigrationServiceTests {
    @Test func migrationServiceConvertsLegacyTaskMemoryIntoV2State() async throws {
        let harness = try TaskMemoryMigrationHarness()
        let report = try harness.service.migrate(sessionID: "s1")

        #expect(report.successCount == 1)
        #expect(report.failureCount == 0)
        #expect(report.migratedSessionIDs == ["s1"])
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryMigrationServiceTests
```

Expected: FAIL because the migration service does not exist.

**Step 3: Write minimal implementation**

Implement:

- `TaskMemoryV2Store` for load/save/list/status
- `TaskMemoryMigrationService` for legacy import
- `TaskMemoryMigrationReport` with totals, per-session status, differences, failures

Use `TaskMemoryService.load(sessionId:)` as the read source only for migration input, not as the new runtime store.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TaskMemoryMigrationReport.swift agentGui/Services/TaskMemoryV2Store.swift agentGui/Services/TaskMemoryMigrationService.swift agentGuiTests/TaskMemoryMigrationServiceTests.swift
git commit -m "feat: add task memory v2 migration service"
```

### Task 9: Add Dual-Read And Runtime Parity Checks

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryMigrationIntegrationTests.swift`

**Step 1: Write the failing tests**

Require the runtime to prefer V2 data when available and fall back to legacy only for unmigrated sessions.

```swift
    @Test func taskMemoryAdapterPrefersV2StateWhenPresent() async throws {
        let harness = try TaskMemoryParityHarness()
        let records = try harness.adapter.records(for: .session(id: "s1"))
        #expect(records.contains { $0.title == "V2 fact" })
    }
```

```swift
    @Test func runtimeCoordinatorReadsMigratedTaskMemoryWithoutLegacyProjection() async throws {
        let harness = try MemoryMigrationIntegrationHarness()
        let context = try await harness.coordinator.prepareContext(for: harness.request)
        #expect(context.records.contains { $0.title == "Migrated fact" })
    }
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: FAIL because the adapter only knows about legacy projection.

**Step 3: Write minimal implementation**

Refactor `TaskMemoryStoreAdapter` into a transition adapter:

- read V2 first
- if V2 missing, read legacy and project
- attach migration state metadata where helpful for diagnostics

Keep the legacy path only as a transition read branch.

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/TaskMemoryStoreAdapter.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGuiTests/TaskMemoryStoreAdapterTests.swift agentGuiTests/MemoryMigrationIntegrationTests.swift
git commit -m "feat: prefer task memory v2 in runtime reads"
```

### Task 10: Route New Task-Level Writes Into TaskMemory V2

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryV2Store.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryMigrationIntegrationTests.swift`

**Step 1: Write the failing tests**

Pin that task-scoped outcomes and consolidated candidates update V2 state.

```swift
    @Test func coordinatorRecordsTaskOutcomeIntoTaskMemoryV2() async throws {
        let harness = try TaskMemoryWriteHarness()
        await harness.coordinator.recordOutcome(harness.outcome)
        #expect(try harness.v2Store.load(sessionID: "s1")?.records.isEmpty == false)
    }
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: FAIL because outcome recording only writes unified store.

**Step 3: Write minimal implementation**

Update `recordOutcome` and task-scoped consolidation flow so task-domain records also update `TaskMemoryV2Store`. Keep unified store writes for shared runtime visibility, but treat V2 as the authoritative task-domain state.

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/TaskMemoryV2Store.swift agentGui/Services/MemoryConsolidationEngine.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryMigrationIntegrationTests.swift
git commit -m "feat: write task-domain outcomes into task memory v2"
```

### Task 11: Surface Migration And Scheduler Health In The UI

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`

**Step 1: Write the failing test**

Require the view model to expose scheduler health and migration status counts.

```swift
    @Test func viewModelSurfacesSchedulerAndMigrationHealth() async throws {
        let harness = try MemoryManagementHarness.withJobsAndMigrationData()
        let viewModel = harness.makeViewModel()
        try viewModel.reload()

        #expect(viewModel.latestSweepReport != nil)
        #expect(viewModel.migratedTaskMemoryCount >= 0)
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryManagementViewModelTests
```

Expected: FAIL because those view model properties do not exist.

**Step 3: Write minimal implementation**

Expose:

- latest sweep report
- background queue counts
- last scheduler run
- migrated / legacy / failed migration counts

Render them in `MemoryManagementPanel` and settings as status rows, not advanced control panels.

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/ContentView.swift agentGuiTests/MemoryManagementViewModelTests.swift
git commit -m "feat: surface memory scheduler and migration health"
```

### Task 12: Remove Legacy TaskMemory Code After Cutover

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/TaskMemoryService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TaskMemory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-10-agent-architecture.md`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TaskMemoryStoreAdapterTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryMigrationIntegrationTests.swift`

**Step 1: Write the failing test**

Add a cutover test that assumes no legacy write path is required in normal runtime mode.

```swift
    @Test func runtimeOperatesWithoutLegacyTaskMemoryServiceForMigratedSessions() async throws {
        let harness = try MemoryMigrationIntegrationHarness.migratedOnly()
        let context = try await harness.coordinator.prepareContext(for: harness.request)
        #expect(context.records.contains { $0.title == "Migrated fact" })
    }
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: FAIL until legacy assumptions are removed.

**Step 3: Write minimal implementation**

Remove normal-runtime dependency on legacy `TaskMemoryService` and legacy projection code. If a read-only importer still exists, move it behind `TaskMemoryMigrationService` and mark it as migration-only.

Update docs to reflect the new authoritative schema and removed adapter path.

**Step 4: Run tests to verify they pass**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/UnifiedMemoryStoreContractTests \
  -only-testing:agentGuiTests/UnifiedMemoryFileStoreAdapterTests \
  -only-testing:agentGuiTests/MemoryGovernanceServiceTests \
  -only-testing:agentGuiTests/MemoryGovernedWriteRoutingTests \
  -only-testing:agentGuiTests/MemoryConflictResolverTests \
  -only-testing:agentGuiTests/MemoryRetentionServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationEngineTests \
  -only-testing:agentGuiTests/MemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/MemoryManagementViewModelTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: PASS with no normal-path dependency on legacy `TaskMemory`.

**Step 5: Commit**

```bash
git add agentGui/Services/TaskMemoryStoreAdapter.swift agentGui/Services/TaskMemoryService.swift agentGui/Models/TaskMemory.swift agentGui/Services/ClaudeService+ContextCompression.swift docs/spec/2026-03-10-memory-governance-operations-and-taskmemory-migration-requirements.md docs/technical-spec/2026-03-10-agent-architecture.md agentGuiTests/TaskMemoryStoreAdapterTests.swift agentGuiTests/MemoryMigrationIntegrationTests.swift
git commit -m "refactor: remove legacy task memory runtime path"
```

## Final Verification Pass

After Task 12, run the full memory suite once more:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/UnifiedMemoryStoreContractTests \
  -only-testing:agentGuiTests/UnifiedMemoryFileStoreAdapterTests \
  -only-testing:agentGuiTests/TaskMemoryStoreAdapterTests \
  -only-testing:agentGuiTests/StoryMemoryStoreAdapterTests \
  -only-testing:agentGuiTests/MemoryGovernanceServiceTests \
  -only-testing:agentGuiTests/MemoryGovernedWriteRoutingTests \
  -only-testing:agentGuiTests/MemoryConflictResolverTests \
  -only-testing:agentGuiTests/MemoryRetentionServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationEngineTests \
  -only-testing:agentGuiTests/MemoryDomainProfileTests \
  -only-testing:agentGuiTests/MemoryPromptBudgetingTests \
  -only-testing:agentGuiTests/MemoryRetrievalPlannerTests \
  -only-testing:agentGuiTests/MemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/MemoryManagementViewModelTests \
  -only-testing:agentGuiTests/MemoryRuntimeSettingsTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/TaskMemoryMigrationServiceTests \
  -only-testing:agentGuiTests/TaskMemoryV2StoreTests \
  -only-testing:agentGuiTests/MemoryMigrationIntegrationTests
```

Expected: PASS.

## Risks And Watchpoints

- `pending-confirmations.json` and unified record files must not be mixed during enumeration. Keep file filtering explicit.
- Background scheduling must not create duplicate consolidation jobs for the same session and same candidate set.
- Migration must never silently delete legacy files before parity is confirmed.
- `TaskMemoryV2` should not reintroduce the old anti-pattern of storing everything as opaque strings. Keep record-level structure first.
- UI actions must remain available even if a background scheduler is disabled.

## Suggested Execution Order

1. Tasks 1-3: make pending confirmations actionable.
2. Tasks 4-6: add persistent background scheduling and sweep reporting.
3. Tasks 7-10: define V2 schema, migrate, and route runtime writes.
4. Tasks 11-12: surface health, cut over, and remove legacy code.

Plan complete and saved to `docs/plans/2026-03-10-memory-governance-operations-and-taskmemory-migration-implementation.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
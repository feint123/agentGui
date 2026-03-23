# Workbench Git Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a modular Workbench Git workflow that supports daily source-control actions inside agentGui, starting with file-level stage or unstage or discard, commit composition, branch and sync controls, stash entry points, and change filtering.

**Architecture:** Keep the existing Git diff preview and repository snapshot flow, but split read-only status from write operations so refresh and mutation do not fight each other. Expand the current Git service into a capability-oriented command layer, move Workbench-specific orchestration into a dedicated sidebar view model, and break the UI into stable section views that can grow toward history, conflicts, and graph features without reworking the panel shell again.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, existing Git CLI integration via `Process`, Workbench context window state, `xcodebuild` test workflow.

---

## 1. Implementation Rules

- Follow @test-driven-development for every task: tests first, then the smallest production change that makes them pass.
- Keep the current diff preview path intact: `GitPanelViewModel.selectDiff` and `WorkspaceState.showGitDiffDetail` remain the source of truth until the panel rewrite is complete.
- Prefer adding new section views and one new sidebar-specific view model over inflating `GitPanelViewModel` with more UI-only state.
- Do not add history graph, hunk staging, blame, or AI commit message generation in this plan.
- Do not replace the existing `GitService` parser pipeline unless a task explicitly needs to expand it.
- Use focused `xcodebuild` test runs after each task; only run broader smoke once the panel closes the P0 workflow.
- Finish with @requesting-code-review focused on Git mutation safety, Workbench state sync, and SwiftUI view composition.

## 2. Scope

### In scope

- File-level stage, unstage, and discard actions.
- Commit composer with summary and description plus preflight validation.
- Branch creation and branch checkout.
- Fetch, pull, push, and sync entry points.
- Stash save, apply, and pop entry points.
- Change filtering in the Git panel.
- Modular Git sidebar section views and a dedicated sidebar composition model.

### Out of scope

- Hunk-level or line-level staging.
- Commit history graph.
- Merge editor or full conflict resolution UI.
- Multi-repository orchestration.
- AI commit message generation.

## 3. Existing Files To Reuse

### Production

- `agentGui/Services/GitService.swift`
- `agentGui/ViewModels/GitPanelViewModel.swift`
- `agentGui/Views/GitPanelView.swift`
- `agentGui/Views/GitDiffView.swift`
- `agentGui/Views/Workbench/WorkbenchGitPanelView.swift`
- `agentGui/Utilities/WorkspaceState.swift`
- `agentGui/Views/Workbench/WorkbenchContextWindowView.swift`

### Existing tests

- `agentGuiTests/GitServiceTests.swift`
- `agentGuiTests/GitPanelViewModelTests.swift`

## 4. New Files Expected

### Production

- `agentGui/Models/GitOperationState.swift`
- `agentGui/Models/GitCommitDraft.swift`
- `agentGui/Models/GitRemoteStatus.swift`
- `agentGui/Models/GitStashEntry.swift`
- `agentGui/ViewModels/GitSidebarViewModel.swift`
- `agentGui/Views/Git/GitSidebarOverviewSection.swift`
- `agentGui/Views/Git/GitSidebarChangesSection.swift`
- `agentGui/Views/Git/GitSidebarCommitSection.swift`
- `agentGui/Views/Git/GitSidebarBranchSection.swift`
- `agentGui/Views/Git/GitSidebarUtilitiesSection.swift`

### Tests

- `agentGuiTests/GitSidebarViewModelTests.swift`
- `agentGuiTests/GitPanelViewTests.swift`

## 5. Desired End State

When this plan is complete:

- The Workbench Git sidebar shows stable Overview, Changes, Commit, Branch and Sync, and Utilities sections.
- Users can stage or unstage or discard at file level without leaving agentGui.
- Users can write a commit message and create a commit after validation.
- Users can fetch, pull, push, create a branch, switch branches, and trigger basic stash actions.
- The panel remains compatible with current Workbench diff preview and file tree Git indicators.
- Git mutations use explicit service methods with user-facing error reporting instead of raw command strings embedded in views.

## 6. Task Breakdown

### Task 1: Lock The Current Git Sidebar Baseline And Mutation Contracts

**Files:**
- Modify: `agentGuiTests/GitServiceTests.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`
- Create: `agentGuiTests/GitSidebarViewModelTests.swift`

**Step 1: Write the failing test**

Add tests that define the first-wave mutation contract the rest of the plan will build around:

- `GitService` can stage a file, unstage a file, discard a file, commit, fetch, pull, push, create a branch, and list or apply stash entries through dedicated methods.
- `GitSidebarViewModel` exposes disabled reasons for commit, sync, and stash actions.
- Refresh after mutation keeps diff selection consistent when the file still exists in the next snapshot.

Example skeletons:

```swift
@Test func stageFileUsesExpectedArguments() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")
    let change = GitRepositorySnapshot.fixture().unstagedChanges[0]

    runner.results = [.success(.init(stdout: "", stderr: "", exitCode: 0))]

    try await service.stage(change: change, repositoryRoot: repositoryRoot)

    #expect(runner.invocations[0].arguments == ["add", "--", change.relativePath])
}

@Test func commitRequiresNonEmptySummaryAndStagedChanges() async throws {
    let viewModel = GitSidebarViewModel(panelViewModel: GitPanelViewModel(gitService: FakeGitService()))
    viewModel.commitDraft = GitCommitDraft(summary: "", description: "")
    viewModel.snapshot = .fixture(stagedChanges: [])

    #expect(viewModel.commitDisabledReason == .missingSummary)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitServiceTests -only-testing:agentGuiTests/GitPanelViewModelTests -only-testing:agentGuiTests/GitSidebarViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the new mutation API surface and sidebar view model do not exist yet.

**Step 3: Write minimal implementation**

Only add the smallest placeholder types and protocol stubs needed to compile the tests. Do not implement UI in this task.

```swift
enum GitOperationState: Equatable {
    case idle
    case running
    case failed(String)
}
```

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/GitServiceTests.swift agentGuiTests/GitPanelViewModelTests.swift agentGuiTests/GitSidebarViewModelTests.swift agentGui/Models/GitOperationState.swift agentGui/ViewModels/GitSidebarViewModel.swift
git commit -m "test: lock git sidebar mutation contracts"
```

### Task 2: Expand GitService For File Mutations And Commit Execution

**Files:**
- Modify: `agentGui/Services/GitService.swift`
- Create: `agentGui/Models/GitCommitDraft.swift`
- Modify: `agentGuiTests/GitServiceTests.swift`

**Step 1: Write the failing test**

Add focused tests for file mutation and commit commands:

- stage uses `git add -- <path>`
- unstage uses `git restore --staged -- <path>`
- discard uses `git restore -- <path>`
- commit writes summary and optional description into a temporary message file or equivalent safe mechanism
- empty commit summary is rejected before shelling out

Example skeleton:

```swift
@Test func commitUsesMessageFileWhenDescriptionExists() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

    runner.results = [.success(.init(stdout: "", stderr: "", exitCode: 0))]

    try await service.commit(
        draft: GitCommitDraft(summary: "feat: add git actions", description: "Implements file-level stage and discard."),
        repositoryRoot: repositoryRoot
    )

    #expect(runner.invocations[0].arguments.first == "commit")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the mutation methods are not implemented.

**Step 3: Write minimal implementation**

Extend `GitServicing` and `GitService` with:

```swift
func stage(change: GitFileChange, repositoryRoot: URL) async throws
func unstage(change: GitFileChange, repositoryRoot: URL) async throws
func discard(change: GitFileChange, repositoryRoot: URL) async throws
func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws
```

Use a safe temporary commit message file for summary plus description instead of building shell-escaped multiline arguments.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitService.swift agentGui/Models/GitCommitDraft.swift agentGuiTests/GitServiceTests.swift
git commit -m "feat: add git file mutation and commit service APIs"
```

### Task 3: Add Branch Creation, Remote Sync, And Stash Service Methods

**Files:**
- Modify: `agentGui/Services/GitService.swift`
- Create: `agentGui/Models/GitRemoteStatus.swift`
- Create: `agentGui/Models/GitStashEntry.swift`
- Modify: `agentGuiTests/GitServiceTests.swift`

**Step 1: Write the failing test**

Add tests for:

- `createBranch(named:switchAfterCreate:repositoryRoot:)`
- `fetch(repositoryRoot:)`
- `pull(repositoryRoot:)`
- `push(repositoryRoot:)`
- `listStashes(repositoryRoot:)`
- `saveStash(message:repositoryRoot:)`
- `applyStash(id:pop:repositoryRoot:)`

Example skeleton:

```swift
@Test func createBranchUsesSwitchCreateArguments() async throws {
    let runner = FakeGitCommandRunner()
    let service = GitService(commandRunner: runner)
    let repositoryRoot = URL(fileURLWithPath: "/tmp/repo")

    runner.results = [.success(.init(stdout: "", stderr: "", exitCode: 0))]

    try await service.createBranch(named: "feature/git-sidebar", switchAfterCreate: true, repositoryRoot: repositoryRoot)

    #expect(runner.invocations[0].arguments == ["switch", "-c", "feature/git-sidebar"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the sync and stash APIs are missing.

**Step 3: Write minimal implementation**

Add the service methods and lightweight stash parsing.

```swift
func fetch(repositoryRoot: URL) async throws
func pull(repositoryRoot: URL) async throws
func push(repositoryRoot: URL) async throws
func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws
func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry]
func saveStash(message: String?, repositoryRoot: URL) async throws
func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws
```

Keep parsing simple: stash id and summary are enough for phase 1.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/GitService.swift agentGui/Models/GitRemoteStatus.swift agentGui/Models/GitStashEntry.swift agentGuiTests/GitServiceTests.swift
git commit -m "feat: add git sync branch and stash service APIs"
```

### Task 4: Introduce A Dedicated GitSidebarViewModel

**Files:**
- Create: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `agentGui/Views/Workbench/WorkbenchGitPanelView.swift`
- Modify: `agentGuiTests/GitSidebarViewModelTests.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: Write the failing test**

Add tests that prove the sidebar composition layer owns UI-only behavior while `GitPanelViewModel` stays focused on repository snapshot and diff projection:

- change filter text and section visibility live in `GitSidebarViewModel`
- commit draft validation lives in `GitSidebarViewModel`
- mutation actions call into `GitServicing` through `GitPanelViewModel` or injected mutation closures without duplicating refresh logic

Example skeleton:

```swift
@Test func filteredChangesIncludesMatchingUntrackedAndModifiedFiles() async throws {
    let panel = GitPanelViewModel(gitService: FakeGitService())
    panel.snapshot = .fixture()
    let sidebar = GitSidebarViewModel(panelViewModel: panel)
    sidebar.changeFilterText = "WorkspacePanel"

    #expect(sidebar.filteredUnstagedChanges.count == 1)
    #expect(sidebar.filteredStagedChanges.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitSidebarViewModelTests -only-testing:agentGuiTests/GitPanelViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the sidebar view model does not yet own this state.

**Step 3: Write minimal implementation**

Add a sidebar-only view model that wraps the existing panel model.

```swift
@Observable
@MainActor
final class GitSidebarViewModel {
    let panelViewModel: GitPanelViewModel
    var changeFilterText = ""
    var commitDraft = GitCommitDraft()
    var changesSectionExpansion: Set<GitChangeSection> = Set(GitChangeSection.allCases)
}
```

Keep `GitPanelViewModel` responsible for refresh, diff selection, and repository-root-aware command execution.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitSidebarViewModel.swift agentGui/ViewModels/GitPanelViewModel.swift agentGui/Views/Workbench/WorkbenchGitPanelView.swift agentGuiTests/GitSidebarViewModelTests.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "refactor: separate git sidebar UI state from panel runtime"
```

### Task 5: Split GitPanelView Into Stable Section Views

**Files:**
- Modify: `agentGui/Views/GitPanelView.swift`
- Create: `agentGui/Views/Git/GitSidebarOverviewSection.swift`
- Create: `agentGui/Views/Git/GitSidebarChangesSection.swift`
- Create: `agentGui/Views/Git/GitSidebarCommitSection.swift`
- Create: `agentGui/Views/Git/GitSidebarBranchSection.swift`
- Create: `agentGui/Views/Git/GitSidebarUtilitiesSection.swift`
- Create: `agentGuiTests/GitPanelViewTests.swift`

**Step 1: Write the failing test**

Add view tests that lock the new section structure and accessibility identifiers:

- overview appears when snapshot exists
- changes section renders staged, modified, and untracked groups
- commit section shows summary field and commit button
- branch section shows branch menu and sync controls
- utilities section shows stash and repository helper actions

Example skeleton:

```swift
@Test func gitPanelRendersCommitAndBranchSectionsWhenSnapshotExists() async throws {
    let panel = GitPanelViewModel(gitService: FakeGitService())
    panel.snapshot = .fixture()
    let sidebar = GitSidebarViewModel(panelViewModel: panel)

    let view = GitPanelView(sidebarViewModel: sidebar, showsBackground: false)

    #expect(view != nil)
}
```

If the repo does not already use view inspection, keep the tests shallow and assert stable accessibility IDs through existing UI-test-friendly patterns.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitPanelViewTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the section views and new initializer shape do not exist yet.

**Step 3: Write minimal implementation**

Refactor `GitPanelView` into a composition shell that renders new subviews and forwards actions from `GitSidebarViewModel`.

```swift
struct GitPanelView: View {
    @Bindable var sidebarViewModel: GitSidebarViewModel
    let showsBackground: Bool
}
```

Preserve the existing empty state, progress state, and alert behavior during the split.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/GitPanelView.swift agentGui/Views/Git agentGuiTests/GitPanelViewTests.swift
git commit -m "refactor: split git panel into sidebar section views"
```

### Task 6: Implement File-Level Stage Or Unstage Or Discard Actions In The Changes Section

**Files:**
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`
- Modify: `agentGuiTests/GitSidebarViewModelTests.swift`

**Step 1: Write the failing test**

Add tests for:

- staging an unstaged file refreshes snapshot and keeps selection aligned
- unstaging a staged file refreshes snapshot
- discarding a file requires an explicit confirmation state before mutation runs
- user-facing errors populate the panel alert model

Example skeleton:

```swift
@Test func stageChangeRefreshesSnapshotAfterMutation() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture()
    let viewModel = GitPanelViewModel(gitService: service)
    let change = GitRepositorySnapshot.fixture().unstagedChanges[0]

    await viewModel.stage(change: change)

    #expect(service.stagedChanges == [change.relativePath])
    #expect(service.refreshInputs.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitPanelViewModelTests -only-testing:agentGuiTests/GitSidebarViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because mutation actions are not exposed to the UI yet.

**Step 3: Write minimal implementation**

Add mutation methods on `GitPanelViewModel` that call service APIs and then refresh the active repository root.

```swift
func stage(change: GitFileChange, workspaceState: WorkspaceState? = nil) async
func unstage(change: GitFileChange, workspaceState: WorkspaceState? = nil) async
func discard(change: GitFileChange, workspaceState: WorkspaceState? = nil) async
```

Expose a confirmation state from `GitSidebarViewModel` for discard instead of mutating directly from the view.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGui/ViewModels/GitSidebarViewModel.swift agentGui/Views/Git/GitSidebarChangesSection.swift agentGuiTests/GitPanelViewModelTests.swift agentGuiTests/GitSidebarViewModelTests.swift
git commit -m "feat: add file-level git changes actions to sidebar"
```

### Task 7: Implement Commit Composer Validation And Execution

**Files:**
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Modify: `agentGui/Views/Git/GitSidebarCommitSection.swift`
- Modify: `agentGuiTests/GitSidebarViewModelTests.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: Write the failing test**

Add tests for:

- commit button disabled with empty summary
- commit button disabled with no staged files
- successful commit clears draft and refreshes snapshot
- failed commit leaves draft intact and surfaces error text

Example skeleton:

```swift
@Test func successfulCommitClearsDraftAndRefreshes() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture()
    let panel = GitPanelViewModel(gitService: service)
    let sidebar = GitSidebarViewModel(panelViewModel: panel)
    sidebar.commitDraft = .init(summary: "feat: commit from sidebar", description: "")

    await sidebar.commit(workspaceState: WorkspaceState())

    #expect(sidebar.commitDraft.summary.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitSidebarViewModelTests -only-testing:agentGuiTests/GitPanelViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because commit orchestration is not yet connected.

**Step 3: Write minimal implementation**

Add a commit action on the sidebar model that validates before delegating to the panel model.

```swift
var commitDisabledReason: GitCommitDisabledReason?
func commit(workspaceState: WorkspaceState) async
```

Only after a successful commit should the draft reset.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGui/ViewModels/GitSidebarViewModel.swift agentGui/Views/Git/GitSidebarCommitSection.swift agentGuiTests/GitSidebarViewModelTests.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "feat: add git commit composer to sidebar"
```

### Task 8: Implement Branch Creation And Remote Sync Controls

**Files:**
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Modify: `agentGui/Views/Git/GitSidebarBranchSection.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`
- Modify: `agentGuiTests/GitSidebarViewModelTests.swift`

**Step 1: Write the failing test**

Add tests for:

- creating a branch with switch enabled refreshes snapshot and branch list
- fetch, pull, and push share a common operation state and user-facing error path
- sync controls disable when no remote tracking branch exists

Example skeleton:

```swift
@Test func createBranchRefreshesBranchesAndSnapshot() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture(branchName: "main")
    let panel = GitPanelViewModel(gitService: service)

    await panel.createBranch(named: "feature/git-sidebar", switchAfterCreate: true)

    #expect(service.createdBranches == ["feature/git-sidebar"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitPanelViewModelTests -only-testing:agentGuiTests/GitSidebarViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the branch and sync actions are not wired.

**Step 3: Write minimal implementation**

Implement branch create and sync methods on the panel model, then render them in the branch section.

```swift
func createBranch(named: String, switchAfterCreate: Bool, workspaceState: WorkspaceState? = nil) async
func fetch(workspaceState: WorkspaceState? = nil) async
func pull(workspaceState: WorkspaceState? = nil) async
func push(workspaceState: WorkspaceState? = nil) async
```

Reuse a shared `GitOperationState` instead of ad hoc booleans for each button.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGui/ViewModels/GitSidebarViewModel.swift agentGui/Views/Git/GitSidebarBranchSection.swift agentGuiTests/GitPanelViewModelTests.swift agentGuiTests/GitSidebarViewModelTests.swift
git commit -m "feat: add git branch and sync controls"
```

### Task 9: Implement Stash Entry Points And Change Filtering

**Files:**
- Modify: `agentGui/ViewModels/GitSidebarViewModel.swift`
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `agentGui/Views/Git/GitSidebarChangesSection.swift`
- Modify: `agentGui/Views/Git/GitSidebarUtilitiesSection.swift`
- Modify: `agentGuiTests/GitSidebarViewModelTests.swift`
- Modify: `agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: Write the failing test**

Add tests for:

- change filter narrows staged, modified, and untracked lists without mutating the underlying snapshot
- saving a stash triggers refresh
- applying or popping a stash triggers refresh
- utilities section disables stash actions when there are no local changes or no stash entries

Example skeleton:

```swift
@Test func saveStashRefreshesAndClearsOperationFailure() async throws {
    let service = FakeGitService()
    service.snapshot = .fixture()
    let panel = GitPanelViewModel(gitService: service)

    await panel.saveStash(message: "wip git sidebar")

    #expect(service.savedStashMessages == ["wip git sidebar"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitSidebarViewModelTests -only-testing:agentGuiTests/GitPanelViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because stash actions and filter plumbing are incomplete.

**Step 3: Write minimal implementation**

Add the stash actions and use the existing section split to surface them in Utilities. Keep UI scope small: menu or button cluster is enough.

```swift
func saveStash(message: String?) async
func applyStash(id: String, pop: Bool) async
```

For filtering, prefer computed arrays on `GitSidebarViewModel`; do not mutate the snapshot itself.

**Step 4: Run test to verify it passes**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/GitSidebarViewModel.swift agentGui/ViewModels/GitPanelViewModel.swift agentGui/Views/Git/GitSidebarChangesSection.swift agentGui/Views/Git/GitSidebarUtilitiesSection.swift agentGuiTests/GitSidebarViewModelTests.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "feat: add git stash entry points and change filtering"
```

### Task 10: Full Git Sidebar Regression Sweep And Review

**Files:**
- Modify: any touched files from Tasks 1-9 as needed
- Modify: `docs/plans/2026-03-24-git-workbench-implementation-plan.md` only if execution deviates from plan

**Step 1: Run focused unit tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/GitServiceTests -only-testing:agentGuiTests/GitPanelViewModelTests -only-testing:agentGuiTests/GitSidebarViewModelTests -only-testing:agentGuiTests/GitPanelViewTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 2: Run a full build**

Run:

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 3: Run repository smoke if Git panel behavior touches broader Workbench integration**

Run the existing workspace task or equivalent command:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS or documented unrelated failures.

**Step 4: Request code review**

Run @requesting-code-review with focus on:

- mutation safety
- refresh after write operations
- diff selection preservation
- SwiftUI section decomposition
- Workbench state integration regressions

**Step 5: Commit**

```bash
git add agentGui agentGuiTests docs/plans/2026-03-24-git-workbench-implementation-plan.md
git commit -m "feat: complete workbench git daily workflow"
```

## 7. Risks And Guardrails

- **Risk:** write actions race with refresh and lose current diff selection.
  **Guardrail:** always refresh through one panel-model path and keep tests for selection preservation.

- **Risk:** `GitPanelViewModel` becomes a second god object.
  **Guardrail:** UI-only state lives in `GitSidebarViewModel`; command execution stays in `GitService` and panel runtime model.

- **Risk:** commit message execution becomes shell-fragile.
  **Guardrail:** use a temporary message file, not multiline shell escaping.

- **Risk:** SwiftUI section extraction breaks existing empty and loading states.
  **Guardrail:** lock the current shell state behavior with `GitPanelViewTests` before splitting the view.

- **Risk:** stash UI grows into a low-value surface area during phase 1.
  **Guardrail:** keep stash to minimal save or apply or pop entry points and postpone stash history detail until after history work starts.

## 8. Definition Of Done

- File-level stage or unstage or discard works from the Git sidebar.
- Commit composer validates and creates commits.
- Branch create and checkout plus fetch or pull or push are available.
- Stash save plus apply or pop entry points exist.
- Change filtering works across sections.
- Focused Git tests pass.
- Project build passes.
- Code review has been requested.

Plan complete and saved to `docs/plans/2026-03-24-git-workbench-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
# Workbench UI Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild the workbench around a chat-first layout, an on-demand contextual detail inspector, a composer-adjacent proposal dock, a unified assist-panel system, and explicit workspace identity across sessions.

**Architecture:** Introduce a typed detail-selection and detail-visibility state model in `WorkspaceState`, migrate workbench routing so `ChatView` becomes the main content column and file / diff / proposal review becomes the detail column, then layer in a proposal dock and shared composer assist container above the input area. Keep the migration incremental: first add compatibility adapters around the new state model, then move producers and views to the new abstractions, then remove the legacy selection fields once all callers and tests are migrated.

**Tech Stack:** Swift 6, SwiftUI for macOS, SwiftData, Observation, existing `WorkspaceState`, `WorkbenchShellView`, `ChatView`, `FileEditorView`, `ChangeReviewProjectionStore`, Swift Testing, XCTest UI tests.

**Depends On:** [docs/plans/2026-03-22-workbench-ui-redesign-design.md](../plans/2026-03-22-workbench-ui-redesign-design.md)

---

## 0. Read This First

- Use @test-driven-development on every production change in this plan. No new production code lands before a failing test proves the behavior gap.
- Use @swiftui-expert-skill when touching `WorkbenchShellView`, `ChatView`, `SessionListView`, and any new SwiftUI panel components. Prefer small extracted views, stable state ownership, and modern SwiftUI APIs already used in the repo.
- `WorkspaceState` currently fans out detail-related state across `selectedFile`, `selectedGitDiffPath`, `selectedGitDiffText`, `selectedGitDiffTitle`, `selectedChangeProposalID`, and `selectedChangeProposalFilePath`. Do not attempt a flag-day rewrite. Add a typed compatibility layer first, then migrate producers, then delete legacy paths.
- The app already has useful focused test anchors: `WorkspaceStateTests`, `FileEditorDisplayModeTests`, `WorkspaceTreeViewModelTests`, `GitPanelViewModelTests`, `WorkbenchTitlePresentationTests`, `ChatComposerTodoCardPresentationTests`, `ChatComposerSlashStateTests`, `ChatFlowUITests`, and `SessionManagementUITests`. Extend these where possible before inventing new suites.
- `scripts/run_quality_smoke.sh unit` runs the focused unit / integration smoke suite. The `ui` mode is currently a placeholder, so UI verification in this plan must use explicit `xcodebuild test -only-testing:agentGuiUITests/...` commands.
- In this repo, `xcodebuild test` can be blocked by local macOS UI test signing. If that happens before unit suites run, validate compile health with:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build-for-testing CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/agentgui-workbench-ui-dd
```

- `ChatView` state that is shared across extension files must not be marked `private` if extensions need to read it. Keep this in mind when extracting composer-panel state.

## 1. Scope Guardrails

- Do not redesign the message transcript, execution theater, or artifact shelf as part of this plan.
- Do not replace `ChangeProposalReviewView` with an inline message review flow. Proposal review remains a dedicated detail inspector.
- Do not redesign the left-side workbench navigation taxonomy. Keep the current `WorkbenchSidebarView` panel set intact.
- Do not add new provider-specific proposal behavior. The dock must work from the generic session-level `ChangeReviewProjectionStore`.
- Do not introduce a generic mega-protocol for every popup in the app. Unify shell, selection behavior, and presentation models only where it reduces duplication.
- Do not remove legacy selection fields until all producers, consumers, and focused tests have been migrated.

## 2. Relevant Existing Files

### Workbench and state

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`

### Detail producers and consumers

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/GitDiffView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChangeProposalReviewView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`

### Composer and chat UI

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/InputAreaTodoCardView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`

### Session and workspace identity

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

### Existing tests to extend

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorDisplayModeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchTitlePresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeReviewProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

## 3. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailSelection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailVisibilityMode.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailLayoutResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ProposalDockPresenter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionWorkspacePresentationFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ComposerAssistSelectionController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchDetailHost.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkspaceIdentityHeaderView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Session/SessionWorkspaceBadgeView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ComposerAssistPanelContainer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ComposerSelectableList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ProposalDockView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ProposalDockItemView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchDetailLayoutResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ProposalDockPresenterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionWorkspacePresentationFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ComposerAssistSelectionControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLayoutUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorDisplayModeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchTitlePresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

## 4. Implementation Order

Lock the detail state model first, then flip the workbench shell, then migrate all detail producers to the new model, then add proposal dock, then unify assist-panel presentation and keyboard behavior, then add workspace identity surfaces, then delete legacy glue.

---

### Task 1: Add typed detail selection, visibility, and layout resolution in `WorkspaceState`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailSelection.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailVisibilityMode.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchDetailLayoutResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchDetailLayoutResolverTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorDisplayModeTests.swift`

**Step 1: Write the failing tests**

Add focused tests that lock the new state contract before touching production code:

- `WorkspaceState.detailSelection` defaults to `.none`
- `WorkspaceState.detailVisibilityMode` defaults to `.automatic`
- Selecting a file yields `.file(url)`
- Selecting a git diff yields `.gitDiff(...)` and clears file/proposal compatibility selection
- Selecting a proposal yields `.changeProposal(...)`
- `WorkbenchDetailLayoutResolver` returns `showsDetail == false` when mode is `.userCollapsed`
- `WorkbenchDetailLayoutResolver` returns `showsDetail == true` for `.automatic + selection != .none`

Test sketch:

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchDetailLayoutResolverTests {
    @Test func automaticModeShowsDetailWhenSelectionExists() {
        let result = WorkbenchDetailLayoutResolver.resolve(
            selection: .file(URL(fileURLWithPath: "/tmp/repo/file.swift")),
            visibilityMode: .automatic
        )

        #expect(result.showsDetail)
    }

    @Test func collapsedModeHidesDetailEvenWhenSelectionExists() {
        let result = WorkbenchDetailLayoutResolver.resolve(
            selection: .changeProposal(proposalID: UUID(), filePath: nil),
            visibilityMode: .userCollapsed
        )

        #expect(!result.showsDetail)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkspaceStateTests \
  -only-testing:agentGuiTests/FileEditorDisplayModeTests \
  -only-testing:agentGuiTests/WorkbenchDetailLayoutResolverTests
```

Expected: FAIL because the typed detail-selection and resolver types do not exist yet.

**Step 3: Write minimal implementation**

Implement only the state model and compatibility bridge:

- Add `WorkbenchDetailSelection`
- Add `WorkbenchDetailVisibilityMode`
- Add `WorkbenchDetailLayoutResolver`
- Extend `WorkspaceState` with `detailSelection`, `detailVisibilityMode`, and helpers such as `showDetail()`, `hideDetail()`, and compatibility setters
- Keep legacy fields alive, but make them mirror the new typed state rather than acting as independent sources of truth

Do not flip the workbench layout yet.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkbenchDetailSelection.swift agentGui/Utilities/WorkbenchDetailVisibilityMode.swift agentGui/Utilities/WorkbenchDetailLayoutResolver.swift agentGui/Utilities/WorkspaceState.swift agentGuiTests/WorkspaceStateTests.swift agentGuiTests/FileEditorDisplayModeTests.swift agentGuiTests/WorkbenchDetailLayoutResolverTests.swift
git commit -m "feat: add typed workbench detail state"
```

### Task 2: Flip `WorkbenchShellView` to chat-first layout and add a dedicated detail host

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchDetailHost.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchLayoutUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Lock the new shell behavior:

- `WorkbenchShellView` renders chat as the content column
- Detail is hidden when `detailSelection == .none` and mode is `.automatic`
- Launching with a selected file opens the detail column
- Creating a new session still reaches the empty-chat state in the main content column

UI sketch:

```swift
import XCTest

final class WorkbenchLayoutUITests: UITestBase {
    @MainActor
    func testEditorDetailIsHiddenWhenNoContextSelectionExists() throws {
        launchApp(arguments: ["-com.agentgui.test.preloadMessages", "false"])

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "panel.chat").firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "panel.editor").firstMatch.exists)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/WorkbenchLayoutUITests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because the shell still uses `FileEditorView` as content and `ChatView` as detail.

**Step 3: Write minimal implementation**

Implement the layout swap only:

- `WorkbenchShellView` becomes `Sidebar | Chat | Detail`
- `WorkbenchDetailHost` interprets the typed detail selection and renders file editor / diff / proposal review
- `WorkbenchConversationPane` wraps `ChatView` and owns the content-column presentation and toolbar integration for detail toggle
- Use `NavigationSplitViewVisibility` together with the new `WorkbenchDetailLayoutResolver` so detail can auto-hide without losing selection

Do not migrate every producer to the new detail API in this task; only consume the new state in the shell.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchShellView.swift agentGui/Views/Workbench/WorkbenchDetailHost.swift agentGui/Views/Workbench/WorkbenchConversationPane.swift agentGui/Views/Workbench/WorkbenchTitlePresentation.swift agentGui/Views/FileEditorView.swift agentGuiUITests/WorkbenchLayoutUITests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: switch workbench to chat-first layout"
```

### Task 3: Migrate all detail producers to the typed detail API

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/GitPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/WorkspaceTreeViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorDisplayModeTests.swift`

**Step 1: Write the failing tests**

Extend the focused producer suites so they assert against the typed detail state:

- workspace-tree selection writes `.file(...)`
- git panel diff selection writes `.gitDiff(...)`
- opening a proposal from tool-call UI writes `.changeProposal(...)`
- compatibility helpers still expose the correct legacy values during migration

Test sketch:

```swift
@MainActor
struct GitPanelViewModelTests {
    @Test func selectDiffWritesTypedDetailSelection() async throws {
        let workspaceState = WorkspaceState()
        let viewModel = GitPanelViewModel(gitService: GitPanelViewModelTestGitService())
        let change = GitFileChange(relativePath: "file.swift", absoluteURL: URL(fileURLWithPath: "/tmp/repo/file.swift"), status: .modified)

        await viewModel.selectDiff(for: change, staged: false, workspaceState: workspaceState)

        #expect(workspaceState.detailSelection == .gitDiff(title: "file.swift", diffText: "diff --git a/file b/file"))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests \
  -only-testing:agentGuiTests/FileEditorDisplayModeTests
```

Expected: FAIL because producers still write only the legacy ad hoc fields.

**Step 3: Write minimal implementation**

Migrate one producer at a time:

- workspace tree opens files via typed detail selection
- git panel diff selection routes through typed detail selection
- proposal-opening actions use one typed API instead of writing `selectedChangeProposalID` directly
- keep compatibility properties in sync until the final cleanup task

Do not touch the composer proposal UI yet.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkspaceState.swift agentGui/ViewModels/GitPanelViewModel.swift agentGui/ViewModels/WorkspaceTreeViewModel.swift agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/WorkspaceTreeViewModelTests.swift agentGuiTests/GitPanelViewModelTests.swift agentGuiTests/FileEditorDisplayModeTests.swift
git commit -m "refactor: route detail producers through typed selection"
```

### Task 4: Add a proposal dock above the composer and keep full review in the detail inspector

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ProposalDockPresenter.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ProposalDockView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ProposalDockItemView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ProposalDockPresenterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChatComposerTodoCardPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerTodoCardPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

Cover the new proposal-dock contract:

- presenter builds invisible output when a session has no pending proposals
- presenter sorts proposals deterministically and exposes summary text for file count and pending count
- assist-surface resolution treats proposal as a persistent panel that coexists with the composer, while slash still takes interaction priority
- UI test can launch a proposal fixture and see the dock above the composer

Test sketch:

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ProposalDockPresenterTests {
    @Test func buildReturnsVisibleItemsForPendingProposalProjection() throws {
        let projection = SessionChangeReviewProjection(
            sessionID: "session-1",
            pendingProposalCount: 1,
            pendingFileCount: 3,
            proposalIDs: [UUID()]
        )

        let presentation = ProposalDockPresenter().build(from: projection)
        #expect(presentation.isVisible)
        #expect(presentation.items.count == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/ProposalDockPresenterTests \
  -only-testing:agentGuiTests/ChatComposerTodoCardPresentationTests \
  -only-testing:agentGuiUITests/ChatFlowUITests
```

Expected: FAIL because there is no proposal-dock presenter, no proposal dock view, and no UI fixture for the dock.

**Step 3: Write minimal implementation**

Implement only the dock and its opening behavior:

- build a `ProposalDockPresenter` from `SessionChangeReviewProjection`
- render `ProposalDockView` above the composer shell when the current session has pending proposals
- replace the old single badge button with the dock list / single-card entry
- clicking or confirming a dock item opens the existing `ChangeProposalReviewView` through the typed detail API
- add a lightweight launch fixture path in `agentGuiApp.swift` if UI tests need deterministic proposal seed data

Do not unify all panel shells yet.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ProposalDockPresenter.swift agentGui/Views/ChatComposer/ProposalDockView.swift agentGui/Views/ChatComposer/ProposalDockItemView.swift agentGui/Views/ChatView+InputArea.swift agentGui/ViewModels/ChatComposerTodoCardPresentation.swift agentGui/agentGuiApp.swift agentGuiTests/ProposalDockPresenterTests.swift agentGuiTests/ChatComposerTodoCardPresentationTests.swift agentGuiUITests/ChatFlowUITests.swift
git commit -m "feat: add proposal dock above chat composer"
```

### Task 5: Extract a shared composer assist container and keyboard-selection controller

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ComposerAssistSelectionController.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ComposerAssistPanelContainer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatComposer/ComposerSelectableList.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ComposerAssistSelectionControllerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerSlashStateTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/ChatFlowUITests.swift`

**Step 1: Write the failing tests**

Lock the shared behavior instead of hardcoding it per panel:

- moving selection up/down wraps or clamps consistently
- pressing enter confirms the highlighted item for slash, mention, and proposal
- pressing escape dismisses transient assist panels first
- todo and proposal share the same shell styling but preserve their own row content

Test sketch:

```swift
import Testing
@testable import agentGui

struct ComposerAssistSelectionControllerTests {
    @Test func moveSelectionAdvancesWithinItemCount() {
        var controller = ComposerAssistSelectionController(itemCount: 3, selectedIndex: 0)

        controller.move(delta: 1)
        #expect(controller.selectedIndex == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/ComposerAssistSelectionControllerTests \
  -only-testing:agentGuiTests/ChatComposerSlashStateTests \
  -only-testing:agentGuiUITests/ChatFlowUITests
```

Expected: FAIL because there is no shared assist selection controller or shared panel shell.

**Step 3: Write minimal implementation**

Implement the shared shell and routing layer:

- `ComposerAssistPanelContainer` standardizes title row, card chrome, spacing, and transitions
- `ComposerSelectableList` standardizes highlighted row handling and keyboard-driven selection
- `ComposerAssistSelectionController` owns reusable index math and dismiss / commit routing
- migrate slash, mention, todo, and proposal views in `ChatView+InputArea.swift` to use the shared shell without changing their underlying data models yet

Do not refactor unrelated message UI while doing this extraction.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ComposerAssistSelectionController.swift agentGui/Views/ChatComposer/ComposerAssistPanelContainer.swift agentGui/Views/ChatComposer/ComposerSelectableList.swift agentGui/Views/ChatView+InputArea.swift agentGuiTests/ComposerAssistSelectionControllerTests.swift agentGuiTests/ChatComposerSlashStateTests.swift agentGuiUITests/ChatFlowUITests.swift
git commit -m "refactor: unify composer assist panel behavior"
```

### Task 6: Add explicit workspace identity to sessions, chat header, and title presentation

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionWorkspacePresentationFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Session/SessionWorkspaceBadgeView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkspaceIdentityHeaderView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionWorkspacePresentationFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchTitlePresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchTitlePresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Cover workspace identity as a single shared presentation model:

- session-level working directory overrides global directory presentation
- global directory appears when the session has no override
- missing directory shows an explicit “未设置工作区” state
- session row and chat header consume the same short-name + source-kind presentation

Test sketch:

```swift
import Testing
@testable import agentGui

@MainActor
struct SessionWorkspacePresentationFactoryTests {
    @Test func sessionOverrideWinsOverGlobalDirectory() {
        let session = Session.fixture(workingDirectory: "/tmp/RepoA")

        let presentation = SessionWorkspacePresentationFactory().build(
            session: session,
            globalWorkingDirectory: "/tmp/RepoB"
        )

        #expect(presentation.title == "RepoA")
        #expect(presentation.kindLabel == "会话级")
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/SessionWorkspacePresentationFactoryTests \
  -only-testing:agentGuiTests/WorkbenchTitlePresentationTests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because the presentation factory and the new UI surfaces do not exist yet.

**Step 3: Write minimal implementation**

Implement the identity surfaces without reshaping unrelated session UI:

- `SessionWorkspacePresentationFactory` resolves short name, full path, and source label
- `SessionWorkspaceBadgeView` is added to each session row
- `WorkspaceIdentityHeaderView` is added to the chat content header or toolbar area
- `WorkbenchTitlePresentation` continues to set represented URL, but now stays consistent with the shared presentation source

Do not add a separate workspace picker here; this task is display-only.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/SessionWorkspacePresentationFactory.swift agentGui/Views/Session/SessionWorkspaceBadgeView.swift agentGui/Views/Workbench/WorkspaceIdentityHeaderView.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView.swift agentGui/Views/Workbench/WorkbenchTitlePresentation.swift agentGuiTests/SessionWorkspacePresentationFactoryTests.swift agentGuiTests/WorkbenchTitlePresentationTests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: surface workspace identity in sessions and chat"
```

### Task 7: Remove legacy detail glue, stabilize the shell, and run end-to-end verification

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceStateTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FileEditorDisplayModeTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceTreeViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/GitPanelViewModelTests.swift`

**Step 1: Write the failing cleanup tests**

Add or update tests that prove the old fields are no longer independent sources of truth:

- clearing detail selection clears legacy compatibility values
- `FileEditorDisplayMode` resolves entirely from typed detail selection
- hiding detail does not destroy the underlying selection
- reopening detail restores the last typed selection

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkspaceStateTests \
  -only-testing:agentGuiTests/FileEditorDisplayModeTests \
  -only-testing:agentGuiTests/WorkspaceTreeViewModelTests \
  -only-testing:agentGuiTests/GitPanelViewModelTests
```

Expected: FAIL because compatibility fields still behave like first-class state.

**Step 3: Write minimal implementation**

Finish the migration:

- collapse legacy selection fields into computed compatibility accessors or delete them if all callers are gone
- make `FileEditorDisplayMode` read from typed detail state only
- ensure hide/show detail only changes visibility mode, not current selection
- remove dead badge-based proposal entry points and any no-longer-used selection clearing helpers

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Run full feature validation**

Run focused unit and UI validation:

```bash
./scripts/run_quality_smoke.sh unit
```

Expected: PASS with `==> Quality smoke suite completed`.

Then run the focused UI suites introduced or updated by this feature:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/WorkbenchLayoutUITests \
  -only-testing:agentGuiUITests/ChatFlowUITests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: PASS. If local signing prevents the UI run, fall back to compile validation:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build-for-testing CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/agentgui-workbench-ui-dd
```

Expected: BUILD SUCCEEDED.

**Step 6: Commit**

```bash
git add agentGui/Utilities/WorkspaceState.swift agentGui/Views/FileEditorView.swift agentGui/Views/Workbench/WorkbenchShellView.swift agentGuiTests/WorkspaceStateTests.swift agentGuiTests/FileEditorDisplayModeTests.swift agentGuiTests/WorkspaceTreeViewModelTests.swift agentGuiTests/GitPanelViewModelTests.swift
git commit -m "refactor: finalize workbench ui detail migration"
```

## 5. Execution Notes

- Keep PR-sized reviewability. Each task above is intended to stay small enough to inspect independently.
- Do not merge Tasks 4, 5, and 6 into one giant “composer cleanup” patch. Proposal dock, shared panel shell, and workspace identity should remain separately reviewable.
- If a task uncovers a missing fixture path for UI tests, add the minimum deterministic launch argument needed in `TestLaunchOptions` / `agentGuiApp.swift` and keep that fixture change in the same task that needs it.
- Favor extracting small presenters and state controllers over adding more logic directly into `ChatView+InputArea.swift`. The file is already large enough to become brittle.

## 6. Suggested Execution Choice

Plan complete and saved to `docs/plans/2026-03-22-workbench-ui-redesign-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
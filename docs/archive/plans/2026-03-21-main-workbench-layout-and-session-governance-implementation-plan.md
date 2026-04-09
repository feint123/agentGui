# Main Workbench Layout And Session Governance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current split top-level navigation and implicit session-source behavior with a unified left-side workbench shell, typed session governance, dedicated background-task sessions, true read-only channel/background conversations, and Apple-native Liquid Glass navigation treatment.

**Architecture:** Keep the current editor and chat collaboration model, but move top-level product navigation into a single workbench shell that owns the sidebar tab state and embeds session, workspace, skills, and diagnostics panels. Add explicit session kind and source metadata to `Session`, centralize session listing and interaction policy in a dedicated catalog layer, and migrate background tasks and channel routing to create source-aware sessions so chat UI and management actions can enforce read-only rules consistently.

**Tech Stack:** Swift 6, SwiftUI for macOS, SwiftData, Observation, existing `Session` / `BackgroundAgentTask` / `RemoteConversationBinding` / `SessionProjectionBinding` models, existing `SettingsWindowView`, existing `ChatView`, Swift Testing, XCTest UI tests.

**Depends On:** [docs/spec/2026-03-21-main-workbench-layout-and-session-governance-requirements.md](../spec/2026-03-21-main-workbench-layout-and-session-governance-requirements.md)

---

## 0. Read This First

- The current app still has two top-level navigation layers: a root `TabView` in `ContentView.swift` and a `NavigationSplitView` in `MainSplitView.swift`. The plan collapses that into one workbench shell before doing UI polish.
- `Session` currently has no first-class session kind, source, or read-only metadata. Do not implement read-only behavior by inspecting relationships ad hoc in views.
- Background tasks currently require manual session selection. The first production path in this plan removes that UI and turns background tasks into one-task-one-session flows.
- Channel sessions are currently created as plain `Session` rows in `RemoteConversationRouter`. That path must be updated early enough that read-only UI can rely on persisted metadata.
- The project deployment target is already macOS 26.0, so native Liquid Glass APIs can be used directly. The risk is overuse and inconsistent layering, not backward compatibility.
- The current `run_quality_smoke.sh ui` path is a placeholder and does not execute real UI tests. For this feature, use focused `xcodebuild` UI suites explicitly.

## 1. Scope Guardrails

- Do not redesign message bubbles or the file editor in this plan. Keep the editor/chat composition intact while changing the shell around it.
- Do not introduce cloud sync, multi-user session sharing, or cross-device state merge.
- Do not migrate background task management out of Settings in this phase; only change its session ownership and navigation hooks.
- Do not keep two parallel primary navigation paths after the shell migration. The root `TabView` must stop being the main product navigation.
- Do not encode channel/background read-only logic directly into individual buttons. A shared interaction policy layer must be the source of truth.
- Do not add gratuitous animation before the new state model is stable. Motion comes after shell, catalog, and read-only behavior are testable.

## 2. Relevant Existing Files

### Current implementation files that must be read before touching code

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/WorkspacePanelView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSessionResultWriter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

### Existing tests to extend instead of duplicating unnecessarily

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionToolbarActionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDeletionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundSessionResultWriterTests.swift`

## 3. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/SessionInteractionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/BackgroundTaskSessionFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionCatalogViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Skills/SkillsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionKindTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionInteractionPolicyTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionCatalogViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchNavigationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchNavigationUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSessionResultWriter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkspaceState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionToolbarActionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDeletionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundSessionResultWriterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

## 4. Implementation Order

Lock the session model first, then build the workbench shell, then swap in the session catalog, then enforce read-only behavior, then rewire background-task ownership, then convert channel sessions and apply workbench motion/glass. Do not start with visual polish.

---

### Task 1: Add explicit session kind, source metadata, and shared interaction policy

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/SessionKind.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/SessionInteractionPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionKindTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionInteractionPolicyTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`

**Step 1: Write the failing tests**

Lock the minimum contract for typed sessions:

- New sessions default to `.local`
- Channel and background-task sessions are read-only
- Local sessions can rename / submit / clear
- Read-only policy yields a human-readable reason for UI messaging

Test sketch:

```swift
import Testing
@testable import agentGui

struct SessionKindTests {
    @Test func localSessionDefaultsToEditableKind() {
        let session = Session()

        #expect(session.kind == .local)
        #expect(session.isReadOnly == false)
    }
}

struct SessionInteractionPolicyTests {
    @Test func channelSessionsDisableComposerAndRename() {
        let session = Session.fixture(title: "Feishu")
        session.kind = .channel

        let policy = SessionInteractionPolicy(session: session)
        #expect(policy.canSend == false)
        #expect(policy.canRename == false)
        #expect(policy.readOnlyReason.isEmpty == false)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/SessionInteractionPolicyTests
```

Expected: FAIL because `SessionKind`, `SessionInteractionPolicy`, and the new session metadata fields do not exist yet.

**Step 3: Write minimal implementation**

Implement the smallest persisted model needed for the rest of the plan:

- Add a `SessionKind` enum
- Persist `kindRaw`, `sourceIdentifier`, `sourceDisplayName`, and `readOnlyReasonOverride` on `Session`
- Add computed helpers such as `kind`, `isReadOnly`, and `displaySourceTitle`
- Centralize edit/delete/send capabilities in `SessionInteractionPolicy`
- Register any new model-side types or schema changes needed by the app container

Keep the first version deliberately narrow. Do not add tags, pinning, or archive state in this task.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/SessionKind.swift agentGui/Models/Session.swift agentGui/Services/Sessions/SessionInteractionPolicy.swift agentGui/agentGuiApp.swift agentGuiTests/SessionKindTests.swift agentGuiTests/SessionInteractionPolicyTests.swift
git commit -m "feat: add typed session governance model"
```

### Task 2: Collapse top-level navigation into a unified workbench shell

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchState.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchNavigationItem.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Skills/SkillsView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkbenchNavigationTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchNavigationUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`

**Step 1: Write the failing tests**

Lock the new shell contract:

- Workbench tabs are `sessions`, `workspace`, `skills`, `diagnostics`
- Default tab is `sessions`
- The root app no longer requires the top-level `TabView` to reach skills or diagnostics
- UI test can switch between workbench tabs using stable accessibility identifiers

Test sketch:

```swift
import Testing
@testable import agentGui

struct WorkbenchNavigationTests {
    @Test func workbenchNavigationDefaultOrderIsStable() {
        #expect(WorkbenchNavigationItem.allCases == [.sessions, .workspace, .skills, .diagnostics])
        #expect(WorkbenchNavigationItem.defaultItem == .sessions)
    }
}
```

UI sketch:

```swift
final class WorkbenchNavigationUITests: UITestBase {
    @MainActor
    func testSwitchingWorkbenchTabsShowsExpectedPanels() throws {
        launchApp()

        XCTAssertTrue(app.buttons["workbench.tab.sessions"].waitForExistence(timeout: 2))
        app.buttons["workbench.tab.skills"].click()
        XCTAssertTrue(app.staticTexts["Skills"].waitForExistence(timeout: 2))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/WorkbenchNavigationTests \
  -only-testing:agentGuiUITests/WorkbenchNavigationUITests
```

Expected: FAIL because the workbench shell, tab model, and accessibility identifiers do not exist yet.

**Step 3: Write minimal implementation**

Implement only the shell and extraction work:

- Introduce a `WorkbenchState` for selected sidebar tab
- Extract `SkillsView` out of `ContentView.swift` into its own file
- Build `WorkbenchShellView` around a single `NavigationSplitView`
- Move the old `ContentView` root from top-level `TabView` to `WorkbenchShellView`
- Route sidebar tab selection to one of: session panel, workspace panel, skills panel, diagnostics panel

Do not yet redesign the session panel itself in this task. Reuse existing placeholders where necessary.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Utilities/WorkbenchState.swift agentGui/Views/Workbench/WorkbenchNavigationItem.swift agentGui/Views/Workbench/WorkbenchSidebarView.swift agentGui/Views/Workbench/WorkbenchShellView.swift agentGui/Views/Skills/SkillsView.swift agentGui/Views/MainSplitView.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGui/ContentView.swift agentGuiTests/WorkbenchNavigationTests.swift agentGuiUITests/WorkbenchNavigationUITests.swift
git commit -m "feat: add unified workbench shell"
```

### Task 3: Turn the session panel into a real catalog with grouping, search, and local-only rename

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/SessionCatalogViewModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionCatalogViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MainSplitView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Cover the new catalog behavior:

- Sessions group into local, channel, and background-task sections
- Search matches title, preview text, and source title
- Only local sessions expose rename affordances
- Read-only sessions still appear in results but with disabled rename state

Test sketch:

```swift
@MainActor
struct SessionCatalogViewModelTests {
    @Test func viewModelGroupsSessionsByKindAndSearchesAcrossSourceDisplay() throws {
        let context = try SessionCatalogHarness.makeContext()
        let local = Session.fixture(title: "本地修复")
        let channel = Session.fixture(title: "Feishu")
        channel.kind = .channel
        channel.sourceDisplayName = "飞书 · 团队群"

        context.insert(local)
        context.insert(channel)
        try context.save()

        let viewModel = SessionCatalogViewModel(modelContext: context)
        viewModel.searchText = "团队群"

        #expect(viewModel.visibleSections.count == 1)
        #expect(viewModel.visibleSections.first?.items.map(\.session.sessionId) == [channel.sessionId])
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/SessionCatalogViewModelTests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because there is no catalog view model, no grouped sections, and no search-based session sidebar yet.

**Step 3: Write minimal implementation**

Implement the smallest catalog stack that the shell can use:

- A `SessionCatalogViewModel` that fetches, sorts, groups, and searches sessions
- A revised `SessionListView` that shows grouped sections with a top search field
- A rename flow limited to local sessions only
- Stable accessibility identifiers for sections, rows, search, and rename actions

Keep batch actions, pinning, and archive behavior out of scope for this task.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/SessionCatalogViewModel.swift agentGui/Views/SessionListView.swift agentGui/Views/MainSplitView.swift agentGuiTests/SessionCatalogViewModelTests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: add grouped session catalog sidebar"
```

### Task 4: Enforce read-only session behavior in chat and session actions

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionToolbarActionTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionDeletionCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Cover the two layers of read-only enforcement:

- Channel/background sessions cannot send from chat
- Channel/background sessions cannot rename from the catalog
- Toolbar delete/clear actions refuse read-only sessions or require source-aware routing

Test sketch:

```swift
@MainActor
struct SessionToolbarActionTests {
    @Test func deletingReadOnlySessionIsRejected() async throws {
        let harness = try ReadOnlySessionHarness.make(kind: .channel)

        let deleted = try await SessionToolbarActions(
            modelContext: harness.context,
            workspaceState: harness.state
        ).deleteCurrentSessionIfAllowed()

        #expect(deleted == false)
    }
}
```

UI sketch:

```swift
final class SessionManagementUITests: UITestBase {
    @MainActor
    func testChannelSessionDisablesComposer() throws {
        launchApp(arguments: ["-com.agentgui.test.channelSession", "1"])

        XCTAssertTrue(app.staticTexts["chat.readOnlyBanner"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["chat.sendButton"].isEnabled)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/SessionToolbarActionTests \
  -only-testing:agentGuiTests/SessionDeletionCoordinatorTests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because chat send readiness, toolbar actions, and deletion flow are not yet source-aware.

**Step 3: Write minimal implementation**

Implement only the policy-driven behavior needed to enforce read-only state:

- Make `canSend` depend on `SessionInteractionPolicy`
- Show a source/read-only banner in chat when composer is locked
- Remove or disable rename/clear/delete affordances for read-only sessions
- Stop relying on toolbar session picker as the primary session-navigation surface

Do not add the “copy as local session” flow yet; that belongs after source-specific sessions are created reliably.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/ChatView.swift agentGui/Views/ChatView+Toolbar.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+Actions.swift agentGui/Services/Channels/SessionDeletionCoordinator.swift agentGuiTests/SessionToolbarActionTests.swift agentGuiTests/SessionDeletionCoordinatorTests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: enforce read-only session interaction rules"
```

### Task 5: Make background tasks own dedicated sessions automatically

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Sessions/BackgroundTaskSessionFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/BackgroundSessionResultWriter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundSessionResultWriterTests.swift`

**Step 1: Write the failing tests**

Replace the old manual-session contract with dedicated-session ownership:

- Saving a new task auto-creates a bound session of kind `.backgroundTask`
- Editing the same task reuses its existing session
- Updating the task title updates the bound session title
- Result writer always resolves the task’s dedicated session without relying on a manually chosen UI field

Test sketch:

```swift
@MainActor
struct BackgroundTaskManagementViewModelTests {
    @Test func saveDraftCreatesDedicatedBackgroundSessionAutomatically() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let viewModel = BackgroundTaskManagementViewModel(
            modelContext: context,
            persistenceCoordinator: nil
        )

        viewModel.makeNewTask()
        viewModel.draftTitle = "日报"
        viewModel.draftPrompt = "汇总今日进展"

        try viewModel.saveDraft()

        let task = try #require(context.fetch(FetchDescriptor<BackgroundAgentTask>()).first)
        let session = try #require(context.fetch(FetchDescriptor<Session>()).first)
        #expect(task.sessionId == session.sessionId)
        #expect(session.kind == .backgroundTask)
        #expect(session.isReadOnly)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/BackgroundTaskManagementViewModelTests \
  -only-testing:agentGuiTests/BackgroundSessionResultWriterTests
```

Expected: FAIL because the current flow still expects `draftSessionID` and writes results to an arbitrarily selected existing session.

**Step 3: Write minimal implementation**

Implement the smallest ownership change:

- Introduce a `BackgroundTaskSessionFactory`
- Remove the manual “result write-back session” selector from the settings UI
- Ensure `BackgroundTaskManagementViewModel.saveDraft()` creates or reuses a dedicated session
- Persist background-task session source metadata and read-only state
- Keep `BackgroundAgentTask.sessionId` as the dedicated-session pointer unless a stronger rename is necessary during implementation

Do not yet build task-to-session deep-link UI beyond basic display.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Sessions/BackgroundTaskSessionFactory.swift agentGui/Models/BackgroundAgentTask.swift agentGui/ViewModels/BackgroundTaskManagementViewModel.swift agentGui/Views/Settings/SettingsBackgroundTasksView.swift agentGui/Services/Background/BackgroundSessionResultWriter.swift agentGuiTests/BackgroundTaskManagementViewModelTests.swift agentGuiTests/BackgroundSessionResultWriterTests.swift
git commit -m "feat: bind background tasks to dedicated sessions"
```

### Task 6: Make channel routing create typed read-only sessions and add local-clone escape hatch

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/RemoteConversationRouterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteConversationRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Toolbar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SessionToolbarActionTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Lock the channel source contract and the escape hatch:

- `RemoteConversationRouter` creates channel sessions with `.channel` kind and source metadata
- A read-only session can be cloned into a new local session
- The cloned local session is editable and detached from source constraints

Test sketch:

```swift
@MainActor
struct RemoteConversationRouterTests {
    @Test func routerCreatesReadOnlyChannelSession() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let message = InboundChannelMessage.fixture(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalUserID: "ou_1"
        )

        let session = try harness.router.resolveSession(for: message, modelContext: harness.context)

        #expect(session.kind == .channel)
        #expect(session.isReadOnly)
        #expect(session.sourceDisplayName.contains("飞书"))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/RemoteConversationRouterTests \
  -only-testing:agentGuiTests/SessionToolbarActionTests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because channel sessions are still created as plain sessions and there is no copy-to-local path.

**Step 3: Write minimal implementation**

Implement only the missing source-aware behavior:

- Mark newly created channel sessions as `.channel`
- Persist channel source display metadata when routing inbound messages
- Add a “copy as local session” action for read-only sessions
- Ensure the cloned session clears read-only/source constraints and becomes the selected session

Do not add bidirectional sync or linked-session editing.

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/RemoteConversationRouter.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView+Toolbar.swift agentGuiTests/RemoteConversationRouterTests.swift agentGuiTests/SessionToolbarActionTests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: type channel sessions and add local clone flow"
```

### Task 7: Apply Liquid Glass navigation treatment, source banners, and final validation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchSidebarView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SessionListView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Reliability/ReliabilityCenterView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/WorkbenchNavigationUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write the failing tests**

Add focused UI assertions for the stable semantics that should survive animation work:

- Workbench tab identifiers stay stable after shell styling
- Read-only banner appears for channel/background sessions
- Search field and primary actions remain discoverable in the session sidebar

Do not write fragile pixel or animation timing tests.

**Step 2: Run UI tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/WorkbenchNavigationUITests \
  -only-testing:agentGuiUITests/SessionManagementUITests
```

Expected: FAIL because the shell still lacks the final navigation-layer glass treatment and source-aware readonly presentation.

**Step 3: Write minimal implementation**

Apply the final shell styling and motion semantics:

- Group workbench tabs inside `GlassEffectContainer`
- Use `glassEffect`, `glassEffectID`, and standard glass button styles only on navigation/high-value control layers
- Add a source/read-only banner treatment to chat for non-editable sessions
- Keep content areas readable and avoid full-surface glass backgrounds
- Keep all motion attached to explicit state changes such as tab change, section filtering, and readonly lock transitions

**Step 4: Run focused UI tests again**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Run final validation suites**

Run the focused suites first, then smoke:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/SessionKindTests \
  -only-testing:agentGuiTests/SessionInteractionPolicyTests \
  -only-testing:agentGuiTests/SessionCatalogViewModelTests \
  -only-testing:agentGuiTests/RemoteConversationRouterTests \
  -only-testing:agentGuiTests/BackgroundTaskManagementViewModelTests \
  -only-testing:agentGuiTests/BackgroundSessionResultWriterTests \
  -only-testing:agentGuiTests/SessionToolbarActionTests \
  -only-testing:agentGuiTests/SessionDeletionCoordinatorTests

xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/WorkbenchNavigationUITests \
  -only-testing:agentGuiUITests/SessionManagementUITests \
  -only-testing:agentGuiUITests/SettingsWindowUITests

./scripts/run_quality_smoke.sh unit
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Views/Workbench/WorkbenchSidebarView.swift agentGui/Views/SessionListView.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView.swift agentGui/Views/Reliability/ReliabilityCenterView.swift agentGuiUITests/WorkbenchNavigationUITests.swift agentGuiUITests/SessionManagementUITests.swift
git commit -m "feat: polish workbench shell with source-aware glass navigation"
```

## 5. Review Checklist For Execution

- Session kind/source metadata is the only source of truth for read-only behavior.
- Root `TabView` navigation is gone from the main product flow.
- Session catalog grouping/search works without requiring the chat toolbar picker.
- Background task creation no longer requires manual session choice.
- Channel and background-task sessions are read-only in both chat and management actions.
- Read-only sessions can be cloned into local editable sessions.
- Liquid Glass is confined to navigation and high-value interaction layers, not large content surfaces.
- Focused unit and UI suites pass, and final smoke validation runs.

## 6. Execution Handoff

Plan complete and saved to `docs/plans/2026-03-21-main-workbench-layout-and-session-governance-implementation-plan.md`.

Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, and iterate directly in this session.

**2. Parallel Session (separate)** - Open a new session and execute this plan with the executing-plans workflow and explicit checkpoints.

Which approach?
# Launch Batch A Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the v1 launch-readiness batch A flow so a first-time user can understand why the app is not ready, open settings directly, validate connection-related configuration, and see tool permission guidance.

**Architecture:** Add a lightweight launch-readiness model that derives onboarding and configuration status from existing `AppSettings`, project it into the empty chat state and settings screens, and keep the changes local to the current app shell instead of introducing a new navigation system. Use small reusable SwiftUI views plus a testable validator service for readiness and connection checks.

**Tech Stack:** SwiftUI, SwiftData, XCTest, macOS UI tests.

---

### Task 1: Add failing tests for launch-readiness UX

**Files:**
- Modify: `agentGuiUITests/SettingsUITests.swift`
- Modify: `agentGuiUITests/SessionManagementUITests.swift`

**Step 1: Write failing UI tests**

- Add a test that launches without a preloaded API key and verifies the empty chat state shows onboarding actions.
- Add a test that verifies settings show readiness status and a connection validation button.

**Step 2: Run tests to verify failure**

Run the focused UI tests for the new cases and confirm they fail because the new affordances do not exist yet.

**Step 3: Implement minimal UI**

- Add onboarding CTA buttons to the empty chat state.
- Add settings readiness / validation UI.

**Step 4: Re-run focused UI tests**

Confirm the new tests pass.

### Task 2: Add failing tests for readiness evaluation and connection validation

**Files:**
- Create: `agentGuiTests/LaunchReadinessEvaluatorTests.swift`
- Create: `agentGuiTests/ConnectionValidationServiceTests.swift`

**Step 1: Write failing unit tests**

- Cover readiness states for missing API key, missing working directory, and configured app.
- Cover validation states for missing key, invalid base URL, invalid proxy URL, and successful local validation.

**Step 2: Run tests to verify failure**

Run the new test targets and confirm the helper types do not exist yet.

**Step 3: Implement minimal helpers**

- Add a launch-readiness evaluator.
- Add a connection validation service with injectable probe behavior.

**Step 4: Re-run focused unit tests**

Confirm the new tests pass.

### Task 3: Project readiness into app shell and settings

**Files:**
- Modify: `agentGui/Views/ChatView+MessageList.swift`
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/Settings/SettingsConnectionView.swift`
- Modify: `agentGui/Views/Settings/SettingsGeneralView.swift`
- Modify: `agentGui/Views/Settings/SettingsToolsView.swift`
- Create: `agentGui/Views/LaunchReadinessCard.swift`
- Create: `agentGui/Services/LaunchReadinessEvaluator.swift`
- Create: `agentGui/Services/ConnectionValidationService.swift`

**Step 1: Add reusable launch-readiness UI**

- Show a compact card in the empty chat state with direct actions.

**Step 2: Add settings readiness summary and validation action**

- Show current launch status on the connection page.
- Add a validation button and structured result message.

**Step 3: Add tool permission guidance**

- Add concise per-tool purpose / risk / prerequisite notes.

**Step 4: Re-run relevant tests**

Run the focused unit and UI tests.

### Task 4: Run smoke verification

**Files:**
- No code changes.

**Step 1: Run the existing smoke suite**

Run `Quality Smoke` or the focused equivalent.

**Step 2: Review regressions**

Fix only regressions caused by this batch.
# Onboarding Window Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the inline first-launch guidance with a dedicated step-by-step onboarding window that opens for unconfigured users, includes a dynamic breathing light background, and removes the temporary onboarding code from the main app shell.

**Architecture:** Introduce a dedicated onboarding scene and a small onboarding state model that reads and writes `AppSettings`. Keep connection validation logic in the existing service, move first-launch CTA flow into a standalone window, and delete the temporary chat/content overlays added in the previous batch.

**Tech Stack:** SwiftUI, SwiftData, XCTest, macOS UI tests.

---

### Task 1: Add failing tests for dedicated onboarding window

**Files:**
- Modify: `agentGuiUITests/SessionManagementUITests.swift`
- Modify: `agentGuiUITests/SettingsUITests.swift`

**Step 1: Write failing UI tests**

- Verify launch without a preloaded API key shows an onboarding window with step controls.
- Verify the onboarding flow can advance from welcome to connection step.
- Keep the settings readiness test intact.

**Step 2: Run focused tests and confirm failure**

Run the updated UI tests and confirm the window / step identifiers do not exist yet.

### Task 2: Add a focused state test for step progression

**Files:**
- Create: `agentGuiTests/OnboardingFlowStateTests.swift`

**Step 1: Write failing unit tests**

- Cover step ordering, forward/back navigation, and completion gating.

**Step 2: Run the unit test and confirm failure**

### Task 3: Implement dedicated onboarding scene and state

**Files:**
- Create: `agentGui/Views/Onboarding/OnboardingWindowView.swift`
- Create: `agentGui/Views/Onboarding/OnboardingFlowState.swift`
- Create: `agentGui/Views/Onboarding/BreathingLightBackground.swift`
- Modify: `agentGui/agentGuiApp.swift`
- Modify: `agentGui/Utilities/TestLaunchOptions.swift`

**Step 1: Build step model**

- Add explicit steps for welcome, connection, and workspace/tool readiness.

**Step 2: Add window scene**

- Add a separate onboarding window scene and auto-open it for unconfigured users.

**Step 3: Add breathing background**

- Add a dedicated animated background only for onboarding.

### Task 4: Remove inline onboarding from main app shell

**Files:**
- Delete: `agentGui/Views/LaunchReadinessCard.swift` if no longer needed
- Modify: `agentGui/ContentView.swift`
- Modify: `agentGui/Views/ChatView.swift`
- Modify: `agentGui/Views/ChatView+MessageList.swift`
- Modify: `agentGui/Views/MainSplitView.swift`

**Step 1: Remove temporary overlays / banners**

- Delete the chat banner, content overlay, and empty-detail onboarding card.

**Step 2: Keep only persistent readiness surfaces that still make sense**

- Preserve settings readiness summary and validation.

### Task 5: Verify and smoke test

**Files:**
- No code changes.

**Step 1: Run focused xcodebuild tests**

Run the onboarding UI tests plus relevant unit tests.

**Step 2: Run `Quality Smoke`**

Confirm the refactor did not regress the current baseline.
# agentGui Quality Test Matrix

Last updated: 2026-03-11

## Current Focused Gates

### Unit and integration scenarios

- `agentGuiTests/QualityFixtureBuilderTests`
  - Verifies UI test launch arguments, shared recovery fixtures, and in-memory harness seeding.
- `agentGuiTests/ReleaseScenarioTests`
  - Verifies user-goal scenarios for configured API key, normal conversation persistence, tool call presentation data, bash task summaries, story-memory project hits, and runtime recovery summary generation.

### macOS UI smoke coverage

- `agentGuiUITests/SessionManagementUITests`
  - Verifies the chat workspace boots into the seeded session, exposes stable automation anchors, and can create a new empty conversation.
- `agentGuiUITests/SettingsUITests`
  - Verifies launch-to-settings and API key form presence.
- `agentGuiUITests/ChatFlowUITests`
  - Verifies the seeded user and agent conversation content is visible.
- `agentGuiUITests/ToolCallUITests`
  - Verifies a seeded tool call appears in the conversation flow.
- `agentGuiUITests/WorkflowRecoveryUITests`
  - Verifies workflow recovery banner visibility and core recovery actions.

## Recommended Local Commands

```bash
# Unified smoke entrypoint
./scripts/run_quality_smoke.sh

# Unit + integration only
./scripts/run_quality_smoke.sh unit

# UI smoke only
./scripts/run_quality_smoke.sh ui

# Release scenario coverage
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/QualityFixtureBuilderTests \
  -only-testing:agentGuiTests/ReleaseScenarioTests

# Focused UI smoke coverage
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiUITests/SessionManagementUITests \
  -only-testing:agentGuiUITests/SettingsUITests \
  -only-testing:agentGuiUITests/ChatFlowUITests \
  -only-testing:agentGuiUITests/ToolCallUITests \
  -only-testing:agentGuiUITests/WorkflowRecoveryUITests
```

## Stability Rules

- UI automation must launch the app with `-com.agentgui.test.mode true` so SwiftData switches to an in-memory store.
- New UI tests should prefer stable accessibility identifiers first, then visible user text only when SwiftUI container identifiers are not exposed by macOS accessibility.
- Release-scenario tests should validate user outcomes, not internal implementation details that can change under the same behavior.
- Prefer `./scripts/run_quality_smoke.sh` or the VS Code `Quality Smoke` task for day-to-day regression checks so the focused gate set stays consistent across contributors.
- CI should call `./scripts/run_quality_smoke.sh unit` and `./scripts/run_quality_smoke.sh ui` separately so failures remain easy to localize.
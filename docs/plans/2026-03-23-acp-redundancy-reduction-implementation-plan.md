# ACP Redundancy Reduction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce redundant ACP orchestration code, collapse unnecessary state duplication, and simplify provider-specific logic without changing end-user behavior for Copilot and OpenCode external ACP sessions.

**Architecture:** Keep the ACP wire protocol stack, runtime transport, and message normalization intact. Refactor the external ACP orchestration layer around a thinner provider specification, a smaller session lifecycle coordinator, and a single session-context state source so that provider differences stay data-driven and session recovery logic stops leaking across caches, routers, and bindings.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, macOS app runtime, existing ACP transport stack, `ConversationExecutionProvider`, `ACPExternalExecutionProviderBase`, `ACPSessionRuntimeActor`, `ACPExternalAgentRuntimeClient`.

---

## 1. Implementation Rules

- This plan is a behavior-preserving refactor. Do not change UI copy, permission policy semantics, or remote ACP protocol payloads unless a test proves the current behavior is dead code.
- Follow @test-driven-development for every task: write or expand failing tests first, then implement the smallest change that makes them pass.
- Prefer deleting unused abstraction points over adding new compatibility layers.
- Keep commits small. One task, one commit.
- Do not refactor the ACP transport or wire message layer in this pass unless a simplification task explicitly calls for it.
- After the final task, run @requesting-code-review with emphasis on session restore, provider switching, and feature update routing regressions.

## 2. Scope

### In scope

- Thin down provider-specific override points in the external ACP execution layer.
- Remove or isolate no-value abstractions such as empty feature adapters and unused persistence fields.
- Collapse duplicated session state kept in router objects, feature-store caches, and provider-local state.
- Narrow external ACP request inputs to the fields actually consumed by ACP providers.
- Replace expensive or overbroad persistence and logging patterns with focused implementations.

### Out of scope

- Rewriting ACP protocol models.
- Reworking the built-in Claude execution provider.
- UI redesign or product-level permission-flow changes.
- Introducing new external ACP providers.

## 3. Target Files

### Core production files

- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- Modify: `agentGui/Services/ACP/ACPSessionUpdateRouter.swift`
- Modify: `agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Modify: `agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `agentGui/Models/ACPExternalSessionBinding.swift`

### Primary tests

- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `agentGuiTests/ACPSessionRuntimeActorTests.swift`
- Modify: `agentGuiTests/ACPProviderRuntimeSupervisorTests.swift`
- Modify: `agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- Modify: `agentGuiTests/ACPExternalUpdateProjectorTests.swift`
- Modify: `agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

## 4. Desired End State

When this plan is complete:

- `ACPExternalExecutionProviderBase` is no longer the owner of provider-specific policy switches beyond a compact provider spec.
- Copilot and OpenCode providers differ by configuration resolution, launch configuration, availability service, and model-override policy only.
- One session-context object owns active-turn state, feature snapshots, current remote session id, and update gating state.
- The feature store no longer maintains two command caches for the same logical session view.
- `ACPExternalProviderFeatureAdapter` is either deleted or replaced with a concrete provider bootstrap data source that has real behavior.
- ACP request handling no longer drags built-in-agent-only fields through the external provider path.
- Binding lookups use focused fetches instead of reading the whole table.

## 5. Task Breakdown

### Task 1: Lock Current External ACP Behavior With Characterization Tests

**Files:**
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `agentGuiTests/ACPSessionRuntimeActorTests.swift`
- Modify: `agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`
- Modify: `agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`

**Step 1: Write the failing tests**

Add characterization coverage for the behaviors this refactor must preserve:

- provider reset removes runtime activation without losing persisted binding when reset is non-destructive
- feature updates remain available after bootstrap and after an empty replacement
- restore failure still falls back to `session/new`
- repeated send on same remote session does not trigger a second restore

Test skeleton to add:

```swift
@Test func externalProviderRetainsRemoteBindingAcrossInactiveRuntimeShutdown() async throws {
    let harness = try ExternalACPProviderHarness.make()
    try await harness.provider.prepareForActivation(
        session: harness.session,
        isActiveProvider: true,
        modelContext: harness.modelContext,
        trigger: .slashCommandWarmup
    )

    let storedBinding = try #require(harness.bindingStore.binding(for: harness.session.sessionId, providerID: harness.provider.id))
    #expect(!storedBinding.remoteSessionID.isEmpty)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPSessionRuntimeActorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the new characterization cases are not implemented yet.

**Step 3: Write the minimal implementation**

Only add helper scaffolding needed by the tests. Do not refactor production code in this task beyond exposing existing seams or fixing test harness setup.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPSessionRuntimeActorTests.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift
git commit -m "test: lock external acp lifecycle behavior"
```

### Task 2: Replace Inheritance-Heavy Provider Overrides With A Compact Provider Spec

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing tests**

Add tests proving the shared external ACP layer can derive behavior from a provider spec rather than subclass overrides:

- provider id remains correct
- selected model override policy differs correctly between Copilot and OpenCode
- unavailable errors still map to provider-specific error types

Test skeleton:

```swift
@Test func providerSpecControlsModelOverrideBehavior() async throws {
    let copilot = makeCopilotProvider()
    let openCode = makeOpenCodeProvider()

    #expect(copilot.debugSelectedModelOverride(defaultModel: "gpt-5", supportsSessionModelOverride: false) == "gpt-5")
    #expect(openCode.debugSelectedModelOverride(defaultModel: "gpt-5", supportsSessionModelOverride: false) == nil)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because no provider-spec seam exists.

**Step 3: Write minimal implementation**

Introduce a small provider-spec value owned by the base layer. It should cover only:

- configuration resolver
- availability checker
- unsupported or unavailable error mapping
- model override rule
- runtime client builder

Do not add a generic DSL. Keep it specific to the current two providers.

Suggested shape:

```swift
struct ACPExternalProviderSpec<Configuration> {
    let providerID: ConversationExecutionProviderID
    let resolveConfiguration: @MainActor (Session, AppSettings) -> Configuration
    let quickAvailabilityStatus: (Configuration) -> ACPCLIAvailabilityStatus
    let unavailableError: (String) -> Error
    let selectedModelOverride: (Configuration, ACPExternalAgentSessionHandshake) -> String?
}
```

**Step 4: Run tests to verify they pass**

Run the same `xcodebuild` command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "refactor: drive external acp providers from spec"
```

### Task 3: Collapse Session State Into A Single Context Owner

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- Modify: `agentGui/Services/ACP/ACPSessionUpdateRouter.swift`
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`
- Modify: `agentGuiTests/ACPExternalUpdateProjectorTests.swift`

**Step 1: Write the failing tests**

Add tests that assert one session context controls both update gating and turn phase:

- restore-phase updates are consumed for features but not projected into assistant output
- live-turn updates are projected immediately
- reset clears active-turn state, activation id, and pending update task together

Test skeleton:

```swift
@Test func sessionContextSeparatesRestoreFeatureConsumptionFromLiveProjection() async throws {
    let store = ACPExternalProviderSessionStateStore()
    let state = store.state(for: "session-1")

    state.beginRestore(activationID: RuntimeActivationID())
    #expect(state.shouldConsumeFeatureUpdate(for: state.activationID!) == true)
    #expect(state.shouldProjectIncomingUpdate(for: state.activationID!) == false)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPExternalUpdateProjectorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because phase logic is still split across separate router types.

**Step 3: Write minimal implementation**

Move phase and activation-aware gating into `SessionState` and delete or inline the logic from:

- `ACPExternalSessionTurnRouter`
- `ACPSessionUpdateRouter`

If a router file becomes a trivial wrapper, delete it and migrate callers in the same task.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift agentGui/Services/ACP/ACPSessionUpdateRouter.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift agentGuiTests/ACPExternalUpdateProjectorTests.swift
git commit -m "refactor: unify external acp session context state"
```

### Task 4: Remove Redundant Feature Bootstrap And Duplicate Command Caches

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGuiTests/ACPExternalSessionFeatureStoreTests.swift`

**Step 1: Write the failing tests**

Add tests proving:

- empty provider bootstrap produces no synthetic commands
- commands are stored once per effective session context, not once by remote id and once by local id
- replacing commands with an empty list fully clears the visible command set

Test skeleton:

```swift
@Test func featureStoreExposesSingleCommandViewPerSessionContext() async throws {
    let store = ACPExternalSessionFeatureStore(taskStateStore: makeTaskStateStore())
    try store.apply([.replaceCommands(makeCommandSnapshot())], sessionID: "session-1")

    #expect(store.commands(for: "session-1", providerID: .openCodeCLI).map(\.name) == ["review"])
    #expect(store.debugCommandCacheCount == 1)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the feature store still maintains duplicated cache views.

**Step 3: Write minimal implementation**

- Delete `ACPExternalProviderFeatureAdapter` if it still only returns empty adapters.
- Remove `sessionCommandsCache` from the feature store.
- Let session state own the currently visible command snapshot.

If deleting the adapter causes compile fallout, replace it with a simple provider bootstrap enum or a static helper that has actual behavior.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalProviderFeatureAdapter.swift agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGuiTests/ACPExternalSessionFeatureStoreTests.swift
git commit -m "refactor: remove duplicate external acp command caches"
```

### Task 5: Remove Dead Persistence Surface And Narrow ACP Request Inputs

**Files:**
- Modify: `agentGui/Models/ACPExternalSessionBinding.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Modify: `agentGui/Services/ConversationExecutionProviderRegistry.swift`
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing tests**

Add tests for two constraints:

- external ACP binding persistence does not store `selectedAgentName` when no external provider reads it
- external ACP execution requests use only `text`, `session`, `modelContext`, `targetAgentMessageID`, and `workingDirectoryOverride`

Test skeleton:

```swift
@Test func externalBindingOmitsUnusedAgentNamePersistence() async throws {
    let binding = try upsertBinding(selectedAgentName: nil)
    #expect(binding.lastSelectedAgentName.isEmpty)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because request and binding surfaces are still broader than needed.

**Step 3: Write minimal implementation**

- Introduce an ACP-specific execution request view or helper instead of reading the whole `ConversationExecutionRequest` everywhere.
- Delete `lastSelectedAgentName` from `ACPExternalSessionBinding` only if no production code depends on it.
- If full model migration is too risky for this task, keep the persisted column but stop threading the parameter through the provider path and mark the field as legacy-only in code comments.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ACPExternalSessionBinding.swift agentGui/Services/ACP/ACPExternalSessionBindingStore.swift agentGui/Services/ConversationExecutionProviderRegistry.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "refactor: narrow external acp request and binding surface"
```

### Task 6: Keep Runtime Client Low-Level And Move Recovery Policy Upward

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `agentGui/Services/ACP/ACPSessionRuntimeActor.swift`
- Modify: `agentGuiTests/ACPExternalAgentRuntimeClientTests.swift`
- Modify: `agentGuiTests/ACPSessionRuntimeActorTests.swift`

**Step 1: Write the failing tests**

Add tests asserting:

- runtime client handles initialize, load, prompt, cancel, and close only
- actor owns fallback policy after load failure or initialize timeout
- provider-specific capability fallback is expressed by caller policy, not internal hidden switches

Test skeleton:

```swift
@Test func runtimeActorOwnsSessionRecoveryPolicy() async throws {
    let actor = makeActorWithRecoveringRuntimeSequence()
    let prepared = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/recovery")

    #expect(prepared.handshake.remoteSessionID == "remote-new")
    #expect(await actor.runtimeRebuildCount == 1)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ACPSessionRuntimeActorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because recovery decisions are still split across both layers.

**Step 3: Write minimal implementation**

- Strip provider-policy concerns out of `ACPExternalAgentRuntimeClient`.
- Keep timeouts and raw protocol operations there.
- Move the load-or-new-session decision into `ACPSessionRuntimeActor`.

Avoid changing the external transport client interface beyond what the tests need.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPSessionRuntimeActor.swift agentGuiTests/ACPExternalAgentRuntimeClientTests.swift agentGuiTests/ACPSessionRuntimeActorTests.swift
git commit -m "refactor: move external acp recovery policy into runtime actor"
```

### Task 7: Replace Broad Fetches And Unstructured Logging

**Files:**
- Modify: `agentGui/Services/ACP/ACPExternalSessionBindingStore.swift`
- Modify: `agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift`
- Modify: `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`
- Modify: `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift`
- Test: `agentGuiTests/ACPExternalExecutionProviderBaseTests.swift`

**Step 1: Write the failing tests**

Add tests for:

- binding lookup fetches the exact provider and session record
- debug logging can be disabled or injected without relying on `print`

Test skeleton:

```swift
@Test func bindingStoreFetchesTargetBindingOnly() async throws {
    let store = ACPExternalSessionBindingStore(modelContext: context)
    let binding = try #require(store.binding(for: "session-1", providerID: .githubCopilotCLI))
    #expect(binding.providerID == .githubCopilotCLI)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because the current binding store uses broad fetch-plus-filter behavior or logging is still hard-coded.

**Step 3: Write minimal implementation**

- Replace table-wide binding fetches with a focused `FetchDescriptor` predicate.
- Replace direct `print` calls in ACP orchestration and feature-store paths with one injected logger or `Logger` wrapper.

Do not rewrite every log site in the app. Limit the change to ACP files touched by this plan.

**Step 4: Run tests to verify they pass**

Run the same command again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ACP/ACPExternalSessionBindingStore.swift agentGui/Services/ACP/ACPExternalExecutionProviderBase.swift agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift agentGuiTests/ACPExternalExecutionProviderBaseTests.swift
git commit -m "refactor: tighten acp persistence and logging"
```

### Task 8: Full ACP Regression Sweep And Cleanup

**Files:**
- Modify: any touched files from Tasks 1-7 as needed
- Modify: `docs/plans/2026-03-23-acp-redundancy-reduction-implementation-plan.md` with final status notes if execution deviates

**Step 1: Run focused ACP tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests -only-testing:agentGuiTests/ACPSessionRuntimeActorTests -only-testing:agentGuiTests/ACPExternalSessionFeatureStoreTests -only-testing:agentGuiTests/ACPExternalUpdateProjectorTests -only-testing:agentGuiTests/ACPExternalAgentRuntimeClientTests -only-testing:agentGuiTests/ACPProviderRuntimeSupervisorTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 2: Run broader ACP smoke suite**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/ACPExternalSessionBindingStoreTests -only-testing:agentGuiTests/ACPExternalSessionFeatureExtractorTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

**Step 3: Clean up dead code**

Delete any now-unused helpers, imports, wrappers, or compatibility overloads introduced only for migration.

**Step 4: Commit**

```bash
git add agentGui docs/plans/2026-03-23-acp-redundancy-reduction-implementation-plan.md agentGuiTests
git commit -m "refactor: simplify external acp orchestration"
```

## 6. Risks And Guardrails

- **Risk:** session restore replay leaks into live-turn projection during refactor.
  **Guardrail:** keep characterization tests around restore-phase and live-phase event handling until the end.

- **Risk:** deleting persistence fields triggers SwiftData migration fallout.
  **Guardrail:** if migration becomes non-trivial, stop at parameter removal and mark the field legacy-only for a later schema cleanup.

- **Risk:** provider-spec extraction turns into a new abstraction layer with the same complexity.
  **Guardrail:** keep the spec as a data holder for exactly the differences between Copilot and OpenCode, nothing more.

- **Risk:** moving policy into the runtime actor breaks timeout handling.
  **Guardrail:** keep raw timeout primitives in `ACPExternalAgentRuntimeClient`; only move the recovery decision, not the low-level timing wrapper.

## 7. Definition Of Done

- Focused ACP tests pass.
- Copilot and OpenCode provider classes are visibly smaller and mostly declarative.
- `ACPExternalExecutionProviderBase` no longer contains a forest of provider-specific override points.
- One session-context state owner replaces separate turn-router and update-router phase state.
- The feature store exposes one command view per effective external ACP session.
- Dead or no-value abstraction points are deleted or isolated behind explicit legacy markers.

Plan complete and saved to `docs/plans/2026-03-23-acp-redundancy-reduction-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
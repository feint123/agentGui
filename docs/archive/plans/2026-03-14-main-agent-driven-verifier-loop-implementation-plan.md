# Main-Agent-Driven Verifier Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current host-invoked, final-only verifier flow with a main-agent-driven verification loop where the main agent decides when to call `run_subagent` with `verifier`, while the host runtime maintains verification frontier state and blocks unsafe completion.

**Architecture:** Keep `VerificationState` and the existing RMS projection pipeline, but remove host-direct verifier execution from `AgentLoopVerificationCoordinator`. Verification becomes a normal runtime behavior: the main agent chooses when to call `run_subagent`, verifier output flows back through ordinary tool execution, and the host only maintains frontier state, applies completion gates, and routes failed verification into reflection. This plan supersedes the verifier invocation parts of `docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, existing `run_subagent` tool path, existing `VerificationState` / `EpistemicState` / RMS UI pipeline.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 1. Design constraints

- Verification must no longer be triggered only after `.finalizing` as a host-owned tail step.
- The main agent must decide whether to call `run_subagent` with `agent_name: "verifier"`.
- The host runtime must retain final completion authority by checking `VerificationState` frontier and certificate state.
- `verifier.agent.md` remains a subagent definition, but host code must stop constructing verifier tasks and directly calling `runNamedSubagent`.
- `verify_completion` remains a self-report tool only; it cannot be treated as proof of completion.
- Existing `VerificationState`, RMS projection, and UI surfaces should be reused rather than replaced.

## 2. Target file set

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopPhaseOutcomeApplier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Prompting.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundExecutorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

### Optional docs update

- `/Volumes/T7/文稿/Projects/agentGui/docs/verify-capability-research-2026-03-14.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`

## 3. Task breakdown

### Task 1: Lock the new verification ownership model with failing tests

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundExecutorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

**Step 1: Write failing integration tests that express the new contract**

Add or replace tests with these expectations:

1. The host runtime must not auto-launch the verifier subagent after `end_turn`.
2. If completion is claimed but no verifier result or equivalent frontier closure exists, the loop must re-enter `.executing` with a verification obligation.
3. If the main agent explicitly calls `run_subagent` with `agent_name: "verifier"`, the returned JSON must update `VerificationState` and may unlock completion.

Example test shape for `AgentLoopIntegrationTests.swift`:

```swift
@Test func runCoreAgentLoopDoesNotHostInvokeVerifierAfterEndTurn() async throws {
    let claudeService = ClaudeService()
    let modelContext = try makeModelContext()
    let service = SequencedFakeAnthropicService(streamBatches: [
        [
            decodeStreamEvent("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete"}}
            """),
            decodeStreamEvent("""
            {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
            """)
        ]
    ])

    var messages: [MessageParameter.Message] = [
        .init(role: .user, content: .text("finish with proof"))
    ]

    let result = try await claudeService.runCoreAgentLoop(
        messages: &messages,
        service: service,
        modelId: "claude-test",
        tools: [],
        system: nil,
        settings: .testFixture(),
        sessionId: "session-no-host-verifier",
        modelContext: modelContext,
        maxRounds: 2,
        makeRound: { AgentRound(roundIndex: $0) },
        parentMessage: nil,
        streamProjectionTarget: .none
    )

    let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())

    #expect(!result.completedSuccessfully)
    #expect(!toolCalls.contains(where: { $0.subagentAgentName == "verifier" }))
}
```

**Step 2: Write failing reducer/coordinator tests for pure host-side verification state updates**

Update `AgentLoopVerificationCoordinatorTests.swift` so the coordinator is tested as a parser/reducer instead of a subagent launcher.

Add tests for:

- `buildVerificationState` from verifier payload + existing evidence
- `buildCertificate` without invoking Anthropic service
- fallback behavior when a verifier payload is missing or malformed

Example assertion:

```swift
@Test func verificationCoordinatorBuildsCertificateWithoutLaunchingVerifier() {
    let payload = VerifierPayload(
        frontierRanking: [],
        missingEvidence: [],
        residualRisks: [],
        recommendedNextAction: "finish"
    )

    let state = AgentLoopVerificationCoordinator.buildVerificationStateForTests(
        payload: payload,
        verification: CompletionVerification(verified: ["swift test passed"], notVerified: []),
        executionEvidence: [.bash],
        fallbackSummary: "ok"
    )

    #expect(state.certificate?.decision == .pass)
}
```

**Step 3: Write failing phase/outcome tests for the new gate behavior**

In `AgentLoopPhaseOutcomeApplierTests.swift`, add a test that proves `.finalizing` no longer transitions directly to `.verifying`.

Expected replacement behavior:

- when verification is unresolved, phase becomes `.executing`
- a verification obligation user message is inserted

**Step 4: Write failing tool execution tests for verifier-as-normal-subagent flow**

In `AgentLoopToolExecutionCoordinatorTests.swift`, add a test asserting that a `run_subagent` result with `agent_name == "verifier"` is treated like any other subagent call and not special-cased at dispatch time.

**Step 5: Run the focused tests to confirm failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopRoundExecutorTests \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests
```

Expected: FAIL because the current implementation still auto-launches the verifier after `finalizing`.

**Step 6: Commit**

```bash
git add agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift agentGuiTests/AgentLoopRoundExecutorTests.swift agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift
git commit -m "test: lock main-agent-driven verifier ownership"
```

### Task 2: Remove the host-direct verifier launch path from `AgentLoopVerificationCoordinator`

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`

**Step 1: Write a failing unit test for pure coordinator behavior**

Add a test proving the coordinator can build `VerificationState` and `ConvergenceCertificate` without `ClaudeService`, `AnthropicService`, or `runNamedSubagent`.

**Step 2: Run the focused coordinator tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests
```

Expected: FAIL because the coordinator still requires subagent execution dependencies.

**Step 3: Write minimal implementation**

Refactor `AgentLoopVerificationCoordinator` into a pure host-side state builder.

Delete or deprecate these responsibilities:

- `makeVerifierTask(...)`
- creation of a `run_subagent` `ToolCall`
- direct call to `claudeService.runNamedSubagent(...)`
- all business events whose purpose is to represent host-launched verifier execution

Keep and expose these responsibilities:

- `parseVerifierPayload(...)`
- `buildClaims(...)`
- `buildEvidence(...)`
- `buildFrontier(...)`
- `buildVerificationState(...)`
- `buildCertificate(...)`
- `verificationAssessmentUpdate(...)`

The result type should become something close to:

```swift
struct AgentLoopVerificationReduction: Equatable {
    let report: CompletionVerification
    let verificationState: VerificationState
    let failureTrigger: FailureTrigger?
}
```

The reduction must accept an already-available verifier payload instead of invoking the verifier itself.

**Step 4: Run the coordinator tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopVerificationCoordinator.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift
git commit -m "refactor: make verification coordinator host-side reducer only"
```

### Task 3: Change the finalization gate from `host verify now` to `re-open execution with a verification obligation`

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopPhaseOutcomeApplier.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundExecutorTests.swift`

**Step 1: Write the failing tests**

Add tests for these rules:

1. `.finalizing` does not auto-transition to `.verifying`.
2. If verification frontier is unresolved, the host inserts a user-visible verification obligation and returns to `.executing`.
3. If a pass certificate already exists, `.finalizing` is allowed to finish.

Example test shape:

```swift
@Test func finalizationReopensExecutionWhenVerificationFrontierIsStillOpen() {
    var loopContext = AgentLoopContext()
    loopContext.phase = .finalizing
    var messages: [MessageParameter.Message] = []

    let outcome = AgentLoopPhaseOutcomeApplier.apply(
        phase: .finalizing,
        loopContext: &loopContext,
        messages: &messages,
        accumulatedText: "candidate complete",
        accumulatedTextBeforeRound: "",
        currentRoundText: "candidate complete",
        assistantObjects: [],
        reflectionEnabled: true,
        verificationEnabled: true,
        verificationResolution: .needsMoreEvidence(
            openClaims: ["Need direct runtime proof"],
            suggestedProbe: "Call run_subagent verifier before finishing"
        )
    )

    #expect(loopContext.phase == .executing)
    #expect(messages.contains { ClaudeService().extractText(from: $0.content).contains("Call run_subagent") })
}
```

**Step 2: Run the focused tests to confirm failure**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopRoundExecutorTests
```

Expected: FAIL because `.finalizing` currently transitions into `.verifying`.

**Step 3: Write minimal implementation**

Make these structural changes:

1. In `AgentLoopPhaseOutcomeApplier`, remove the `finalizing -> verifying` transition.
2. Add a new host-side verification resolution input, for example:

```swift
enum VerificationGateResolution: Equatable {
    case clearToFinish
    case needsMoreEvidence(openClaims: [String], suggestedProbe: String?)
}
```

3. In `AgentLoopRoundExecutor.applyFinalization`, compute gate resolution from the current `VerificationState`.
4. If the gate says `needsMoreEvidence`, append a user message such as:

```text
Before you finish, verification is still open:
- Need direct runtime proof
Suggested next step: Call run_subagent with verifier or gather equivalent direct evidence.
```

5. Transition back to `.executing` instead of `.verifying`.

Do not delete `.verifying` in this task unless it becomes fully unused; it may still be cleaned up later.

**Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AgentLoopPhase.swift agentGui/Services/AgentLoopPhaseOutcomeApplier.swift agentGui/Services/AgentLoopRoundExecutor.swift agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift agentGuiTests/AgentLoopRoundExecutorTests.swift
git commit -m "feat: reopen execution instead of host-running verifier at finalization"
```

### Task 4: Route verifier output through the normal `run_subagent` tool result path

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing tests**

Lock these behaviors:

1. `run_subagent` with `agent_name == "verifier"` is executed by the same coordinator path as any other subagent.
2. When the verifier subagent returns JSON, `AgentLoopRoundExecutor.applyToolResults` parses it and updates `state.verificationState`.
3. `sharedState.writeVerification(...)` is called from tool result handling, not from a special final verification phase.

Example assertion:

```swift
@Test func verifierRunSubagentResultUpdatesVerificationStateDuringToolProcessing() async throws {
    var state = AgentLoopRunState()
    let verifierMessage = AgentMessage.detecting(
        text: "{\"frontier_ranking\":[],\"missing_evidence\":[],\"residual_risks\":[],\"recommended_next_action\":\"finish\"}",
        sender: "verifier",
        metadata: [:]
    )

    // Build pending tool + fake result plumbing, then assert
    // state.verificationState?.certificate?.decision == .pass
}
```

**Step 2: Run the focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL because verifier results are not yet reduced during normal tool processing.

**Step 3: Write minimal implementation**

Implement the new path in three parts:

1. Keep `AgentLoopToolExecutionCoordinator` generic. It should continue to treat `run_subagent` uniformly.
2. In `ClaudeService+Subagent`, ensure verifier subagent metadata remains available on the resulting `ToolCall`.
3. In `AgentLoopRoundExecutor.applyToolResults`, detect:

```swift
if pending.name == "run_subagent", record.subagentAgentName == "verifier" {
    // parse result.text
    // reduce into VerificationState
    // update shared state + failure trigger + epistemic envelope
}
```

Use the refactored `AgentLoopVerificationCoordinator` from Task 2 as a pure reducer here.

Write back:

- `state.verificationState`
- `state.hookState.verificationState`
- `sharedState.writeVerification(...)`
- `state.loopCtx.pendingFailureTrigger` when appropriate

**Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGui/Services/AgentLoopRoundExecutor.swift agentGui/Services/ClaudeService+Subagent.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: process verifier results through normal run_subagent flow"
```

### Task 5: Rewrite prompting and tool guidance so the main agent actively decides when to verify

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Prompting.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing tests**

Add assertions that the system prompt and tool description no longer claim the host will automatically run verifier before finish.

Suggested expectations:

- prompt text tells the main agent to proactively close verification frontier
- `run_subagent` description presents `verifier` as a normal specialist agent
- verifier instructions continue to output JSON only

**Step 2: Run the focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL until prompt contract changes are reflected in behavior or string assertions.

**Step 3: Write minimal implementation**

Update `ClaudeService+Prompting.swift` so the verify section says:

1. the host tracks verification frontier and may block unsafe completion
2. the main agent must actively gather proof for high-impact claims
3. the main agent may use `run_subagent` with `agent_name: "verifier"` as a final quality gate
4. `verify_completion` is a self-report tool only

Update `ToolRegistry.swift` so `run_subagent` describes `verifier` as:

- a specialist used when the main agent wants evidence review, frontier ranking, and residual risk analysis

Keep `verifier.agent.md` as a true subagent definition, but remove any phrasing that implies the host itself invokes it.

**Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+Prompting.swift agentGui/Services/ToolRegistry.swift agentGui/Resources/Agents/verifier.agent.md agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: instruct main agent to drive verifier subagent usage"
```

### Task 6: Keep reflection and RMS projection aligned with tool-driven verification updates

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateReducer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing tests**

Add tests that prove:

1. reflection still receives structured verification state when verifier results come through `run_subagent`
2. verifier-derived frontier, debt, residual risks, and recommended next action continue to project into RMS / detail presentation

**Step 2: Run the focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL if the state update timing no longer reaches reflection and RMS projection.

**Step 3: Write minimal implementation**

Ensure that the tool-result-driven verification update path preserves existing downstream behavior:

- `ClaudeService+Reflection` still receives the latest `verificationState`
- `EpistemicStateReducer` still receives the same semantic events
- `ToolCallDetailContentView` keeps rendering verifier metadata from subagent output

The key rule is timing: these updates must happen during tool processing, before the next reflection/finalization decision.

**Step 4: Run the tests to verify they pass**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+Reflection.swift agentGui/Services/EpistemicStateReducer.swift agentGuiTests/ToolCallDetailPresentationTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: preserve reflection and rms projection for tool-driven verifier state"
```

### Task 7: Full regression, smoke validation, and plan handoff cleanup

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-14-main-agent-driven-verifier-loop-implementation-plan.md`
- Optional Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`

**Step 1: Run the targeted regression slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopRoundExecutorTests \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: PASS.

**Step 2: Run repository smoke validation**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS, or only pre-existing failures with no new verify-related regressions.

**Step 3: Update this plan with any execution-time deviations**

Record any differences discovered during implementation, such as renamed test targets, changed file ownership, or removed dead phases.

**Step 4: Mark the older verifier plan as partially superseded**

If appropriate, add a short note near the top of:

- `docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`

stating that verifier invocation ownership has moved to the main-agent-driven plan.

**Step 5: Commit**

```bash
git add docs/plans/2026-03-14-main-agent-driven-verifier-loop-implementation-plan.md docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md
git commit -m "docs: finalize main-agent-driven verifier loop plan"
```

## 4. Implementation notes

- Do not start by deleting `.verifying` from `AgentLoopPhase`. First remove the host-direct path and prove the new gate works; only then decide whether `.verifying` is dead code.
- Keep the main agent in control of subagent choice, but do not weaken host completion safety. The host still owns the final `pass / revise / fail / abstain` gate.
- Do not move verifier parsing into `ClaudeService+Subagent`; keep that file generic. Verifier-specific reduction belongs in loop orchestration.
- Do not let `verify_completion` become mandatory. It remains a structured self-report, not proof.
- Reuse existing `VerificationState`, RMS UI, and reflection context rather than introducing a second verification model.

## 5. Acceptance criteria

- The host runtime no longer calls `runNamedSubagent("verifier", ...)` directly.
- Verification is no longer only a final-afterthought phase; unresolved verification reopens execution with explicit obligations.
- The main agent can call `run_subagent` with `verifier` like any other specialist agent.
- Verifier JSON results flow through normal tool execution and update `VerificationState` in-band.
- The host still blocks unsafe completion when high-impact frontier items remain unresolved.
- Reflection and RMS surfaces continue to receive structured verification context.

Plan complete and saved to `docs/plans/2026-03-14-main-agent-driven-verifier-loop-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
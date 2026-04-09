# Agent-First Verify Capability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the current verify flow from a terminal verifier verdict into an agent-first verification control loop that maintains structured claim/evidence/frontier state, drives repair and stop decisions, and feeds the existing RMS epistemic UI.

**Architecture:** Keep the existing main loop skeleton centered on `AgentLoopRunner`, `AgentLoopRoundExecutor`, and `AgentLoopVerificationCoordinator`, but promote verification from a flat report into a first-class `VerificationState`. Reuse the existing `CompletionVerification`, `EpistemicState`, and RMS rendering pipeline instead of creating a second cognitive state system: `VerificationState` becomes the host-side control state, and high-value slices of it are projected into `EpistemicState` for bootstrap, reflection, and UI.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, existing main agent loop, existing verifier subagent, existing RMS / EpistemicState pipeline.

---

## 1. Design constraints

- This is an incremental evolution of the existing `verifying` phase, not a rewrite of the whole agent loop.
- `verify_completion` stays as the main agent's self-report tool, but it must no longer be treated as the final truth source.
- The host runtime owns verification decisions. The `verifier` subagent becomes a specialist backend, not the sole authority.
- Do not invent a parallel memory UI. Project verification frontier, debt, and residual risk into the existing RMS cognition surfaces.
- Preserve backward compatibility for persisted verification data so older sessions still decode.
- Keep the existing run entry points intact:
  - `ClaudeService.runAgenticLoop(...)`
  - `AgentLoopRunner.run(...)`
  - `ClaudeService.executeVerifyCompletion(...)`

## 2. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/VerificationState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VerificationStateTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunState.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDependencyFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSCognitionPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/EpistemicStateCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/EpistemicStateTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

---

## 3. Task breakdown

### Task 1: Lock the new agent-first verification behavior with failing tests

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VerificationStateTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/EpistemicStateCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

**Step 1: Write a failing model test for backward-compatible verification decoding**

Add a test proving older `CompletionVerification` payloads decode even when `verificationState` is absent.

```swift
@Test func completionVerificationDecodesLegacyPayloadWithoutVerificationState() throws {
    let data = Data(#"""
    {
      "verified": ["unit tests passed"],
      "notVerified": [],
      "conclusion": "looks good"
    }
    """#.utf8)

    let decoded = try JSONDecoder().decode(CompletionVerification.self, from: data)

    #expect(decoded.verified == ["unit tests passed"])
    #expect(decoded.verificationState == nil)
}
```

**Step 2: Write a failing coordinator test for frontier prioritization and certificate output**

Extend `AgentLoopVerificationCoordinatorTests` with a test that asserts the coordinator produces a high-impact frontier for unverified execution claims and does not return a passing certificate.

```swift
@Test func verificationBuildsFrontierForExecutionClaimWithoutDirectEvidence() async throws {
    let outcome = try await coordinator.verify(
        currentAnswer: "I fixed the issue and all targeted tests passed.",
        executionEvidence: [],
        existingVerification: .init(
            verified: ["targeted tests passed"],
            notVerified: [],
            conclusion: "done"
        ),
        latestFailureTrigger: nil
    )

    #expect(outcome.verificationState.frontier.contains { $0.claimType == .execution })
    #expect(outcome.verificationState.certificate?.decision != .pass)
}
```

**Step 3: Write a failing integration test for host-owned stop semantics**

Extend `AgentLoopIntegrationTests` so one test proves the main loop does not finish only because the verifier says `passed`; it finishes only after the host sees an empty high-impact frontier or a low enough expected value of more verification.

Assert at minimum:

- `result.completedSuccessfully == true`
- persisted verification contains a non-`nil` `certificate`
- `certificate.decision == .pass`
- `certificate.openClaims.isEmpty`

**Step 4: Write a failing epistemic projection test**

Extend `EpistemicStateCoordinatorTests` with one test proving verification frontiers and debt are projected into `EpistemicState`.

```swift
@Test func verificationEnvelopeProducesFrontierAndDebt() async throws {
    let envelope = EpistemicInputEnvelope(
        sessionId: "s-1",
        roundIndex: 3,
        userAgentMessages: ["Verification failed because no test evidence exists"],
        toolObservations: ["open_claim: regression tests still unverified"],
        events: [
            AtomicEpistemicEvent(kind: .claimRaised, summary: "Regression tests are still unverified", sourceRefs: ["verification:s-1:3"])
        ]
    )

    let result = try await EpistemicStateCoordinator.fallbackOnly().buildState(from: [envelope])

    #expect(!result.state.frontiers.isEmpty)
    #expect(!result.state.verificationDebt.isEmpty)
}
```

**Step 5: Write a failing detail-presentation test**

Extend `ToolCallDetailPresentationTests` so verifier tool details must show residual risk and the next recommended probe when present.

**Step 6: Run the focused failing suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/VerificationStateTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: FAIL because `VerificationState`, convergence certificate semantics, and RMS projection do not exist yet.

**Step 7: Commit**

```bash
git add agentGuiTests/VerificationStateTests.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/EpistemicStateCoordinatorTests.swift agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "test: lock agent-first verification behavior"
```

### Task 2: Introduce `VerificationState` and persist it beside the self-report record

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/VerificationState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopRunState.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VerificationStateTests.swift`

**Step 1: Define the host-owned verification data model**

Create `VerificationState.swift` with a minimal, explicit model.

```swift
enum VerificationDecision: String, Codable, Equatable, Sendable {
    case pass
    case revise
    case fail
    case abstain
}

enum VerificationClaimType: String, Codable, Equatable, Sendable {
    case execution
    case fileState
    case behavioral
    case factual
    case coverage
    case policy
    case citation
}

struct VerificationClaim: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var claimType: VerificationClaimType
    var importance: Double
    var verifiability: Double
    var status: ClaimStatus
    var evidenceRefs: [String]
}

struct VerificationEvidence: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var source: String
    var summary: String
    var strength: Double
    var sourceRefs: [String]
}

struct VerificationFrontierItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var claimID: String
    var claimType: VerificationClaimType
    var openQuestion: String
    var recommendedProbe: String
    var riskScore: Double
}

struct ConvergenceCertificate: Codable, Equatable, Sendable {
    var decision: VerificationDecision
    var supportedClaims: [String]
    var contradictedClaims: [String]
    var openClaims: [String]
    var residualRisks: [String]
    var expectedValueOfMoreVerification: Double
    var stopReason: String
}

struct VerificationState: Codable, Equatable, Sendable {
    var riskScore: Double
    var claims: [VerificationClaim]
    var evidence: [VerificationEvidence]
    var frontier: [VerificationFrontierItem]
    var repairQueue: [String]
    var openQuestions: [String]
    var certificate: ConvergenceCertificate?
}
```

Rules:

- Keep the first version small. Do not add graphs or recursive node trees until the flat representation is insufficient.
- Prefer stable IDs based on round + normalized claim text so UI diffing remains deterministic.

**Step 2: Attach `VerificationState` to `CompletionVerification`**

Extend `CompletionVerification` with one optional field:

```swift
var verificationState: VerificationState?
```

Keep all existing fields so current UI and persisted JSON stay valid.

**Step 3: Carry verification state inside the run state**

Extend `AgentLoopRunState` with one field:

```swift
var verificationState: VerificationState?
```

This lets reflection, verification, and final result assembly access the same host-owned state without rereading storage on every branch.

**Step 4: Run the model tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/VerificationStateTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/VerificationState.swift agentGui/Models/ExecutionPlan.swift agentGui/Models/AgentLoopRunState.swift agentGuiTests/VerificationStateTests.swift
git commit -m "feat: add persisted verification state model"
```

### Task 3: Refactor `AgentLoopVerificationCoordinator` into a verification control loop

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Upgrade `AgentLoopVerificationOutcome` to carry structured state**

Refactor the outcome shape to include decision semantics and the generated verification state.

```swift
struct AgentLoopVerificationOutcome: Equatable {
    let decision: VerificationDecision
    let passed: Bool
    let report: CompletionVerification
    let verificationState: VerificationState
    let failureTrigger: FailureTrigger?
}
```

**Step 2: Split verification into explicit host-side phases inside the coordinator**

Refactor `verify(...)` into private helpers in this order:

1. `decomposeClaims(...)`
2. `collectEvidence(...)`
3. `rankFrontier(...)`
4. `runVerifierIfNeeded(...)`
5. `buildCertificate(...)`

The first version should remain heuristic-heavy. Do not wait for an LLM-only decomposition pipeline.

Suggested heuristics:

- If a claim contains words like `passed`, `ran`, `built`, `executed`, mark it as `.execution`.
- If a claim names files or changes on disk, mark it as `.fileState`.
- If a claim references requirements coverage, mark it as `.coverage`.
- Any claim with no direct tool, diff, or file-read support starts with higher uncertainty.

**Step 3: Restrict the `verifier` subagent to specialist duties**

Rewrite `verifier.agent.md` so the subagent no longer decides the final answer alone. Its job becomes:

- rank the most critical unresolved claims
- identify missing evidence
- propose the next cheapest high-value probe
- summarize residual risk

It should still return JSON only, but the host runtime computes the final `ConvergenceCertificate`.

Suggested output contract:

```json
{
  "frontier_ranking": [
    {
      "claim_id": "claim-1",
      "reason": "No direct execution evidence exists",
      "recommended_probe": "inspect targeted test invocation"
    }
  ],
  "missing_evidence": ["No focused test result was observed"],
  "residual_risks": ["Behavioral regression remains untested"],
  "recommended_next_action": "retry_execution"
}
```

**Step 4: Let the host runtime own pass / revise / fail / abstain**

Inside `AgentLoopRoundExecutor.executeVerification(...)`:

- write `verificationOutcome.verificationState` into `state.verificationState`
- persist it through `CompletionVerification.verificationState`
- route `.pass` back to normal completion
- route `.revise` and `.fail` into reflection via `FailureTrigger.verificationFailure(...)`
- treat `.abstain` as non-passing and surface explicit missing evidence

**Step 5: Run the coordinator and integration suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Services/AgentLoopVerificationCoordinator.swift agentGui/Services/AgentLoopRoundExecutor.swift agentGui/Resources/Agents/verifier.agent.md agentGuiTests/AgentLoopVerificationCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: turn verification into host-owned control loop"
```

### Task 4: Feed `VerificationState` into reflection and the RMS epistemic pipeline

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Reflection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/EpistemicStateReducer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/EpistemicStateCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/EpistemicStateTests.swift`

**Step 1: Extend reflection input to consume structured verification context**

Change `reflectOnRound(...)` to accept an optional `verificationState`.

```swift
func reflectOnRound(
    messages: [MessageParameter.Message],
    service: any AnthropicService,
    modelId: String,
    settings: AppSettings,
    failureTrigger: FailureTrigger? = nil,
    verificationState: VerificationState? = nil
) async -> Reflection?
```

Append a compact structured section to the reflection prompt containing:

- contradicted claims
- open claims
- missing evidence
- repair queue
- certificate stop reason, if one exists

**Step 2: Pass verification state from the hook dependency factory into reflection**

When `resolveReflection(...)` calls `claudeService.reflectOnRound(...)`, pass the latest `state.verificationState`.

**Step 3: Emit richer epistemic events from verification**

Inside `executeVerification(...)`, replace the current single `claimResolved` event with a small event set derived from the verification state.

Example mapping:

- frontier item -> `.claimRaised`
- contradicted claim -> `.counterexampleFound`
- missing evidence -> `.verificationDebtIntroduced`
- recommended probe -> `.actionRecommended`

If the existing `AtomicEpistemicEvent.Kind` enum lacks these exact cases, add the smallest compatible expansion necessary and update tests.

**Step 4: Project verification data into `EpistemicState` rather than duplicating UI-specific data**

Update the reducer so verification-derived events populate:

- `frontiers`
- `verificationDebt`
- `candidateActions`
- `counterexamples`
- `residualRisk`
- `expectedValueOfMoreReasoning`

Do not add a second `verificationFrontier` array to `EpistemicState`; reuse the existing surface.

**Step 5: Run the epistemic-focused suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests \
  -only-testing:agentGuiTests/EpistemicStateTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Services/ClaudeService+Reflection.swift agentGui/Services/AgentLoopHookDependencyFactory.swift agentGui/Services/AgentLoopRoundExecutor.swift agentGui/Services/EpistemicStateCoordinator.swift agentGui/Services/EpistemicStateReducer.swift agentGuiTests/EpistemicStateCoordinatorTests.swift agentGuiTests/EpistemicStateTests.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift
git commit -m "feat: project verification state into reflection and epistemic runtime"
```

### Task 5: Surface the new verification control state in developer-facing UI

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/RMSCognitionPanel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

**Step 1: Add residual-risk and stop-signal exposure to the RMS panel view model**

Extend `RMSCognitionPanelViewModel.DeveloperDiagnostics` or add a small verification summary value object.

Suggested shape:

```swift
struct VerificationSummary: Equatable {
    let residualRisk: Double
    let expectedValueOfMoreReasoning: Double
    let frontierCount: Int
    let debtCount: Int
}
```

**Step 2: Add a compact verification summary block to `RMSCognitionPanel`**

Show at minimum:

- residual risk
- frontier count
- verification debt count
- expected value of more verification

Keep this above the existing frontiers list so the stop condition is visible before the raw details.

**Step 3: Expand verifier tool detail rendering**

In `ToolCallDetailContentView`, add sections for:

- residual risk
- recommended next probe
- open claims count
- contradicted claims count

Prefer concise labels over dumping the full JSON payload.

**Step 4: Run the UI-presentation tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGui/Views/Memory/RMSCognitionPanel.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "feat: expose verification control state in rms ui"
```

### Task 6: Run the full verification regression slice and repo smoke checks

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`

**Step 1: Run the full targeted regression slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/VerificationStateTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/EpistemicStateTests \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: PASS.

**Step 2: Run the repo smoke script**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 3: Update this plan with any command deviations discovered during execution**

If any test targets or scripts differ from the assumptions above, edit this plan so the next executor does not rediscover them.

**Step 4: Commit**

```bash
git add docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md
git commit -m "docs: finalize agent-first verify capability plan"
```

## 4. Implementation notes

- Favor host-side heuristics before adding more model calls. Claim typing and frontier scoring do not need to be LLM-generated in V1.
- Reuse the existing RMS pipeline aggressively. The repository already has `EpistemicState`, `FrontierMemory`, `VerificationDebt`, and RMS views; the fastest correct path is to feed them better data.
- Keep the first convergence rule simple:
  - pass when no critical/high-impact frontier remains and `expectedValueOfMoreVerification` is below threshold
  - revise when concrete repair steps exist
  - fail when contradiction is blocking and no repair is available
  - abstain when the answer may be correct but required evidence is unavailable
- Do not widen the `verifier` tool permissions during this work. If it needs shell or web for evidence gathering, keep the host runtime in control of when those probes happen.

## 5. Acceptance criteria

- The persisted verification record contains a structured `verificationState` with certificate information.
- The host runtime, not the subagent, decides whether verification passes.
- Verification failures reach reflection with structured context, not only a flat summary string.
- RMS cognition surfaces show frontiers, verification debt, and a compact residual-risk summary sourced from verification output.
- The focused regression slice and the repo smoke script pass.

## 6. Risks to watch

- If `VerificationState` duplicates too much of `EpistemicState`, the system will drift into two competing truth sources.
- If frontier scoring is too noisy, the host may over-trigger reflection and reduce task completion rate.
- If the verifier prompt still reads like a final judge instead of a specialist, the runtime contract will regress toward the old approval-flow behavior.
- If UI rendering dumps raw verification JSON, the developer signal quality will get worse rather than better.

Plan complete and saved to `docs/plans/2026-03-14-agent-first-verify-capability-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
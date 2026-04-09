# RMS Phase 1-3 Gap Closure Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 补齐 RMS 当前最关键的三段缺口：Phase 1 的 decision-delta admission、Phase 2 的强语义 negative memory / tactic kernel distillation、Phase 3 的 decision-impact retrieval planner。

**Architecture:** 采用原位重写，直接替换当前过时的 admission、distillation 和 retrieval 语义，不保留旧的 relevance-only、summary-only、layer-first 双轨逻辑。保留 unified store、background scheduler 和 agent loop 这些基础设施，但在触及的代码路径内同步删除过时字段、旧解释文案、兼容分支和无效测试，确保最终只剩一套 RMS 主语义。

**Tech Stack:** Swift 6、SwiftData、Swift Testing、SwiftAnthropic、现有 MemoryRuntimeCoordinator / MemoryGovernanceService / MemoryBackgroundScheduler、`xcodebuild`、`./scripts/run_quality_smoke.sh`。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## Scope

本计划只覆盖以下三段缺口：

1. Phase 1：大体完成，但缺真正的 `decision-delta admission`
2. Phase 2：部分完成，已有 jobs，但 `negative memory` 和 `tactic kernel` 还不够“强语义”
3. Phase 3：明显未完成，planner 还不是 `decision-impact planner`

不包含以下内容：

1. Phase 4 的 verify / reflection / memory 单一 `EpistemicState` 统一主链
2. 新存储后端、向量索引或图数据库

但本计划明确包含：在 Phase 1-3 涉及到的 admission、distillation、planner 范围内，直接删除旧语义与兼容逻辑，而不是继续并存。

## Success Criteria

完成后必须满足：

1. admission 层显式执行 `Decision Delta Test`、`Transfer Test`、`Evidence Test`、`Decay Test`
2. counterexample / tactic kernel / invalidation 的后台 job 产出强语义对象，而不是只有字符串摘要
3. retrieval planner 根据 frontier 风险、counterexample 优先级和 decision impact 分配预算与排序
4. `MemoryInfluenceTrace` 能解释哪些记忆改变了动作排序、阻止了哪条错误路径
5. 触及范围内不再保留旧 relevance-only admission、summary-only distillation、layer-first retrieval 的双轨代码
6. 定向测试通过，且不引入新的 smoke failure

## Task 1: Add Explicit Decision-Delta Admission Gates

**Files:**
- Create: `agentGui/Models/MemoryDecisionImpactAssessment.swift`
- Create: `agentGui/Services/MemoryDecisionImpactEvaluator.swift`
- Modify: `agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- Modify: `agentGui/Services/MemoryAdmissionPolicy.swift`
- Modify: `agentGui/Services/MemoryGovernanceService.swift`
- Modify: `agentGui/Models/MemoryAdmissionExplanation.swift`
- Test: `agentGuiTests/MemoryAdmissionPolicyTests.swift`
- Test: `agentGuiTests/MemoryGovernanceServiceTests.swift`

**Step 1: Write the failing tests**

锁定 admission 新契约：候选记忆必须显式给出四道门判断结果，而不再只依赖原有 feature vector 总分。

```swift
@Test func admissionPolicyRejectsCandidateWithoutDecisionDelta() throws {
    let evaluator = MemoryDecisionImpactEvaluator()
    let assessment = evaluator.assess(
        candidate: .fixture(title: "Cosmetic repo fact", summary: "README has a subtitle"),
        request: .fixture(userRequest: "Fix failing build"),
        epistemicState: EpistemicState(frontiers: [
            FrontierMemory(
                frontierId: "f-1",
                goal: "Fix build",
                openClaim: "Need shared scheme evidence",
                uncertaintyType: .tooling,
                impactLevel: .high,
                suggestedProbe: "Run xcodebuild -list",
                stopCondition: "Scheme confirmed"
            )
        ])
    )

    #expect(assessment.decisionDelta.passes == false)
    #expect(assessment.transfer.passes == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryAdmissionPolicyTests \
  -only-testing:agentGuiTests/MemoryGovernanceServiceTests
```

Expected: FAIL because `MemoryDecisionImpactEvaluator` and the new gate fields do not exist.

**Step 3: Write minimal implementation**

新增显式 assessment 模型，至少包含：

```swift
struct MemoryDecisionImpactAssessment: Equatable, Sendable {
    var decisionDelta: MemoryAdmissionGateResult
    var transfer: MemoryAdmissionGateResult
    var evidence: MemoryAdmissionGateResult
    var decay: MemoryAdmissionGateResult
}
```

实现一版启发式 `MemoryDecisionImpactEvaluator`：

1. `decisionDelta`：判断是否改变工具选择、验证顺序、stop/go 判断、恢复路径
2. `transfer`：判断是否能跨相似任务复用，而不是只属于一次性上下文
3. `evidence`：判断是否存在 tool/file/review/test anchors
4. `decay`：判断是否高度依赖环境状态、时间性、局部配置

把结果写进 `MemoryAdmissionExplanation`，并让 `MemoryAdmissionPolicy` / `MemoryGovernanceService` 以 gate 结果作为主导，而不是只看累计分数。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryDecisionImpactAssessment.swift agentGui/Services/MemoryDecisionImpactEvaluator.swift agentGui/Services/MemoryAdmissionFeatureExtractor.swift agentGui/Services/MemoryAdmissionPolicy.swift agentGui/Services/MemoryGovernanceService.swift agentGui/Models/MemoryAdmissionExplanation.swift agentGuiTests/MemoryAdmissionPolicyTests.swift agentGuiTests/MemoryGovernanceServiceTests.swift
git commit -m "feat: add decision-delta memory admission gates"
```

## Task 2: Replace Legacy Admission Scoring Semantics In Place

**Files:**
- Modify or Delete: `agentGui/Models/MemoryAdmissionFeatureVector.swift`
- Modify or Delete: `agentGui/Models/MemoryAdmissionScore.swift`
- Modify: `agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- Modify: `agentGui/Services/MemoryAdmissionPolicy.swift`
- Test: `agentGuiTests/MemoryAdmissionPolicyTests.swift`

**Step 1: Write the failing test**

新增断言，要求 admission explanation 能直接暴露 `decisionDelta`、`transferability`、`evidenceStrength`、`decayRisk` 语义。

```swift
@Test func admissionExplanationUsesDecisionImpactFieldsWithoutLegacyScoringLanguage() throws {
    let explanation = try #require(policy.evaluate(candidate: candidate, request: request).explanation)
    #expect(explanation.reasons.contains { $0.contains("decision delta") })
    #expect(explanation.reasons.contains { $0.contains("transfer") })
    #expect(explanation.reasons.contains { $0.contains("evidence") })
    #expect(explanation.reasons.contains { $0.contains("futureUtility") } == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryAdmissionPolicyTests
```

Expected: FAIL because the explanation still reports old scoring semantics.

**Step 3: Write minimal implementation**

直接替换旧 admission scoring 语义：

1. 删除或重命名仍然强绑定旧 relevance/confidence 话语的字段与解释文案
2. 如果 `MemoryAdmissionScore` 仍保留，必须改成 gate-aware aggregate，不再作为旧语义别名存在
3. `MemoryAdmissionPolicy` 只保留 RMS gate 主导的准入逻辑，不再保留单独旧分数分支
4. 同步删除对应的旧测试断言和兼容分支

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryAdmissionFeatureVector.swift agentGui/Models/MemoryAdmissionScore.swift agentGui/Services/MemoryAdmissionFeatureExtractor.swift agentGui/Services/MemoryAdmissionPolicy.swift agentGuiTests/MemoryAdmissionPolicyTests.swift
git commit -m "refactor: replace legacy admission scoring with rms gate semantics"
```

## Task 3: Upgrade Counterexample Distillation to Strong-Semantic Negative Memory

**Files:**
- Modify: `agentGui/Services/CounterexampleDistillationService.swift`
- Modify: `agentGui/Models/MemoryCandidate.swift`
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `agentGui/Services/MemoryConsolidationEngine.swift`
- Test: `agentGuiTests/MemoryConsolidationEngineTests.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing tests**

锁定 counterexample 产出必须带“被推翻的假设 / 证据 / 替代动作 / 上下文指纹”，而不是只有一条 summary。

```swift
@Test func counterexampleDistillationProducesNegativeMemoryWithReplacementAction() throws {
    let candidates = CounterexampleDistillationService().distill(from: outcome)
    let candidate = try #require(candidates.first)
    #expect(candidate.tags.contains("counterexample"))
    #expect(candidate.tags.contains("anti-pattern"))
    if case let .structured(fields) = candidate.payload {
        #expect(fields["falsified_assumption"]?.isEmpty == false)
        #expect(fields["replacement_action"]?.isEmpty == false)
        #expect(fields["context_fingerprint"]?.isEmpty == false)
    } else {
        Issue.record("Expected structured counterexample payload")
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryConsolidationEngineTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because counterexample distillation still emits text-only summaries.

**Step 3: Write minimal implementation**

让 `CounterexampleDistillationService` 产出结构化 negative memory：

1. `falsified_assumption`
2. `contradicting_evidence`
3. `replacement_action`
4. `context_fingerprint`
5. `failure_mode`

同时新增 tag：

1. `counterexample`
2. `anti-pattern`
3. `invalidated-procedure`（条件满足时）

同时删除旧的 text-only summary fallback，不再让 counterexample 以弱语义字符串形式落地。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/CounterexampleDistillationService.swift agentGui/Models/MemoryCandidate.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Services/MemoryConsolidationEngine.swift agentGuiTests/MemoryConsolidationEngineTests.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: distill strong-semantic negative memory candidates"
```

## Task 4: Upgrade Tactic Kernel Distillation to Applicability-Aware Kernels

**Files:**
- Create: `agentGui/Models/TacticKernelDescriptor.swift`
- Modify: `agentGui/Services/TacticKernelDistillationService.swift`
- Modify: `agentGui/Models/MemoryCandidate.swift`
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Test: `agentGuiTests/MemoryConsolidationEngineTests.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing tests**

锁定 tactic kernel 必须携带 applicability / failure / verification / exit 信息。

```swift
@Test func tacticKernelDistillationProducesApplicabilityAwareKernel() throws {
    let candidates = TacticKernelDistillationService().distill(from: outcome)
    let candidate = try #require(candidates.first)
    if case let .structured(fields) = candidate.payload {
        #expect(fields["applicable_precondition"]?.isEmpty == false)
        #expect(fields["preferred_action_sequence"]?.isEmpty == false)
        #expect(fields["failure_signals"]?.isEmpty == false)
        #expect(fields["verification_path"]?.isEmpty == false)
        #expect(fields["exit_condition"]?.isEmpty == false)
    } else {
        Issue.record("Expected structured tactic kernel payload")
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryConsolidationEngineTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because tactic kernel distillation still collapses to a concatenated fact summary.

**Step 3: Write minimal implementation**

实现 `TacticKernelDescriptor`，并让 distiller 在成功闭环或复现 episode 上构造：

1. `applicable_precondition`
2. `preferred_action_sequence`
3. `failure_signals`
4. `verification_path`
5. `exit_condition`

同时要求只有满足 evidence anchor / repeated success 门槛时才产出 kernel，并删除旧的“verified facts join 成 summary 就算 tactic kernel”的实现。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TacticKernelDescriptor.swift agentGui/Services/TacticKernelDistillationService.swift agentGui/Models/MemoryCandidate.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGuiTests/MemoryConsolidationEngineTests.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: distill applicability-aware tactic kernels"
```

## Task 5: Strengthen Memory Invalidation Beyond Failed-ID Lists

**Files:**
- Modify: `agentGui/Services/MemoryInvalidationService.swift`
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `agentGui/Models/MemoryRecord.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing tests**

锁定 invalidation 不只是“返回 failed record IDs”，还要能标记相关 procedure 已失效或进入 debt。

```swift
@Test func invalidationPromotesFailedProcedureToInvalidatedProcedureSignal() throws {
    let result = MemoryInvalidationService().analyze(outcome)
    #expect(result.invalidatedRecordIDs.contains("kernel-1"))
    #expect(result.generatedSignals.contains { $0.tags.contains("invalidated-procedure") })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because the invalidation service only returns record IDs.

**Step 3: Write minimal implementation**

让 invalidation 分析同时输出：

1. 需要 touch / supersede / archive 的 record IDs
2. 新的 `invalidated-procedure` / `verificationDebt` signals
3. 原因摘要，供 audit 和 snapshot 使用

并删除“只返回 failed IDs”的旧服务接口或旧调用路径，避免新旧 invalidation 语义并存。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryInvalidationService.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Models/MemoryRecord.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: add semantic invalidation signals for rms memory"
```

## Task 6: Replace Layer-Weighted Retrieval with Frontier-Aware Decision-Impact Planning

**Files:**
- Modify: `agentGui/Models/MemoryRetrievalIntent.swift`
- Modify: `agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- Modify: `agentGui/Services/MemoryRetrievalPlanner.swift`
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing tests**

锁定 planner 不再只按 layer/budget，而要按 frontier 风险和 object impact 分配预算，并去掉残留 `bridge` 语义。

```swift
@Test func retrievalPlannerAllocatesExtraBudgetToHighRiskFrontierObjects() throws {
    let plan = MemoryRetrievalPlanner().makeRMSPlan(
        request: .fixture(userRequest: "Fix failing build", contextBudget: 8000),
        profiles: MemoryDomainProfileRegistry().profiles(for: .fixture()),
        epistemicState: EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "f-1",
                    goal: "Fix build",
                    openClaim: "Need shared scheme evidence",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "Run xcodebuild -list",
                    stopCondition: "Scheme confirmed"
                )
            ],
            counterexamples: [CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")]
        )
    )

    #expect(plan.objectBudgetByType[.counterexample, default: 0] > 0)
    #expect(plan.objectBudgetByType[.procedure, default: 0] > 0)
    #expect(plan.objectBudgetByType.keys.contains(.bridge) == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because planner still uses layer-weight heuristics and includes `bridge` object types.

**Step 3: Write minimal implementation**

更新 retrieval 语义：

1. 从 `MemoryRetrievalObjectType` 中删除 `bridge`
2. classifier 从 request keyword 提示升级为 frontier/counterexample/debt aware phase selection
3. planner 根据 frontier `impactLevel`、counterexample presence、verification debt 生成 object budgets
4. 为高风险 frontier 增加 extra budget，而不是统一归一分配
5. 删除旧 layer-first fallback 逻辑与对应说明文案，不保留“先按 layer，再按 impact”的兼容路线

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryRetrievalIntent.swift agentGui/Services/MemoryRetrievalIntentClassifier.swift agentGui/Services/MemoryRetrievalPlanner.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: add frontier-aware decision impact retrieval planning"
```

## Task 7: Expand Influence Trace into Action-Ranking Audit Output

**Files:**
- Modify: `agentGui/Models/MemoryInfluenceTrace.swift`
- Modify: `agentGui/Services/EpistemicStateReducer.swift`
- Modify: `agentGui/Models/MemoryRuntimeSnapshot.swift`
- Modify: `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`
- Modify: `agentGui/Views/Memory/RMSCognitionPanel.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing tests**

锁定 influence trace 必须能回答“哪条记忆改变了哪个动作排序、阻止了哪条错误路径”。

```swift
@Test func influenceTraceCapturesActionRankingAndBlockingRationale() throws {
    let trace = MemoryInfluenceTrace(
        activatedMemoryIDs: ["ce-1"],
        rankedActionIDs: ["run:xcodebuild-list"],
        blockedActionIDs: ["edit:project-file"],
        actionRankingChanges: [
            .init(memoryID: "ce-1", fromAction: "edit:project-file", toAction: "run:xcodebuild-list", rationale: "counterexample blocked premature edit")
        ]
    )

    #expect(trace.actionRankingChanges.count == 1)
    #expect(trace.actionRankingChanges.first?.rationale.contains("counterexample") == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because `MemoryInfluenceTrace` only stores ID arrays.

**Step 3: Write minimal implementation**

新增结构化 trace entries：

1. `actionRankingChanges`
2. `blockedPathReasons`
3. `frontierBudgetDecisions`

并在 cognition panel 中展示为 secondary diagnostics，而不是只显示 ID 列表。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryInfluenceTrace.swift agentGui/Services/EpistemicStateReducer.swift agentGui/Models/MemoryRuntimeSnapshot.swift agentGui/ViewModels/RMSCognitionPanelViewModel.swift agentGui/Views/Memory/RMSCognitionPanel.swift agentGuiTests/RMSCognitionPanelViewModelTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "feat: expand influence trace into action ranking audit output"
```

## Task 8: Run End-to-End RMS Phase 1-3 Regression

**Files:**
- Test: `agentGuiTests/MemoryAdmissionPolicyTests.swift`
- Test: `agentGuiTests/MemoryGovernanceServiceTests.swift`
- Test: `agentGuiTests/MemoryConsolidationEngineTests.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Test: `agentGuiTests/RMSCognitionPanelViewModelTests.swift`

**Step 1: Run the targeted regression suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/MemoryAdmissionPolicyTests \
  -only-testing:agentGuiTests/MemoryGovernanceServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationEngineTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/RMSCognitionPanelViewModelTests
```

Expected: PASS.

**Step 2: Run smoke**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: no new failures introduced by the RMS Phase 1-3 work.

**Step 3: Commit**

```bash
git add .
git commit -m "test: validate rms phase 1-3 gap closure"
```

## Notes For Execution

1. 每个 task 必须先让对应测试失败，再写最小实现。
2. 不要扩展到 Phase 4 的统一状态主链，但必须在触及范围内直接删除旧语义与兼容分支。
3. 如果 planner 改动导致现有 UI / snapshot 文案变化，优先补测试，并同步删掉旧 layer-first 解释。
4. 如果 `MemoryCandidate` / `MemoryRecord` 的 payload schema 变复杂，优先用 `structured` payload，而不是继续追加自由文本 summary。
5. 不允许为了降低改动量而保留 relevance-only admission、summary-only distillation、layer-first retrieval 的双轨逻辑。

Plan complete and saved to `docs/plans/2026-03-14-rms-phase1-3-gap-closure-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
# Memory Control Plane Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将当前 unified memory runtime 逐步演进为 evidence-backed、goal-conditioned、可治理、可观测的 memory control plane，并保持现有记忆链路可运行、可回滚、可测试。

**Architecture:** 采用增量替换而不是大爆炸重写。核心做法是保留现有 `MemoryRuntimeCoordinator -> MemoryRuntimeContext` 主链路，先把 admission、retrieval、lifecycle 三个决策面抽象成可组合策略对象，再把 evidence、bridge、procedure 这些新能力挂到现有 record/store/snapshot 之上，最后再做 background distillation 与 UI 治理面扩展。设计上优先使用 Policy Object + Strategy、Pipeline、Repository、State Machine、Value Object，避免把复杂度继续堆回 `MemoryRuntimeCoordinator` 或 `MemoryGovernanceService`。

**Tech Stack:** Swift 6、SwiftUI、Foundation JSON persistence、现有 unified memory runtime、Swift Testing、`xcodebuild`、现有 Quality Smoke 脚本。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 实施策略选择

### 推荐方案：Infrastructure-first incremental rollout

先把决策接口、评分模型、生命周期状态和证据对象建起来，再逐步替换现有 admission、retrieval、background consolidation。理由很直接：当前 memory 主链已经在运行，big-bang 重写风险太高，而单独先做 UI 或经验蒸馏又会建立在不稳定抽象之上。

### 备选方案 A：先做 experience distillation

优点是用户能更快看到“记忆变聪明”。缺点是 admission 和 retrieval 还没升级，distilled memory 很容易继续被错误写入策略和静态检索浪费掉，不推荐作为第一阶段。

### 备选方案 B：先做 graph/bridge retrieval

优点是多跳命中会更快提升。缺点是没有 evidence model 和 lifecycle control，桥接关系会很快失真，运行成本也难控，不推荐作为第一阶段。

## 设计模式与代码质量约束

### 必须采用的模式

1. **Policy Object + Strategy**：用于 admission policy、retrieval intent policy、lifecycle policy。不要把阈值和规则继续硬编码在单个 service 中。
2. **Pipeline**：用于 `MemoryRuntimeCoordinator` 内部的 prepare flow，拆成 candidate generation、feature extraction、selection、bridge expansion、dereference、prompt assembly。
3. **Repository**：继续由 store adapter 负责持久化，不让 UI、scheduler、governance 直接操作 JSON 文件。
4. **State Machine**：用于 lifecycle tier 迁移和 confirmation/governance 状态。
5. **Value Object**：用于 score、feature vector、evidence anchor、bridge edge、working set cost，避免字典和裸字符串四处漂移。

### 明确避免的反模式

1. 不要把所有新逻辑继续塞进 `MemoryRuntimeCoordinator.swift`。
2. 不要用自由格式 `[String: String]` 长期承载关键语义，能建类型就建类型。
3. 不要引入过早的通用图数据库抽象；第一期只做轻量 bridge/index 层。
4. 不要为了模式而模式。简单枚举可解的问题，不要上 class hierarchy。
5. 不要让 UI 成为治理真相源，治理日志必须来自 service 层。

## 实施顺序总览

### Iteration 1：Admission Foundation

目标：把现有记忆写入从静态阈值判断升级为可解释、可测试的评分决策。

### Iteration 2：Goal-conditioned Retrieval

目标：让检索先理解当前任务子阶段，再决定 budget 和对象类型。

### Iteration 3：Evidence And Bridge Layer

目标：让 memory 能回溯证据，并支持 bridge-aware 检索扩展。

### Iteration 4：Experience Distillation

目标：把 background consolidation 升级为 strategy / recovery / procedure 蒸馏。

### Iteration 5：Lifecycle Control

目标：从 TTL 清理升级为 hot/warm/cold/archive working-set 管理。

### Iteration 6：Governance UI And Rollout

目标：把 admission explanation、tier、evidence、lifecycle 和 drift audit 对用户可见，并加 feature flag 控制 rollout。

## Proposed File Layout

**Create admission and decision value objects:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionFeatureVector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionScore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionExplanation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRetrievalIntent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryLifecycleTier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryEvidenceAnchor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBridgeEdge.swift`

**Create policy and pipeline services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DefaultMemoryAdmissionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBridgeExpander.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryEvidenceResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryExperienceDistillationService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryProcedureInductionService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryLifecycleManager.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryWorkingSetBudgeter.swift`

**Modify existing runtime and persistence files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundJobStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeSnapshotStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryPromptAssembler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/UnifiedMemoryStoredRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBackgroundJob.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryKind.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`

**Modify existing UI and view-model files:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`

**Create or expand tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryAdmissionPolicyTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalIntentClassifierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBridgeExpanderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryEvidenceResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConsolidationEngineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryLifecycleManagerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryFileStoreAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/memory-system-evolution-report-2026-03.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-10-memory-governance-operations-and-taskmemory-migration-implementation.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-unified-memory-runtime-observability-implementation.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-11-taskmemory-direct-unified-memory-implementation.md`

## Delivery Gates

### Gate A：Contract Safety

必须满足：

1. targeted unit tests 绿。
2. memory integration tests 绿。
3. 现有 prompt assembly 输出没有明显回归。

### Gate B：Runtime Safety

必须满足：

1. 新策略均可 feature flag 关闭。
2. snapshot 中能看到旧行为与新行为的决策解释。
3. 背景任务失败不会阻塞主对话路径。

### Gate C：Product Safety

必须满足：

1. Settings 中可独立开关 admission v2、bridge retrieval、lifecycle manager、experience distillation。
2. 管理面板可以查看 explanation、tier、evidence 数量。
3. Quality Smoke 通过。

### Task 1: Establish Admission Contracts And Evidence Anchors

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionFeatureVector.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionScore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryAdmissionExplanation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryEvidenceAnchor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/UnifiedMemoryStoredRecord.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryAdmissionPolicyTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedMemoryFileStoreAdapterTests.swift`

**Step 1: Write the failing test**

新增测试，锁定 evidence-backed 记忆的最小契约：记忆可携带 evidence anchors，评分结果可编码，解释对象可持久化。

```swift
import Foundation
import Testing
@testable import agentGui

struct MemoryAdmissionPolicyTests {
    @Test func admissionValueObjectsRoundTrip() throws {
        let anchor = MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild test")
        let featureVector = MemoryAdmissionFeatureVector(
            futureUtility: 0.9,
            factualConfidence: 0.8,
            novelty: 0.7,
            temporalRecency: 0.6,
            taskRelevance: 0.95,
            verificationSupport: 1,
            privacyRisk: 0.0,
            driftRisk: 0.1
        )
        let score = MemoryAdmissionScore(total: 0.82, route: .hotPath)
        let explanation = MemoryAdmissionExplanation(score: score, featureVector: featureVector, reasons: ["verified tool evidence"])

        #expect(explanation.reasons.contains("verified tool evidence"))
        #expect(score.route == .hotPath)
        #expect(anchor.kind == .toolCall)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryAdmissionPolicyTests -only-testing:agentGuiTests/UnifiedMemoryFileStoreAdapterTests
```

Expected: FAIL because the new value objects and `MemoryRecord` evidence fields do not exist.

**Step 3: Write minimal implementation**

实现：

1. `MemoryEvidenceAnchor` 作为 value object，支持 tool call、message、file、verification artifact。
2. `MemoryAdmissionFeatureVector`、`MemoryAdmissionScore`、`MemoryAdmissionExplanation`。
3. `MemoryRecord` 增加 `evidenceAnchors`、`admissionExplanation` 可选字段。
4. `UnifiedMemoryStoredRecord` 完成新字段的读写映射。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryAdmissionFeatureVector.swift agentGui/Models/MemoryAdmissionScore.swift agentGui/Models/MemoryAdmissionExplanation.swift agentGui/Models/MemoryEvidenceAnchor.swift agentGui/Models/MemoryRecord.swift agentGui/Models/UnifiedMemoryStoredRecord.swift agentGuiTests/MemoryAdmissionPolicyTests.swift agentGuiTests/UnifiedMemoryFileStoreAdapterTests.swift
git commit -m "feat: add admission value objects and evidence anchors"
```

### Task 2: Replace Static Governance With Policy-based Admission Engine

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionFeatureExtractor.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryAdmissionPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/DefaultMemoryAdmissionPolicy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryGovernanceService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryGovernanceTypes.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernanceServiceTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryGovernedWriteRoutingTests.swift`

**Step 1: Write the failing test**

新增测试，要求 `MemoryGovernanceService` 不再直接硬编码阈值，而是委托 feature extractor 和 policy 输出 explanation。

```swift
@Test func governanceServiceUsesPolicyAndPersistsExplanation() async throws {
    let policy = DefaultMemoryAdmissionPolicy()
    let extractor = MemoryAdmissionFeatureExtractor()
    let service = MemoryGovernanceService(policy: policy, featureExtractor: extractor)
    let candidate = MemoryCandidate.fixture(confidence: 0.96, verificationStatus: .verified)

    let decision = service.evaluate(candidate)

    #expect(decision.explanation != nil)
    #expect(decision.route == .acceptHotPath)
    #expect(decision.explanation?.featureVector.taskRelevance != nil)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryGovernanceServiceTests -only-testing:agentGuiTests/MemoryGovernedWriteRoutingTests
```

Expected: FAIL because `MemoryGovernanceService` has no injectable policy path and no explanation output.

**Step 3: Write minimal implementation**

实现：

1. `MemoryAdmissionFeatureExtractor` 负责从 candidate + scope + source 提取特征。
2. `MemoryAdmissionPolicy` protocol 作为 Strategy 接口。
3. `DefaultMemoryAdmissionPolicy` 负责打分与 route。
4. `MemoryGovernanceService` 变成 Facade，只协调 extractor、policy、store、confirmation store。
5. route 结果与 explanation 写入 `MemoryRecord` 或 confirmation candidate。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryAdmissionFeatureExtractor.swift agentGui/Services/MemoryAdmissionPolicy.swift agentGui/Services/DefaultMemoryAdmissionPolicy.swift agentGui/Services/MemoryGovernanceService.swift agentGui/Models/MemoryGovernanceTypes.swift agentGuiTests/MemoryGovernanceServiceTests.swift agentGuiTests/MemoryGovernedWriteRoutingTests.swift
git commit -m "feat: replace static governance with policy-based admission"
```

### Task 3: Introduce Goal-conditioned Retrieval Intent

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRetrievalIntent.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetrievalPlanner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeTypes.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalIntentClassifierTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetrievalPlannerTests.swift`

**Step 1: Write the failing test**

新增测试，要求 planner 根据当前子阶段返回不同预算，而不是只根据 `taskKind`。

```swift
@Test func retrievalPlannerBudgetsByIntentNotOnlyTaskKind() throws {
    let request = MemoryRuntimeRequest(sessionId: "s1", threadId: "t1", workflowRunId: nil, userRequest: "Fix failing SwiftUI snapshot test", taskKind: .coding, projectId: nil, workspaceRoot: "/tmp/repo", contextBudget: 4000)
    let classifier = MemoryRetrievalIntentClassifier()
    let intent = classifier.classify(request: request, phaseHint: .verification)
    let plan = MemoryRetrievalPlanner().makePlan(request: request, profiles: [.codingTask()], intent: intent)

    #expect(intent.phase == .verification)
    #expect(plan.objectBudgetByType[.procedure, default: 0] >= 1)
    #expect(plan.objectBudgetByType[.fact, default: 0] >= 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRetrievalIntentClassifierTests -only-testing:agentGuiTests/MemoryRetrievalPlannerTests
```

Expected: FAIL because no retrieval intent type or object budget exists.

**Step 3: Write minimal implementation**

实现：

1. `MemoryRetrievalIntent` 作为 value object，至少包含 `phase`、`neededObjectTypes`、`reason`。
2. `MemoryRetrievalIntentClassifier` 根据 request、phase hint、tool state 做轻量分类。
3. `MemoryRetrievalPlan` 增加 `objectBudgetByType`。
4. `MemoryRetrievalPlanner` 变成 Policy Object，按 intent 生成 layer + object 双 budget。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryRetrievalIntent.swift agentGui/Services/MemoryRetrievalIntentClassifier.swift agentGui/Services/MemoryRetrievalPlanner.swift agentGui/Models/MemoryRuntimeTypes.swift agentGuiTests/MemoryRetrievalIntentClassifierTests.swift agentGuiTests/MemoryRetrievalPlannerTests.swift
git commit -m "feat: add goal-conditioned retrieval intent planning"
```

### Task 4: Add Bridge Expansion And Evidence Dereference To Runtime Pipeline

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBridgeEdge.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBridgeExpander.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryEvidenceResolver.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRuntimeSnapshotStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRuntimeSnapshot.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBridgeExpanderTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryEvidenceResolverTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing test**

新增测试，要求 runtime 可以先选中一条记录，再通过 bridge 扩展出恢复策略，并记录 dereference 链路。

```swift
@Test func coordinatorExpandsBridgesAndCapturesDereferenceTrace() async throws {
    let coordinator = MemoryRuntimeCoordinator.makeForTests(unifiedRecords: sampleBridgeReadyRecords())
    let request = MemoryRuntimeRequest(sessionId: "s1", threadId: "t1", workflowRunId: nil, userRequest: "Fix xcodebuild scheme failure", taskKind: .coding, projectId: nil, workspaceRoot: "/tmp/repo", contextBudget: 4000)

    let context = try await coordinator.prepareContext(for: request)
    let snapshot = try #require(context.runtimeSnapshot)

    #expect(snapshot.selectedRecords.contains { $0.title.contains("scheme failure") })
    #expect(snapshot.bridgeExpansions.isEmpty == false)
    #expect(snapshot.dereferenceCount > 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryBridgeExpanderTests -only-testing:agentGuiTests/MemoryEvidenceResolverTests -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because bridge expansion and evidence dereference do not exist.

**Step 3: Write minimal implementation**

实现：

1. `MemoryBridgeEdge` 作为轻量关系边，不引入通用图存储。
2. `MemoryBridgeExpander` 根据 error/file/tool tags 做有限扩展。
3. `MemoryEvidenceResolver` 根据 selected memory 回拉 evidence anchors 摘要。
4. `MemoryRuntimeCoordinator` 重构为 pipeline：candidate -> score/sort -> select -> bridge expand -> evidence dereference -> prompt assemble。
5. snapshot 记录 bridge expansions、dereference count、cost metrics。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryBridgeEdge.swift agentGui/Services/MemoryBridgeExpander.swift agentGui/Services/MemoryEvidenceResolver.swift agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/MemoryRuntimeSnapshotStore.swift agentGui/Models/MemoryRuntimeSnapshot.swift agentGuiTests/MemoryBridgeExpanderTests.swift agentGuiTests/MemoryEvidenceResolverTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: add bridge-aware expansion and evidence dereference"
```

### Task 5: Upgrade Consolidation Into Experience And Procedure Distillation

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryExperienceDistillationService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryProcedureInductionService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryConsolidationEngine.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryBackgroundJob.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryKind.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryConsolidationEngineTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryBackgroundSchedulerTests.swift`

**Step 1: Write the failing test**

新增测试，要求 consolidation 可以从 trajectory 生成 strategy、recovery、procedure 三类对象，而不是只做 record merge。

```swift
@Test func consolidationEngineDistillsStrategyRecoveryAndProcedureRecords() throws {
    let engine = MemoryConsolidationEngine(
        experienceDistiller: MemoryExperienceDistillationService(),
        procedureInductor: MemoryProcedureInductionService()
    )

    let outcome = try engine.consolidate(sampleCodingTrajectoryOutcome())

    #expect(outcome.records.contains { $0.tags.contains("strategy-tip") })
    #expect(outcome.records.contains { $0.tags.contains("recovery-tip") })
    #expect(outcome.records.contains { $0.tags.contains("procedure") })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryConsolidationEngineTests -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: FAIL because the engine does not support distillation services or new job kinds.

**Step 3: Write minimal implementation**

实现：

1. `MemoryExperienceDistillationService` 从 tool trajectory 与 verification result 抽取 strategy/recovery/anti-pattern。
2. `MemoryProcedureInductionService` 从 repeated success pattern 生成 procedure record。
3. `MemoryBackgroundJob.JobType` 增加 `experienceDistillation`、`procedureInduction`。
4. scheduler 能处理新 job，但失败时只记录 audit，不阻塞主链。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryExperienceDistillationService.swift agentGui/Services/MemoryProcedureInductionService.swift agentGui/Services/MemoryConsolidationEngine.swift agentGui/Models/MemoryBackgroundJob.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Models/MemoryKind.swift agentGuiTests/MemoryConsolidationEngineTests.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift
git commit -m "feat: add experience and procedure distillation"
```

### Task 6: Replace TTL-only Cleanup With Lifecycle Tier Manager

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryLifecycleTier.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryLifecycleManager.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryWorkingSetBudgeter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/MemoryRetentionService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/MemoryRecord.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryLifecycleManagerTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRetentionServiceTests.swift`

**Step 1: Write the failing test**

新增测试，要求 lifecycle 迁移由命中率、贡献率和成本驱动，而不是只看时间。

```swift
@Test func lifecycleManagerDemotesColdRecordsAndProtectsHotVerifiedRecords() throws {
    let manager = MemoryLifecycleManager(budgeter: MemoryWorkingSetBudgeter())
    let result = manager.rebalance(records: sampleLifecycleRecords(), budget: .init(maxHotCount: 8, maxWarmCount: 32))

    #expect(result.updatedRecords.contains { $0.tags.contains("hot") })
    #expect(result.updatedRecords.contains { $0.tags.contains("cold") })
    #expect(result.auditEntries.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryLifecycleManagerTests -only-testing:agentGuiTests/MemoryRetentionServiceTests
```

Expected: FAIL because lifecycle tiers and rebalance manager do not exist.

**Step 3: Write minimal implementation**

实现：

1. `MemoryLifecycleTier` 定义 hot、warm、cold、archive。
2. `MemoryLifecycleManager` 作为 State Machine + Policy Object，输出迁移结果和审计记录。
3. `MemoryWorkingSetBudgeter` 管理 hot/warm working set 上限。
4. `MemoryRetentionService` 改为组合 TTL sweep + lifecycle rebalance，而不是取代 TTL。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryLifecycleTier.swift agentGui/Services/MemoryLifecycleManager.swift agentGui/Services/MemoryWorkingSetBudgeter.swift agentGui/Services/MemoryRetentionService.swift agentGui/Services/UnifiedMemoryFileStoreAdapter.swift agentGui/Models/MemoryRecord.swift agentGuiTests/MemoryLifecycleManagerTests.swift agentGuiTests/MemoryRetentionServiceTests.swift
git commit -m "feat: add lifecycle tier management for memory working set"
```

### Task 7: Surface Explanations, Evidence, And Lifecycle In UI And Settings

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryManagementPanel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryManagementViewModelTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`

**Step 1: Write the failing test**

新增测试，要求 view model 能暴露 explanation、evidence count、lifecycle tier 与 feature flag 状态。

```swift
@Test func memoryManagementViewModelExposesTierAndAdmissionExplanation() throws {
    let viewModel = MemoryManagementViewModel(store: makeStoreWithExplainedRecords())
    try viewModel.reload()

    #expect(viewModel.totalRecordCount > 0)
    #expect(viewModel.scopeSummaries.isEmpty == false)
    #expect(viewModel.recordRows.contains { $0.lifecycleTierLabel == "Hot" })
    #expect(viewModel.recordRows.contains { $0.admissionExplanationSummary.contains("verified") })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryManagementViewModelTests -only-testing:agentGuiTests/MemoryRuntimeSnapshotViewModelTests
```

Expected: FAIL because the UI view models do not expose these new fields.

**Step 3: Write minimal implementation**

实现：

1. `AppSettings` 增加 feature flags：`enableAdmissionV2`、`enableGoalConditionedRetrieval`、`enableBridgeExpansion`、`enableLifecycleManager`、`enableExperienceDistillation`。
2. 管理面板展示 tier、evidence 数、explanation 摘要、drift / privacy 风险标签。
3. snapshot panel 展示 bridge expansions、dereference count、working-set cost。
4. settings 面板独立控制 rollout 开关。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGuiTests/MemoryManagementViewModelTests.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift
git commit -m "feat: surface admission and lifecycle details in memory ui"
```

### Task 8: Roll Out With Integration Tests And Smoke Gates

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ContextCompression.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/memory-system-evolution-report-2026-03.md`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeCoreTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`

**Step 1: Write the failing test**

新增集成测试，锁定 feature flags 打开时 admission explanation、intent planning、bridge expansion 和 lifecycle tier 都会进入 runtime snapshot，但关闭时仍保持旧路径兼容。

```swift
@Test func memoryRuntimeSupportsFlaggedV2PathWithoutBreakingLegacyFallback() async throws {
    let harness = try MemoryRuntimeIntegrationHarness(enableAdmissionV2: true, enableGoalConditionedRetrieval: true, enableBridgeExpansion: true, enableLifecycleManager: true)

    let context = try await harness.prepareContext(userRequest: "Fix failing build and verify tests")
    let snapshot = try #require(context.runtimeSnapshot)

    #expect(snapshot.selectedRecords.isEmpty == false)
    #expect(snapshot.bridgeExpansions.isEmpty == false)
    #expect(snapshot.metrics.workingSetCost > 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests -only-testing:agentGuiTests/MemoryRuntimeCoreTests -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests
```

Expected: FAIL because the runtime does not yet support full flagged rollout behavior.

**Step 3: Write minimal implementation**

实现：

1. `ClaudeService+AgenticLoop` 和 `ClaudeService+ContextCompression` 从 `AppSettings` 读取 feature flags。
2. `AgentLoopMemoryBootstrapComposer` 在 bootstrap prompt 中利用新 snapshot 与 procedure memory，但保留旧路径 fallback。
3. README 和 memory report 增加 rollout 说明、feature flag 说明和回滚步骤。

**Step 4: Run test to verify it passes**

Run targeted tests above, then run the repo smoke gate:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests -only-testing:agentGuiTests/MemoryRuntimeCoreTests -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGui/Services/AgentLoopMemoryBootstrapComposer.swift README.md docs/memory-system-evolution-report-2026-03.md agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGuiTests/MemoryRuntimeCoreTests.swift agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift
git commit -m "feat: roll out memory control plane behind feature flags"
```

## 测试策略

### 单元测试优先级

1. admission feature extraction 和 scoring。
2. retrieval intent classification。
3. bridge expansion 和 evidence resolver。
4. lifecycle tier rebalance。
5. procedure induction 输出契约。

### 集成测试优先级

1. `MemoryRuntimeCoordinator` 生成的 snapshot 是否包含 explanation、bridge、cost。
2. feature flags 关闭时是否回退到旧行为。
3. background distillation 失败时是否只影响后台任务，不影响主对话。

### 回归门禁

1. `MemoryRuntimeIntegrationTests`
2. `MemoryRuntimeCoordinatorTests`
3. `MemoryGovernanceServiceTests`
4. `MemoryBackgroundSchedulerTests`
5. `./scripts/run_quality_smoke.sh`

## 里程碑验收标准

### Milestone 1：Admission V2 可用

验收：

1. 每条新写入 record 都可选携带 explanation。
2. confirmation / archive / hot-path 决策可解释。
3. settings 可关闭 admission v2。

### Milestone 2：Goal-conditioned Retrieval 可用

验收：

1. snapshot 中能看到 retrieval intent。
2. planner 会按 phase 变化 budget。
3. 旧 layer-based fallback 仍可用。

### Milestone 3：Evidence And Bridge 可用

验收：

1. selected records 能显示 evidence anchor 数量。
2. snapshot 能显示 bridge expansion 和 dereference count。
3. prompt token 成本受 budget 控制。

### Milestone 4：Experience Distillation And Lifecycle 可用

验收：

1. 后台任务可以产出 strategy / recovery / procedure memory。
2. store 中能看到 hot/warm/cold/archive tier。
3. lifecycle rebalance 不会破坏现有 retrieval correctness。

## 实施注意事项

1. 先建 contract types 和 tests，再改主流程，不要反过来。
2. 每个 iteration 都必须 feature-flagged，可独立关闭。
3. 任何新 memory object 若没有 evidence anchors，只能停留在低信任 tier。
4. procedure memory 必须带最近验证时间和 supporting evidence，避免固化过时经验。
5. bridge expansion 要有最大深度和最大条目数，避免 prompt 爆炸。
6. lifecycle manager 不能替代 TTL；TTL 负责兜底清理，lifecycle 负责 working-set 管理。

Plan complete and saved to `docs/plans/2026-03-13-memory-control-plane-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
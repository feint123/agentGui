# RMS Agent-First Memory Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将当前 record-centric memory control plane 逐步重构为 prompt-first、agent-first 的 RMS，能够从对话与工具执行轨迹中提取 `EpistemicState`、`frontier`、`counterexample`、`constraint`、`verificationDebt` 和 `tacticKernel`，并在完成主链接入后系统性清理旧概念与无效代码。

**Architecture:** 采用增量替换而不是大爆炸重写。第一阶段不改底层存储真相源，先在 agent loop 内引入 runtime-only 的 `EpistemicState` 和 prompt-first extraction contract，把语义提取、frontier 合成、counterexample 判定做成独立服务；第二阶段再把 `MemoryRuntimeCoordinator`、background jobs、snapshot/UI 改造成以 epistemic objects 为中心；最后统一收口 legacy `TaskMemory`、layer-first retrieval、旧 rollout flags 和旧测试。

**Tech Stack:** Swift 6、SwiftData、SwiftUI、SwiftAnthropic、现有 AgentLoop hooks/runtime、现有 unified memory store、Swift Testing、`xcodebuild`、`./scripts/run_quality_smoke.sh`。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. 设计约束

### 必须满足的约束

1. 抽取主路径必须是 `prompt-first`，不能把关键词匹配或启发式分类当成对象语义判断主链。
2. 允许规则存在，但只能用于窗口裁剪、低成本触发、审计对照，不能决定 `frontier` / `counterexample` / `constraint` 等对象语义。
3. 长期层只能保存 reasoning residue，不能保存原始 chain-of-thought。
4. 新旧概念不能长期双轨并存。每引入一个新对象，都要给出对应旧对象的保留、收敛、边缘化或删除方案。
5. 所有关键迁移都必须有 feature flag、snapshot 可观测性和 targeted tests。

### 当前代码入口

本计划基于以下现有入口展开：

1. agent loop 主链：`agentGui/Services/ClaudeService+AgenticLoop.swift`、`agentGui/Services/AgentLoopRunner.swift`、`agentGui/Services/AgentLoopRoundExecutor.swift`
2. hook 与 bootstrap：`agentGui/Services/AgentLoopBuiltInHookFactory.swift`、`agentGui/Services/AgentLoopHookDependencyFactory.swift`、`agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
3. memory runtime：`agentGui/Services/MemoryRuntimeCoordinator.swift`、`agentGui/Services/MemoryPromptAssembler.swift`、`agentGui/Models/MemoryRuntimeTypes.swift`、`agentGui/Models/MemoryRuntimeSnapshot.swift`
4. legacy task memory：`agentGui/Models/TaskMemory.swift`、`agentGui/Services/TaskMemoryRecordFactory.swift`
5. background jobs：`agentGui/Services/MemoryBackgroundScheduler.swift`、`agentGui/Services/MemoryConsolidationEngine.swift`、`agentGui/Models/MemoryBackgroundJob.swift`
6. rollout/UI：`agentGui/Models/AppSettings.swift`、`agentGui/Views/Settings/SettingsMemoryView.swift`、`agentGui/ViewModels/MemoryManagementViewModel.swift`、`agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`

## 1. 推荐实施顺序

### 推荐方案：Runtime-first, prompt-first, cleanup-enforced

先在 runtime 内建立 `EpistemicState` 和 extraction contract，再让 retrieval / distillation / UI 跟进，最后删除旧概念。理由很直接：如果先改 store 或先改 UI，而没有把语义提取主链跑通，项目只会多一层 schema 和面板，不会真的得到 agent-first memory。

### 非目标

以下内容不在本期范围内：

1. 不引入新的向量库或图数据库。
2. 不做全量历史数据重算迁移脚本。
3. 不把所有 legacy 字段一次性删除。
4. 不把 extraction prompt 外包成独立云服务。

## 2. 交付门槛

### Gate A：语义主链可运行

1. agent loop 每轮都能构建 `EpistemicInputEnvelope`。
2. extraction service 能返回结构化对象，而不是自由文本总结。
3. `EpistemicState` 能进入 memory bootstrap / retrieval / snapshot。

### Gate B：新旧语义不混乱

1. UI 不再把 layer-first retrieval 当核心解释。
2. 新 rollout flag 已覆盖 extraction、epistemic retrieval、legacy cleanup。
3. 旧 `TaskMemory` 和旧 memory flags 已有明确 sunset 条件。

### Gate C：质量门槛

1. 相关 unit tests 全绿。
2. `AgentLoopIntegrationTests` 与 `MemoryRuntimeIntegrationTests` 无回归。
3. 运行 `./scripts/run_quality_smoke.sh` 无新增失败。

## 3. 实施任务

### Task 1: 建立 Epistemic 核心模型与最小运行时状态

**Files:**
- Create: `agentGui/Models/EpistemicState.swift`
- Create: `agentGui/Models/AtomicEpistemicEvent.swift`
- Create: `agentGui/Models/EpistemicInputEnvelope.swift`
- Create: `agentGui/Models/MemoryInfluenceTrace.swift`
- Modify: `agentGui/Models/AgentLoopRunState.swift`
- Modify: `agentGui/Models/MemoryRuntimeTypes.swift`
- Test: `agentGuiTests/EpistemicStateTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoreTests.swift`

**Step 1: Write the failing tests**

先锁定最小契约：`EpistemicState` 可编码、可合并、可表达 frontiers / constraints / debt / activated memories。

```swift
import Foundation
import Testing
@testable import agentGui

struct EpistemicStateTests {
    @Test func epistemicStateCarriesFrontiersConstraintsAndDebt() throws {
        let state = EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "f-1",
                    goal: "Fix failing build",
                    openClaim: "Shared scheme may be missing",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "Run xcodebuild -list",
                    stopCondition: "Scheme confirmed"
                )
            ],
            activeConstraints: [
                ConstraintMemory(id: "c-1", summary: "先跑 targeted test 再改实现", scope: .session(id: "s1"))
            ],
            candidateActions: ["Run xcodebuild -list"],
            verificationDebt: [
                VerificationDebt(id: "d-1", claim: "Scheme issue", reason: "No direct evidence yet")
            ]
        )

        #expect(state.frontiers.count == 1)
        #expect(state.activeConstraints.count == 1)
        #expect(state.verificationDebt.count == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/EpistemicStateTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoreTests
```

Expected: FAIL because the new epistemic models do not exist.

**Step 3: Write minimal implementation**

实现最小可运行模型：

```swift
struct EpistemicState: Codable, Equatable, Sendable {
    var frontiers: [FrontierMemory] = []
    var activeConstraints: [ConstraintMemory] = []
    var candidateActions: [String] = []
    var verificationDebt: [VerificationDebt] = []
    var activatedMemories: [String] = []
    var counterexamples: [CounterexampleMemory] = []
    var residualRisk: Double = 0
    var expectedValueOfMoreReasoning: Double = 0
}
```

并在 `AgentLoopRunState` 增加 `epistemicState`、`influenceTrace` 占位字段，但先不让其影响主流程决策。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/EpistemicState.swift agentGui/Models/AtomicEpistemicEvent.swift agentGui/Models/EpistemicInputEnvelope.swift agentGui/Models/MemoryInfluenceTrace.swift agentGui/Models/AgentLoopRunState.swift agentGui/Models/MemoryRuntimeTypes.swift agentGuiTests/EpistemicStateTests.swift agentGuiTests/MemoryRuntimeCoreTests.swift
git commit -m "feat: add epistemic runtime core models"
```

### Task 2: 建立 prompt-first extraction contract 与解析器

**Files:**
- Create: `agentGui/Models/EpistemicExtractionModels.swift`
- Create: `agentGui/Services/EpistemicEventExtractionPromptBuilder.swift`
- Create: `agentGui/Services/FrontierSynthesisPromptBuilder.swift`
- Create: `agentGui/Services/CounterexampleExtractionPromptBuilder.swift`
- Create: `agentGui/Services/ConstraintDebtExtractionPromptBuilder.swift`
- Create: `agentGui/Services/EpistemicExtractionResponseParser.swift`
- Create: `agentGui/Services/EpistemicExtractionService.swift`
- Test: `agentGuiTests/EpistemicExtractionPromptBuilderTests.swift`
- Test: `agentGuiTests/EpistemicExtractionResponseParserTests.swift`

**Step 1: Write the failing tests**

先锁定 prompt contract 和 JSON 解析契约，确保输出不是自由文本。

```swift
@Test func parserDecodesStructuredExtractionPayload() throws {
    let json = #"""
    {
      "objects": [
        {
          "kind": "frontier",
          "id": "f-1",
          "summary": "Need to verify shared scheme",
          "source_refs": ["message:user:0", "tool:bash:tool-1"],
          "decision_delta": "changes next action from edit to inspect",
          "evidence_level": "partial"
        }
      ],
      "rejected": [],
      "missingEvidence": ["xcodebuild -list output"],
      "decisionImpactNote": "inspect scheme before editing"
    }
    """#

    let result = try EpistemicExtractionResponseParser().parse(json)
    #expect(result.objects.count == 1)
    #expect(result.missingEvidence == ["xcodebuild -list output"])
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/EpistemicExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/EpistemicExtractionResponseParserTests
```

Expected: FAIL because the extraction prompt builders and parser do not exist.

**Step 3: Write minimal implementation**

实现四类 prompt builder，统一输出 host contract：

```swift
struct EpistemicExtractionOutput: Codable, Equatable, Sendable {
    var objects: [EpistemicObjectCandidate]
    var rejected: [RejectedEpistemicObject]
    var missingEvidence: [String]
    var decisionImpactNote: String
}
```

并在 prompt 中强制要求：

1. 每个对象给出 `source_refs`
2. 每个对象给出 `evidence_level`
3. 每个对象给出 `decision_delta`
4. 不允许输出 chain-of-thought

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/EpistemicExtractionModels.swift agentGui/Services/EpistemicEventExtractionPromptBuilder.swift agentGui/Services/FrontierSynthesisPromptBuilder.swift agentGui/Services/CounterexampleExtractionPromptBuilder.swift agentGui/Services/ConstraintDebtExtractionPromptBuilder.swift agentGui/Services/EpistemicExtractionResponseParser.swift agentGui/Services/EpistemicExtractionService.swift agentGuiTests/EpistemicExtractionPromptBuilderTests.swift agentGuiTests/EpistemicExtractionResponseParserTests.swift
git commit -m "feat: add prompt-first epistemic extraction contract"
```

### Task 3: 在 Agent Loop 中收集 extraction 输入，而不是直接写 legacy TaskMemory

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`
- Modify: `agentGui/Models/AgentLoopRuntime.swift`
- Modify: `agentGui/Models/AgentLoopSharedStateAccess.swift`
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `agentGui/Models/ToolCall.swift`
- Test: `agentGuiTests/AgentLoopRoundExecutorTests.swift`
- Test: `agentGuiTests/AgentLoopToolAuditHookTests.swift`
- Test: `agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing tests**

新增测试，锁定每轮能形成 `EpistemicInputEnvelope`，包含 user/assistant messages、tool results、failure trigger、verification outcome。

```swift
@Test func roundExecutorBuildsEpistemicInputEnvelopeAfterToolResults() async throws {
    var state = AgentLoopRunState()
    state.epistemicState.candidateActions = ["Run xcodebuild -list"]

    let envelope = EpistemicInputEnvelope(
        sessionID: "s1",
        roundIndex: 1,
        userAgentMessages: ["Fix build", "I will inspect the scheme"],
        toolObservations: ["xcodebuild failed: scheme not shared"]
    )

    #expect(envelope.toolObservations.count == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopRoundExecutorTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL because the loop does not yet persist epistemic envelopes.

**Step 3: Write minimal implementation**

在 `AgentLoopRoundExecutor` 的以下位置补采集：

1. `executeStreamingRound(...)` 结束后收当前轮 text / thinking / stopReason
2. `applyToolResults(...)` 收 tool input / tool result / failure classification
3. `executeVerification(...)` 收 verification summary / missing evidence

不要先改 hook protocol。第一阶段把 envelope 写入 `AgentLoopSharedStateAccess` 即可，降低侵入性。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift agentGui/Models/AgentLoopRuntime.swift agentGui/Models/AgentLoopSharedStateAccess.swift agentGui/Services/AgentLoopToolExecutionCoordinator.swift agentGui/Models/ToolCall.swift agentGuiTests/AgentLoopRoundExecutorTests.swift agentGuiTests/AgentLoopToolAuditHookTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: capture epistemic input envelopes from agent loop"
```

### Task 4: 引入 EpistemicStateCoordinator，让模型提取结果进入主链运行时

**Files:**
- Create: `agentGui/Services/EpistemicStateCoordinator.swift`
- Create: `agentGui/Services/EpistemicStateReducer.swift`
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Modify: `agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- Modify: `agentGui/Models/AgentLoopRuntime.swift`
- Test: `agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- Test: `agentGuiTests/AgentLoopHookDependencyFactoryTests.swift`
- Test: `agentGuiTests/EpistemicStateCoordinatorTests.swift`

**Step 1: Write the failing tests**

锁定 bootstrap 可以读取当前 `EpistemicState` 并把 frontier / constraints / debt 注入启动上下文。

```swift
@Test func memoryBootstrapComposerRendersEpistemicStateSummary() async throws {
    let state = AgentLoopBuiltInHookFactory.State()
    state.epistemicState = EpistemicState(
        frontiers: [
            FrontierMemory(
                frontierId: "f-1",
                goal: "Fix build",
                openClaim: "Need to verify shared scheme",
                uncertaintyType: .tooling,
                impactLevel: .high,
                suggestedProbe: "Run xcodebuild -list",
                stopCondition: "Scheme confirmed"
            )
        ]
    )

    let composer = AgentLoopMemoryBootstrapComposer(memoryBootstrapLoader: { _ in nil })
    let summary = composer.renderEpistemicSummary(state.epistemicState)
    #expect(summary.contains("Need to verify shared scheme"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopHookDependencyFactoryTests \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests
```

Expected: FAIL because bootstrap and dependencies do not know about `EpistemicState`.

**Step 3: Write minimal implementation**

实现 `EpistemicStateCoordinator`：

1. 从 `EpistemicInputEnvelope` 调用 `EpistemicExtractionService`
2. 把 extraction output 归约进 `EpistemicState`
3. 生成 `MemoryInfluenceTrace`

并让 `ClaudeService+AgenticLoop` 在 unified memory bootstrap 之前先更新 runtime state，再把摘要注入 bootstrap prompt。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/EpistemicStateCoordinator.swift agentGui/Services/EpistemicStateReducer.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/AgentLoopHookDependencyFactory.swift agentGui/Services/AgentLoopMemoryBootstrapComposer.swift agentGui/Models/AgentLoopRuntime.swift agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift agentGuiTests/AgentLoopHookDependencyFactoryTests.swift agentGuiTests/EpistemicStateCoordinatorTests.swift
git commit -m "feat: integrate epistemic state into agent loop bootstrap"
```

### Task 5: 重写 MemoryRuntimeCoordinator，使 retrieval 和 prompt assembly 以 EpistemicState 为中心

**Files:**
- Modify: `agentGui/Services/MemoryRuntimeCoordinator.swift`
- Modify: `agentGui/Services/MemoryPromptAssembler.swift`
- Modify: `agentGui/Models/MemoryRuntimeSnapshot.swift`
- Modify: `agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- Modify: `agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift`
- Modify: `agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`
- Test: `agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`

**Step 1: Write the failing tests**

锁定新的 runtime snapshot 和 prompt 中应出现 frontier / counterexample / constraint / debt，而不是仅仅是 layer-based sections。

```swift
@Test func promptAssemblerRendersFrontiersAndCounterexamples() throws {
    let context = MemoryRuntimeContext(
        profiles: ["coding-task"],
        records: [],
        writePolicy: .readMostly,
        warnings: [],
        epistemicState: EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "f-1",
                    goal: "Fix build",
                    openClaim: "Need to confirm shared scheme",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "Run xcodebuild -list",
                    stopCondition: "Scheme confirmed"
                )
            ],
            counterexamples: [
                CounterexampleMemory(id: "ce-1", summary: "Do not edit before checking scheme", replacementAction: "Inspect build configuration first")
            ]
        )
    )

    let rendered = MemoryPromptAssembler().render(context: context)
    #expect(rendered.contains("Need to confirm shared scheme"))
    #expect(rendered.contains("Do not edit before checking scheme"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryRuntimeSnapshotViewModelTests
```

Expected: FAIL because `MemoryRuntimeContext` and prompt assembly do not yet understand `EpistemicState`.

**Step 3: Write minimal implementation**

实现以下变更：

1. `MemoryRuntimeContext` 增加 `epistemicState` 和 `influenceTrace`
2. `MemoryRuntimeCoordinator.prepareContext(...)` 接受当前 runtime `EpistemicState`
3. `MemoryPromptAssembler` 输出新结构：`未决前沿`、`激活反例`、`当前约束`、`验证债务`、`支持性事实`
4. `MemoryRuntimeSnapshot` 增加 epistemic metrics 和 influence trace summary

先保留 legacy records 作为 supporting facts，不立即删除 store 中 record 读取。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRuntimeCoordinator.swift agentGui/Services/MemoryPromptAssembler.swift agentGui/Models/MemoryRuntimeSnapshot.swift agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotPanel.swift agentGui/Views/Memory/MemoryRuntimeSnapshotRecordList.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift
git commit -m "feat: drive memory runtime from epistemic state"
```

### Task 6: 把 background jobs 改造成 counterexample/kernel/invalidation 作业，而不是旧 consolidation 语义

**Files:**
- Modify: `agentGui/Models/MemoryBackgroundJob.swift`
- Modify: `agentGui/Services/MemoryBackgroundScheduler.swift`
- Modify: `agentGui/Services/MemoryConsolidationEngine.swift`
- Create: `agentGui/Services/CounterexampleDistillationService.swift`
- Create: `agentGui/Services/TacticKernelDistillationService.swift`
- Create: `agentGui/Services/MemoryInvalidationService.swift`
- Test: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- Test: `agentGuiTests/MemoryRuntimeCoordinatorTests.swift`

**Step 1: Write the failing tests**

锁定新 job type 会产出 `counterexample`、`tacticKernel` 或 invalidation，而不是只会生成 failure-chain / recovery-tip。

```swift
@Test func schedulerConsumesCounterexampleDistillationJobs() async throws {
    let job = MemoryBackgroundJob.counterexampleDistillation(outcome: .fixture())
    #expect(job.type == .counterexampleDistillation)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests
```

Expected: FAIL because the new background job types do not exist.

**Step 3: Write minimal implementation**

新增 job types：

1. `counterexampleDistillation`
2. `tacticKernelDistillation`
3. `memoryInvalidation`

并让旧 `consolidation` 内部改为调用新服务，而不是继续承载最终产品语义。这样可以先兼容旧队列，再逐步删除旧命名。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryBackgroundJob.swift agentGui/Services/MemoryBackgroundScheduler.swift agentGui/Services/MemoryConsolidationEngine.swift agentGui/Services/CounterexampleDistillationService.swift agentGui/Services/TacticKernelDistillationService.swift agentGui/Services/MemoryInvalidationService.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift agentGuiTests/MemoryRuntimeCoordinatorTests.swift
git commit -m "feat: add rms distillation and invalidation jobs"
```

### Task 7: 收敛 legacy TaskMemory 写路径，改为 episodeDelta 兼容层

**Files:**
- Modify: `agentGui/Models/TaskMemory.swift`
- Modify: `agentGui/Services/TaskMemoryRecordFactory.swift`
- Modify: `agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `agentGui/Services/ClaudeService+ContextCompression.swift`
- Test: `agentGuiTests/TaskMemoryUnifiedWritePathTests.swift`
- Test: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing tests**

锁定 legacy reflection/task memory 不再直接定义长期语义，而是变成 `episodeDelta` 或 extraction input source。

```swift
@Test func reflectionFailureWritesEpisodeDeltaCompatibleRecords() async throws {
    let records = TaskMemoryRecordFactory().makeEpisodeDeltaRecords(
        sessionId: "s1",
        failedAttempts: [FailedAttempt(action: "Run tests", reason: "Scheme missing")],
        timestamp: Date()
    )

    #expect(records.allSatisfy { $0.tags.contains("episode-delta") })
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TaskMemoryUnifiedWritePathTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because TaskMemory still writes confirmed-fact / failed-attempt directly as runtime truth.

**Step 3: Write minimal implementation**

实现迁移策略：

1. `TaskMemory` 保留作兼容输入层，不再当长期语义模型扩展
2. `TaskMemoryRecordFactory` 新增 `episodeDelta` 路径
3. `recordReflectionFailure(...)` 先写 episode delta / extraction candidate，而不是继续放大 legacy categories

不要在这一 task 直接删 `TaskMemory.swift`，先把它收窄成兼容壳。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TaskMemory.swift agentGui/Services/TaskMemoryRecordFactory.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+ContextCompression.swift agentGuiTests/TaskMemoryUnifiedWritePathTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "refactor: demote task memory to episode delta compatibility layer"
```

### Task 8: 更新 rollout/UI，并清理旧概念暴露

**Files:**
- Modify: `agentGui/Models/AppSettings.swift`
- Modify: `agentGui/Views/Settings/SettingsMemoryView.swift`
- Modify: `agentGui/ViewModels/MemoryManagementViewModel.swift`
- Modify: `agentGui/Views/Memory/MemoryManagementPanel.swift`
- Modify: `agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift`
- Test: `agentGuiTests/MemoryRuntimeSettingsTests.swift`
- Test: `agentGuiTests/MemoryManagementViewModelTests.swift`
- Test: `agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift`

**Step 1: Write the failing tests**

锁定新设置项与 view model 文案：不再以 `Admission V2`、`Goal-conditioned Retrieval`、`Legacy layer-based retrieval` 作为主要产品语义。

```swift
@Test func appSettingsExposeRMSFlags() async throws {
    let settings = AppSettings()
    #expect(settings.enableEpistemicExtraction == false)
    #expect(settings.enableRMSRetrieval == false)
    #expect(settings.enableLegacyMemoryCompatibility == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRuntimeSettingsTests \
  -only-testing:agentGuiTests/MemoryManagementViewModelTests \
  -only-testing:agentGuiTests/MemoryRuntimeSnapshotViewModelTests
```

Expected: FAIL because the new RMS flags and view labels do not exist.

**Step 3: Write minimal implementation**

替换或兼容新增设置：

1. `enableEpistemicExtraction`
2. `enableRMSRetrieval`
3. `enableRMSDistillation`
4. `enableLegacyMemoryCompatibility`

并同步更新设置页、管理面板、snapshot 文案，使 UI 以 frontier / counterexample / debt / influence trace 为中心，而不是继续突出 `lifecycleTier` 和 legacy retrieval。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGui/ViewModels/MemoryManagementViewModel.swift agentGui/Views/Memory/MemoryManagementPanel.swift agentGui/ViewModels/MemoryRuntimeSnapshotViewModel.swift agentGuiTests/MemoryRuntimeSettingsTests.swift agentGuiTests/MemoryManagementViewModelTests.swift agentGuiTests/MemoryRuntimeSnapshotViewModelTests.swift
git commit -m "feat: expose rms rollout and observability UI"
```

### Task 9: 删除或正式边缘化旧概念，防止无效代码长期滞留

**Files:**
- Modify: `agentGui/Services/MemoryRetrievalPlanner.swift`
- Modify: `agentGui/Services/MemoryRetrievalIntentClassifier.swift`
- Modify: `agentGui/Services/MemoryExperienceDistillationService.swift`
- Modify: `agentGui/Services/MemoryProcedureInductionService.swift`
- Modify: `agentGui/Services/MemoryLifecycleManager.swift`
- Modify: `agentGui/Services/MemoryWorkingSetBudgeter.swift`
- Modify: `agentGui/Models/MemoryLifecycleTier.swift`
- Modify: `agentGuiTests/MemoryRetrievalPlannerTests.swift`
- Modify: `agentGuiTests/MemoryBackgroundSchedulerTests.swift`
- Modify: `agentGuiTests/MemoryRuntimeIntegrationTests.swift`

**Step 1: Write the failing tests**

把测试目标改成新语义，确保旧对象如果仍存在，也只能作为 compatibility path。

```swift
@Test func retrievalPlannerUsesFrontierAndCounterexamplePriority() throws {
    let planner = MemoryRetrievalPlanner()
    let plan = planner.makeRMSPlan(
        epistemicState: EpistemicState(
            frontiers: [
                FrontierMemory(
                    frontierId: "f-1",
                    goal: "Fix build",
                    openClaim: "Need scheme evidence",
                    uncertaintyType: .tooling,
                    impactLevel: .high,
                    suggestedProbe: "Run xcodebuild -list",
                    stopCondition: "Scheme confirmed"
                )
            ],
            counterexamples: [CounterexampleMemory(id: "ce-1", summary: "Do not edit before inspect", replacementAction: "Inspect first")]
        )
    )

    #expect(plan.intentPhase == .frontierResolution)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/MemoryRetrievalPlannerTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests
```

Expected: FAIL because retrieval and distillation still center old semantics.

**Step 3: Write minimal implementation**

处理原则：

1. `MemoryRetrievalPlanner` 改成 frontier / counterexample / constraint / debt aware planner
2. `MemoryExperienceDistillationService` 与 `MemoryProcedureInductionService` 合并对外语义到 RMS distillation
3. `MemoryLifecycleTier` 降级为 secondary metadata；如果某处仍依赖它，必须经过 compatibility layer
4. 旧测试中仅验证 layer-first / lifecycle-first 逻辑的部分，改写或删除

只有在这一步完成后，才允许把 legacy rollout flag 设为默认关闭。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/MemoryRetrievalPlanner.swift agentGui/Services/MemoryRetrievalIntentClassifier.swift agentGui/Services/MemoryExperienceDistillationService.swift agentGui/Services/MemoryProcedureInductionService.swift agentGui/Services/MemoryLifecycleManager.swift agentGui/Services/MemoryWorkingSetBudgeter.swift agentGui/Models/MemoryLifecycleTier.swift agentGuiTests/MemoryRetrievalPlannerTests.swift agentGuiTests/MemoryBackgroundSchedulerTests.swift agentGuiTests/MemoryRuntimeIntegrationTests.swift
git commit -m "refactor: retire legacy memory semantics behind rms planner"
```

### Task 10: 运行回归验证并冻结 sunset 清单

**Files:**
- Modify: `docs/memory-agent-first-research-2026-03-14.md`
- Modify: `docs/plans/2026-03-14-rms-agent-first-memory-implementation-plan.md`
- Optional Modify: `docs/memory-system-evolution-report-2026-03.md`

**Step 1: Run targeted test suites**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/EpistemicStateTests \
  -only-testing:agentGuiTests/EpistemicExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/EpistemicExtractionResponseParserTests \
  -only-testing:agentGuiTests/EpistemicStateCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/MemoryRuntimeCoordinatorTests \
  -only-testing:agentGuiTests/MemoryRuntimeIntegrationTests \
  -only-testing:agentGuiTests/MemoryBackgroundSchedulerTests
```

Expected: PASS.

**Step 2: Run smoke validation**

Run:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS with no new memory-related regressions.

**Step 3: Update sunset checklist**

把以下对象标记为 `deprecated -> compatibility-only -> removable` 三段状态，并写回研究文档：

1. `TaskMemory` 直接语义写入
2. `MemoryLifecycleTier` 作为 planner 主轴
3. `enableAdmissionV2`
4. `enableGoalConditionedRetrieval`
5. `enableLifecycleManager`
6. `enableExperienceDistillation`

Execution status frozen on 2026-03-14:

1. Tasks 1-9 targeted regression batch passed with 64 tests.
2. `Quality Smoke` remains failing in existing UI smoke coverage: `ChatFlowUITests` (2), `SessionManagementUITests` (1), `ToolCallUITests` (1), `WorkflowRecoveryUITests` (1).
3. Sunset state after Task 9:
    `TaskMemory` direct semantics = compatibility-only via `episode-delta`.
    `MemoryLifecycleTier` = removed from code path, snapshots, and governance UI.
    `enableAdmissionV2`, `enableGoalConditionedRetrieval`, `enableLifecycleManager`, `enableExperienceDistillation` = removed from the code path and replaced by RMS-native names.

**Step 4: Commit**

```bash
git add docs/memory-agent-first-research-2026-03-14.md docs/plans/2026-03-14-rms-agent-first-memory-implementation-plan.md docs/memory-system-evolution-report-2026-03.md
git commit -m "docs: finalize rms migration sunset checklist"
```

## 4. 实施注意事项

1. 不要在 Task 2 之前就把 extraction 逻辑塞进 `MemoryRuntimeCoordinator`。抽取主链属于 agent loop runtime，不属于 retrieval planner。
2. 不要在 Task 3 之前删除 `TaskMemory`。先把它降级成 compatibility shell，再删。
3. 不要让 `MemoryRuntimeSnapshotViewModel` 同时长期保留 “Legacy layer-based retrieval” 和新的 epistemic summary 文案。
4. 不要把 prompt-first extraction 简化成“先规则判断，再让模型补充”。这会重新回到旧思路。
5. 不要保存 extraction 原始推理过程。只保存结构化 residue 和 evidence refs。

## 5. 完成定义

满足以下条件才算这次迁移完成：

1. agent loop 能持续维护 `EpistemicState`。
2. retrieval 和 bootstrap 基于 frontier / counterexample / constraint / debt 运转。
3. background jobs 能产出 `counterexample`、`tacticKernel`、`invalidation`。
4. UI 和 settings 已切换到 RMS 语义。
5. legacy concepts 已有明确删除或 compatibility-only 状态，不再是主产品概念。

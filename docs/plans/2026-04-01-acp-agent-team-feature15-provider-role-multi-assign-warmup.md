# Feature 15: Provider 角色多重分配与 Warm-up 模型选择 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让同一个 ACP provider 可以同时担任 conductor、worker、reviewer 中的一个或多个角色；在用户打开 Brief Composer 时自动 warm-up 所有可用 provider，并将 warm-up 结果（modes、model 选项）暴露给 `AgentTeamMissionBriefDraft`，供后续 Feature 16 UI 展示。

**Architecture:** 三层变更：(1) 模型层——新增 `AgentTeamProviderRole` 枚举与 `AgentTeamProviderRoleAssignment` 结构体；`AgentTeamProviderPlan` 直接重写为以 `roleAssignments: [AgentTeamProviderRoleAssignment]` 为唯一存储字段，`eligibleProviders`、`preferredConductor`、`preferredReviewer` 降为计算属性，删除旧的独立字段存储；(2) ViewModel 层——`AgentTeamMissionBriefDraft` 直接替换 `eligibleProviderIDs`、`preferredConductorID`、`preferredReviewerID` 为 `roleAssignments`，`buildBrief()` 从 roleAssignments 构建 providerPlan；新增 `BriefComposerProviderWarmupCoordinator`（`@Observable @MainActor`），对可用 provider 并发 warm-up 并缓存 modes/modelOptions；(3) View 层——`AgentTeamBriefComposerSheet` 在 `.task` 中触发 warmupCoordinator，将 warm-up 结果写回 `roleAssignments` 内的 `selectedModelID`/`selectedModeID`，provider 选择 UI 改为按 role chip 多选（conductor 唯一性在 toggle 方法内保证）。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, `ACPExternalSessionFeatureStore`（现有），`ClaudeService.handleExecutionProviderSelectionChange`（现有 sessionBootstrap 路径），`ACPProviderProfileRepository`（现有），Swift Testing (`@Test` / `#expect`)。

---

## 依赖说明

- 依赖 Feature 14（`AgentTeamDispatchBudget`、`AgentTeamMissionBriefDraft.rawInput`）。
- 不依赖 Feature 16（UI 重设计），两者可并行。
- 影响文件：`AgentTeamMissionBrief.swift`、`AgentTeamMissionBriefDraft.swift`、`AgentTeamMissionBriefDraftTests.swift`、`AgentTeamMissionBriefTests.swift`、`AgentTeamSessionFactoryTests.swift`、`AgentTeamBriefComposerSheet.swift`。

---

## 关键现有文件速查

| 文件 | Feature 15 关联作用 |
|---|---|
| `agentGui/Models/AgentTeamMissionBrief.swift` | `AgentTeamProviderPlan`（直接重写）、`AgentTeamDispatchBudget` |
| `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift` | `AgentTeamMissionBriefDraft`（直接替换 string ID 字段）、`buildBrief()` |
| `agentGui/Services/Team/AgentTeamSessionFactory.swift` | 调用 `draft.buildBrief()` → 无需修改逻辑 |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | 读 `brief.providerPlan.preferredConductor`、`.eligibleProviders`（通过计算属性继续可用） |
| `agentGui/Services/ACP/ACPExternalSessionFeatureStore.swift` | warm-up 完成后读取 modes/modelOptions |
| `agentGui/Services/ConversationExecutionProviderRegistry.swift` | `ProviderSelectionChangeTrigger.sessionBootstrap` |
| `agentGui/Repositories/ACPProviderProfileRepository.swift` | 枚举所有可用 ACP provider profile |
| `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift` | 需注入 warm-up coordinator，替换 provider 选择 UI |
| `agentGuiTests/AgentTeamMissionBriefTests.swift` | 需新增 roleAssignment 相关测试用例 |
| `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` | 直接用新 API 重写旧 string-ID 用例 |
| `agentGuiTests/AgentTeamSessionFactoryTests.swift` | 直接将 eligibleProviderIDs → roleAssignments API 调用 |

---

## Task 1：新增 `AgentTeamProviderRole` 与 `AgentTeamProviderRoleAssignment`

**Files:**
- Modify: `agentGui/Models/AgentTeamMissionBrief.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefTests.swift`

### 背景

当前 `AgentTeamProviderPlan` 用 `preferredConductor` / `preferredReviewer` 两个独立字段表达角色，reviewer 选项在 UI 层强制排除与 conductor 相同的 provider（见 `AgentTeamBriefComposerSheet.reviewerOptions`），导致同一 provider 无法身兼两职。Feature 15 引入显式 role 枚举与 assignment 结构体。

### Step 1：写失败测试（验证新类型存在与行为）

在 `agentGuiTests/AgentTeamMissionBriefTests.swift` 末尾追加：

```swift
@Test
func providerRoleAssignmentAllowsSameProviderAsConductorAndReviewer() {
    let provider = ExecutionProviderReference.builtIn
    var assignment = AgentTeamProviderRoleAssignment(providerReference: provider)
    assignment.roles.insert(.conductor)
    assignment.roles.insert(.reviewer)

    #expect(assignment.roles.contains(.conductor))
    #expect(assignment.roles.contains(.reviewer))
    #expect(assignment.isConductor)
    #expect(assignment.isReviewer)
}

@Test
func providerRoleAssignmentRoundTripsThroughJSON() throws {
    let assignment = AgentTeamProviderRoleAssignment(
        providerReference: LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference,
        roles: [.conductor, .worker],
        selectedModelID: "claude-opus-4",
        selectedModeID: "code"
    )
    let data = try JSONEncoder().encode(assignment)
    let decoded = try JSONDecoder().decode(AgentTeamProviderRoleAssignment.self, from: data)
    #expect(decoded == assignment)
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`AgentTeamProviderRole`、`AgentTeamProviderRoleAssignment` 未定义。

### Step 3：在 `AgentTeamMissionBrief.swift` 开头追加新类型

在 `import Foundation` 后、`AgentTeamProviderPlan` 之前插入：

```swift
enum AgentTeamProviderRole: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case conductor
    case worker
    case reviewer
}

struct AgentTeamProviderRoleAssignment: Codable, Equatable, Sendable {
    let providerReference: ExecutionProviderReference
    var roles: Set<AgentTeamProviderRole>
    var selectedModelID: String?
    var selectedModeID: String?

    init(
        providerReference: ExecutionProviderReference,
        roles: Set<AgentTeamProviderRole> = [],
        selectedModelID: String? = nil,
        selectedModeID: String? = nil
    ) {
        self.providerReference = providerReference
        self.roles = roles
        self.selectedModelID = selectedModelID
        self.selectedModeID = selectedModeID
    }

    var isConductor: Bool { roles.contains(.conductor) }
    var isWorker:    Bool { roles.contains(.worker) }
    var isReviewer:  Bool { roles.contains(.reviewer) }
}
```

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：新增两个测试通过，其余测试不受影响。

### Step 5：Commit

```bash
git add agentGui/Models/AgentTeamMissionBrief.swift \
        agentGuiTests/AgentTeamMissionBriefTests.swift
git commit -m "feat(team): add AgentTeamProviderRole and AgentTeamProviderRoleAssignment types"
```

---

## Task 2：重写 `AgentTeamProviderPlan` 为 `roleAssignments`-first

**Files:**
- Modify: `agentGui/Models/AgentTeamMissionBrief.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefTests.swift`

### 背景

`AgentTeamProviderPlan` 目前有四个存储字段：`eligibleProviders`、`preferredConductor`、`preferredReviewer`、`dispatchPolicy`。直接重写后，`roleAssignments` 成为唯一存储字段，其他三个改为计算属性，标准 `Codable` 合成即可，无需 migration。

### Step 1：写失败测试

在 `AgentTeamMissionBriefTests.swift` 末尾追加：

```swift
@Test
func providerPlanUsesRoleAssignmentsAsSourceOfTruth() {
    let conductor = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
    let reviewer = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
    let plan = AgentTeamProviderPlan(
        roleAssignments: [
            AgentTeamProviderRoleAssignment(
                providerReference: conductor,
                roles: [.conductor, .worker]
            ),
            AgentTeamProviderRoleAssignment(
                providerReference: reviewer,
                roles: [.reviewer]
            )
        ],
        dispatchPolicy: .manualSelection
    )

    #expect(plan.preferredConductor == conductor)
    #expect(plan.preferredReviewer == reviewer)
    #expect(plan.eligibleProviders == [conductor, reviewer])
}

@Test
func providerPlanAllowsSameProviderAsConductorAndReviewer() {
    let solo = ExecutionProviderReference.builtIn
    let plan = AgentTeamProviderPlan(
        roleAssignments: [
            AgentTeamProviderRoleAssignment(providerReference: solo, roles: [.conductor, .reviewer])
        ],
        dispatchPolicy: .manualSelection
    )
    #expect(plan.preferredConductor == solo)
    #expect(plan.preferredReviewer == solo)
    #expect(plan.eligibleProviders == [solo])
}

@Test
func providerPlanRoleAssignmentsRoundTripsThroughJSON() throws {
    let plan = AgentTeamProviderPlan(
        roleAssignments: [
            AgentTeamProviderRoleAssignment(
                providerReference: .builtIn,
                roles: [.conductor, .reviewer]
            )
        ],
        dispatchPolicy: .autoClaim
    )
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(AgentTeamProviderPlan.self, from: data)
    #expect(decoded == plan)
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task2 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：三个新测试编译错误（`AgentTeamProviderPlan.init(roleAssignments:...)` 不存在）。

### Step 3：重写 `AgentTeamProviderPlan`

将 `AgentTeamMissionBrief.swift` 中现有的 `AgentTeamProviderPlan` 结构体完整替换为：

```swift
struct AgentTeamProviderPlan: Codable, Equatable, Sendable {
    var roleAssignments: [AgentTeamProviderRoleAssignment]
    var dispatchPolicy: AgentTeamDispatchPolicy

    init(
        roleAssignments: [AgentTeamProviderRoleAssignment],
        dispatchPolicy: AgentTeamDispatchPolicy = .manualSelection
    ) {
        self.roleAssignments = roleAssignments
        self.dispatchPolicy = dispatchPolicy
    }

    // MARK: - 计算属性
    var eligibleProviders: [ExecutionProviderReference] {
        roleAssignments.map(\.providerReference)
    }

    var preferredConductor: ExecutionProviderReference {
        roleAssignments.first(where: { $0.isConductor })?.providerReference ?? .builtIn
    }

    var preferredReviewer: ExecutionProviderReference? {
        roleAssignments.first(where: { $0.isReviewer })?.providerReference
    }
}
```

`Codable` 由编译器合成，不需要手写。

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task2 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部测试通过。旧的 `providerPlanPreservesEligibleProvidersAndRoles` 测试此时已使用旧四参数 init，若编译失败则同步删除该测试，改用 `providerPlanUsesRoleAssignmentsAsSourceOfTruth` 替代。

### Step 5：Commit

```bash
git add agentGui/Models/AgentTeamMissionBrief.swift \
        agentGuiTests/AgentTeamMissionBriefTests.swift
git commit -m "feat(team): rewrite AgentTeamProviderPlan to roleAssignments-first, remove legacy fields"
```

---

## Task 3：重写 `AgentTeamMissionBriefDraft` 换用 `roleAssignments`

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefDraftTests.swift`

### 背景

`AgentTeamMissionBriefDraft` 目前用 `eligibleProviderIDs: [String]`、`preferredConductorID: String`、`preferredReviewerID: String` 三个字符串字段表达角色意图。这些字段无法表示同一 provider 的多角色分配。本 Task 直接用 `roleAssignments: [AgentTeamProviderRoleAssignment]` 替换这三个字段，更新所有相关 mutation 方法，保证 `buildBrief()` 输出正确。

### Step 1：写失败测试

在 `AgentTeamMissionBriefDraftTests.swift` 末尾追加：

```swift
@Test
func draftRoleAssignmentsAllowSameProviderAsConductorAndReviewer() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    let provider = ExecutionProviderReference.builtIn
    draft.setRole(.conductor, for: provider, enabled: true)
    draft.setRole(.reviewer, for: provider, enabled: true)

    let assignment = draft.roleAssignments.first(where: { $0.providerReference == provider })
    #expect(assignment?.isConductor == true)
    #expect(assignment?.isReviewer == true)
}

@Test
func draftBuildBriefDerivedFromRoleAssignments() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    let conductor = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
    draft.roleAssignments = [
        AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker])
    ]
    draft.objective = "测试任务"

    let brief = draft.buildBrief()
    #expect(brief.providerPlan.preferredConductor == conductor)
    #expect(brief.providerPlan.eligibleProviders == [conductor])
}

@Test
func draftPrefilledFromSourceSeesSeededProviderAsConductor() {
    let source = NewSessionMenuAction.SourceContext(
        sessionID: "chat-1",
        title: "修复 ACP",
        defaultExecutionProviderReference: LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
    )
    let draft = AgentTeamMissionBriefDraft.prefilled(fromSourceContext: source)
    let conductorAssignment = draft.roleAssignments.first(where: { $0.isConductor })
    #expect(conductorAssignment?.providerReference == LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference)
}

@Test
func draftReconcileProviderOptionsDropsUnavailableAssignments() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    let staleRef = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
    draft.roleAssignments = [
        AgentTeamProviderRoleAssignment(providerReference: staleRef, roles: [.conductor])
    ]
    let options = [ExecutionOptionItem(id: ExecutionProviderReference.builtIn.persistedValue, title: "Built-in", isEnabled: true)]

    draft.reconcileProviderOptions(options)

    #expect(draft.roleAssignments.allSatisfy { options.map(\.id).contains($0.providerReference.persistedValue) })
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task3 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：四个新测试编译错误（`roleAssignments` 字段、`setRole(_:for:enabled:)` 不存在）。

### Step 3：重写 `AgentTeamMissionBriefDraft` 结构体

用以下内容替换 `AgentTeamMissionBriefDraft.swift` 的结构体定义及相关 extension（保留 `BriefExtractionState` 枚举和文件级 `private` helpers 不变）：

```swift
struct AgentTeamMissionBriefDraft: Equatable, Sendable {
    var rawInput: String
    var objective: String
    var constraintsText: String
    var acceptanceCriteriaText: String
    var mode: AgentTeamMode
    var maxActiveProviders: Int
    var initialContextSummary: String
    var sourceSessionTitle: String
    var roleAssignments: [AgentTeamProviderRoleAssignment]
    var dispatchPolicy: AgentTeamDispatchPolicy
    var extractionState: BriefExtractionState

    init(
        rawInput: String = "",
        objective: String = "",
        constraintsText: String = "",
        acceptanceCriteriaText: String = "",
        mode: AgentTeamMode = .executionDelivery,
        maxActiveProviders: Int = 2,
        initialContextSummary: String = "",
        sourceSessionTitle: String = "",
        roleAssignments: [AgentTeamProviderRoleAssignment] = [],
        dispatchPolicy: AgentTeamDispatchPolicy = .manualSelection,
        extractionState: BriefExtractionState = .idle
    ) {
        self.rawInput = rawInput
        self.objective = objective
        self.constraintsText = constraintsText
        self.acceptanceCriteriaText = acceptanceCriteriaText
        self.mode = mode
        self.maxActiveProviders = maxActiveProviders
        self.initialContextSummary = initialContextSummary
        self.sourceSessionTitle = sourceSessionTitle
        self.roleAssignments = roleAssignments
        self.dispatchPolicy = dispatchPolicy
        self.extractionState = extractionState
    }
}
```

### Step 4：更新 `prefilled(from:)` 与 `prefilled(fromSourceContext:)`

```swift
extension AgentTeamMissionBriefDraft {
    static func prefilled(from source: Session?) -> Self {
        let sourceTitle = source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = source?.lastMessagePreview.trimmedNonEmpty
        let seededProvider: ExecutionProviderReference?
        if let persisted = source?.defaultExecutionProviderReference,
           persisted != .builtIn || source?.defaultExecutionProviderID.isEmpty == false {
            seededProvider = persisted
        } else {
            seededProvider = nil
        }
        let assignments = Self.initialAssignments(seededConductor: seededProvider)
        return Self(
            rawInput: "",
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: preview),
            sourceSessionTitle: sourceTitle,
            roleAssignments: assignments,
            dispatchPolicy: seededProvider != nil ? .sourceSessionSeeded : .manualSelection,
            extractionState: .idle
        )
    }

    static func prefilled(fromSourceContext sourceContext: NewSessionMenuAction.SourceContext?) -> Self {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seededProvider = sourceContext.flatMap { ctx -> ExecutionProviderReference? in
            let ref = ctx.defaultExecutionProviderReference
            return ref.persistedValue.isEmpty ? nil : ref
        }
        let assignments = Self.initialAssignments(seededConductor: seededProvider)
        return Self(
            rawInput: "",
            objective: defaultObjective(for: sourceTitle),
            constraintsText: "",
            acceptanceCriteriaText: "",
            mode: .executionDelivery,
            maxActiveProviders: 2,
            initialContextSummary: defaultContextSummary(sourceTitle: sourceTitle, preview: nil),
            sourceSessionTitle: sourceTitle,
            roleAssignments: assignments,
            dispatchPolicy: seededProvider != nil ? .sourceSessionSeeded : .manualSelection,
            extractionState: .idle
        )
    }

    /// 初始时若有 seeded provider，自动分配为 conductor+worker；否则空分配
    private static func initialAssignments(
        seededConductor: ExecutionProviderReference?
    ) -> [AgentTeamProviderRoleAssignment] {
        guard let ref = seededConductor else { return [] }
        return [AgentTeamProviderRoleAssignment(providerReference: ref, roles: [.conductor, .worker])]
    }
}
```

### Step 5：更新 `buildBrief()` 与 role mutation 方法

```swift
extension AgentTeamMissionBriefDraft {
    func buildBrief() -> AgentTeamMissionBrief {
        AgentTeamMissionBrief(
            objective: resolvedObjective,
            constraints: Self.normalizeLines(from: constraintsText),
            acceptanceCriteria: Self.normalizeLines(from: acceptanceCriteriaText),
            mode: mode,
            dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: max(1, maxActiveProviders)),
            initialContextSummary: resolvedContextSummary,
            providerPlan: AgentTeamProviderPlan(
                roleAssignments: roleAssignments,
                dispatchPolicy: dispatchPolicy
            )
        )
    }

    /// 为某个 provider 设置或取消某个 role。
    /// conductor 唯一性规则：若 enabled=true 且 role==.conductor，
    /// 先将其他所有 assignment 的 .conductor 移除。
    mutating func setRole(
        _ role: AgentTeamProviderRole,
        for provider: ExecutionProviderReference,
        enabled: Bool
    ) {
        if enabled, role == .conductor {
            for i in roleAssignments.indices {
                roleAssignments[i].roles.remove(.conductor)
            }
        }
        if let idx = roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
            if enabled {
                roleAssignments[idx].roles.insert(role)
            } else {
                roleAssignments[idx].roles.remove(role)
            }
        } else if enabled {
            roleAssignments.append(
                AgentTeamProviderRoleAssignment(providerReference: provider, roles: [role])
            )
        }
    }

    /// 若 provider 不在 assignments 中，追加（roles 为空）；否则移除整条 assignment。
    mutating func toggleProviderParticipation(_ provider: ExecutionProviderReference) {
        if let idx = roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
            roleAssignments.remove(at: idx)
            // 若被移除的是 conductor，自动把第一个 worker 提升为 conductor
            if !roleAssignments.contains(where: { $0.isConductor }),
               let first = roleAssignments.indices.first {
                roleAssignments[first].roles.insert(.conductor)
            }
        } else {
            roleAssignments.append(
                AgentTeamProviderRoleAssignment(providerReference: provider, roles: [.worker])
            )
        }
    }

    /// 根据可用 provider 列表过滤 roleAssignments，保证 conductor 始终存在。
    mutating func reconcileProviderOptions(
        _ options: [ExecutionOptionItem],
        sourceDefaultProviderID: String? = nil
    ) {
        let availableIDs = Set(options.filter(\.isEnabled).map(\.id))
        roleAssignments = roleAssignments.filter {
            availableIDs.contains($0.providerReference.persistedValue)
        }
        // 若有 seeded provider 且 assignments 为空，自动追加 conductor
        if roleAssignments.isEmpty,
           let seedID = sourceDefaultProviderID,
           !seedID.isEmpty,
           availableIDs.contains(seedID) {
            let ref = ExecutionProviderReference.decodePersisted(seedID)
            roleAssignments = [AgentTeamProviderRoleAssignment(providerReference: ref, roles: [.conductor, .worker])]
        }
        // 保证至少存在一个 conductor
        if !roleAssignments.contains(where: { $0.isConductor }),
           let first = roleAssignments.indices.first {
            roleAssignments[first].roles.insert(.conductor)
        }
        // 更新 dispatchPolicy
        if let seedID = sourceDefaultProviderID,
           !seedID.isEmpty,
           roleAssignments.first(where: { $0.isConductor })?.providerReference.persistedValue == seedID {
            dispatchPolicy = .sourceSessionSeeded
        } else {
            dispatchPolicy = .manualSelection
        }
    }
}
```

### Step 6：更新旧测试用例

在 `AgentTeamMissionBriefDraftTests.swift` 中，直接修改以下三个使用旧字段的测试：
- `buildBriefNormalizesMultilineFields`（使用了 `draft.eligibleProviderIDs`、`draft.preferredConductorID`）
- `sourceContextPrefillsSeededProviderParticipationPlan`（使用了旧字段）
- `reconcileProviderOptionsDropsUnavailableSelectionsWithoutImplicitStandaloneFallback`（旧字段）

前两个已被 Step 1 追加的新测试所替代，直接删除旧测试即可。`buildBriefNormalizesMultilineFields` 用以下版本就地替换：

```swift
@Test
func buildBriefNormalizesMultilineFields() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.rawInput = "修复 ACP 团队协作中的并发问题"
    draft.objective = "为 ACP team 生成修复计划"
    draft.constraintsText = " 仅修改 Swift 文件 \n\n 保持 focused tests \n"
    draft.acceptanceCriteriaText = " Mission Header 回显 brief \n\n team session 持久化 brief  "
    draft.maxActiveProviders = 2
    let conductor = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
    draft.roleAssignments = [
        AgentTeamProviderRoleAssignment(providerReference: conductor, roles: [.conductor, .worker])
    ]

    let brief = draft.buildBrief()

    #expect(brief.objective == "为 ACP team 生成修复计划")
    #expect(brief.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
    #expect(brief.acceptanceCriteria == ["Mission Header 回显 brief", "team session 持久化 brief"])
    #expect(brief.dispatchBudget == AgentTeamDispatchBudget(maxActiveProviders: 2))
}
```

（`sourceContextPrefillsSeededProviderParticipationPlan` 已被 `draftPrefilledFromSourceSeesSeededProviderAsConductor` 替代，`reconcileProviderOptionsDropsUnavailableSelectionsWithoutImplicitStandaloneFallback` 已被 `draftReconcileProviderOptionsDropsUnavailableAssignments` 替代，两者在 Step 1 中已添加，直接删除旧版本即可。）

### Step 7：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task3 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部 AgentTeamMissionBriefDraftTests 通过。

### Step 8：Commit

```bash
git add agentGui/ViewModels/AgentTeamMissionBriefDraft.swift \
        agentGuiTests/AgentTeamMissionBriefDraftTests.swift
git commit -m "feat(team): rewrite AgentTeamMissionBriefDraft with roleAssignments, remove string ID fields"
```

---

## Task 4：更新 `AgentTeamSessionFactoryTests` 使用新 API

**Files:**
- Modify: `agentGuiTests/AgentTeamSessionFactoryTests.swift`

### 背景

`AgentTeamSessionFactoryTests` 中多处测试使用了 `draft.eligibleProviderIDs`、`draft.preferredConductorID`、`draft.preferredReviewerID`——这些字段在 Task 3 中已被删除。`AgentTeamSessionFactory.create(from:draft:)` 自身不变（它只调用 `draft.buildBrief()`），只需直接修改测试的对象构造方式。

### Step 1：运行测试，确认编译失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task4 \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -20
```

预期：编译错误，`Value of type 'AgentTeamMissionBriefDraft' has no member 'eligibleProviderIDs'`。

### Step 2：修复 `AgentTeamSessionFactoryTests.swift`

以 `createFromChatPersistsMissionBriefIntoState` 测试为例，将旧字段构造替换为 roleAssignments API：

旧代码：
```swift
draft.eligibleProviderIDs = [
    ExecutionProviderReference.builtIn.persistedValue,
    LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference.persistedValue
]
draft.preferredConductorID = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference.persistedValue
```

替换为：
```swift
let conductorRef = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
draft.roleAssignments = [
    AgentTeamProviderRoleAssignment(providerReference: .builtIn, roles: [.worker]),
    AgentTeamProviderRoleAssignment(providerReference: conductorRef, roles: [.conductor, .worker])
]
```

对测试文件内所有其他字段引用（`preferredConductorID`、`preferredReviewerID`、`eligibleProviderIDs`）做相同方向的直接替换。断言中 `result.state.missionBrief?.providerPlan.preferredConductor` 仍有效（计算属性）。

### Step 3：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task4 \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 AgentTeamSessionFactoryTests 通过。

### Step 4：Commit

```bash
git add agentGuiTests/AgentTeamSessionFactoryTests.swift
git commit -m "test(team): update AgentTeamSessionFactoryTests for roleAssignments-first draft API"
```

---

## Task 5：新增 `BriefComposerProviderWarmupCoordinator`

**Files:**
- Create: `agentGui/ViewModels/BriefComposerProviderWarmupCoordinator.swift`
- Create: `agentGuiTests/BriefComposerProviderWarmupCoordinatorTests.swift`

### 背景

Brief Composer Sheet 打开时，需要对所有已启用的 ACP provider 发起后台 warm-up 探测，获取可用 modes 和 model 选项，以便让用户在创建 team 前直接为每个 provider 选择模型。warm-up 不能阻塞用户输入，失败时降级为静态 curated 列表。

### Step 1：写测试（仅可测核心逻辑；warm-up 需要真实 provider，用 stub 隔离）

在新文件 `agentGuiTests/BriefComposerProviderWarmupCoordinatorTests.swift` 创建：

```swift
import Testing
@testable import agentGui

@MainActor
struct BriefComposerProviderWarmupCoordinatorTests {
    @Test
    func initialStateIsIdleForAllProviders() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        #expect(coord.warmupState(for: ref) == .idle)
    }

    @Test
    func markReadyStoresModesAndModelOptions() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = LegacyExternalACPProviderKey.openCodeCLI.compatibilityReference
        let modes = [ExecutionOptionItem(id: "code", title: "Code")]
        let models = [ExecutionOptionItem(id: "model-a", title: "Model A")]
        coord.markReady(ref, modes: modes, modelOptions: models)
        if case .ready(let m, let mo) = coord.warmupState(for: ref) {
            #expect(m == modes)
            #expect(mo == models)
        } else {
            Issue.record("Expected .ready state")
        }
    }

    @Test
    func markFailedSetsFailedState() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        coord.markFailed(ref)
        #expect(coord.warmupState(for: ref) == .failed)
    }

    @Test
    func isWarmingReturnsTrueOnlyWhenAtLeastOneProviderWarming() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = ExecutionProviderReference.builtIn
        #expect(coord.isWarmingAny == false)
        coord.markWarming(ref)
        #expect(coord.isWarmingAny == true)
        coord.markFailed(ref)
        #expect(coord.isWarmingAny == false)
    }

    @Test
    func fallbackModelOptionsReturnedWhenFailed() {
        let coord = BriefComposerProviderWarmupCoordinator()
        let ref = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference
        coord.markFailed(ref)
        let options = coord.modelOptions(for: ref)
        // fallback 应为 non-empty curated list
        #expect(!options.isEmpty)
    }
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task5 \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`BriefComposerProviderWarmupCoordinator` 未定义。

### Step 3：创建 `BriefComposerProviderWarmupCoordinator.swift`

```swift
import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class BriefComposerProviderWarmupCoordinator {
    enum WarmupState: Equatable {
        case idle
        case warming
        case ready(modes: [ExecutionOptionItem], modelOptions: [ExecutionOptionItem])
        case failed
    }

    private var states: [ExecutionProviderReference: WarmupState] = [:]

    // MARK: - 查询

    func warmupState(for provider: ExecutionProviderReference) -> WarmupState {
        states[provider] ?? .idle
    }

    var isWarmingAny: Bool {
        states.values.contains(where: { $0 == .warming })
    }

    func modelOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        if case .ready(_, let models) = states[provider] { return models }
        // Fallback：静态 curated list（按 provider 类型选择）
        return fallbackModelOptions(for: provider)
    }

    func modeOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        if case .ready(let modes, _) = states[provider] { return modes }
        return []
    }

    // MARK: - 状态写入（由 warmup 方法和测试调用）

    func markWarming(_ provider: ExecutionProviderReference) {
        states[provider] = .warming
    }

    func markReady(
        _ provider: ExecutionProviderReference,
        modes: [ExecutionOptionItem],
        modelOptions: [ExecutionOptionItem]
    ) {
        states[provider] = .ready(modes: modes, modelOptions: modelOptions)
    }

    func markFailed(_ provider: ExecutionProviderReference) {
        states[provider] = .failed
    }

    // MARK: - 真实 warm-up 入口（在 View 的 .task 中调用）

    /// 对单个 ACP provider 触发 warm-up，超时 8 秒后 markFailed。
    func warmup(
        provider: ExecutionProviderReference,
        claudeService: ClaudeService,
        sourceSession: Session?,
        modelContext: ModelContext
    ) async {
        guard states[provider] == nil || states[provider] == .idle else { return }
        markWarming(provider)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw CancellationError()
                }
                group.addTask { @MainActor in
                    // 使用 source session（有时）或临时 session ID 进行 bootstrap 探测
                    let probeSession: Session
                    if let existing = sourceSession {
                        probeSession = existing
                    } else {
                        probeSession = Session(title: "__warmup_probe__", kind: .local)
                        modelContext.insert(probeSession)
                    }
                    await claudeService.handleExecutionProviderSelectionChange(
                        session: probeSession,
                        selectedProviderReference: provider,
                        modelContext: modelContext,
                        trigger: .sessionBootstrap
                    )
                    // 读取配置快照
                    let featureStore = claudeService.featureStore(
                        for: probeSession.sessionId,
                        provider: provider,
                        modelContext: modelContext
                    )
                    let snapshot = featureStore?.latestConfigurationSnapshot(
                        for: provider,
                        sessionID: probeSession.sessionId
                    )
                    let modes = snapshot?.modes?.map { ExecutionOptionItem(id: $0.id, title: $0.displayName) } ?? []
                    let models = snapshot?.modelOptions?.map { ExecutionOptionItem(id: $0.id, title: $0.displayName) }
                        ?? self.fallbackModelOptions(for: provider)
                    // 清理临时 session
                    if sourceSession == nil {
                        modelContext.delete(probeSession)
                    }
                    await MainActor.run {
                        self.markReady(provider, modes: modes, modelOptions: models)
                    }
                }
                // 取第一个完成的——若超时先结束则抛错进 catch
                if let result = try await group.next() {
                    group.cancelAll()
                    _ = result
                }
            }
        } catch {
            markFailed(provider)
        }
    }

    // MARK: - Private

    private func fallbackModelOptions(for provider: ExecutionProviderReference) -> [ExecutionOptionItem] {
        switch provider {
        case .externalACP(let key) where key == LegacyExternalACPProviderKey.githubCopilotCLI.rawValue:
            return GitHubCopilotCLIConfiguration.curatedModelOptions
        default:
            return []
        }
    }
}
```

> **注意**：上述 `warmup(...)` 实现中 `claudeService.featureStore(for:provider:modelContext:)` 是一个需要确认的方法签名——若 `ClaudeService` 不直接暴露 `featureStore`，则把读取 snapshot 的逻辑改为通过 `ACPExternalProviderSessionStateStore` 获取（见 `agentGui/Services/ACP/ACPExternalProviderSessionStateStore.swift`）。执行计划时先读实际 API 再决定。

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task5 \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：5 个测试全部通过。

### Step 5：Commit

```bash
git add agentGui/ViewModels/BriefComposerProviderWarmupCoordinator.swift \
        agentGuiTests/BriefComposerProviderWarmupCoordinatorTests.swift
git commit -m "feat(team): add BriefComposerProviderWarmupCoordinator with per-provider WarmupState"
```

---

## Task 6：将 `AgentTeamBriefComposerSheet` 更新为 roleAssignments UI + 触发 warm-up

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

Brief Composer Sheet 当前使用 Toggle + Picker 实现 `eligibleProviderIDs` / `preferredConductorID`——这套 API 已被 Task 3 删除。本 Task：
1. 将 provider 选择替换为 role chip 行（Conductor / Worker / Reviewer 三个 toggleable Text chip）。
2. 注入 `BriefComposerProviderWarmupCoordinator`，在 Sheet 出现时触发所有 provider warm-up。
3. 每个 provider 行显示 warm-up 状态 indicator（`.idle` → 空、`.warming` → ProgressView、`.ready` → 绿色圆点、`.failed` → 灰色圆点）。
4. `.ready` 时在 provider 行展示 Model 与 Mode 的简单 Picker，写入 `draft.roleAssignments[i].selectedModelID`/`.selectedModeID`。

### Step 1：确认编译错误

先直接构建，确认 Task 3 带来的编译错误：

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f15-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -30
```

预期：`has no member 'eligibleProviderIDs'`、`'preferredConductorID'`、`'preferredReviewerID'`、`'toggleEligibleProvider'` 等错误集中在 `AgentTeamBriefComposerSheet.swift`。

### Step 2：替换 provider 选择区域

在 `AgentTeamBriefComposerSheet.swift` 中：

**（a）添加 `@State` warm-up coordinator**

```swift
@State private var warmupCoordinator = BriefComposerProviderWarmupCoordinator()
```

**（b）删除旧字段引用方法**

删除或重写 `resolvedProviderOptions`、`selectedProviderOptions`、`reviewerOptions` 计算属性（它们依赖旧字段），以及 `reconcileProviderOptions` 调用处。

**（c）将 provider section 替换为 role chip section**

用以下结构替换 Sheet 中的 "Provider 选择" VStack 区域：

```swift
// MARK: - Provider 角色分配区

private var providerRoleSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Team 成员与角色")
            .font(.headline)

        let options = resolvedAllProviderOptions
        if options.isEmpty {
            Text("未检测到启用的 Provider，将使用内置 Built-in。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(options, id: \.id) { option in
                let ref = ExecutionProviderReference.decodePersisted(option.id)
                ProviderRoleRowView(
                    providerName: option.title,
                    warmupState: warmupCoordinator.warmupState(for: ref),
                    assignment: assignmentBinding(for: ref),
                    modelOptions: warmupCoordinator.modelOptions(for: ref),
                    modeOptions: warmupCoordinator.modeOptions(for: ref)
                )
            }
        }
    }
}

/// 从 roleAssignments 提供 Binding
private func assignmentBinding(
    for provider: ExecutionProviderReference
) -> Binding<AgentTeamProviderRoleAssignment> {
    Binding(
        get: {
            self.draft.roleAssignments.first(where: { $0.providerReference == provider })
                ?? AgentTeamProviderRoleAssignment(providerReference: provider)
        },
        set: { newValue in
            if let idx = self.draft.roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
                self.draft.roleAssignments[idx] = newValue
            } else {
                self.draft.roleAssignments.append(newValue)
            }
        }
    )
}
```

**（d）新增 `ProviderRoleRowView`（内嵌在同文件或单独 file）**

```swift
private struct ProviderRoleRowView: View {
    let providerName: String
    let warmupState: BriefComposerProviderWarmupCoordinator.WarmupState
    @Binding var assignment: AgentTeamProviderRoleAssignment
    let modelOptions: [ExecutionOptionItem]
    let modeOptions: [ExecutionOptionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Warm-up 状态 indicator
                warmupStatusView
                Text(providerName)
                    .fontWeight(.medium)
                Spacer()
                // Role chips
                ForEach(AgentTeamProviderRole.allCases, id: \.self) { role in
                    RoleChipButton(
                        label: role.displayLabel,
                        isSelected: assignment.roles.contains(role)
                    ) {
                        toggleRole(role)
                    }
                }
            }
            // Model/Mode picker（仅 warm-up 成功后显示）
            if case .ready = warmupState, !modelOptions.isEmpty {
                HStack(spacing: 12) {
                    if !modelOptions.isEmpty {
                        Picker("模型", selection: Binding(
                            get: { assignment.selectedModelID ?? "" },
                            set: { assignment.selectedModelID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("默认").tag("")
                            ForEach(modelOptions) { opt in
                                Text(opt.title).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    if !modeOptions.isEmpty {
                        Picker("模式", selection: Binding(
                            get: { assignment.selectedModeID ?? "" },
                            set: { assignment.selectedModeID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("默认").tag("")
                            ForEach(modeOptions) { opt in
                                Text(opt.title).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    @ViewBuilder
    private var warmupStatusView: some View {
        switch warmupState {
        case .idle:    Color.clear.frame(width: 10, height: 10)
        case .warming: ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case .ready:   Circle().fill(.green).frame(width: 8, height: 8)
        case .failed:  Circle().fill(.secondary).frame(width: 8, height: 8)
        }
    }

    private func toggleRole(_ role: AgentTeamProviderRole) {
        // conductor 唯一性由 chunk: `setRole` 的外部保证；
        // 这里简化：直接 toggle，让 draft.setRole 管理唯一性
        var copy = assignment
        if copy.roles.contains(role) {
            copy.roles.remove(role)
        } else {
            copy.roles.insert(role)
        }
        assignment = copy
    }
}

private struct RoleChipButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension AgentTeamProviderRole {
    fileprivate var displayLabel: String {
        switch self {
        case .conductor: "指挥"
        case .worker:    "执行"
        case .reviewer:  "审核"
        }
    }
}
```

**（e）在 body 中触发 warm-up**

在 `body` 的 `.task` 修饰符中添加 warm-up 触发：

```swift
.task(id: sourceContext?.sessionID ?? "") {
    // 已有：extractionVM 初始化...
    // 新增：触发所有 provider warm-up
    let allOptions = resolvedAllProviderOptions
    await withTaskGroup(of: Void.self) { group in
        for option in allOptions where option.isEnabled {
            let ref = ExecutionProviderReference.decodePersisted(option.id)
            group.addTask { @MainActor in
                await warmupCoordinator.warmup(
                    provider: ref,
                    claudeService: claudeService,
                    sourceSession: nil, // 无法直接访问 source session 对象，传 nil 使用临时 probe
                    modelContext: modelContext
                )
            }
        }
    }
}
```

**（f）更新 `reconcileProviderOptions` 调用**

将 `draft.reconcileProviderOptions(options, sourceDefaultProviderID: ...)` 的调用位置（原 `onAppear` 或 `resolvedProviderOptions`）改为：

```swift
draft.reconcileProviderOptions(
    resolvedAllProviderOptions,
    sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
)
```

其中 `resolvedAllProviderOptions` 是已有的 `resolvedProviderOptions` 重命名。

### Step 3：构建验证通过

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f15-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED" | tail -10
```

预期：`BUILD SUCCEEDED`，无编译错误。

### Step 4：运行全量相关测试，验证无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f15-task6-full \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部通过。

### Step 5：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(team): wire BriefComposerProviderWarmupCoordinator into Brief Composer, replace provider UI with role chips"
```

---

## 验收标准

1. 同一 provider 可以在 Brief Composer 中被同时标记为 conductor 和 reviewer，创建的 `AgentTeamMissionBrief` 中 `providerPlan.preferredConductor == providerPlan.preferredReviewer` 成立。
2. Brief Composer 打开后，ACP provider 行显示 warm-up 进度（idle/warming/ready/failed indicator）。
3. warm-up 成功的 provider 行展示可用 models 和 modes 的 Picker，选中值写入 `roleAssignments[i].selectedModelID`/`.selectedModeID`。
4. warm-up 失败的 provider 仍可参与 team（角色 chip 仍可 toggle），只是无 model picker（或展示 fallback curated list）。
5. `AgentTeamLaunchCoordinator` 通过 `brief.providerPlan.preferredConductor`（计算属性）读取 conductor，行为与 Feature 1-14 一致，无需修改。
6. 所有 Feature 1-14 的已有 Team 测试（Claim、TaskBoard、ArtifactBoard、ReviewReport 等）继续通过。
7. 所有调用旧 `AgentTeamProviderPlan(eligibleProviders:preferredConductor:preferredReviewer:dispatchPolicy:)` 的地方均已直接替换为 `roleAssignments` 构造，代码库中不存在旧字段引用。

---

## 回归测试命令

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-feature15-regression \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamArtifactBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamMergeGateEvaluatorTests \
  -only-testing:agentGuiTests/AgentTeamReviewCoordinatorTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

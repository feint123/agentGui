# Feature 14: Smart Brief Composer — 单输入口与 AI 结构化提取 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Team Mission Brief 的创建入口收敛为单个自由文本输入框，通过内置 built-in LLM 自动提取结构化字段（objective、constraints、acceptanceCriteria），并彻底移除对 ACP provider 无实际调度意义的 `tokenBudgetText` / `costBudgetText` 字段。

**Architecture:** 三层变更：(1) 模型层——`AgentTeamBudget` → `AgentTeamDispatchBudget`（仅保留 `maxActiveProviders`），`AgentTeamMissionBriefDraft` 新增 `rawInput` 与 `extractionState`；(2) 服务层——新增 `MissionBriefExtractionService` 协议与 `BuiltInMissionBriefExtractionService` 实现（单轮 LLM JSON 提取，复用 `ModelResponseJSONExtractor` 与 `AnthropicService`）；(3) UI 层——`AgentTeamBriefComposerSheet` 主界面替换为单 TextEditor + "解析 Brief" 按钮 + 提取结果预览区。不引入兼容性保护——直接替换所有引用。

**Tech Stack:** Swift 6, SwiftUI, SwiftAnthropic (`AnthropicService.createMessage`), `ModelResponseJSONExtractor`（现有），SwiftData (`AppSettings.selectedModel`, `AppSettings.apiKey`)。

---

## 依赖说明

- 不依赖 Feature 13，可独立执行。
- 变更影响：`AgentTeamMissionBrief`、`AgentTeamBudget`、`AgentTeamMissionBriefDraft`、`AgentTeamMissionBriefResolver`、`AgentTeamLaunchCoordinator`、`AgentTeamMissionBriefResolverTests`、`AgentTeamMissionBriefTests`、`AgentTeamMissionBriefDraftTests`、`AgentTeamSessionFactoryTests`、`AgentTeamBriefComposerSheet`。

---

## Task 1: 重命名 `AgentTeamBudget` → `AgentTeamDispatchBudget`，移除文本字段

**Files:**
- Modify: `agentGui/Models/AgentTeamMissionBrief.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefTests.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefResolverTests.swift`
- Modify: `agentGuiTests/AgentTeamSessionFactoryTests.swift`

**背景**

当前 `AgentTeamBudget` 有三个字段：`maxActiveProviders: Int`、`tokenBudgetText: String`、`costBudgetText: String`。后两个字段在 ACP 执行层无任何调度语义。Feature 14 要求完全移除并重命名结构体。

**Step 1: 写失败测试——验证新结构没有文本字段**

在 `agentGuiTests/AgentTeamMissionBriefTests.swift` 中，**删除** 旧的 `budgetPreservesStableFields` 测试，添加新测试：

```swift
@Test
func dispatchBudgetOnlyHasMaxActiveProviders() {
    let budget = AgentTeamDispatchBudget(maxActiveProviders: 3)
    #expect(budget.maxActiveProviders == 3)
}

@Test
func briefUsesDispatchBudget() throws {
    let brief = AgentTeamMissionBrief(
        objective: "测试",
        constraints: [],
        acceptanceCriteria: [],
        mode: .executionDelivery,
        dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
        initialContextSummary: ""
    )
    let data = try JSONEncoder().encode(brief)
    let decoded = try JSONDecoder().decode(AgentTeamMissionBrief.self, from: data)
    #expect(decoded.dispatchBudget.maxActiveProviders == 2)
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`AgentTeamDispatchBudget` 未定义。

**Step 3: 修改 `agentGui/Models/AgentTeamMissionBrief.swift`**

1. 删除 `AgentTeamBudget` 结构体，新增：

```swift
struct AgentTeamDispatchBudget: Codable, Equatable, Sendable {
    var maxActiveProviders: Int

    init(maxActiveProviders: Int = 2) {
        self.maxActiveProviders = maxActiveProviders
    }
}
```

2. 在 `AgentTeamMissionBrief` 中，将 `var budget: AgentTeamBudget` 替换为 `var dispatchBudget: AgentTeamDispatchBudget`，更新 `init`：

```swift
struct AgentTeamMissionBrief: Codable, Equatable, Sendable {
    var objective: String
    var constraints: [String]
    var acceptanceCriteria: [String]
    var mode: AgentTeamMode
    var dispatchBudget: AgentTeamDispatchBudget
    var initialContextSummary: String
    var providerPlan: AgentTeamProviderPlan

    init(
        objective: String,
        constraints: [String],
        acceptanceCriteria: [String],
        mode: AgentTeamMode,
        dispatchBudget: AgentTeamDispatchBudget = AgentTeamDispatchBudget(),
        initialContextSummary: String,
        providerPlan: AgentTeamProviderPlan = AgentTeamProviderPlan(
            eligibleProviders: [.builtIn],
            preferredConductor: .builtIn,
            preferredReviewer: nil,
            dispatchPolicy: .manualSelection
        )
    ) {
        self.objective = objective
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
        self.mode = mode
        self.dispatchBudget = dispatchBudget
        self.initialContextSummary = initialContextSummary
        self.providerPlan = providerPlan
    }
}
```

3. 为 `AgentTeamMissionBrief` 添加向后兼容 Codable 解码（读旧 `budget` key 并映射）：

```swift
// MARK: - Codable Migration (budget → dispatchBudget)
extension AgentTeamMissionBrief {
    enum CodingKeys: String, CodingKey {
        case objective, constraints, acceptanceCriteria
        case mode, dispatchBudget, initialContextSummary, providerPlan
        case legacyBudget = "budget"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objective = try c.decode(String.self, forKey: .objective)
        constraints = try c.decode([String].self, forKey: .constraints)
        acceptanceCriteria = try c.decode([String].self, forKey: .acceptanceCriteria)
        mode = try c.decode(AgentTeamMode.self, forKey: .mode)
        initialContextSummary = try c.decodeIfPresent(String.self, forKey: .initialContextSummary) ?? ""
        providerPlan = try c.decodeIfPresent(AgentTeamProviderPlan.self, forKey: .providerPlan)
            ?? AgentTeamProviderPlan(eligibleProviders: [.builtIn], preferredConductor: .builtIn, preferredReviewer: nil, dispatchPolicy: .manualSelection)

        if let newBudget = try c.decodeIfPresent(AgentTeamDispatchBudget.self, forKey: .dispatchBudget) {
            dispatchBudget = newBudget
        } else if let legacy = try? c.decodeIfPresent(LegacyBudgetDecodable.self, forKey: .legacyBudget) {
            dispatchBudget = AgentTeamDispatchBudget(maxActiveProviders: legacy.maxActiveProviders)
        } else {
            dispatchBudget = AgentTeamDispatchBudget()
        }
    }

    private struct LegacyBudgetDecodable: Decodable {
        let maxActiveProviders: Int
    }
}
```

**Step 4: 修复所有编译错误**

全局搜索并替换所有 `budget:` 参数（`AgentTeamBudget(...)` → `AgentTeamDispatchBudget(...)`，移除 `tokenBudgetText` / `costBudgetText` 参数），涉及文件：
- `agentGui/Services/Team/AgentTeamMissionBriefResolver.swift` — `fallbackBrief` 中移除 budget 文本字段
- `agentGuiTests/AgentTeamMissionBriefTests.swift` — 已在 Step 1 更新
- `agentGuiTests/AgentTeamMissionBriefResolverTests.swift` — 替换 `budget: .init(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium")` → `dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2)`
- `agentGuiTests/AgentTeamSessionFactoryTests.swift` — 同上

**Step 5: 运行测试验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试 PASS。

**Step 6: Commit**

```bash
git add agentGui/Models/AgentTeamMissionBrief.swift \
  agentGui/Services/Team/AgentTeamMissionBriefResolver.swift \
  agentGuiTests/AgentTeamMissionBriefTests.swift \
  agentGuiTests/AgentTeamMissionBriefResolverTests.swift \
  agentGuiTests/AgentTeamSessionFactoryTests.swift
git commit -m "feat(f14): rename AgentTeamBudget to AgentTeamDispatchBudget, remove text fields"
```

---

## Task 2: 更新 `AgentTeamMissionBriefDraft` — 移除文本 Budget 字段，新增 `rawInput` 与 `extractionState`

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefDraftTests.swift`

**背景**

`AgentTeamMissionBriefDraft` 是 Sheet 的临时编辑模型。需要：
1. 移除 `tokenBudgetText` 和 `costBudgetText`
2. 新增 `rawInput: String`（主输入框绑定）
3. 新增 `extractionState: BriefExtractionState`（驱动 UI loading 状态）
4. `buildBrief()` 改用 `AgentTeamDispatchBudget`
5. `rawInput` 为空时 `buildBrief()` 用 `objective`；`objective` 也空时用 `rawInput` 作为 fallback objective

**Step 1: 写失败测试**

在 `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` 中，**删除** 所有引用 `tokenBudgetText` / `costBudgetText` 的测试，更新 `buildBriefNormalizesMultilineFields` 测试：

```swift
@Test
func buildBriefNormalizesMultilineFields() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.rawInput = "修复 ACP 团队协作中的并发问题"
    draft.objective = "为 ACP team 生成修复计划"
    draft.constraintsText = " 仅修改 Swift 文件 \n\n 保持 focused tests \n"
    draft.acceptanceCriteriaText = " Mission Header 回显 brief \n\n team session 持久化 brief  "
    draft.maxActiveProviders = 2
    draft.eligibleProviderIDs = [
        ExecutionProviderReference.builtIn.persistedValue,
        LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue
    ]
    draft.preferredConductorID = LegacyExternalACPProviderKey.githubCopilotCLI.compatibilityReference.persistedValue

    let brief = draft.buildBrief()

    #expect(brief.objective == "为 ACP team 生成修复计划")
    #expect(brief.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
    #expect(brief.acceptanceCriteria == ["Mission Header 回显 brief", "team session 持久化 brief"])
    #expect(brief.dispatchBudget == AgentTeamDispatchBudget(maxActiveProviders: 2))
}

@Test
func buildBriefFallsBackToRawInputWhenObjectiveEmpty() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.rawInput = "快速修复并发问题"
    draft.objective = ""
    draft.eligibleProviderIDs = [ExecutionProviderReference.builtIn.persistedValue]
    draft.preferredConductorID = ExecutionProviderReference.builtIn.persistedValue

    let brief = draft.buildBrief()
    #expect(brief.objective == "快速修复并发问题")
}

@Test
func extractionStateDefaultsToIdle() {
    let draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    #expect(draft.extractionState == .idle)
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task2 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`rawInput` / `extractionState` / `BriefExtractionState` 未定义。

**Step 3: 新增 `BriefExtractionState` enum**

在 `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift` 文件顶部（`import Foundation` 后）新增：

```swift
enum BriefExtractionState: Equatable, Sendable {
    case idle
    case extracting
    case done
    case failed(String)
}
```

**Step 4: 更新 `AgentTeamMissionBriefDraft` 结构体**

- 移除 `tokenBudgetText: String` 和 `costBudgetText: String` 字段
- 新增：
  ```swift
  var rawInput: String
  var extractionState: BriefExtractionState
  ```
- 更新 `init` 参数：移除两个文本 budget 参数，新增 `rawInput: String = ""`、`extractionState: BriefExtractionState = .idle`

完整更新后结构体需拥有字段：
```
rawInput, objective, constraintsText, acceptanceCriteriaText,
mode, maxActiveProviders,
initialContextSummary, sourceSessionTitle,
eligibleProviderIDs, preferredConductorID, preferredReviewerID,
dispatchPolicy, extractionState
```

**Step 5: 更新 `prefilled(from:)` 和 `prefilled(fromSourceContext:)` 工厂方法**

移除 `tokenBudgetText: "20k"` 和 `costBudgetText: "medium"` 参数，新增 `rawInput: ""` 和 `extractionState: .idle`。

**Step 6: 更新 `buildBrief()` 方法**

```swift
func buildBrief() -> AgentTeamMissionBrief {
    AgentTeamMissionBrief(
        objective: resolvedObjective,
        constraints: Self.normalizeLines(from: constraintsText),
        acceptanceCriteria: Self.normalizeLines(from: acceptanceCriteriaText),
        mode: mode,
        dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: max(1, maxActiveProviders)),
        initialContextSummary: resolvedContextSummary,
        providerPlan: buildProviderPlan()
    )
}
```

更新 `resolvedObjective` 计算属性：

```swift
private var resolvedObjective: String {
    // objective 优先；若空则用 rawInput；若仍空则用 source session title fallback
    let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedObjective.isEmpty { return trimmedObjective }
    let trimmedRaw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedRaw.isEmpty { return trimmedRaw }
    return Self.defaultObjective(for: sourceSessionTitle)
}
```

**Step 7: 更新 `canSubmit` 逻辑（为 Sheet 快速路径做准备）**

注意：`canSubmit` 目前在 Sheet 里计算，Draft 自身不持有此属性，不需要修改 Draft，只需确保 Sheet 侧会检查 `rawInput` 非空（Task 5 处理）。

**Step 8: 运行测试验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task2 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试 PASS。

**Step 9: Commit**

```bash
git add agentGui/ViewModels/AgentTeamMissionBriefDraft.swift \
  agentGuiTests/AgentTeamMissionBriefDraftTests.swift
git commit -m "feat(f14): add rawInput/extractionState to MissionBriefDraft, remove budget text fields"
```

---

## Task 3: 新增 `MissionBriefExtractionService` 协议与 `BuiltInMissionBriefExtractionService` 实现

**Files:**
- Create: `agentGui/Services/Team/MissionBriefExtractionService.swift`
- Create: `agentGuiTests/MissionBriefExtractionServiceTests.swift`

**背景**

这是 Feature 14 的核心服务层。使用 built-in LLM 发送单轮请求（`service.createMessage`），通过 JSON schema 约束让 LLM 返回 `{objective, constraints, acceptanceCriteria, suggestedMode}` 结构，然后用 `ModelResponseJSONExtractor` 解析。

**Step 1: 写失败测试**

创建 `agentGuiTests/MissionBriefExtractionServiceTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

struct MissionBriefExtractionServiceTests {

    // MARK: - Stub

    struct StubSuccessService: MissionBriefExtractionService {
        let result: MissionBriefExtractionResult
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            result
        }
    }

    struct StubFailService: MissionBriefExtractionService {
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            throw URLError(.timedOut)
        }
    }

    @Test
    func stubSuccessReturnsExpectedResult() async throws {
        let expected = MissionBriefExtractionResult(
            objective: "为 ACP 修复并发问题",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["Focused tests 全通过"],
            suggestedMode: .executionDelivery
        )
        let service: any MissionBriefExtractionService = StubSuccessService(result: expected)
        let result = try await service.extract(from: "修复 ACP 并发问题，只改 Swift 文件，测试绿")
        #expect(result.objective == expected.objective)
        #expect(result.constraints == expected.constraints)
        #expect(result.acceptanceCriteria == expected.acceptanceCriteria)
        #expect(result.suggestedMode == .executionDelivery)
    }

    @Test
    func stubFailPropagatesError() async {
        let service: any MissionBriefExtractionService = StubFailService()
        do {
            _ = try await service.extract(from: "some input")
            #expect(Bool(false), "应当抛出错误")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    // JSON 解析逻辑测试（直接测 extractionResultFromJSON）
    @Test
    func parsesBriefExtractionJSON() throws {
        let json = """
        {
          "objective": "统一修复 ACP team",
          "constraints": ["仅修改 Swift 文件", "保持 focused tests"],
          "acceptanceCriteria": ["Mission Header 回显 brief"],
          "suggestedMode": "executionDelivery"
        }
        """
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON(json)
        #expect(result?.objective == "统一修复 ACP team")
        #expect(result?.constraints == ["仅修改 Swift 文件", "保持 focused tests"])
        #expect(result?.acceptanceCriteria == ["Mission Header 回显 brief"])
        #expect(result?.suggestedMode == .executionDelivery)
    }

    @Test
    func parsesBriefExtractionJSONWithCodeFence() throws {
        let json = """
        ```json
        {
          "objective": "修复 ACP",
          "constraints": [],
          "acceptanceCriteria": [],
          "suggestedMode": "creativeExploration"
        }
        ```
        """
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON(json)
        #expect(result?.objective == "修复 ACP")
        #expect(result?.suggestedMode == .creativeExploration)
    }

    @Test
    func parseReturnsNilForMalformedJSON() {
        let result = BuiltInMissionBriefExtractionService.parseExtractionJSON("not json")
        #expect(result == nil)
    }
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task3 \
  -only-testing:agentGuiTests/MissionBriefExtractionServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，协议与类型未定义。

**Step 3: 实现 `MissionBriefExtractionService.swift`**

创建 `agentGui/Services/Team/MissionBriefExtractionService.swift`：

```swift
import Foundation
import SwiftAnthropic

// MARK: - Result

struct MissionBriefExtractionResult: Sendable, Equatable {
    let objective: String
    let constraints: [String]
    let acceptanceCriteria: [String]
    let suggestedMode: AgentTeamMode
}

// MARK: - Protocol

protocol MissionBriefExtractionService: Sendable {
    func extract(from rawInput: String) async throws -> MissionBriefExtractionResult
}

// MARK: - Built-In Implementation

struct BuiltInMissionBriefExtractionService: MissionBriefExtractionService {

    let service: any AnthropicService
    let modelID: String

    func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
        let prompt = buildPrompt(rawInput: rawInput)
        let params = MessageParameter(
            model: .other(modelID),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 1024
        )
        let response = try await service.createMessage(params)
        let raw = response.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()

        guard let result = Self.parseExtractionJSON(raw) else {
            // 降级：将 rawInput 整体作为 objective
            return MissionBriefExtractionResult(
                objective: rawInput.trimmingCharacters(in: .whitespacesAndNewlines),
                constraints: [],
                acceptanceCriteria: [],
                suggestedMode: .executionDelivery
            )
        }
        return result
    }

    // MARK: - Internal (exposed for testing)

    static func parseExtractionJSON(_ raw: String) -> MissionBriefExtractionResult? {
        guard let parsed = ModelResponseJSONExtractor.decodeIfPresent(ExtractionJSON.self, from: raw) else {
            return nil
        }
        let mode = AgentTeamMode(rawValue: parsed.suggestedMode) ?? .executionDelivery
        return MissionBriefExtractionResult(
            objective: parsed.objective,
            constraints: parsed.constraints,
            acceptanceCriteria: parsed.acceptanceCriteria,
            suggestedMode: mode
        )
    }

    // MARK: - Private

    private func buildPrompt(rawInput: String) -> String {
        """
        你是一个任务分析助手。分析下方任务描述，提取结构化 brief。**只输出 JSON，不要包含任何其他文字或代码块标记**。

        输出格式（严格 JSON，所有字段必须存在）：
        {
          "objective": "一句话描述任务核心目标",
          "constraints": ["约束1", "约束2"],
          "acceptanceCriteria": ["验收条件1", "验收条件2"],
          "suggestedMode": "executionDelivery"
        }

        `suggestedMode` 可选值：
        - "executionDelivery"：目标明确、需要实际交付物（代码修复、文档生成等）
        - "creativeExploration"：需要多角度创意探索（方案探索、头脑风暴等）
        - "researchAndSynthesis"：需要调研汇总（技术选型、文献综述等）

        约束说明：若任务描述中没有明确约束，`constraints` 请填空数组。验收条件同理。

        任务描述：
        \(rawInput)
        """
    }

    // MARK: - JSON Decodable

    private struct ExtractionJSON: Decodable {
        let objective: String
        let constraints: [String]
        let acceptanceCriteria: [String]
        let suggestedMode: String
    }
}
```

**Step 4: 将新文件加入 Xcode target**

在 `agentGui.xcodeproj` 中，将 `MissionBriefExtractionService.swift` 和 `MissionBriefExtractionServiceTests.swift` 加入各自 target。

**Step 5: 运行测试验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task3 \
  -only-testing:agentGuiTests/MissionBriefExtractionServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试 PASS。

**Step 6: Commit**

```bash
git add agentGui/Services/Team/MissionBriefExtractionService.swift \
  agentGuiTests/MissionBriefExtractionServiceTests.swift \
  agentGui.xcodeproj/project.pbxproj
git commit -m "feat(f14): add MissionBriefExtractionService protocol and BuiltInMissionBriefExtractionService"
```

---

## Task 4: 新增 `BriefComposerExtractionViewModel` — 驱动提取交互状态

**Files:**
- Create: `agentGui/ViewModels/BriefComposerExtractionViewModel.swift`
- Create: `agentGuiTests/BriefComposerExtractionViewModelTests.swift`

**背景**

Sheet 的提取交互逻辑需要一个独立的 `@Observable` ViewModel 来管理：自动触发防抖（1.5s 后触发）、正在提取期间阻止重复请求、提取完成后更新 Draft 字段。将这个逻辑从 View 中抽出，确保可单元测试。

**Step 1: 写失败测试**

创建 `agentGuiTests/BriefComposerExtractionViewModelTests.swift`：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct BriefComposerExtractionViewModelTests {

    struct ImmediateSuccessExtractionService: MissionBriefExtractionService {
        let result: MissionBriefExtractionResult
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult { result }
    }

    struct ImmediateFailExtractionService: MissionBriefExtractionService {
        func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
            throw URLError(.timedOut)
        }
    }

    @Test
    func extractPopulatesDraftFields() async {
        let expected = MissionBriefExtractionResult(
            objective: "修复 ACP 并发问题",
            constraints: ["仅修改 Swift 文件"],
            acceptanceCriteria: ["tests 全通过"],
            suggestedMode: .executionDelivery
        )
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "修复 ACP 并发问题"

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateSuccessExtractionService(result: expected)
        )
        await vm.triggerExtraction(draft: &draft)

        #expect(draft.objective == "修复 ACP 并发问题")
        #expect(draft.constraintsText == "仅修改 Swift 文件")
        #expect(draft.acceptanceCriteriaText == "tests 全通过")
        #expect(draft.mode == .executionDelivery)
        #expect(draft.extractionState == .done)
    }

    @Test
    func extractSetsFailedStateOnError() async {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "测试输入"

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateFailExtractionService()
        )
        await vm.triggerExtraction(draft: &draft)

        if case .failed = draft.extractionState {
            // pass
        } else {
            #expect(Bool(false), "应当进入 failed 状态，实际：\(draft.extractionState)")
        }
    }

    @Test
    func extractDoesNothingWhenRawInputIsEmpty() async {
        var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
        draft.rawInput = "   "

        let vm = BriefComposerExtractionViewModel(
            extractionService: ImmediateSuccessExtractionService(
                result: MissionBriefExtractionResult(
                    objective: "不应出现",
                    constraints: [],
                    acceptanceCriteria: [],
                    suggestedMode: .executionDelivery
                )
            )
        )
        await vm.triggerExtraction(draft: &draft)

        #expect(draft.extractionState == .idle)
        #expect(draft.objective == "")
    }
}
```

**Step 2: 运行测试验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task4 \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`BriefComposerExtractionViewModel` 未定义。

**Step 3: 实现 `BriefComposerExtractionViewModel`**

创建 `agentGui/ViewModels/BriefComposerExtractionViewModel.swift`：

```swift
import Foundation
import SwiftAnthropic

@Observable
@MainActor
final class BriefComposerExtractionViewModel {

    private let extractionService: any MissionBriefExtractionService
    private var debounceTask: Task<Void, Never>?

    init(extractionService: any MissionBriefExtractionService) {
        self.extractionService = extractionService
    }

    // MARK: - Public API

    /// 立即触发提取（点击按钮路径）
    func triggerExtraction(draft: inout AgentTeamMissionBriefDraft) async {
        let trimmedInput = draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }

        draft.extractionState = .extracting
        do {
            let result = try await extractionService.extract(from: trimmedInput)
            applyResult(result, to: &draft)
            draft.extractionState = .done
        } catch {
            draft.extractionState = .failed(error.localizedDescription)
        }
    }

    /// 启动防抖提取（输入停止 1.5s 后触发），供 onChange 调用
    func scheduleDebounceExtraction(draft: Binding<AgentTeamMissionBriefDraft>) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            draft.wrappedValue.extractionState = .extracting
            let trimmedInput = draft.wrappedValue.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty else {
                draft.wrappedValue.extractionState = .idle
                return
            }
            do {
                let result = try await self.extractionService.extract(from: trimmedInput)
                self.applyResult(result, to: &draft.wrappedValue)
                draft.wrappedValue.extractionState = .done
            } catch {
                if !Task.isCancelled {
                    draft.wrappedValue.extractionState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Private

    private func applyResult(
        _ result: MissionBriefExtractionResult,
        to draft: inout AgentTeamMissionBriefDraft
    ) {
        draft.objective = result.objective
        draft.constraintsText = result.constraints.joined(separator: "\n")
        draft.acceptanceCriteriaText = result.acceptanceCriteria.joined(separator: "\n")
        draft.mode = result.suggestedMode
    }
}

// MARK: - Binding helpers for tests
// `Binding` cannot be used in pure test targets without SwiftUI import.
// We expose triggerExtraction(draft:) with inout for tests; Binding variant is
// used only from Views.
```

> **注意：** SwiftUI 的 `Binding<AgentTeamMissionBriefDraft>` 用于 `scheduleDebounceExtraction`，需要 `import SwiftUI`。纯测试用例只测 `triggerExtraction(draft:)` 的 `inout` 版本，不需要 SwiftUI。

**Step 4: 加入 Xcode target，运行测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task4 \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试 PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/BriefComposerExtractionViewModel.swift \
  agentGuiTests/BriefComposerExtractionViewModelTests.swift \
  agentGui.xcodeproj/project.pbxproj
git commit -m "feat(f14): add BriefComposerExtractionViewModel with debounce and inout trigger"
```

---

## Task 5: 重写 `AgentTeamBriefComposerSheet` — 单输入框 + 提取结果预览区

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

**背景**

原 Sheet 有多个独立 TextEditor（Objective、Constraints、Acceptance Criteria）和 Budget 文本字段。新 Sheet：
- 主区域：单个大 TextEditor（`rawInput` 绑定）+ "解析 Brief" 按钮
- 提取结果展示：提取完成后以可折叠预览卡片展示 objective / constraints / acceptanceCriteria，支持点击进入编辑
- 快速路径：用户可以跳过提取、直接用 rawInput 提交（`canSubmit` 检查 rawInput 或 objective 非空）
- Budget 区：`maxActiveProviders` 移入可折叠"高级选项" DisclosureGroup，默认折叠
- 提取状态：`.extracting` 时显示 ProgressView + 屏蔽按钮，`.failed` 时显示内联错误

此任务为 UI 层改动，无需单元测试（UI 可视验证为主），但必须确保编译通过且 `AgentTeamBriefComposerRequest` 不受影响。

**Step 1: 确认编译环境无其他错误**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f14-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:" | head -30
```

**Step 2: 重写 Sheet**

将 `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift` 中的 `AgentTeamBriefComposerSheet` 结构体 `body` 替换为以下设计：

```swift
import SwiftUI
import SwiftData

struct AgentTeamBriefComposerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService

    let sourceContext: NewSessionMenuAction.SourceContext?
    let onCancel: () -> Void
    let onSubmit: (AgentTeamMissionBriefDraft) -> Void

    @State private var draft: AgentTeamMissionBriefDraft
    @State private var extractionVM: BriefComposerExtractionViewModel?
    @State private var showAdvancedOptions = false
    @State private var showExtractionDetail = false

    init(
        sourceContext: NewSessionMenuAction.SourceContext?,
        initialDraft: AgentTeamMissionBriefDraft,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (AgentTeamMissionBriefDraft) -> Void
    ) {
        self.sourceContext = sourceContext
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("创建 Team Mission Brief")
                    .font(.title3.weight(.semibold))
                Text(sourceSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentTeam.brief.sourceSummary")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // MARK: 主输入框
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务描述")
                            .font(.headline)
                        TextEditor(text: $draft.rawInput)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18))
                            )
                            .accessibilityIdentifier("agentTeam.brief.rawInput")
                            .onChange(of: draft.rawInput) { _, _ in
                                extractionVM?.scheduleDebounceExtraction(draft: $draft)
                            }

                        HStack {
                            // 提取状态提示
                            extractionStatusLabel
                            Spacer()
                            Button("解析 Brief") {
                                Task { await extractionVM?.triggerExtraction(draft: &draft) }
                            }
                            .disabled(draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || draft.extractionState == .extracting)
                            .accessibilityIdentifier("agentTeam.brief.extractButton")
                        }
                    }

                    // MARK: 提取结果预览（仅在 done 时展示）
                    if draft.extractionState == .done || showExtractionDetail {
                        extractionResultSection
                    }

                    // MARK: Provider 选择（保持原逻辑不变）
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Providers")
                            .font(.headline)

                        if resolvedProviderOptions.isEmpty {
                            Text("当前没有可用 provider。请先在设置中启用至少一个执行器。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(resolvedProviderOptions) { option in
                                Toggle(isOn: binding(for: option.id)) {
                                    Text(option.title)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("agentTeam.brief.provider.\(option.id)")
                            }

                            Picker("Conductor", selection: $draft.preferredConductorID) {
                                ForEach(selectedProviderOptions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(selectedProviderOptions.isEmpty)
                            .accessibilityIdentifier("agentTeam.brief.preferredConductor")

                            Picker("Reviewer", selection: $draft.preferredReviewerID) {
                                Text("不指定").tag("")
                                ForEach(reviewerOptions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(selectedProviderOptions.isEmpty)
                            .accessibilityIdentifier("agentTeam.brief.preferredReviewer")
                        }
                    }

                    // MARK: 高级选项（折叠）
                    DisclosureGroup("高级选项", isExpanded: $showAdvancedOptions) {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(value: $draft.maxActiveProviders, in: 1...6) {
                                Text("并发上限：\(draft.maxActiveProviders)")
                            }
                            .accessibilityIdentifier("agentTeam.brief.maxActiveProviders")

                            Picker("Mode", selection: $draft.mode) {
                                ForEach(AgentTeamMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("agentTeam.brief.mode")

                            Text("Initial Context Summary")
                                .font(.headline)
                            TextEditor(text: $draft.initialContextSummary)
                                .frame(minHeight: 80)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                                .accessibilityIdentifier("agentTeam.brief.contextSummary")
                        }
                        .padding(.top, 4)
                    }
                }
            }

            // Footer
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("agentTeam.brief.cancel")

                Button("创建 Team") {
                    onSubmit(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSubmit == false)
                .accessibilityIdentifier("agentTeam.brief.submit")
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520, alignment: .topLeading)
        .accessibilityIdentifier("agentTeam.briefComposer")
        .onAppear {
            draft.reconcileProviderOptions(
                resolvedProviderOptions,
                sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
            )
            setupExtractionVM()
        }
        .onDisappear {
            extractionVM?.cancelDebounce()
        }
    }

    // MARK: - Extraction Status Label

    @ViewBuilder
    private var extractionStatusLabel: some View {
        switch draft.extractionState {
        case .idle:
            EmptyView()
        case .extracting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在解析…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("解析完成", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - Extraction Result Section

    @ViewBuilder
    private var extractionResultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("解析结果（可编辑）")
                .font(.headline)

            TextField("Objective", text: $draft.objective, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agentTeam.brief.objective")

            Text("Constraints")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $draft.constraintsText)
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .accessibilityIdentifier("agentTeam.brief.constraints")

            Text("Acceptance Criteria")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $draft.acceptanceCriteriaText)
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .accessibilityIdentifier("agentTeam.brief.acceptance")
        }
    }

    // MARK: - Helpers

    private var canSubmit: Bool {
        let hasInput = draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasProvider = draft.eligibleProviderIDs.isEmpty == false
            && draft.preferredConductorID.isEmpty == false
        return hasInput && hasProvider
    }

    private var sourceSummary: String {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sourceTitle.isEmpty { return "独立 Team Mode 会话" }
        return "来源会话：\(sourceTitle)"
    }

    private var resolvedProviderOptions: [ExecutionOptionItem] {
        SettingsStore(modelContext: modelContext, persistenceCoordinator: nil)
            .defaultExecutionProviderOptions()
            .filter(\.isEnabled)
    }

    private var selectedProviderOptions: [ExecutionOptionItem] {
        resolvedProviderOptions.filter { draft.eligibleProviderIDs.contains($0.id) }
    }

    private var reviewerOptions: [ExecutionOptionItem] {
        selectedProviderOptions.filter { $0.id != draft.preferredConductorID }
    }

    private func binding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { draft.eligibleProviderIDs.contains(providerID) },
            set: { _ in draft.toggleEligibleProvider(providerID) }
        )
    }

    private func setupExtractionVM() {
        guard let service = claudeService.service else { return }
        let settings = AppSettings.getOrCreate(in: modelContext)
        extractionVM = BriefComposerExtractionViewModel(
            extractionService: BuiltInMissionBriefExtractionService(
                service: service,
                modelID: settings.selectedModel
            )
        )
    }
}
```

**Step 3: 验证编译**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f14-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

预期：无 error。

**Step 4: Commit**

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f14): rewrite BriefComposerSheet with single rawInput, extraction preview, advanced options"
```

---

## Task 6: 修复 `AgentTeamMissionBriefResolver.fallbackBrief` 中的 Budget 引用

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamMissionBriefResolver.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefResolverTests.swift`

**背景**

`AgentTeamMissionBriefResolver.fallbackBrief` 中仍然构造 `AgentTeamBudget(maxActiveProviders: 2, tokenBudgetText: "20k", costBudgetText: "medium")`，需要改为 `AgentTeamDispatchBudget(maxActiveProviders: 2)`。若 Task 1 已正确完成，此处应当已导致编译错误被修复——通过此 Task 单独验证并补充测试。

**Step 1: 补充测试**

在 `agentGuiTests/AgentTeamMissionBriefResolverTests.swift` 中新增：

```swift
@Test
func fallbackBriefUsesDispatchBudget() {
    let brief = AgentTeamMissionBriefResolver.fallbackBrief(
        sessionTitle: "Test",
        sourceTitle: nil,
        mode: .executionDelivery
    )
    #expect(brief.dispatchBudget.maxActiveProviders >= 1)
}
```

**Step 2: 确认 `fallbackBrief` 使用 `AgentTeamDispatchBudget`**

检查 `agentGui/Services/Team/AgentTeamMissionBriefResolver.swift` 中 `fallbackBrief`，确认：
```swift
dispatchBudget: AgentTeamDispatchBudget(maxActiveProviders: 2),
```
若未修改（Task 1 遗漏），此时补改。

**Step 3: 运行测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task6 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有测试 PASS。

**Step 4: Commit**

```bash
git add agentGui/Services/Team/AgentTeamMissionBriefResolver.swift \
  agentGuiTests/AgentTeamMissionBriefResolverTests.swift
git commit -m "feat(f14): update fallbackBrief to use AgentTeamDispatchBudget"
```

---

## Task 7: `AgentTeamLaunchCoordinator` 与 `AgentTeamTaskBoardCoordinator` 中 budget 引用清理

**Files:**
- Modify: `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift`
- Modify: `agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift`（如有 budget 引用）
- Modify: `agentGuiTests/AgentTeamLaunchCoordinatorTests.swift`（如有）

**背景**

`AgentTeamLaunchCoordinator` 在 `claimPrimaryCard` 中读取 `brief.budget.maxActiveProviders`，需要改为 `brief.dispatchBudget.maxActiveProviders`。

**Step 1: 搜索所有 `.budget.` 引用**

在项目中搜索 `\.budget\.` 或 `brief.budget`，找出所有残留引用：

```bash
grep -rn "\.budget\." agentGui/ --include="*.swift"
grep -rn "\.budget\." agentGuiTests/ --include="*.swift"
```

**Step 2: 修改所有引用**

将 `brief.budget.maxActiveProviders` 替换为 `brief.dispatchBudget.maxActiveProviders`。

**Step 3: 运行全量 Team 相关测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-task7 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/MissionBriefExtractionServiceTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：所有测试 PASS，零 error。

**Step 4: Commit**

```bash
git add agentGui/Services/Team/AgentTeamLaunchCoordinator.swift \
  agentGui/Services/Team/AgentTeamTaskBoardCoordinator.swift
git commit -m "feat(f14): replace budget.maxActiveProviders with dispatchBudget.maxActiveProviders"
```

---

## Task 8: 全量回归验证与 Smoke 构建

**Files:**
- 无新文件，验证已有所有变更

**Step 1: 运行所有 Agent Team 测试（含已有测试）**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f14-smoke \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/AgentTeamLaunchCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamClaimCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamTaskBoardCoordinatorTests \
  -only-testing:agentGuiTests/AgentTeamWorkbenchPresentationTests \
  -only-testing:agentGuiTests/MissionBriefExtractionServiceTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case).*passed|failed|error:" | tail -40
```

预期：全部 PASS，零 failed。

**Step 2: 完整 build 验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f14-smoke \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

预期：`BUILD SUCCEEDED`。

**Step 3: 验证 Feature 14 验收标准**

逐条手工检查：

1. **[ ]** Sheet 打开时只有一个主要输入框（rawInput TextEditor），用户无需打开任何折叠区域就能完成 Team 创建。
2. **[ ]** 输入文本后点击"解析 Brief"或等待 1.5s 自动触发，Sheet 进入 extracting 状态（ProgressView 可见）。
3. **[ ]** 提取完成后 objective / constraints / acceptanceCriteria 预览区可见，字段可编辑。
4. **[ ]** Budget 相关文本字段（tokenBudget、costBudget）在任何 UI 位置不可见。
5. **[ ]** 跳过提取直接输入 rawInput 后点击"创建 Team"，能成功创建。
6. **[ ]** 提取失败时显示内联错误提示，"创建 Team" 按钮仍可用（降级路径）。
7. **[ ]** 旧的 JSON 持久化数据（含 `budget` key）能正确 Codable migration，`maxActiveProviders` 不丢失。

**Step 4: 最终 Commit**

```bash
git add -A
git commit -m "feat(f14): smart brief composer — single input, AI extraction, remove budget text fields"
```

---

## 文件变更总览

| 文件 | 操作 | 说明 |
|---|---|---|
| `agentGui/Models/AgentTeamMissionBrief.swift` | 修改 | `AgentTeamBudget` → `AgentTeamDispatchBudget`，移除文本字段，添加 Codable migration |
| `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift` | 修改 | 新增 `rawInput`、`extractionState`、`BriefExtractionState`；移除 budget 文本字段 |
| `agentGui/Services/Team/AgentTeamMissionBriefResolver.swift` | 修改 | `fallbackBrief` 改用 `AgentTeamDispatchBudget` |
| `agentGui/Services/Team/AgentTeamLaunchCoordinator.swift` | 修改 | `budget.maxActiveProviders` → `dispatchBudget.maxActiveProviders` |
| `agentGui/Services/Team/MissionBriefExtractionService.swift` | **新建** | 协议 + `BuiltInMissionBriefExtractionService` 实现 |
| `agentGui/ViewModels/BriefComposerExtractionViewModel.swift` | **新建** | 提取交互 ViewModel（防抖 + 状态驱动） |
| `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift` | 修改 | 单输入框 + 提取结果区 + 高级选项折叠 |
| `agentGuiTests/AgentTeamMissionBriefTests.swift` | 修改 | 替换 budget 测试为 dispatchBudget 测试 |
| `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` | 修改 | 移除旧 budget 字段断言，新增 rawInput / extractionState 测试 |
| `agentGuiTests/AgentTeamMissionBriefResolverTests.swift` | 修改 | 替换 budget 为 dispatchBudget |
| `agentGuiTests/AgentTeamSessionFactoryTests.swift` | 修改 | 同上 |
| `agentGuiTests/MissionBriefExtractionServiceTests.swift` | **新建** | 协议 stub 测试 + JSON 解析测试 |
| `agentGuiTests/BriefComposerExtractionViewModelTests.swift` | **新建** | ViewModel 状态流转测试 |

---

**Plan complete and saved to `docs/plans/2026-03-31-acp-agent-team-feature14-smart-brief-composer.md`.**

**两个执行选项：**

**1. Subagent-Driven（本 session）** — 逐 Task 派发子 agent，每 Task 完成后审查，快速迭代

**2. Parallel Session（新 session）** — 在新 session 中使用 executing-plans skill 批量执行

**请选择哪种方式？**

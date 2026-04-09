# S-G1 · SkillsView 增强 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `SkillsView` 从"名称 + 描述 + 开关"三段式展示升级为能完整展示 S-A1 扩展后 Skill Manifest 的丰富 UI，包括来源徽章、执行上下文标签、版本号、whenToUse 可折叠区、参数提示标签以及条件激活状态，同时为内置技能（`.bundled`）隐藏开关改为只读展示。

**Architecture:** 提取一个纯 struct `SkillRowPresentation`（不依赖 SwiftUI，方便单元测试）来封装所有行级显示决策；所有 SwiftUI 辅助视图以 `private` struct 形式留在 `SkillsView.swift` 内，避免过度拆文件。扩展状态（哪些行展开了 whenToUse）由父视图用 `@State private var expandedIDs: Set<String>` 托管。

**Tech Stack:** Swift 6, SwiftUI, 现有 `Skill` / `SkillEnums` / `SkillService` / `WorkbenchSidebarPanelStyle`

---

## 背景与约束

### 已完成的依赖

| 特性 | 文件 | 状态 |
|------|------|------|
| S-A1 Skill Manifest 扩展 | `agentGui/Models/Skill.swift` | ✅ 含 whenToUse / argumentHint / version / paths / loadedFrom / executionContext 等字段 |
| SkillEnums | `agentGui/Models/SkillEnums.swift` | ✅ `SkillSource`、`SkillExecutionContext`、`EffortLevel` |
| SkillService @Observable | `agentGui/Services/SkillService.swift` | ✅ `availableSkills: [Skill]`、`enabledSkills()` |
| WorkbenchSidebarPanelStyle | `agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift` | ✅ 色调、间距常量 |
| 现有 SkillsView | `agentGui/Views/Skills/SkillsView.swift` | ✅ 已有框架，本 Feature 在此基础修改 |

### 尚不存在的部分（本 Feature 范围）

- `agentGui/Views/Skills/SkillRowPresentation.swift` ← 纯 struct，行级显示决策
- `agentGuiTests/SkillsViewPresentationTests.swift` ← 单元测试
- `SkillsView.swift` 的 UI 增强部分（展示新字段）

### 当前 skillRow 布局

```
[name (semibold)] [description (caption, secondary)]     [Toggle]
```

### 目标 skillRow 布局

```
[name (semibold)]  [argumentHint tag?]         [Toggle / "内置" chip]
[description (caption, secondary)]
[source badge]  [fork badge?]  [version badge?]  [paths badge?]
▼ whenToUse（可折叠，仅在字段非空时展示）
```

### SkillSource → UI 映射

| source | 显示文本 | 颜色语义 |
|--------|---------|---------|
| `.user` | 用户  | `.secondary` (gray) |
| `.project` | 项目 | `.blue` |
| `.managed` | 管理 | `.orange` |
| `.bundled` | 内置 | `.purple` |

### 激活状态（paths 字段）

| 条件 | 展示 |
|------|-----|
| `paths == nil` | 无额外标签（始终可用）|
| `paths != nil` | "按路径激活" 灰色 chip |

---

## 测试运行命令

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sg1-derived \
  -only-testing:agentGuiTests/SkillsViewPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|SUCCEEDED|FAILED"
```

---

## Task 1 — 创建 `SkillRowPresentation` struct（纯逻辑，无 SwiftUI）

**Files:**
- Create: `agentGui/Views/Skills/SkillRowPresentation.swift`

### Step 1: 写 failing 测试文件（先骨架）

新建 `agentGuiTests/SkillsViewPresentationTests.swift`，写入以下测试（此时 `SkillRowPresentation` 还不存在，所有 case 都会编译失败）：

```swift
// agentGuiTests/SkillsViewPresentationTests.swift
import XCTest
@testable import agentGui

final class SkillsViewPresentationTests: XCTestCase {

    // MARK: - toggleIsVisible

    func test_toggleIsVisible_userSkill_true() {
        let skill = makeSkill(loadedFrom: .user)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_projectSkill_true() {
        let skill = makeSkill(loadedFrom: .project)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_managedSkill_true() {
        let skill = makeSkill(loadedFrom: .managed)
        XCTAssertTrue(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    func test_toggleIsVisible_bundledSkill_false() {
        let skill = makeSkill(loadedFrom: .bundled)
        XCTAssertFalse(SkillRowPresentation(skill: skill).toggleIsVisible)
    }

    // MARK: - sourceLabel

    func test_sourceLabel_user() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .user)).sourceLabel, "用户")
    }

    func test_sourceLabel_project() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .project)).sourceLabel, "项目")
    }

    func test_sourceLabel_managed() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .managed)).sourceLabel, "管理")
    }

    func test_sourceLabel_bundled() {
        XCTAssertEqual(SkillRowPresentation(skill: makeSkill(loadedFrom: .bundled)).sourceLabel, "内置")
    }

    // MARK: - showForkBadge

    func test_showForkBadge_inlineContext_false() {
        let skill = makeSkill(executionContext: .inline)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showForkBadge)
    }

    func test_showForkBadge_forkContext_true() {
        let skill = makeSkill(executionContext: .fork)
        XCTAssertTrue(SkillRowPresentation(skill: skill).showForkBadge)
    }

    // MARK: - versionText

    func test_versionText_nil_whenNoVersion() {
        let skill = makeSkill(version: nil)
        XCTAssertNil(SkillRowPresentation(skill: skill).versionText)
    }

    func test_versionText_present_whenVersionSet() {
        let skill = makeSkill(version: "1.2.3")
        XCTAssertEqual(SkillRowPresentation(skill: skill).versionText, "v1.2.3")
    }

    // MARK: - showArgumentHintTag

    func test_showArgumentHintTag_false_whenNil() {
        let skill = makeSkill(argumentHint: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showArgumentHintTag)
    }

    func test_showArgumentHintTag_true_whenPresent() {
        let skill = makeSkill(argumentHint: "分支名称")
        XCTAssertTrue(SkillRowPresentation(skill: skill).showArgumentHintTag)
    }

    // MARK: - showConditionalPathsBadge

    func test_showConditionalPathsBadge_false_whenPathsNil() {
        let skill = makeSkill(paths: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showConditionalPathsBadge)
    }

    func test_showConditionalPathsBadge_true_whenPathsPresent() {
        let skill = makeSkill(paths: ["**/*.swift"])
        XCTAssertTrue(SkillRowPresentation(skill: skill).showConditionalPathsBadge)
    }

    // MARK: - showWhenToUseDisclosure

    func test_showWhenToUseDisclosure_false_whenNil() {
        let skill = makeSkill(whenToUse: nil)
        XCTAssertFalse(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    func test_showWhenToUseDisclosure_false_whenEmpty() {
        let skill = makeSkill(whenToUse: "")
        XCTAssertFalse(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    func test_showWhenToUseDisclosure_true_whenPresent() {
        let skill = makeSkill(whenToUse: "当用户请求代码审查时")
        XCTAssertTrue(SkillRowPresentation(skill: skill).showWhenToUseDisclosure)
    }

    // MARK: - Helpers

    private func makeSkill(
        loadedFrom: SkillSource = .user,
        executionContext: SkillExecutionContext = .inline,
        version: String? = nil,
        argumentHint: String? = nil,
        paths: [String]? = nil,
        whenToUse: String? = nil
    ) -> Skill {
        let root = URL(fileURLWithPath: "/tmp/skills/test-skill")
        return Skill(
            directoryName: "test-skill",
            name: "Test Skill",
            description: "A test skill",
            path: root,
            contentURL: root.appendingPathComponent("SKILL.md"),
            whenToUse: whenToUse,
            argumentHint: argumentHint,
            version: version,
            paths: paths,
            loadedFrom: loadedFrom,
            executionContext: executionContext
        )
    }
}
```

### Step 2: 运行测试确认编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sg1-derived \
  -only-testing:agentGuiTests/SkillsViewPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|cannot find"
```

期望：编译错误 `cannot find type 'SkillRowPresentation'`

### Step 3: 实现 `SkillRowPresentation`

新建 `agentGui/Views/Skills/SkillRowPresentation.swift`：

```swift
// agentGui/Views/Skills/SkillRowPresentation.swift
import Foundation

/// 纯值类型，封装 SkillsView 中单行的所有 UI 显示决策。
/// 不依赖 SwiftUI，便于单元测试。
struct SkillRowPresentation {
    let skill: Skill

    /// 是否展示启用/禁用开关（内置技能不展示）
    var toggleIsVisible: Bool {
        skill.loadedFrom != .bundled
    }

    /// 技能来源的展示标签
    var sourceLabel: String {
        switch skill.loadedFrom {
        case .user:    return "用户"
        case .project: return "项目"
        case .managed: return "管理"
        case .bundled: return "内置"
        }
    }

    /// 是否展示 fork 执行模式徽章（inline 为默认，不展示）
    var showForkBadge: Bool {
        skill.executionContext == .fork
    }

    /// 版本文本（加 "v" 前缀），nil 则不展示版本徽章
    var versionText: String? {
        guard let version = skill.version, !version.isEmpty else { return nil }
        return "v\(version)"
    }

    /// 是否展示"接受参数"标签（argumentHint 非空时展示）
    var showArgumentHintTag: Bool {
        guard let hint = skill.argumentHint else { return false }
        return !hint.isEmpty
    }

    /// 是否展示"按路径激活"徽章（paths 非空时展示）
    var showConditionalPathsBadge: Bool {
        skill.paths != nil
    }

    /// 是否展示 whenToUse 折叠区域
    var showWhenToUseDisclosure: Bool {
        guard let text = skill.whenToUse else { return false }
        return !text.isEmpty
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sg1-derived \
  -only-testing:agentGuiTests/SkillsViewPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|SUCCEEDED|FAILED"
```

期望：全部测试通过，`** TEST SUCCEEDED **`

### Step 5: 提交

```
git add -A && git commit -m "feat(s-g1): add SkillRowPresentation struct with unit tests"
```

---

## Task 2 — 添加 SkillsView 状态与辅助视图结构

**Files:**
- Modify: `agentGui/Views/Skills/SkillsView.swift`

### Step 1: 在 SkillsView 添加展开状态

在 `SkillsView` 顶部 `@State` 区域添加：

```swift
@State private var expandedWhenToUseIDs: Set<String> = []
```

（位置：紧接已有的 `@State private var settings: AppSettings?` 之后）

### Step 2: 添加 `SkillSourceBadge` 辅助视图（私有，嵌在同文件）

在文件末尾、closing `}` 之前追加：

```swift
// MARK: - Skill Row Subviews

private struct SkillSourceBadge: View {
    let presentation: SkillRowPresentation

    var body: some View {
        Text(presentation.sourceLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(sourceColor.opacity(0.12), in: Capsule())
    }

    private var sourceColor: Color {
        switch presentation.skill.loadedFrom {
        case .user:    return .secondary
        case .project: return .blue
        case .managed: return .orange
        case .bundled: return .purple
        }
    }
}

private struct SkillMetadataChipsRow: View {
    let presentation: SkillRowPresentation

    var body: some View {
        HStack(spacing: 4) {
            SkillSourceBadge(presentation: presentation)

            if presentation.showForkBadge {
                SkillChip(label: "fork", color: .orange)
            }

            if let version = presentation.versionText {
                SkillChip(label: version, color: .secondary)
            }

            if presentation.showConditionalPathsBadge {
                SkillChip(label: "按路径激活", color: .secondary)
            }
        }
    }
}

private struct SkillChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}
```

### Step 3: 编译验证（辅助视图不受测试覆盖，用编译代替）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`（或无新 error）

---

## Task 3 — 更新 `skillRow` 展示新字段

**Files:**
- Modify: `agentGui/Views/Skills/SkillsView.swift`

### Step 1: 替换 `skillRow` 函数实现

将现有 `private func skillRow(_ skill: Skill, settings: AppSettings) -> some View` 函数体完整替换为以下内容（保留函数签名不变）：

```swift
private func skillRow(_ skill: Skill, settings: AppSettings) -> some View {
    let presentation = SkillRowPresentation(skill: skill)
    let isEnabled = settings.enabledSkillNames.contains(skill.directoryName)
    let toggleBinding = Binding(
        get: { isEnabled },
        set: { newValue in
            var names = settings.enabledSkillNames
            if newValue {
                if !names.contains(skill.directoryName) {
                    names.append(skill.directoryName)
                }
            } else {
                names.removeAll { $0 == skill.directoryName }
            }
            _ = persistSettingsMutation("技能启用状态未成功保存") {
                settings.enabledSkillNames = names
            }
        }
    )

    return VStack(alignment: .leading, spacing: 4) {
        // — 行 1：名称 + 参数标签 + 控件
        HStack(alignment: .center, spacing: WorkbenchSidebarPanelStyle.settingsRowSpacing) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if presentation.showArgumentHintTag {
                    SkillChip(label: "接受参数", color: .blue)
                }
            }

            Spacer(minLength: 0)

            if presentation.toggleIsVisible {
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: WorkbenchSidebarPanelStyle.settingsToggleColumnWidth, alignment: .trailing)
                    .accessibilityLabel(skill.name)
            } else {
                SkillChip(label: "内置", color: .purple)
                    .frame(width: WorkbenchSidebarPanelStyle.settingsToggleColumnWidth, alignment: .trailing)
                    .accessibilityLabel("\(skill.name) 内置技能")
            }
        }

        // — 行 2：描述
        if !skill.description.isEmpty {
            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }

        // — 行 3：元数据 chips
        SkillMetadataChipsRow(presentation: presentation)

        // — 行 4（可折叠）：whenToUse
        if presentation.showWhenToUseDisclosure, let whenToUse = skill.whenToUse {
            Button {
                if expandedWhenToUseIDs.contains(skill.id) {
                    expandedWhenToUseIDs.remove(skill.id)
                } else {
                    expandedWhenToUseIDs.insert(skill.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expandedWhenToUseIDs.contains(skill.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("何时调用")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skills.row.\(skill.directoryName).whenToUseToggle")

            if expandedWhenToUseIDs.contains(skill.id) {
                Text(whenToUse)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("skills.row.\(skill.directoryName).whenToUseText")
            }
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .animation(.easeInOut(duration: 0.15), value: expandedWhenToUseIDs)
}
```

**注意：** `expandedWhenToUseIDs` 是 `SkillsView` 的 `@State` 属性；`SkillChip`、`SkillMetadataChipsRow`、`SkillSourceBadge` 是同文件的 `private struct`，均可直接引用。

### Step 2: 删除 SkillsView.swift 中现有 skillRow 函数原版（已被 Step 1 全量替换）

确认文件中不存在重复的 `func skillRow` 定义。

### Step 3: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

期望：`BUILD SUCCEEDED`

### Step 4: 运行 SkillsViewPresentationTests 回归验证

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sg1-derived \
  -only-testing:agentGuiTests/SkillsViewPresentationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|SUCCEEDED|FAILED"
```

期望：全部通过

### Step 5: 提交

```
git add -A && git commit -m "feat(s-g1): SkillsView enhanced rows - source badge, fork chip, version, whenToUse disclosure, bundled lock"
```

---

## Task 4 — 添加 accessibilityIdentifier 与烟测

**Files:**
- Modify: `agentGui/Views/Skills/SkillsView.swift`（已含大部分 identifier，本 Task 补全）

### Step 1: 补全 accessibilityIdentifier

确认以下 identifier 已存在（Task 3 Step 1 的代码中已包含，本 Step 只做核查）：

| 组件 | identifier 格式 |
|------|----------------|
| whenToUse 折叠按钮 | `skills.row.<directoryName>.whenToUseToggle` |
| whenToUse 文本 | `skills.row.<directoryName>.whenToUseText` |
| 内置标签（替代 toggle） | 通过 `.accessibilityLabel` 已标注 |

若缺失，补入对应 `.accessibilityIdentifier(...)` 调用。

### Step 2: 运行 Skill 相关测试全集回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sg1-derived \
  -only-testing:agentGuiTests/SkillsViewPresentationTests \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|SUCCEEDED|FAILED"
```

期望：全套测试绿色通过

### Step 3: 提交

```
git add -A && git commit -m "feat(s-g1): add accessibility identifiers for whenToUse disclosure"
```

---

## 完整 SkillsView.swift 结构参考（Task 3 完成后）

```
SkillsView
├── @Environment: modelContext, persistenceCoordinator, skillService
├── @State settings: AppSettings?
├── @State expandedWhenToUseIDs: Set<String>      ← 新增
│
├── body
│   ├── WorkbenchSidebarPanelHeader
│   └── WorkbenchSidebarPanelScrollView
│       ├── WorkbenchSidebarSectionCard("已安装的技能")
│       │   └── skillsContent
│       └── WorkbenchSidebarSectionCard(描述文字)
│
├── skillsContent (ViewBuilder)
│   ├── Empty state
│   └── ForEach available skills → skillRow(skill, settings)
│
├── skillRow(_:settings:) → VStack              ← 完整重写
│   ├── 行1: name + argumentHintTag? + (toggle | 内置chip)
│   ├── 行2: description
│   ├── 行3: SkillMetadataChipsRow
│   └── 行4: whenToUse 折叠区（条件展示）
│
├── refreshSkills()
├── persistSettingsMutation(_:mutation:)
│
└── private structs (MARK: Skill Row Subviews)   ← 新增
    ├── SkillSourceBadge
    ├── SkillMetadataChipsRow
    └── SkillChip
```

---

## 验收标准核查表

| # | 验收条件 | 验证方式 |
|---|---------|---------|
| 1 | `whenToUse` 非空时，行底有折叠区 chevron + "何时调用" 文字 | Xcode Preview / 手动运行 |
| 2 | 点击折叠区，文字带动画展开/收起 | 手动运行 |
| 3 | `argumentHint` 非空时，名称旁显示"接受参数"蓝色 chip | Xcode Preview |
| 4 | `version` 非空时，chips 行出现"v1.x.x"灰色 chip | Xcode Preview |
| 5 | `loadedFrom == .user` → 灰色"用户" badge；`.project` → 蓝"项目"；`.managed` → 橙"管理"；`.bundled` → 紫"内置" | 单元测试 + Preview |
| 6 | `executionContext == .fork` 时，chips 行出现橙色"fork" chip | 单元测试 + Preview |
| 7 | `paths != nil` 时，chips 行出现灰色"按路径激活" chip | 单元测试 + Preview |
| 8 | `.bundled` 技能：无 Toggle，右侧显示紫色"内置" chip | 单元测试（toggleIsVisible == false）+ Preview |
| 9 | `.user`/.project`/.managed` 技能：Toggle 正常可用 | 单元测试（toggleIsVisible == true）|
| 10 | `SkillsViewPresentationTests` 全部通过 | CI 测试命令 |
| 11 | `BuiltInSkillRegistryTests` 回归无退步 | CI 测试命令 |

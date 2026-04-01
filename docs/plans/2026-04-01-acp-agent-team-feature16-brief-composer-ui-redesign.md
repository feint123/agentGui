# Feature 16: Brief Composer 全面 UI 重设计 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `AgentTeamBriefComposerSheet` 彻底重构为双栏布局——左栏处理任务意图，右栏处理 Team 配置——并以 Liquid Glass / macOS 26+ 视觉语言、spring 动画与可删除 chip 展示全面取代当前的单栏 TextEditor + 描边边框堆叠方案。

**Architecture:** 纯 View 层重写，不新增任何 SwiftData model 或服务。主体文件 `AgentTeamBriefComposerSheet.swift` 拆分为若干 private struct：`BriefMainInputArea`（左栏主输入）、`BriefExtractionPreviewCard`（提取结果 chip 预览）、`BriefModeSelector`（模式 glass 卡片）、`ProviderRoleCard`（右栏 provider 卡片）。`AgentTeamMissionBriefDraft` 新增 chip 操作计算助手（`constraintChips`、`criteriaChips` 及对应 delete/append 方法），供新 UI 消费。

**Tech Stack:** Swift 6, SwiftUI macOS 26+ (`glassEffect`, `GlassEffectContainer`, `workbenchSidebarCardStyle`), Spring 动画 (`.spring(duration:bounce:)`), SwiftTesting (`@Test` / `#expect`)。

---

## 依赖说明

- **依赖 Feature 15**：`BriefComposerProviderWarmupCoordinator`、`AgentTeamProviderRoleAssignment`、`roleAssignments` 字段必须已就绪。
- 不新增 SwiftData 字段；不修改 `AgentTeamMissionBrief`、`AgentTeamMissionBriefDraft`（仅新增 extension 计算属性）。
- 影响文件：
  - `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift` (主要重写)
  - `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift` (新增 chip 助手)
  - `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` (新增 chip 助手测试)

---

## 关键现有文件速查

| 文件 | Feature 16 关联作用 |
|---|---|
| `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift` | 主体重写目标 |
| `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift` | 新增 chip 操作助手 |
| `agentGui/ViewModels/BriefComposerProviderWarmupCoordinator.swift` | warm-up 状态读取（现有，不修改） |
| `agentGui/Views/Workbench/WorkbenchSidebarPanelStyle.swift` | glass 样式：`workbenchSidebarCardStyle()` / `workbenchSidebarHeaderFieldStyle()` / `WorkbenchSidebarSectionCard` |
| `agentGui/Views/Workbench/WorkbenchSidebarView.swift` | `GlassEffectContainer` 用法参考 |
| `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` | 新增测试追加目标 |
| `agentGuiTests/BriefComposerProviderWarmupCoordinatorTests.swift` | 参考已有测试结构 |

---

## Task 1：在 `AgentTeamMissionBriefDraft` 新增 chip 操作助手

**Files:**
- Modify: `agentGui/ViewModels/AgentTeamMissionBriefDraft.swift`
- Modify: `agentGuiTests/AgentTeamMissionBriefDraftTests.swift`

### 背景

`constraintsText` 和 `acceptanceCriteriaText` 是以 `"\n"` 分隔的字符串。Feature 16 的 chip UI 需要把每行拆成独立 chip 并支持按索引删除或追加。由于 `AgentTeamMissionBriefDraft` 是 `Sendable + Equatable` 的值类型，直接在 extension 里加计算属性和 mutating 方法是最轻量的方案。

### Step 1：写失败测试

在 `agentGuiTests/AgentTeamMissionBriefDraftTests.swift` **末尾追加**（不删除既有测试）：

```swift
// MARK: - Chip 操作助手 (Feature 16)

@Test
func constraintChipsReturnsNonEmptyLines() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.constraintsText = "只改 Swift 文件\n不删除测试\n"
    #expect(draft.constraintChips == ["只改 Swift 文件", "不删除测试"])
}

@Test
func criteriaChipsReturnsNonEmptyLines() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.acceptanceCriteriaText = "所有测试通过\n"
    #expect(draft.criteriaChips == ["所有测试通过"])
}

@Test
func removeConstraintChipDeletesCorrectLine() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.constraintsText = "A\nB\nC"
    draft.removeConstraintChip(at: 1)   // 删除 "B"
    #expect(draft.constraintChips == ["A", "C"])
}

@Test
func removeCriteriaChipDeletesCorrectLine() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.acceptanceCriteriaText = "X\nY"
    draft.removeCriteriaChip(at: 0)     // 删除 "X"
    #expect(draft.criteriaChips == ["Y"])
}

@Test
func appendConstraintChipAddsLine() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.constraintsText = "A"
    draft.appendConstraintChip("B")
    #expect(draft.constraintChips == ["A", "B"])
}

@Test
func chipRoundTripPreservesContent() {
    var draft = AgentTeamMissionBriefDraft.prefilled(from: nil)
    draft.constraintsText = "行一\n行二\n行三"
    draft.removeConstraintChip(at: 1)
    draft.appendConstraintChip("行四")
    #expect(draft.constraintChips == ["行一", "行三", "行四"])
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f16-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`constraintChips`、`removeConstraintChip` 等未定义。

### Step 3：在 `AgentTeamMissionBriefDraft.swift` 末尾追加 extension

```swift
// MARK: - Chip 操作助手 (Feature 16)
extension AgentTeamMissionBriefDraft {
    /// 将 constraintsText 按行拆分，过滤空行，返回 chip 数组。
    var constraintChips: [String] {
        constraintsText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 将 acceptanceCriteriaText 按行拆分，过滤空行，返回 chip 数组。
    var criteriaChips: [String] {
        acceptanceCriteriaText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 删除 constraintChips[at]，重新写回 constraintsText。
    mutating func removeConstraintChip(at index: Int) {
        var chips = constraintChips
        guard chips.indices.contains(index) else { return }
        chips.remove(at: index)
        constraintsText = chips.joined(separator: "\n")
    }

    /// 删除 criteriaChips[at]，重新写回 acceptanceCriteriaText。
    mutating func removeCriteriaChip(at index: Int) {
        var chips = criteriaChips
        guard chips.indices.contains(index) else { return }
        chips.remove(at: index)
        acceptanceCriteriaText = chips.joined(separator: "\n")
    }

    /// 在 constraintChips 末尾追加一行（仅当非空时）。
    mutating func appendConstraintChip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        constraintsText = (constraintChips + [trimmed]).joined(separator: "\n")
    }

    /// 在 criteriaChips 末尾追加一行（仅当非空时）。
    mutating func appendCriteriaChip(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        acceptanceCriteriaText = (criteriaChips + [trimmed]).joined(separator: "\n")
    }
}
```

### Step 4：运行测试验证通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f16-task1 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有 `AgentTeamMissionBriefDraftTests` 通过，包含新增 6 个 chip 测试。

### Step 5：Commit

```bash
git add agentGui/ViewModels/AgentTeamMissionBriefDraft.swift \
        agentGuiTests/AgentTeamMissionBriefDraftTests.swift
git commit -m "feat(f16): add chip helpers to AgentTeamMissionBriefDraft"
```

---

## Task 2：双栏布局 Shell 重构

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

当前 body 是一个 `VStack + ScrollView`，所有内容纵向堆叠。Feature 16 要求改为**水平双栏 + 底部 Commit Bar**：

```
┌─────────────────────────────────────────────────────────┐
│                Header（标题行）                          │
├──────────────────────────┬──────────────────────────────┤
│       Left Column        │       Right Column           │
│   任务意图（ScrollView） │   Team 配置（ScrollView）    │
├──────────────────────────┴──────────────────────────────┤
│                    Bottom Commit Bar                     │
└─────────────────────────────────────────────────────────┘
```

本 task 只做结构拆分，不涉及 glass 风格或动画——先让代码编译通过、现有逻辑能正常运行。

### Step 1：替换 `AgentTeamBriefComposerSheet.body` 的顶层结构

将现有 body 的 `VStack > ScrollView > VStack` 结构改为：

```swift
var body: some View {
    VStack(spacing: 0) {
        // 标题行
        sheetHeader
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

        Divider()

        // 双栏主体
        HStack(alignment: .top, spacing: 0) {
            // 左栏：任务意图
            ScrollView {
                leftColumn
                    .padding(16)
            }
            .frame(minWidth: 320)

            Divider()

            // 右栏：Team 配置
            ScrollView {
                rightColumn
                    .padding(16)
            }
            .frame(minWidth: 280)
        }
        .frame(maxHeight: .infinity)

        Divider()

        // 底部 Commit Bar
        commitBar
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }
    .frame(minWidth: 680, minHeight: 520)
    .accessibilityIdentifier("agentTeam.briefComposer")
    .onAppear { onAppearSetup() }
    .task(id: sourceContext?.sessionID ?? "") { await triggerWarmup() }
    .onDisappear { extractionVM?.cancelDebounce() }
}
```

### Step 2：提取现有内容到 `leftColumn`、`rightColumn`、`sheetHeader`、`commitBar`

把现有的子视图内容搬入 4 个私有计算属性，先保持现有实现不动（glass 升级在后续 task 中进行）：

```swift
// MARK: - Sheet Header

private var sheetHeader: some View {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
            Text("创建 Team Mission")
                .font(.title3.weight(.semibold))
            Text(sourceSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("agentTeam.brief.sourceSummary")
        }
        Spacer()
    }
}

// MARK: - Left Column

private var leftColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
        rawInputSection          // 现有主输入框 + 解析按钮
        if draft.extractionState == .done {
            extractionResultSection   // 现有提取结果预览
        }
        // Mode 占位（Task 4 替换）
        advancedModeSection
    }
}

// MARK: - Right Column

private var rightColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
        providerRoleSection          // 现有 provider 角色分配
        advancedOptionsSection       // 现有高级选项 DisclosureGroup
    }
}

// MARK: - Commit Bar

private var commitBar: some View {
    HStack {
        Spacer()
        Button("取消", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("agentTeam.brief.cancel")

        Button {
            onSubmit(draft)
        } label: {
            Label("创建 Team", systemImage: "arrow.right")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .accessibilityIdentifier("agentTeam.brief.submit")
    }
}
```

同时将现有 `onAppear` 逻辑提取为 `onAppearSetup()`，将 `.task` 的 warm-up 逻辑提取为 `triggerWarmup()`：

```swift
private func onAppearSetup() {
    draft.reconcileProviderOptions(
        resolvedProviderOptions,
        sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
    )
    setupExtractionVM()
}

private func triggerWarmup() async {
    let allOptions = resolvedProviderOptions
    await withTaskGroup(of: Void.self) { group in
        for option in allOptions where option.isEnabled {
            let ref = ExecutionProviderReference.decodePersisted(option.id)
            group.addTask { @MainActor in
                await warmupCoordinator.warmup(
                    provider: ref,
                    claudeService: claudeService,
                    sourceSession: nil,
                    modelContext: modelContext
                )
            }
        }
    }
}
```

### Step 3：编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`，无 error。

### Step 4：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): restructure brief composer to two-column layout"
```

---

## Task 3：Glass 风格升级 — 输入框、provider 卡片、整体容器

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

当前样式使用 `RoundedRectangle.stroke(Color.secondary.opacity(0.18))` 作为输入框边框，`RoundedRectangle.stroke(Color.secondary.opacity(0.2))` 作为 provider 卡片边框。Feature 16 要求改为统一使用 `workbenchSidebarHeaderFieldStyle()`（输入框）和 `workbenchSidebarCardStyle()`（卡片容器）。

### Step 1：升级主输入框 TextEditor

找到 `rawInputSection`（即原来的 `// MARK: 主输入框` 区域），替换 overlay：

**旧代码：**
```swift
TextEditor(text: $draft.rawInput)
    .frame(minHeight: 120)
    .overlay(
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.18))
    )
```

**新代码：**
```swift
TextEditor(text: $draft.rawInput)
    .frame(minHeight: 120)
    .workbenchSidebarHeaderFieldStyle()
```

### Step 2：升级 ProviderRoleRowView → 使用 workbenchSidebarCardStyle

在 `ProviderRoleRowView.body` 中，替换：

**旧代码：**
```swift
.padding(10)
.background(
    RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.2))
)
```

**新代码：**
```swift
.workbenchSidebarCardStyle(padding: 12)
```

### Step 3：左栏包裹提取结果区域为 WorkbenchSidebarSectionCard

在 `extractionResultSection` 或其包裹层加: 提取结果整体用 `WorkbenchSidebarSectionCard` 包裹（标题 "解析结果"）。详见 Task 4 中的具体实现（本 task 只升级已有 stroke 边框；chips 展示留在 Task 4）。

### Step 4：编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 5：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): apply glass card/input styles to brief composer"
```

---

## Task 4：BriefExtractionPreviewCard — chip 展示与 spring 动画

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

当前提取结果用 `TextField` + 两个 `TextEditor` 展示 objective / constraints / criteria。Feature 16 要求：
- Objective 保持 inline 可编辑 TextField（但改用 glass 样式）；
- Constraints 和 Acceptance Criteria 改为可删除 chip 行；
- 整区以 `withAnimation(.spring(duration: 0.35, bounce: 0.2))` 滑入；
- 整区用 `WorkbenchSidebarSectionCard` 包裹。

### Step 1：提取为独立 private struct `BriefExtractionPreviewCard`

在文件末尾（`RoleChipButton` 之后）新增：

```swift
// MARK: - BriefExtractionPreviewCard

private struct BriefExtractionPreviewCard: View {
    @Binding var draft: AgentTeamMissionBriefDraft

    var body: some View {
        WorkbenchSidebarSectionCard(title: "解析结果", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                // Objective 可编辑
                VStack(alignment: .leading, spacing: 4) {
                    Text("目标")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Objective", text: $draft.objective, axis: .vertical)
                        .lineLimit(2...4)
                        .workbenchSidebarHeaderFieldStyle()
                        .accessibilityIdentifier("agentTeam.brief.objective")
                }

                // Constraints chips
                chipSection(
                    label: "限制条件",
                    chips: draft.constraintChips,
                    accessibilityPrefix: "agentTeam.brief.constraintChip",
                    onDelete: { draft.removeConstraintChip(at: $0) }
                )

                // Acceptance Criteria chips
                chipSection(
                    label: "验收标准",
                    chips: draft.criteriaChips,
                    accessibilityPrefix: "agentTeam.brief.criteriaChip",
                    onDelete: { draft.removeCriteriaChip(at: $0) }
                )
            }
        }
        .transition(
            .opacity.combined(with: .offset(y: 12))
        )
        .accessibilityIdentifier("agentTeam.brief.extractionPreview")
    }

    @ViewBuilder
    private func chipSection(
        label: String,
        chips: [String],
        accessibilityPrefix: String,
        onDelete: @escaping (Int) -> Void
    ) -> some View {
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                        DeletableChipView(
                            label: chip,
                            onDelete: { onDelete(index) }
                        )
                        .accessibilityIdentifier("\(accessibilityPrefix).\(index)")
                    }
                }
            }
        }
    }
}
```

### Step 2：新增辅助视图 `DeletableChipView`

```swift
// MARK: - DeletableChipView

private struct DeletableChipView: View {
    let label: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
```

### Step 3：新增简单 `FlowLayout`（若未定义）

若工程中尚无 `FlowLayout`，在同文件末尾追加：

```swift
// MARK: - FlowLayout (simple wrapping HStack)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowX: CGFloat = 0
        var rowY: CGFloat = 0
        var maxRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowX + size.width > width, rowX > 0 {
                totalHeight += maxRowHeight + spacing
                rowX = 0
                rowY += maxRowHeight + spacing
                maxRowHeight = 0
            }
            rowX += size.width + spacing
            maxRowHeight = max(maxRowHeight, size.height)
        }
        totalHeight += maxRowHeight
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rowX = bounds.minX
        var rowY = bounds.minY
        var maxRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowX + size.width > bounds.maxX, rowX > bounds.minX {
                rowY += maxRowHeight + spacing
                rowX = bounds.minX
                maxRowHeight = 0
            }
            subview.place(
                at: CGPoint(x: rowX, y: rowY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            rowX += size.width + spacing
            maxRowHeight = max(maxRowHeight, size.height)
        }
    }
}
```

> **注意：** 若工程已有同名 `FlowLayout`，直接复用，不需要重复定义。先搜索 `grep -r "struct FlowLayout" agentGui/` 确认。

### Step 4：在 `leftColumn` 中替换 `extractionResultSection` 调用

```swift
// 旧代码：
if draft.extractionState == .done {
    extractionResultSection
}

// 新代码：
if draft.extractionState == .done {
    BriefExtractionPreviewCard(draft: $draft)
}
```

并在状态切换时加 spring 动画驱动。在 `rawInputSection` 中 "解析 Brief" 按钮的 action 中，替换调用方式以确保动画生效：

```swift
Button("解析 Brief") {
    Task { @MainActor in
        var localDraft = draft
        await extractionVM?.triggerExtraction(draft: &localDraft)
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
            draft = localDraft
        }
    }
}
```

### Step 5：编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 6：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): extraction preview with chip display and spring animation"
```

---

## Task 5：BriefModeSelector — 模式 glass 卡片

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

当前 Mode 选择在 `DisclosureGroup("高级选项")` 内以 `Picker(.menu)` 呈现，既不醒目，也无动画。Feature 16 要求把 Mode 移到左栏底部，以 3 个 glass 卡片横放，选中态有 `glassEffect(.regular.interactive())` 高亮 + spring scaleEffect。

### Step 1：新增 `BriefModeSelector` 私有 struct

```swift
// MARK: - BriefModeSelector

private struct BriefModeSelector: View {
    @Binding var selectedMode: AgentTeamMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("执行模式")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(AgentTeamMode.allCases, id: \.self) { mode in
                        modeTile(mode)
                    }
                }
            }
        }
        .accessibilityIdentifier("agentTeam.brief.modeSelector")
    }

    @ViewBuilder
    private func modeTile(_ mode: AgentTeamMode) -> some View {
        let isSelected = selectedMode == mode
        Button {
            withAnimation(.spring(duration: 0.25)) {
                selectedMode = mode
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.systemImageName)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(mode.displayName)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(duration: 0.25), value: isSelected)
        .glassEffect(
            isSelected ? .regular.interactive() : .regular,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityIdentifier("agentTeam.brief.mode.\(mode.rawValue)")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "已选中" : "")
    }
}
```

同时在 `AgentTeamMode` 新增 `systemImageName` 计算属性（若未定义）：

```swift
// 在 AgentTeamMode extension（可放在 AgentTeamBriefComposerSheet.swift 末尾的私有 extension）：
private extension AgentTeamMode {
    var systemImageName: String {
        switch self {
        case .creativeExploration:   "lightbulb.max"
        case .executionDelivery:     "hammer"
        case .researchAndSynthesis:  "magnifyingglass.circle"
        }
    }
}
```

### Step 2：在 `leftColumn` 替换 `advancedModeSection`

```swift
// 旧代码（Mode 在高级选项折叠区）：
private var advancedModeSection: some View {
    DisclosureGroup(...) {
        Picker("Mode", selection: $draft.mode) { ... }
        ...
    }
}

// 新代码——直接在 leftColumn 的底部加：
private var leftColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
        rawInputSection
        if draft.extractionState == .done {
            BriefExtractionPreviewCard(draft: $draft)
        }
        BriefModeSelector(selectedMode: $draft.mode)
    }
}
```

同时把 Mode Picker 从 `advancedOptionsSection`（右栏 DisclosureGroup）中移除（避免重复）。

### Step 3：编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 4：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): add BriefModeSelector glass card tiles"
```

---

## Task 6：ProviderRoleCard 重设计 — warm-up 动画 + 模型展开 transition

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

当前 `ProviderRoleRowView` 缺少：
1. warm-up 状态切换动画（从 ProgressView → 绿点 / 红叉无动画）；
2. 模型/模式 Picker 展开无过渡（`if case .ready` 分支直接出现）；
3. 卡片整体视觉未对齐 glass 风格（Task 3 已升级边框，本 task 升级内部布局）。

### Step 1：将 `ProviderRoleRowView` 重命名改写为 `ProviderRoleCard`

在文件内将旧 `ProviderRoleRowView` 整体替换为：

```swift
// MARK: - ProviderRoleCard

private struct ProviderRoleCard: View {
    let providerName: String
    let providerTypeBadge: String           // "Built-in" / "ACP" 等
    let warmupState: BriefComposerProviderWarmupCoordinator.WarmupState
    @Binding var assignment: AgentTeamProviderRoleAssignment
    let modelOptions: [ExecutionOptionItem]
    let modeOptions: [ExecutionOptionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部行：名称 + badge + warm-up indicator
            HStack(spacing: 8) {
                WarmupIndicatorView(state: warmupState)
                    .accessibilityLabel(warmupAccessibilityLabel)

                Text(providerName)
                    .font(.subheadline.weight(.semibold))

                Text(providerTypeBadge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())

                Spacer()
            }

            // 角色 chip 行
            ProviderRoleChipRow(assignment: $assignment)
                .accessibilityIdentifier("agentTeam.brief.provider.\(providerName).roleRow")

            // 展开区：模型 + 模式 Picker（warm-up ready 后显示）
            if case .ready = warmupState, !modelOptions.isEmpty || !modeOptions.isEmpty {
                pickerExpansion
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .workbenchSidebarCardStyle(padding: 12)
        .accessibilityIdentifier("agentTeam.brief.provider.\(providerName)")
    }

    @ViewBuilder
    private var pickerExpansion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 12) {
                if !modelOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
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
                }
                if !modeOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模式")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
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
            }
            .font(.caption)
        }
    }

    private var warmupAccessibilityLabel: String {
        switch warmupState {
        case .idle:    return "待连接 \(providerName)"
        case .warming: return "正在连接 \(providerName)..."
        case .ready:   return "\(providerName) 就绪"
        case .failed:  return "\(providerName) 连接失败"
        }
    }
}
```

### Step 2：新增 `WarmupIndicatorView`（带 spring 过渡）

```swift
// MARK: - WarmupIndicatorView

private struct WarmupIndicatorView: View {
    let state: BriefComposerProviderWarmupCoordinator.WarmupState

    var body: some View {
        ZStack {
            switch state {
            case .idle:
                Circle()
                    .fill(.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
            case .warming:
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            case .ready:
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: 10)
            }
        }
        .animation(.spring(duration: 0.3), value: isReady)
    }

    private var isReady: Bool {
        if case .ready = state { return true }
        return false
    }
}
```

### Step 3：新增 `ProviderRoleChipRow`

```swift
// MARK: - ProviderRoleChipRow

private struct ProviderRoleChipRow: View {
    @Binding var assignment: AgentTeamProviderRoleAssignment

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AgentTeamProviderRole.allCases, id: \.self) { role in
                RoleChipButton(
                    label: role.displayLabel,
                    isSelected: assignment.roles.contains(role)
                ) {
                    toggleRole(role)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleRole(_ role: AgentTeamProviderRole) {
        var copy = assignment
        if copy.roles.contains(role) {
            copy.roles.remove(role)
        } else {
            copy.roles.insert(role)
        }
        assignment = copy
    }
}
```

### Step 4：更新 `providerRoleSection` 中的调用，传入 providerTypeBadge

```swift
private var providerRoleSection: some View {
    VStack(alignment: .leading, spacing: 10) {
        Text("Team 成员与角色")
            .font(.subheadline.weight(.semibold))

        let options = resolvedProviderOptions
        if options.isEmpty {
            Text("未检测到启用的 Provider，将使用内置 Built-in。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(options, id: \.id) { option in
                let ref = ExecutionProviderReference.decodePersisted(option.id)
                let badge = ref == .builtIn ? "Built-in" : "ACP"
                ProviderRoleCard(
                    providerName: option.title,
                    providerTypeBadge: badge,
                    warmupState: warmupCoordinator.warmupState(for: ref),
                    assignment: assignmentBinding(for: ref),
                    modelOptions: warmupCoordinator.modelOptions(for: ref),
                    modeOptions: warmupCoordinator.modeOptions(for: ref)
                )
                .animation(.spring(duration: 0.4, bounce: 0.1), value: warmupCoordinator.warmupState(for: ref) == .warming)
            }
        }
    }
}
```

### Step 5：编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`，无 unused-variable 或 `cannot find type` error。

### Step 6：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): redesign ProviderRoleCard with warm-up animation and picker expansion"
```

---

## Task 7：Shimmer 动画、Commit Bar 升级与 Accessibility 补全

**Files:**
- Modify: `agentGui/Views/Team/AgentTeamBriefComposerSheet.swift`

### 背景

最后一批收尾工作：
1. 提取中进度条改为 shimmer 效果；
2. Commit Bar "创建 Team" 按钮升级为 `.buttonStyle(.glassProminent)`（或 `.borderedProminent`）；
3. 补全所有交互元素的 `accessibilityIdentifier`（按 `agentTeam.brief.*` 前缀规范）。

### Step 1：将提取状态 Label 升级为 shimmer ProgressView

找到 `extractionStatusLabel` 的 `.extracting` 分支：

**旧：**
```swift
case .extracting:
    HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("正在解析…").font(.caption).foregroundStyle(.secondary)
    }
```

**新（shimmer 内联进度条）：**
```swift
case .extracting:
    ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 4)
            .fill(.secondary.opacity(0.1))
            .frame(height: 4)
        ShimmerBarView()
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    .frame(maxWidth: 120)
    .accessibilityIdentifier("agentTeam.brief.extractingProgress")
```

新增 `ShimmerBarView`：

```swift
// MARK: - ShimmerBarView

private struct ShimmerBarView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .secondary.opacity(0.5), .clear],
                startPoint: UnitPoint(x: phase - 0.4, y: 0.5),
                endPoint: UnitPoint(x: phase + 0.4, y: 0.5)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
        }
    }
}
```

### Step 2：升级 Commit Bar 按钮样式

```swift
private var commitBar: some View {
    HStack {
        Spacer()
        Button("取消", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("agentTeam.brief.cancel")

        Button {
            onSubmit(draft)
        } label: {
            Label("创建 Team", systemImage: "arrow.right")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
        .buttonStyle(.borderedProminent)      // 或 .glassProminent（如 #available(macOS 26)）
        .accessibilityIdentifier("agentTeam.brief.submit")
    }
}
```

### Step 3：accessibility 清单检查与补全

验证以下 identifier 均存在（过一遍文件搜索）：

| 标识符 | 对应元素 |
|---|---|
| `agentTeam.briefComposer` | 整个 Sheet |
| `agentTeam.brief.sourceSummary` | 来源说明文本 |
| `agentTeam.brief.rawInput` | 主输入 TextEditor |
| `agentTeam.brief.extractButton` | "解析 Brief" 按钮 |
| `agentTeam.brief.extractingProgress` | shimmer 进度条 |
| `agentTeam.brief.extractionPreview` | 提取结果卡片容器 |
| `agentTeam.brief.objective` | Objective TextField |
| `agentTeam.brief.constraintChip.N` | 每个 constraint chip |
| `agentTeam.brief.criteriaChip.N` | 每个 criteria chip |
| `agentTeam.brief.modeSelector` | 模式卡片容器 |
| `agentTeam.brief.mode.<rawValue>` | 每个模式卡片 |
| `agentTeam.brief.maxActiveProviders` | 并发上限 Stepper |
| `agentTeam.brief.provider.<name>` | 每个 provider 卡片 |
| `agentTeam.brief.provider.<name>.roleRow` | provider 角色 chip 行 |
| `agentTeam.brief.cancel` | 取消按钮 |
| `agentTeam.brief.submit` | 创建按钮 |

对比当前代码，补全缺失的 `.accessibilityIdentifier()` 调用。

### Step 4：运行完整 Brief Composer 相关测试组

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f16-task7 \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部通过，无新增失败。

### Step 5：Commit

```bash
git add agentGui/Views/Team/AgentTeamBriefComposerSheet.swift
git commit -m "feat(f16): shimmer animation, commit bar style, accessibility cleanup"
```

---

## Task 8：最终集成验证

**Files:** 无新修改

### Step 1：运行 Agent Team 全套测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f16-final \
  -only-testing:agentGuiTests/AgentTeamMissionBriefTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefDraftTests \
  -only-testing:agentGuiTests/AgentTeamMissionBriefResolverTests \
  -only-testing:agentGuiTests/AgentTeamSessionFactoryTests \
  -only-testing:agentGuiTests/BriefComposerProviderWarmupCoordinatorTests \
  -only-testing:agentGuiTests/BriefComposerExtractionViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：全部通过。

### Step 2：完整构建

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-f16-final \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|Build succeeded"
```

预期：`Build succeeded`，无 error，warning 数量不超过改动前水平。

### Step 3：验收核对清单

对照 Feature 16 设计验收标准逐一确认：

- [ ] Sheet 双栏布局正常渲染，左右各有独立 ScrollView；
- [ ] 主输入 TextEditor 应用 `workbenchSidebarHeaderFieldStyle()` glass 效果；
- [ ] "解析 Brief" 结果出现时有 spring fade+offset 动画；
- [ ] Constraints / Criteria 以可删除 chip 展示，删除后正确更新 draft；
- [ ] 模式选择 3 个 glass 卡片横排，选中态有 glassEffect 高亮 + scaleEffect；
- [ ] Provider 卡片 warm-up 状态从 ProgressView → 绿点 有 spring 过渡；
- [ ] Provider 卡片 warm-up done 后模型/模式 Picker 以 transition 滑入；
- [ ] "创建 Team" 按钮 disabled 当且仅当 rawInput 为空 **或** 无 conductor 分配；
- [ ] 所有 `agentTeam.brief.*` accessibilityIdentifier 存在于文件中；
- [ ] 现有所有 Brief Composer 相关测试通过。

### Step 4：最终 Commit

```bash
git add -A
git commit -m "feat: Feature 16 Brief Composer UI redesign complete"
```

---

## 附录：动画规格速查

| 场景 | 代码 |
|---|---|
| 提取结果卡片出现 | `withAnimation(.spring(duration: 0.35, bounce: 0.2)) { ... }` + `.transition(.opacity.combined(with: .offset(y: 12)))` |
| Provider warm-up 状态切换 | `.animation(.spring(duration: 0.3), value: isReady)` |
| Provider 模型 Picker 展开 | `.transition(.move(edge: .top).combined(with: .opacity))` + `.animation(.spring(duration: 0.4, bounce: 0.1), ...)` |
| 模式卡片选中 | `withAnimation(.spring(duration: 0.25)) { ... }` + `.scaleEffect(isSelected ? 1.03 : 1.0).animation(.spring(duration: 0.25), value: isSelected)` |
| shimmer 进度条 | `.linear(duration: 1.2).repeatForever(autoreverses: false)` |

## 附录：FlowLayout 检查命令

```bash
grep -r "struct FlowLayout" agentGui/
```

若已存在，直接复用现有类型；若不存在，按 Task 4 中的 `Layout` 实现添加。

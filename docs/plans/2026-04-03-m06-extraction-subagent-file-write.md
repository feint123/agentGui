# Feature M-06: Fix Extraction Subagent → Write Markdown Files

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 session 结束时的 memory extraction subagent 获得正确的执行上下文：预先注入当前已有记忆文件的 manifest（防重复写入），并更新 prompt 与工具集以匹配 M-04 之后 `memory_write` 直接写文件的新行为。

**Architecture:**
- `SessionMemoryExtractorService.runExtraction()` 在构建 prompt 前用 `MemoryTopicScanner` 扫描 `memoryDir`，将结果格式化为 manifest，注入 `MemoryExtractionPromptBuilder`
- `MemoryExtractionPromptBuilder.build()` 新增 `existingMemoriesManifest: String` 参数；内部改用 `MemoryTypeGuidanceComposer` 的型别和禁止保存节（DRY），移除对 `semantic_type` 字段的引用
- `ClaudeService+MemoryExtraction.swift` 删除，`buildExtractionTools()` 移入 `ClaudeService+ToolBuilder.swift`

**Tech Stack:** Swift 6.0, SwiftAnthropic, XCTest — 无新依赖

**Pre-conditions (确认已完成):**
- M-01：`RMSInsightStore` 已删除，`SessionMemoryExtractorService` 中已无 RMS 引用
- M-04：`memory_write` 工具调用 `executeFileMemoryWrite()` 直接写 `.md` 文件并重建 `MEMORY.md`
- `MemoryTopicScanner` / `MemoryManifestFormatter` / `MemoryTypeGuidanceComposer` 均已完整实现

---

## 参考代码（Claude Code 对齐基准）

Claude Code `extractMemories.ts` 中 `runExtraction()` 的核心模式：
```typescript
// Pre-inject manifest so subagent doesn't waste a turn on `ls`
const existingMemories = formatMemoryManifest(
    await scanMemoryFiles(memoryDir, createAbortController().signal),
)
const userPrompt = buildExtractAutoOnlyPrompt(newMessageCount, existingMemories, skipIndex)
```

Claude Code `prompts.ts` `opener()` 的模式：
```typescript
const manifest = existingMemories.length > 0
    ? `\n\n## Existing memory files\n\n${existingMemories}\n\nCheck this list before writing — update an existing file rather than creating a duplicate.`
    : ''
```

---

## Task 1：给 `MemoryExtractionPromptBuilder` 新增 manifest 参数 + 用 GuidanceComposer

**Files:**
- Modify: `agentGui/Services/MemoryExtractionPromptBuilder.swift`

**Step 1: 阅读当前文件**

打开 `agentGui/Services/MemoryExtractionPromptBuilder.swift` 确认当前签名为：
```swift
static func build(newMessageCount: Int) -> String
```
确认内部使用了内联的 `<types>` / "What NOT to save" / "How to save" 节，并且工具说明仍引用 `semantic_type` 字段。

**Step 2: 重写 `MemoryExtractionPromptBuilder.swift`**

用下面的内容完整替换该文件（保留文件头部注释，替换 `enum` 主体）：

```swift
import Foundation

/// 生成 memory extraction subagent 的 user prompt。
///
/// 对齐 Claude Code `buildExtractAutoOnlyPrompt` + `opener()`：
/// - 可注入当前已有记忆文件的 manifest（防重复写入）
/// - 四类型语义指导通过 `MemoryTypeGuidanceComposer` 提供（DRY）
/// - "How to save" 节匹配 M-04 之后 `memory_write` 直接写文件的行为
enum MemoryExtractionPromptBuilder {

    /// 构建 extraction subagent 的 user prompt。
    ///
    /// - Parameters:
    ///   - newMessageCount: 本次需要分析的消息数量，注入给 subagent 作为工作范围提示。
    ///   - existingMemoriesManifest: 已有记忆文件的 manifest（由 `MemoryManifestFormatter` 生成）。
    ///     空字符串时不注入 manifest 节。
    static func build(
        newMessageCount: Int,
        existingMemoriesManifest: String = ""
    ) -> String {
        var lines: [String] = []

        // 角色 + 工作范围
        lines += [
            "You are now acting as the memory extraction subagent.",
            "Analyze the most recent ~\(newMessageCount) messages above and use them to update the persistent memory system.",
            "",
            "Available tools: `memory_write` (writes a topic `.md` file and updates `MEMORY.md` automatically). " +
            "No other write tools are available. Do NOT call bash rm, run_subagent, or any agent tool.",
            "",
            "You have a limited turn budget — complete extraction in at most 3 turns.",
            "Efficient strategy: call all `memory_write` invocations in the same turn (parallel calls).",
            "",
            "You MUST only use content from the last ~\(newMessageCount) messages. " +
            "Do not investigate or verify content further.",
        ]

        // 现有文件 manifest（对齐 Claude Code opener() manifest 块）
        if !existingMemoriesManifest.isEmpty {
            lines += [
                "",
                "## Existing memory files",
                "",
                existingMemoriesManifest,
                "",
                "Check this list before writing — update an existing memory only if the topic is substantially the same. " +
                "Otherwise create a new file. Do NOT manually edit `MEMORY.md` — `memory_write` updates it automatically.",
            ]
        }

        // 型别指导（通过 MemoryTypeGuidanceComposer，与系统提示 DRY）
        let guidance = MemoryTypeGuidanceComposer()
        lines += ["", guidance.typesSection()]
        lines += ["", guidance.whatNotToSaveSection()]

        // 保存说明（extraction-specific：仅用 memory_write，无手动 MEMORY.md 步骤）
        lines += [
            "",
            "## How to save memories",
            "",
            "Call `memory_write` with:",
            "- `content`: the memory body (Markdown text)",
            "- `title`: concise topic label (e.g. `User prefers bun over npm`)",
            "- `type`: `user` | `feedback` | `project` | `reference` (default: `project`)",
            "- `description`: optional one-line hook for MEMORY.md index (≤ 150 chars)",
            "",
            "`memory_write` writes the topic file AND updates `MEMORY.md` automatically.",
            "Do NOT manually write to `MEMORY.md`.",
            "",
            "If nothing new is worth saving, respond with a short explanation and stop. " +
            "Do not write trivial or low-value memories.",
        ]

        return lines.joined(separator: "\n")
    }
}
```

**Step 3: 确认编译无错误**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`（如有 error 先修复再继续）

**Step 4: Commit**

```bash
git add agentGui/Services/MemoryExtractionPromptBuilder.swift
git commit -m "feat(M-06): update MemoryExtractionPromptBuilder — manifest param + GuidanceComposer DRY"
```

---

## Task 2：更新 `MemoryExtractionPromptBuilder` 测试

**Files:**
- Modify: `agentGuiTests/MemoryExtractionPromptBuilderTests.swift`

**Step 1: 先写调用新签名的失败测试（TDD）**

在 `MemoryExtractionPromptBuilderTests.swift` 末尾追加以下测试，确认在 Task 1 完成后它们能通过：

```swift
func test_build_withNonEmptyManifest_containsManifestSection() {
    let manifest = "- [user] swift_preferences.md (2026-04-03T10:00:00Z): Prefers bun over npm"
    let prompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: 5,
        existingMemoriesManifest: manifest
    )
    XCTAssertTrue(prompt.contains("Existing memory files"),
                  "Prompt must contain manifest section header when manifest is non-empty")
    XCTAssertTrue(prompt.contains(manifest),
                  "Prompt must embed the manifest verbatim")
}

func test_build_withEmptyManifest_omitsManifestSection() {
    let prompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: 5,
        existingMemoriesManifest: ""
    )
    XCTAssertFalse(prompt.contains("Existing memory files"),
                   "Prompt must NOT contain manifest section when manifest is empty")
}

func test_build_doesNotContainSemanticTypeFieldName() {
    // M-04 使用 'type' 字段，不是 'semantic_type'
    let prompt = MemoryExtractionPromptBuilder.build(newMessageCount: 4)
    XCTAssertFalse(prompt.contains("semantic_type"),
                   "Prompt must not reference the old semantic_type field — use 'type' instead")
}

func test_build_memoryWriteDescribesFileWrite() {
    let prompt = MemoryExtractionPromptBuilder.build(newMessageCount: 4)
    XCTAssertTrue(prompt.contains("MEMORY.md"),
                  "Prompt should clarify that memory_write updates MEMORY.md automatically")
}
```

**Step 2: 更新现有测试中可能失效的调用**

查找文件中所有 `MemoryExtractionPromptBuilder.build(` 调用：
- 旧签名 `build(newMessageCount:)` 仍有效（`existingMemoriesManifest` 有默认值），无需改动
- 旧测试 `test_build_containsMemoryWriteToolName` 仍应通过（`memory_write` 在新 prompt 中保留）

**Step 3: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-task2 \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASSED

**Step 4: Commit**

```bash
git add agentGuiTests/MemoryExtractionPromptBuilderTests.swift
git commit -m "test(M-06): add manifest injection + type field tests to MemoryExtractionPromptBuilderTests"
```

---

## Task 3：在 `SessionMemoryExtractorService` 中注入 manifest

**Files:**
- Modify: `agentGui/Services/SessionMemoryExtractorService.swift`

**Step 1: 先写失败的集成测试**

在 `agentGuiTests/SessionMemoryExtractorServiceTests.swift` 末尾追加：

```swift
// MARK: - Manifest injection via MemoryExtractionPromptBuilder

/// 验证 MemoryExtractionPromptBuilder.build 对非空 manifest 的处理
/// （作为 runExtraction 注入路径的逻辑等价测试）
func test_promptBuilder_manifestPassthrough_emptyManifest() {
    // 空 manifest → 不注入
    let prompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: 3,
        existingMemoriesManifest: ""
    )
    XCTAssertFalse(prompt.contains("Existing memory files"),
                   "Empty manifest must not produce manifest section")
}

func test_promptBuilder_manifestPassthrough_nonEmptyManifest() {
    let manifest = "- [project] swift_pref.md (2026-04-03T12:00:00Z): Prefers actor isolation"
    let prompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: 3,
        existingMemoriesManifest: manifest
    )
    XCTAssertTrue(prompt.contains("Existing memory files"),
                  "Non-empty manifest must produce the section header in the prompt")
    XCTAssertTrue(prompt.contains("swift_pref.md"),
                  "Non-empty manifest content must appear verbatim in the prompt")
}
```

**Step 2: 修改 `runExtraction()` — 扫描 manifest + 传入 prompt builder**

在 `SessionMemoryExtractorService.swift` 的 `runExtraction(context:claudeService:settings:sessionId:modelContext:)` 函数中做以下修改：

```swift
static func runExtraction(
    context: AgentLoopHookContext,
    claudeService: ClaudeService,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws {
    let messageCount = context.messagesSnapshot.count
    guard messageCount > 0 else { return }

    // ── 新增：扫描当前 memoryDir，构建 manifest 注入 prompt ──
    let memoryDir = ConfigDirectoryManager.shared.memoryDir
    let topicHeaders = (try? await MemoryTopicScanner().scan(memoryDir: memoryDir)) ?? []
    let existingManifest = MemoryManifestFormatter().format(topicHeaders)
    // ────────────────────────────────────────────────────────

    // 构建提取 prompt（注入 manifest）
    let extractionPrompt = MemoryExtractionPromptBuilder.build(
        newMessageCount: messageCount,
        existingMemoriesManifest: existingManifest   // ← 新参数
    )

    // 其余代码不变...
    let restrictedTools = await claudeService.buildExtractionTools(settings: settings)
    // ...
}
```

两处改动要点：
1. 在 `guard messageCount > 0 else { return }` 之后立即扫描 (`scanMemoryFiles`）
2. 将 `existingManifest` 传入 `MemoryExtractionPromptBuilder.build()`

**Step 3: 确认编译**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 4: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-task3 \
  -only-testing:agentGuiTests/SessionMemoryExtractorServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASSED

**Step 5: Commit**

```bash
git add agentGui/Services/SessionMemoryExtractorService.swift \
        agentGuiTests/SessionMemoryExtractorServiceTests.swift
git commit -m "feat(M-06): pre-scan memory manifest and inject into extraction prompt"
```

---

## Task 4：将 `buildExtractionTools()` 移入 `ClaudeService+ToolBuilder.swift`，删除 `ClaudeService+MemoryExtraction.swift`

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`
- Delete: `agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift`
- Modify: `agentGui.xcodeproj/project.pbxproj`（Xcode 自动处理；若手动则删除对该文件的引用）

**Step 1: 查看要迁移的代码**

打开 `ClaudeService+MemoryExtraction.swift`，确认要迁移的三个方法：
```swift
func buildExtractionTools(settings: AppSettings) -> [MessageParameter.Tool]
func toolNameForExtraction(from tool: MessageParameter.Tool) -> String?
private func extractStringFromMirror(labeled target: String, from mirror: Mirror) -> String?
```

**Step 2: 在 `ClaudeService+ToolBuilder.swift` 末尾追加（在最后的 `}` 之前）**

实际追加到 `extension ClaudeService` 的末尾：

```swift
    // MARK: - Extraction Tools

    /// 构建 memory extraction subagent 的受限工具集。
    ///
    /// 从完整工具集中筛选出 `memory_write`（M-04 后直接写 `.md` 文件），
    /// 供 `SessionMemoryExtractorService` 使用。
    ///
    /// 不包含：bash、run_subagent、str_replace_based_edit_tool 等重型工具，
    /// 确保提取 subagent 不会产生副作用或创建递归 loop。
    func buildExtractionTools(settings: AppSettings) -> [MessageParameter.Tool] {
        let allowed: Set<String> = ["memory_write"]
        let allTools = buildTools(modelId: settings.selectedModel, settings: settings)
        return allTools.filter { tool in
            toolNameForExtraction(from: tool).map { allowed.contains($0) } ?? false
        }
    }

    /// 通过 Mirror 安全提取 MessageParameter.Tool 的工具名。
    func toolNameForExtraction(from tool: MessageParameter.Tool) -> String? {
        extractStringFromMirror(labeled: "name", from: Mirror(reflecting: tool))
    }

    private func extractStringFromMirror(labeled target: String, from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == target, let value = child.value as? String {
                return value
            }
            let childMirror = Mirror(reflecting: child.value)
            if let value = extractStringFromMirror(labeled: target, from: childMirror) {
                return value
            }
        }
        return nil
    }
```

> **注意：** `allowed` 集合从 `["memory_write", "read_file"]` 收窄为 `["memory_write"]`。
> `read_file` 从未在 `buildTools()` 中注册，故之前的过滤结果实际上就只有 `memory_write`，
> 此次改动是显式表达，不改变运行行为。

**Step 3: 删除 `ClaudeService+MemoryExtraction.swift`**

在 Xcode 中：右键点击 `ClaudeService+MemoryExtraction.swift` → **Delete** → **Move to Trash**

或通过 Terminal：
```bash
rm agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift
```

然后在 Xcode 中清理 project.pbxproj 引用（Xcode 会自动处理，若 CI 环境需手动删除 pbxproj 中的引用行）。

**Step 4: 确认编译**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift \
        agentGui.xcodeproj/project.pbxproj
git rm agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift
git commit -m "refactor(M-06): move buildExtractionTools to ToolBuilder, delete ClaudeService+MemoryExtraction.swift"
```

---

## Task 5：更新 `ClaudeServiceMemoryExtractionToolsTests`

**Files:**
- Modify: `agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift`

**背景：** 该测试文件测试 `ClaudeService.buildExtractionTools()`，相关方法已在 Task 4 从
`ClaudeService+MemoryExtraction.swift` 迁移到 `ClaudeService+ToolBuilder.swift`。
接口签名不变，测试内容需要反映 `allowed` 集合从 `["memory_write", "read_file"]` 收窄为 `["memory_write"]` 的变化。

**Step 1: 确认测试仍能编译**

Task 4 完成后立即运行：
```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 2: 更新现有测试 + 新增测试**

将 `ClaudeServiceMemoryExtractionToolsTests.swift` 的内容替换为：

```swift
import XCTest
@testable import agentGui

@MainActor
final class ClaudeServiceMemoryExtractionToolsTests: XCTestCase {

    func test_buildExtractionTools_containsMemoryWrite() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertTrue(names.contains("memory_write"),
                      "Extraction tools must include memory_write")
    }

    func test_buildExtractionTools_doesNotContainSubagentTool() throws {
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertFalse(names.contains("run_subagent"),
                       "Extraction tools must not include run_subagent")
    }

    func test_buildExtractionTools_doesNotContainBashOrEditor() throws {
        // bash / str_replace_based_edit_tool 不在授权集合内
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertFalse(names.contains("bash"),
                       "Extraction tools must not include bash")
        XCTAssertFalse(names.contains("str_replace_based_edit_tool"),
                       "Extraction tools must not include str_replace_based_edit_tool")
    }

    func test_buildExtractionTools_exactlyMemoryWrite() throws {
        // M-06: 授权集合收窄为 memory_write only
        let service = ClaudeService()
        let settings = AppSettings.testFixture(apiKey: "sk-ant-test")

        let tools = service.buildExtractionTools(settings: settings)

        let names = tools.compactMap { service.toolNameForExtraction(from: $0) }
        XCTAssertEqual(Set(names), ["memory_write"],
                       "Extraction tools should contain exactly memory_write")
    }
}
```

**Step 3: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-task5 \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASSED

**Step 4: Commit**

```bash
git add agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift
git commit -m "test(M-06): update ClaudeServiceMemoryExtractionToolsTests — reflect memory_write-only tool set"
```

---

## Task 6：全量测试 + 完成验证

**Step 1: 运行 M-06 相关测试套件**

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-final \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/SessionMemoryExtractorServiceTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASSED，0 FAILED

**Step 2: 确认完成标志**

检查清单（对照设计文档）：

- [ ] `SessionMemoryExtractorService.runExtraction()` 中无任何 `RMS` / `rms` 前缀符号引用
- [ ] `MemoryExtractionPromptBuilder.build()` 接受 `existingMemoriesManifest` 参数
- [ ] 非空 manifest 在 prompt 中出现 `## Existing memory files` 节
- [ ] Prompt 不再引用 `semantic_type`（使用 `type`）
- [ ] Prompt 中的型别指导由 `MemoryTypeGuidanceComposer` 提供（含 `body_structure`）
- [ ] `ClaudeService+MemoryExtraction.swift` 文件已删除
- [ ] `buildExtractionTools()` 在 `ClaudeService+ToolBuilder.swift` 中，授权集合为 `["memory_write"]`
- [ ] 全部受影响的测试通过

**Step 3: 最终 commit（若 Task 5 commit 不够干净则在此合并）**

```bash
git add -A
git commit -m "feat(M-06): complete extraction subagent → file write alignment" \
  --allow-empty
```

---

## 已知限制（不在本 Feature 范围内）

**`memory_write` 无更新语义**：当前实现（M-04）每次调用均生成新文件（UUID suffix），无法原地编辑已有 topic 文件。Claude Code 的 subagent 通过 `file_edit` 工具实现更新。agentGui 的 `memory_write` 只能创建新文件。

Manifest 注入（本 Feature）帮助 subagent 感知已有文件从而避免重复写入新文件，但无法让它原地更新旧文件内容。未来可在 `executeFileMemoryWrite()` 中加入基于 title 的 deduplication（查找 title 相同的已有文件并覆盖写入），作为独立的小改进处理。

---

## 涉及文件一览

| 操作 | 文件 |
|------|------|
| 修改 | `agentGui/Services/MemoryExtractionPromptBuilder.swift` |
| 修改 | `agentGui/Services/SessionMemoryExtractorService.swift` |
| 修改 | `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift` |
| **删除** | `agentGui/Services/ClaudeService/ClaudeService+MemoryExtraction.swift` |
| 修改 | `agentGuiTests/MemoryExtractionPromptBuilderTests.swift` |
| 修改 | `agentGuiTests/SessionMemoryExtractorServiceTests.swift` |
| 修改 | `agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift` |

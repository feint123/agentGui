# M-02: 删除 MemoryRecord / 治理层 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 移除 `UnifiedMemoryFileStoreAdapter` JSON 存储体系以及与之配套的治理/审计基础设施（`MemoryRecord` 模型和所有 Admission/Invalidation/DomainProfile 组件），消除约 800+ 行过度设计代码。

**Architecture:** 依赖 M-01 已完成（RMSInsight+MemoryRecord 桥接已删除）。本 Feature 只做删除 + 最小化 stub，为 M-07（MemoryIndexFileSystem 从文件系统重建）铺路。删除 `MemoryRecord` 后，`MemoryIndexFileSystem.rebuild()`、`MemoryTopicFileComposer.compose()` 等方法替换为无参 stub，M-07 将填入文件系统驱动的实现。`MemoryRuntimeSnapshot.swift` 中的 `MemoryRecord` 类型依赖统一替换为 `String` 原始值，保留其运行时可观测性结构。

**Tech Stack:** Swift 6.0+, SwiftData

> **前置条件：** M-01 已完成（RMS 文件已删除）
> **后置 Feature：** M-07 依赖 M-02 完成

---

## 文件地图（执行前速查）

### 需删除的 Service 文件（共 7 个）

```
agentGui/Services/MemoryStoreAdapter.swift                    53 行
agentGui/Services/UnifiedMemoryFileStoreAdapter.swift        222 行
agentGui/Services/MemoryEvidenceResolver.swift                16 行
agentGui/Services/MemoryInvalidationService.swift             45 行
agentGui/Services/MemoryDomainProfileRegistry.swift           32 行
agentGui/Services/TacticKernelDistillationService.swift       38 行
agentGui/Services/CounterexampleDistillationService.swift     65 行
```

### 需删除的 Model 文件（共 14 个）

```
agentGui/Models/MemoryRecord.swift                           186 行
agentGui/Models/MemoryGovernanceTypes.swift
agentGui/Models/MemoryRuntimeTypes.swift
agentGui/Models/MemoryAdmissionScore.swift                    13 行
agentGui/Models/MemoryAdmissionFeatureVector.swift             9 行
agentGui/Models/MemoryAdmissionExplanation.swift               7 行
agentGui/Models/MemoryBackgroundJob.swift                    184 行
agentGui/Models/MemoryConfirmationStatus.swift                 7 行
agentGui/Models/MemoryConfirmationCandidate.swift             98 行
agentGui/Models/MemoryConsolidationRule.swift                 25 行   ← 也用于 M-03
agentGui/Models/UnifiedMemoryStoredRecord.swift
agentGui/Models/MemoryKind.swift
agentGui/Models/MemoryLayer.swift
agentGui/Models/MemoryRetrievalIntent.swift
agentGui/Models/MemoryRuntimeTypes.swift
agentGui/Models/MemorySweepReport.swift
```

### 保留的 Model 文件（**不要误删**）

```
agentGui/Models/MemoryScope.swift               ← 保留（RelevantMemoryRecallService 使用）
agentGui/Models/MemoryRuntimeSnapshot.swift     ← 保留，但需修改移除 MemoryRecord 依赖
```

### 需修改的文件（共 6 个）

| 文件 | 修改摘要 |
|------|----------|
| `agentGui/Models/MemoryRuntimeSnapshot.swift` | 将 `MemoryRecord.VerificationStatus` / `RetentionPolicy` 替换为 `String` |
| `agentGui/Services/Memory/MemoryIndexFileSystem.swift` | `rebuild(with: [MemoryRecord])` → `rebuild()` stub（M-07 填入） |
| `agentGui/Services/Memory/MemoryIndexWriter.swift` | 删除 `build(records: [MemoryRecord])` 方法，保留 truncate 逻辑 |
| `agentGui/Services/Memory/MemoryTopicFileComposer.swift` | 删除 `compose(record: MemoryRecord)` 方法（M-04 新增不同签名） |
| `agentGui/Services/Memory/MemoryTopicFilename.swift` | 删除 `filename(for record: MemoryRecord)` 重载，保留 `sanitizeTitle()` |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | 确认 `triggerMemoryIndexRebuild` 已在 M-01 删除；若有残留 `$0.toMemoryRecord()` 调用则删除 |

### 需删除的测试

```
agentGuiTests/MemoryIndexWriterTests.swift         ← 若测试 build(records: [MemoryRecord])
agentGuiTests/MemoryTopicFileComposerTests.swift   ← 若测试 compose(record: MemoryRecord)
agentGuiTests/MemoryTopicFilenameTests.swift       ← 若测试 filename(for record: MemoryRecord)
agentGuiTests/MemoryIndexFileSystemTests.swift     ← 若测试 rebuild(with: [MemoryRecord])
```

（注：仅删除依赖 MemoryRecord 的测试 case，若同文件内有其他测试可保留）

---

## Task 1: 删除治理层 Service 文件

**Files:**
- Delete: `agentGui/Services/MemoryStoreAdapter.swift`
- Delete: `agentGui/Services/UnifiedMemoryFileStoreAdapter.swift`
- Delete: `agentGui/Services/MemoryEvidenceResolver.swift`
- Delete: `agentGui/Services/MemoryInvalidationService.swift`
- Delete: `agentGui/Services/MemoryDomainProfileRegistry.swift`
- Delete: `agentGui/Services/TacticKernelDistillationService.swift`
- Delete: `agentGui/Services/CounterexampleDistillationService.swift`

**Step 1: 在 Xcode 中删除**

在 Xcode Project Navigator 里多选上述 7 个文件 → 右键 → Delete → **Move to Trash**。

**Step 2: 验证文件消失**

```bash
ls agentGui/Services/MemoryStoreAdapter.swift \
   agentGui/Services/UnifiedMemoryFileStoreAdapter.swift \
   agentGui/Services/MemoryEvidenceResolver.swift \
   agentGui/Services/MemoryInvalidationService.swift 2>&1
# 期望：No such file
```

**Step 3: Commit**

```bash
git add -A agentGui/Services/
git commit -m "chore(M-02): delete governance service files (MemoryStoreAdapter, UnifiedMemoryFileStoreAdapter, etc.)"
```

---

## Task 2: 删除 MemoryRecord 及相关 Model 文件

**Step 1: 在 Xcode 中删除下述 14 个 Model 文件**

多选以下文件 → Delete → Move to Trash：

```
agentGui/Models/MemoryRecord.swift
agentGui/Models/MemoryGovernanceTypes.swift
agentGui/Models/MemoryRuntimeTypes.swift
agentGui/Models/MemoryAdmissionScore.swift
agentGui/Models/MemoryAdmissionFeatureVector.swift
agentGui/Models/MemoryAdmissionExplanation.swift
agentGui/Models/MemoryBackgroundJob.swift
agentGui/Models/MemoryConfirmationStatus.swift
agentGui/Models/MemoryConfirmationCandidate.swift
agentGui/Models/MemoryConsolidationRule.swift
agentGui/Models/UnifiedMemoryStoredRecord.swift
agentGui/Models/MemoryKind.swift
agentGui/Models/MemoryLayer.swift
agentGui/Models/MemoryRetrievalIntent.swift
agentGui/Models/MemorySweepReport.swift
```

> ⚠️ **不要删除** `agentGui/Models/MemoryScope.swift` 和 `agentGui/Models/MemoryRuntimeSnapshot.swift`

**Step 2: 验证未误删保留文件**

```bash
ls agentGui/Models/MemoryScope.swift agentGui/Models/MemoryRuntimeSnapshot.swift
# 期望：两个文件正常存在
```

**Step 3: 尝试构建（记录编译错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | grep -v "^CompileSwift" | head -30
```

预期：`MemoryRecord`、`MemoryKind`、`MemoryLayer` 等类型未定义错误——后续 Task 逐一修复。

**Step 4: Commit（文件删除）**

```bash
git add -A agentGui/Models/
git commit -m "chore(M-02): delete MemoryRecord, MemoryKind, MemoryLayer, and governance model files"
```

---

## Task 3: 修复 MemoryRuntimeSnapshot.swift

**File:** `agentGui/Models/MemoryRuntimeSnapshot.swift`

`MemoryRuntimeSnapshotRecord` 中引用了 `MemoryRecord.VerificationStatus`、`MemoryRecord.RetentionPolicy`、`MemoryKind`、`MemoryLayer`，需替换为 `String` primitive。

**Step 1: 将 layer / kind 字段改为 String**

找到 `MemoryRuntimeSnapshotRecord` 的字段：

```swift
// 修改前
var layer: MemoryLayer
var kind: MemoryKind
var verificationStatus: MemoryRecord.VerificationStatus
var retentionPolicy: MemoryRecord.RetentionPolicy
```

改为：

```swift
// 修改后
var layer: String
var kind: String
var verificationStatus: String
var retentionPolicy: String
```

同时更新 `init(...)` 参数签名（同类型）。

**Step 2: 搜索同文件其他 MemoryRecord / MemoryKind / MemoryLayer 引用**

```bash
grep -n "MemoryRecord\|MemoryKind\|MemoryLayer" agentGui/Models/MemoryRuntimeSnapshot.swift
```

逐一替换为 `String` 或删除（如果是冗余的类型转换方法）。

**Step 3: 检查调用 MemoryRuntimeSnapshotRecord(...) 的文件**

```bash
grep -rn "MemoryRuntimeSnapshotRecord(" agentGui/ --include="*.swift"
```

找到所有构造调用，将 `MemoryKind` / `MemoryLayer` 枚举值改为对应的 `.rawValue` 字符串字面量（如 `"insight"` 替代 `.insight`，`"session"` 替代 `.session`）。

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Models/MemoryRuntimeSnapshot.swift
git commit -m "fix(M-02): replace MemoryRecord/MemoryKind/MemoryLayer types in MemoryRuntimeSnapshot with String"
```

---

## Task 4: 修复 MemoryIndexFileSystem.swift

**File:** `agentGui/Services/Memory/MemoryIndexFileSystem.swift`

当前：`func rebuild(with records: [MemoryRecord], now: Date) throws`

M-07 将实现从文件系统扫描重建 MEMORY.md。本 Task 只添加无参 stub，保证编译通过。

**Step 1: 替换 rebuild 方法签名**

找到当前方法：
```swift
func rebuild(with records: [MemoryRecord], now: Date = .now) throws {
    let output = writer.build(records: records, now: now)
    guard !output.indexContent.isEmpty else { return }
    // ... 写文件逻辑
}
```

替换为 stub（保留写文件骨架，M-07 填充 output 来源）：

```swift
/// M-07 占位实现。
/// Feature M-07 将替换此方法为从 memoryDir 扫描 .md 文件重建 MEMORY.md 的实现。
func rebuild() throws {
    // TODO(M-07): scan memoryDir/*.md frontmatter → build index → write MEMORY.md
}
```

同时删除 `private let writer = MemoryIndexWriter()` 这行（MemoryIndexWriter 的 `build(records:)` 在 Task 5 中也会删除）。

**Step 2: 搜索所有 rebuild(with:) 调用点**

```bash
grep -rn "\.rebuild(" agentGui/ --include="*.swift"
```

找到所有调用 `rebuild(with:)` 的地方，更新为 `rebuild()`（或直接删除调用，因为 stub 是无操作的）。

典型调用点：
- `ClaudeService+ToolDispatch.swift` 中的 `triggerMemoryIndexRebuild`（M-01 已删除，应无残留）
- 可能有其他调用点，逐一更新

**Step 3: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 4: Commit**

```bash
git add agentGui/Services/Memory/MemoryIndexFileSystem.swift
git commit -m "fix(M-02): stub MemoryIndexFileSystem.rebuild() — MemoryRecord removed (M-07 pending)"
```

---

## Task 5: 修复 MemoryIndexWriter.swift

**File:** `agentGui/Services/Memory/MemoryIndexWriter.swift`

当前存在 `build(records: [MemoryRecord], now:) -> MemoryIndexBuildOutput` 方法，需删除。保留截断辅助函数（`truncate(lines:)`等），供 M-07 的新实现使用。

**Step 1: 检查 MemoryIndexWriter 全文**

```bash
wc -l agentGui/Services/Memory/MemoryIndexWriter.swift
cat agentGui/Services/Memory/MemoryIndexWriter.swift
```

**Step 2: 删除 build(records:) 方法和相关 nested types**

找到 `func build(records: [MemoryRecord], ...)` 以及其返回值类型 `MemoryIndexBuildOutput`（如果定义在同文件内），全部删除。

保留：
- `struct MemoryIndexWriter` 声明本身
- 任何截断相关辅助函数（如 `truncate`, `truncateLines`, `buildIndexLine` 等独立函数）

**Step 3: 若 MemoryIndexWriter 删除后成为空 struct，保留骨架**

```swift
import Foundation

/// MEMORY.md 索引写入器。
/// `build(records:)` 已在 M-02 移除；M-07 将在 MemoryIndexFileSystem 中新增
/// 从文件系统扫描驱动的 rebuild 路径。
struct MemoryIndexWriter: Sendable {
    // truncate helpers preserved for M-07
    static let maxLines = 200
    static let maxBytes = 25_000
}
```

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Services/Memory/MemoryIndexWriter.swift
git commit -m "fix(M-02): remove build(records:[MemoryRecord]) from MemoryIndexWriter"
```

---

## Task 6: 修复 MemoryTopicFileComposer.swift

**File:** `agentGui/Services/Memory/MemoryTopicFileComposer.swift`

当前：`func compose(record: MemoryRecord, now: Date) -> String`

M-04 将新增 `compose(title:description:type:content:)` 签名；M-02 只删除 `MemoryRecord` 版本。

**Step 1: 删除 compose(record:) 方法**

找到：
```swift
func compose(record: MemoryRecord, now: Date = .now) -> String {
    ...
}

private func bodyText(from record: MemoryRecord) -> String { ... }
```

删除 `compose(record:)` 方法体和 `bodyText(from record:)` 辅助方法。

**Step 2: 保留 yamlQuote 和 dateFormatter 等工具帮助函数**

检查文件中还有哪些方法：
```bash
grep -n "func " agentGui/Services/Memory/MemoryTopicFileComposer.swift
```

保留所有非 MemoryRecord 依赖的工具函数（`yamlQuote()`、`dateFormatter` 等，M-04 将复用）。

**Step 3: 若 struct 变空，添加 M-04 TODO 注释**

```swift
struct MemoryTopicFileComposer: Sendable {
    // compose(record: MemoryRecord) 已在 M-02 移除。
    // M-04 将新增 compose(title:description:type:content:now:) 方法。

    private static let dateFormatter: ISO8601DateFormatter = { ... }()

    static func yamlQuote(_ value: String) -> String { ... }
}
```

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Services/Memory/MemoryTopicFileComposer.swift
git commit -m "fix(M-02): remove compose(record:MemoryRecord) from MemoryTopicFileComposer (M-04 pending)"
```

---

## Task 7: 修复 MemoryTopicFilename.swift

**File:** `agentGui/Services/Memory/MemoryTopicFilename.swift`

当前有 `filename(for record: MemoryRecord)` 重载，M-02 删除；保留 `sanitizeTitle()` 独立函数（M-04 将直接使用）。

**Step 1: 删除 filename(for record:) 方法**

```swift
// 删除此方法：
static func filename(for record: MemoryRecord) -> String {
    let slug = sanitizeTitle(record.title)
    let id8 = String(record.id.prefix(8))
    if slug.isEmpty {
        return "memory_\(id8).md"
    }
    return "\(slug)_\(id8).md"
}
```

**Step 2: 保留 sanitizeTitle() 方法**

```swift
static func sanitizeTitle(_ title: String) -> String { ... }
```

也可新增一个 `filename(title:id:)` 签名方便 M-04 调用（可选）：

```swift
static func filename(title: String, id: String) -> String {
    let slug = sanitizeTitle(title)
    let id8 = String(id.prefix(8))
    return slug.isEmpty ? "memory_\(id8).md" : "\(slug)_\(id8).md"
}
```

**Step 3: 确认无其他 MemoryRecord 引用**

```bash
grep -n "MemoryRecord" agentGui/Services/Memory/MemoryTopicFilename.swift
# 期望：空输出
```

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Services/Memory/MemoryTopicFilename.swift
git commit -m "fix(M-02): remove filename(for:MemoryRecord) from MemoryTopicFilename; add filename(title:id:)"
```

---

## Task 8: 清理残余 MemoryRecord 引用

**Step 1: 全局搜索残余引用**

```bash
grep -rn "MemoryRecord\|MemoryKind\|MemoryLayer\|MemoryStoreAdapter\|UnifiedMemoryStoredRecord" \
  agentGui/ --include="*.swift" | grep -v "//.*MemoryRecord"
```

列出所有残余引用，逐文件修复。

常见残余位置：
- 若 `ClaudeService+ToolDispatch.swift` 有 `$0.toMemoryRecord()` 调用（M-01 应已删除，确认无残留）
- `MemoryDateUtils.swift` 等辅助文件若引用了 MemoryRecord

**Step 2: 逐个修复**

对每个残余引用：
- 若在已删除文件的调用方，整行删除
- 若在保留文件中用 MemoryRecord 做 type constraint，替换为 `String` 或删除相关函数签名

**Step 3: 全量构建检查（应无错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:"
# 期望：空输出
```

**Step 4: Commit**

```bash
git add -A agentGui/
git commit -m "fix(M-02): cleanup remaining MemoryRecord/MemoryKind/MemoryLayer references"
```

---

## Task 9: 删除并修复相关测试

**Step 1: 找出需删除的测试文件**

```bash
grep -rl "MemoryRecord\|MemoryIndexWriter\|MemoryTopicFileComposer\|UnifiedMemoryStoredRecord" \
  agentGuiTests/ --include="*.swift"
```

**Step 2: 对每个测试文件决定处置方式**

- **MemoryIndexWriterTests.swift**：若只测 `build(records: [MemoryRecord])`，整文件删除；若有其他测试保留文件并删除相关 case
- **MemoryTopicFileComposerTests.swift**：若只测 `compose(record:)`，整文件删除
- **MemoryTopicFilenameTests.swift**：若有测 `filename(for record:)` 的 case，删除这些 case；若有测 `sanitizeTitle()` 的 case，保留
- **MemoryIndexFileSystemTests.swift**：若只测 `rebuild(with records:)`，整文件删除；否则更新调用为 `rebuild()`

**Step 3: 在 Xcode 中删除需要完全删除的测试文件**

选中 → Delete → Move to Trash

**Step 4: 编辑保留但需修改的测试文件**

更新调用签名，确保测试 `rebuild()` 无参版本。

**Step 5: 运行 Memory 相关测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M02-test \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`（或文件不存在时跳过）

**Step 6: Commit**

```bash
git add -A agentGuiTests/
git commit -m "test(M-02): delete/update tests that depend on MemoryRecord"
```

---

## Task 10: 全量 Smoke 验证

**Step 1: 确认无 MemoryRecord 符号**

```bash
grep -rn "MemoryRecord\|MemoryKind\|MemoryLayer\|MemoryStoreAdapter\|unified-memory" \
  agentGui/ --include="*.swift" | grep -v "//.*Memory"
# 期望：空输出
```

**Step 2: 全量编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：** BUILD SUCCEEDED **
```

**Step 3: 运行全量 Memory 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M02-smoke \
  -only-testing:agentGuiTests/MemoryTopicFilenameTests \
  -only-testing:agentGuiTests/MemoryTopicScannerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

**Step 4: 最终 Commit**

```bash
git add -A
git commit -m "feat(M-02): complete MemoryRecord/governance layer removal — -800 lines"
```

---

## 完成标志 Checklist

- [ ] `agentGui/Models/MemoryRecord.swift` 消失
- [ ] `agentGui/Services/UnifiedMemoryFileStoreAdapter.swift` 消失
- [ ] `agentGui/Models/MemoryKind.swift`、`MemoryLayer.swift` 消失
- [ ] `grep -r "MemoryRecord\b" agentGui/ --include="*.swift"` 返回空
- [ ] `MemoryRuntimeSnapshot.swift` 无 MemoryRecord 依赖
- [ ] `MemoryIndexFileSystem.rebuild()` 无参 stub 存在
- [ ] `MemoryTopicFilename.filename(title:id:)` 可调用
- [ ] `xcodebuild build` → BUILD SUCCEEDED
- [ ] `unified-memory/*.json` 不再生成

---

## 注意事项

1. **MemoryConsolidationRule.swift**：该文件同时出现在 M-02 和 M-03 的删除列表中。建议在 M-02 中一并删除，M-03 执行时跳过这一步。
2. **MemoryIndexWriter 保留骨架**：不要完全删除 MemoryIndexWriter.swift，M-07 还需在其中保留 `maxLines`/`maxBytes` 常量。
3. **MemoryRuntimeSnapshot**：该文件保留是为了运行时可观测性 UI，修改后字段类型变为 `String`——调用方若有 `.rawValue` 转换可同时简化掉。

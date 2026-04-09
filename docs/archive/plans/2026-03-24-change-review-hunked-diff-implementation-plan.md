# Change Review Hunked Diff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将当前 change review 的整文件伪 unified diff 升级为真正的 hunk 化 line diff，修正增删行统计，并为后续 Git 风格可读性增强保留结构化扩展点。

**Architecture:** 采用增量替换而不是重写整个审查链路。核心做法是先在 `Services/ChangeReview` 内建立结构化 diff value objects、serializer 和纯算法测试，再把 `WorkspaceChangeCaptureService` 从“整文件删加字符串拼接”切换到“结构化 diff -> unified diff 序列化”，最后补充近邻 hunk 合并、边界优化钩子和回归测试。第一阶段不改 `SwiftData` schema，继续复用 `ProposedFileChange.unifiedDiff` 作为兼容输出。

**Tech Stack:** Swift 6、Foundation、现有 Change Review 服务层、Swift Testing、`xcodebuild`、现有 `Quality Smoke` 任务、可选 `git diff --no-index` 对照脚本。

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 实施策略选择

### 推荐方案：Phase-1 delivery first

先交付真正的 hunk diff、真实统计和现有 UI 兼容输出，再补可读性增强。理由很直接：当前最大的用户痛点是“整文件像被重写”，这不是 UI 问题，而是算法产物错误。只要先把结构化 hunk 建起来，`GitDiffView` 和 review flow 就能立即受益。

### 备选方案 A：直接调用 `git diff --no-index`

优点是快，缺点是把核心能力绑定到外部 Git，且仍然缺少内部结构化 hunks，不推荐作为正式实现。

### 备选方案 B：一次性把 Myers、patience、histogram、moved-block detection 全部做完

优点是一步到位，缺点是范围过大、回归风险高、验证面过宽，不推荐作为第一版。

## 设计约束

### 必须满足

1. 不修改 `ProposedFileChange` 持久化 schema。
2. `WorkspaceChangeCaptureService` 仍保持可取消、可 detached 执行。
3. `ChangeProposalReviewView`、`GitDiffView`、`ProposalDockPresenter` 无需大改即可受益。
4. 所有核心算法先有纯测试，再接服务层。
5. 第一阶段输出必须是合法 unified diff，并能被现有 `GitDiffPresentation.build(...)` 解析成多个 section。

### 明确避免

1. 不要在 `WorkspaceChangeCaptureService.swift` 中继续堆积大段算法代码。
2. 不要把结构化 hunk 只做成一次性局部变量；必须有可复用 value objects。
3. 不要先改 UI 再修算法。
4. 不要把 Git 命令变成运行时强依赖。

## Proposed File Layout

**Create structured diff value objects and helpers:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffTypes.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffEngine.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/UnifiedDiffSerializer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/LineTokenization.swift`

**Modify existing change review integration points:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/WorkspaceChangeCaptureService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/DirectIntentBackend.swift`

**Create or expand tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StructuredDiffEngineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedDiffSerializerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceChangeCaptureServiceTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`

**Reference docs:**
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-24-change-review-hunked-diff-architecture.md`
- `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-21-permission-governance-unification.md`

## Delivery Gates

### Gate A：Algorithm Contract Safety

必须满足：

1. `StructuredDiffEngineTests` 绿。
2. `UnifiedDiffSerializerTests` 绿。
3. 小文件局部编辑不再生成整文件删加 patch。

### Gate B：Service Integration Safety

必须满足：

1. `WorkspaceChangeCaptureServiceTests` 绿。
2. `lineAdditions` / `lineDeletions` 与真实编辑一致。
3. 现有 detached executor 测试仍通过。

### Gate C：Review Flow Safety

必须满足：

1. `ExternalChangeReviewIntegrationTests` 绿。
2. 现有 review UI 能解析多个 `@@` section。
3. `Quality Smoke` 至少通过一次，确认没有明显工作流回归。

## Task 1: Establish Structured Diff Contracts

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffTypes.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StructuredDiffEngineTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedDiffSerializerTests.swift`

**Step 1: Write the failing test**

新增纯 value object 测试，锁定结构化 diff 的最小契约：summary、hunk header 范围、line payload、render policy。

```swift
import Foundation
import Testing
@testable import agentGui

struct StructuredDiffEngineTests {
    @Test func structuredDiffCarriesMultipleHunksAndSummary() {
        let diff = StructuredFileDiff(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            summary: .init(additions: 2, deletions: 1, unchangedPrefixLines: 5, unchangedSuffixLines: 3),
            hunks: [
                .init(
                    id: "hunk-1",
                    oldStart: 6,
                    oldCount: 2,
                    newStart: 6,
                    newCount: 3,
                    lines: [
                        .context(oldLine: 6, newLine: 6, text: "context"),
                        .deletion(oldLine: 7, text: "old"),
                        .addition(newLine: 7, text: "new")
                    ]
                )
            ],
            renderPolicy: .unified
        )

        #expect(diff.summary.additions == 2)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].oldStart == 6)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StructuredDiffEngineTests -only-testing:agentGuiTests/UnifiedDiffSerializerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `StructuredFileDiff`, `DiffSummary`, `DiffHunk`, `DiffHunkLine`, `DiffRenderPolicy` do not exist.

**Step 3: Write minimal implementation**

实现以下 value objects：

1. `StructuredFileDiff`
2. `DiffSummary`
3. `DiffHunk`
4. `DiffHunkLine`
5. `DiffRenderPolicy`

要求：

1. `Sendable` / `Equatable`。
2. `DiffHunk` 带稳定 `id`。
3. 不包含任何 UI 依赖。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/StructuredDiffTypes.swift agentGuiTests/StructuredDiffEngineTests.swift agentGuiTests/UnifiedDiffSerializerTests.swift
git commit -m "feat: add structured diff contracts"
```

## Task 2: Build Unified Diff Serialization From Structured Hunks

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/UnifiedDiffSerializer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedDiffSerializerTests.swift`

**Step 1: Write the failing test**

新增 serializer 测试，要求结构化 hunk 能被序列化成标准 unified diff，多 hunk 时输出多个 `@@` section，并保留 `---` / `+++` 头。

```swift
import Foundation
import Testing
@testable import agentGui

struct UnifiedDiffSerializerTests {
    @Test func serializerRendersTwoUnifiedDiffHunks() {
        let diff = StructuredFileDiff.fixtureWithTwoHunks()

        let text = UnifiedDiffSerializer.serialize(diff)

        #expect(text.contains("--- a/README.md"))
        #expect(text.contains("+++ b/README.md"))
        #expect(text.components(separatedBy: "@@").count > 4)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/UnifiedDiffSerializerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `UnifiedDiffSerializer` does not exist.

**Step 3: Write minimal implementation**

实现 serializer：

1. 支持 `--- a/<path>` / `+++ b/<path>`。
2. 支持多个 hunk。
3. 支持 `context`、`deletion`、`addition`、`noNewlineMarker`。
4. 对新增/删除文件保留可扩展分支，但第一版只需合法 unified diff。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/UnifiedDiffSerializer.swift agentGuiTests/UnifiedDiffSerializerTests.swift
git commit -m "feat: add unified diff serializer"
```

## Task 3: Implement Myers-based Line Diff Core With Prefix/Suffix Trimming

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/LineTokenization.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffEngine.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StructuredDiffEngineTests.swift`

**Step 1: Write the failing test**

为以下行为写测试：

1. 单行替换只产生一个小 hunk。
2. 两处相距很远的修改产生两个 hunk。
3. 仅新增文件和仅删除文件生成正确 summary。
4. 统计只计真实新增/删除行，不计上下文行。

```swift
import Foundation
import Testing
@testable import agentGui

extension StructuredDiffEngineTests {
    @Test func engineBuildsTwoHunksForSeparatedEdits() throws {
        let oldText = ["a", "b", "c", "d", "e", "f", "g", "h"].joined(separator: "\n")
        let newText = ["a", "b2", "c", "d", "e", "f", "g2", "h"].joined(separator: "\n")

        let diff = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            baseContent: oldText,
            stagedContent: newText,
            contextLines: 1,
            interHunkContext: 0
        )

        #expect(diff.hunks.count == 2)
        #expect(diff.summary.additions == 2)
        #expect(diff.summary.deletions == 2)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StructuredDiffEngineTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because `StructuredDiffEngine` does not exist or does not produce real hunks.

**Step 3: Write minimal implementation**

实现：

1. 行切分与末尾换行状态记录。
2. 公共前缀 / 后缀裁剪。
3. Myers shortest edit script 或等价最小编辑实现。
4. 将 edit script 转为初步 hunk 列表。
5. 计算真实 additions / deletions。

实现要求：

1. 不把所有算法内联进 `WorkspaceChangeCaptureService.swift`。
2. 核心逻辑保持纯函数或无副作用 service。
3. context 行和统计严格分离。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/LineTokenization.swift agentGui/Services/ChangeReview/StructuredDiffEngine.swift agentGuiTests/StructuredDiffEngineTests.swift
git commit -m "feat: add myers-based structured diff engine"
```

## Task 4: Integrate Structured Diff Engine Into Workspace Change Capture

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/WorkspaceChangeCaptureService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkspaceChangeCaptureServiceTests.swift`

**Step 1: Write the failing test**

扩展现有 `WorkspaceChangeCaptureServiceTests`，锁定当前服务层的新行为：

1. 轻微修改时 `lineAdditions` / `lineDeletions` 不再等于整文件行数。
2. diff 中必须带有 context 行。
3. 两个远距离修改时，`unifiedDiff` 中出现两个 hunk header。

```swift
@Test func collectArtifactsBuildsRealUnifiedDiffWithAccurateCounts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try ["one", "two", "three", "four"].joined(separator: "\n").write(
        to: root.appending(path: "file.txt"),
        atomically: true,
        encoding: .utf8
    )

    let service = WorkspaceChangeCaptureService(fileManager: .default)
    let snapshot = try service.captureSnapshot(root: root)
    try ["one", "two changed", "three", "four"].joined(separator: "\n").write(
        to: root.appending(path: "file.txt"),
        atomically: true,
        encoding: .utf8
    )

    let artifact = try #require(service.collectArtifacts(from: snapshot).first)
    #expect(artifact.lineAdditions == 1)
    #expect(artifact.lineDeletions == 1)
    #expect(artifact.unifiedDiff.contains(" two"))
    #expect(artifact.unifiedDiff.contains("+two changed"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/WorkspaceChangeCaptureServiceTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL because current implementation still emits whole-file delete/add and inflated counts.

**Step 3: Write minimal implementation**

在 `WorkspaceChangeCaptureService.swift` 中：

1. 用 `StructuredDiffEngine` 取代当前 `ChangeReviewArtifactBuilder.unifiedDiff(...)` 拼接逻辑。
2. 用 `UnifiedDiffSerializer` 输出字符串。
3. 用 `DiffSummary` 回填 `lineAdditions` / `lineDeletions`。
4. 保留 `baseContentSnapshot` / `stagedContentSnapshot` / content hash 行为不变。

如有必要，可把当前 `ChangeReviewArtifactBuilder` 重构为 facade，而不是直接删除，避免调用点大面积变更。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/WorkspaceChangeCaptureService.swift agentGuiTests/WorkspaceChangeCaptureServiceTests.swift
git commit -m "feat: integrate structured diff engine into change capture"
```

## Task 5: Add Hunk Fusion, No-newline Marker, And Readability Guards

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffEngine.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/UnifiedDiffSerializer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StructuredDiffEngineTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/UnifiedDiffSerializerTests.swift`

**Step 1: Write the failing test**

增加后处理测试：

1. 两个距离小于等于 `interHunkContext` 的 edits 应合并成一个 hunk。
2. 文件末尾无换行时应输出 `\ No newline at end of file`。
3. 空文件新增和删除的 header 范围必须正确。

```swift
extension StructuredDiffEngineTests {
    @Test func engineFusesNearbyEditsIntoSingleHunk() throws {
        let oldText = ["a", "b", "c", "d", "e"].joined(separator: "\n")
        let newText = ["a", "b1", "c", "d1", "e"].joined(separator: "\n")

        let diff = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            baseContent: oldText,
            stagedContent: newText,
            contextLines: 1,
            interHunkContext: 1
        )

        #expect(diff.hunks.count == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StructuredDiffEngineTests -only-testing:agentGuiTests/UnifiedDiffSerializerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until hunk merge and no-newline handling are implemented.

**Step 3: Write minimal implementation**

实现：

1. `interHunkContext` 融合逻辑。
2. 末尾无换行 marker 序列化。
3. 轻量边界修正，避免生成明显错误的空 hunk。

第一版不要做完整 indent heuristic，只要把 hunk 构造逻辑稳定下来。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ChangeReview/StructuredDiffEngine.swift agentGui/Services/ChangeReview/UnifiedDiffSerializer.swift agentGuiTests/StructuredDiffEngineTests.swift agentGuiTests/UnifiedDiffSerializerTests.swift
git commit -m "feat: add hunk fusion and newline markers"
```

## Task 6: Verify End-to-end Review Flow And Proposal Statistics

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExternalChangeReviewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChangeProposalStoreTests.swift`
- Optional Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ProposalDockPresenter.swift`

**Step 1: Write the failing test**

补充 end-to-end 回归：

1. 外部 change review proposal 生成后，`unifiedDiff` 至少包含一个 `@@` header。
2. 轻微改动时 proposal file change 的 add/delete 统计为真实值。
3. 不依赖任何 UI 重构即可维持 `ChangeProposalReviewView` 的可解析性。

```swift
@Test func copilotExecutionProducesUnifiedDiffWithRealHunkHeader() async throws {
    let harness = try ExternalChangeReviewHarness.make()
    let jobHandle = try await harness.orchestrator.enqueue(/* existing command */)
    let proposal = try await harness.awaitProposal(for: jobHandle.jobID)
    let change = try #require(proposal.fileChanges.first)

    #expect(change.unifiedDiff.contains("@@"))
    #expect(change.lineAdditions >= 1)
    #expect(change.lineDeletions >= 0)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests -only-testing:agentGuiTests/ChangeProposalStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until service integration and statistics are fully wired.

**Step 3: Write minimal implementation**

完成必要的 service 和 test fixture 调整，确保：

1. 对 proposal store 的写入仍兼容旧字段。
2. 现有 integration harness 不需要知道结构化 hunk 内部细节。
3. review flow 以字符串 unified diff 继续传递，但内容已是真实 hunk diff。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/ExternalChangeReviewIntegrationTests.swift agentGuiTests/ChangeProposalStoreTests.swift
git commit -m "test: verify end-to-end review flow with hunked diffs"
```

## Task 7: Add Git Oracle Comparison And Optional Readability Hooks

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StructuredDiffGitOracleTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ChangeReview/StructuredDiffEngine.swift`

**Step 1: Write the failing test**

新增非阻塞或条件执行的 oracle 测试，对比本地 engine 与 `git diff --no-index --unified=3` 的关键结构：

1. hunk 数量。
2. 增删统计。
3. 不得退化为整文件删加。

```swift
@Test func engineRoughlyMatchesGitForSeparatedEdits() throws {
    try #require(ProcessInfo.processInfo.environment["RUN_GIT_ORACLE_TESTS"] == "1")
    // fixture setup
    // compare hunk count and summary, not byte-for-byte exact output
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
RUN_GIT_ORACLE_TESTS=1 xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StructuredDiffGitOracleTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL until comparison harness exists.

**Step 3: Write minimal implementation**

实现 oracle harness，并为 `StructuredDiffEngine` 预留第二阶段扩展点：

1. `patience anchors` strategy hook。
2. 简单边界优化 hook。
3. 参数对象而不是散落布尔值。

这一步不要求把 patience 完整实现完，但要求架构不把后续增强堵死。

**Step 4: Run test to verify it passes**

Run the same `xcodebuild` command.

Expected: PASS when environment variable is set and Git is available.

**Step 5: Commit**

```bash
git add agentGuiTests/StructuredDiffGitOracleTests.swift agentGui/Services/ChangeReview/StructuredDiffEngine.swift
git commit -m "test: add git oracle coverage for structured diffs"
```

## Task 8: Run Full Validation And Capture Rollout Notes

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-24-change-review-hunked-diff-architecture.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-24-change-review-hunked-diff-implementation-plan.md`

**Step 1: Write the failing test**

这里不新增代码测试，而是定义发布前验证清单，防止遗漏：

1. targeted tests。
2. external integration tests。
3. `Quality Smoke`。

**Step 2: Run test to verify it fails**

先执行完整验证命令，记录任何回归。

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StructuredDiffEngineTests -only-testing:agentGuiTests/UnifiedDiffSerializerTests -only-testing:agentGuiTests/WorkspaceChangeCaptureServiceTests -only-testing:agentGuiTests/ExternalChangeReviewIntegrationTests CODE_SIGNING_ALLOWED=NO
./scripts/run_quality_smoke.sh
```

Expected: PASS. If smoke fails in unrelated areas, document the failure and do not paper over it.

**Step 3: Write minimal implementation**

如验证中暴露小的集成问题：

1. 修正参数默认值。
2. 修正 serializer header 兼容性。
3. 修正 tests fixture 期望。

不要在这一步引入新范围特性。

**Step 4: Run test to verify it passes**

重复执行完整验证命令。

Expected: PASS.

**Step 5: Commit**

```bash
git add docs/technical-spec/2026-03-24-change-review-hunked-diff-architecture.md docs/plans/2026-03-24-change-review-hunked-diff-implementation-plan.md
git commit -m "docs: finalize hunked diff rollout notes"
```

## Suggested Execution Order

1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5
6. Task 6
7. Task 7
8. Task 8

不要并行开始 Task 3 和 Task 4。算法契约没有稳定前，接入服务层只会放大调试成本。

## Rollback Plan

如果在 Task 4 或之后发现回归，可按以下顺序回滚：

1. 先保留 `StructuredDiffEngine` 与 tests。
2. 把 `WorkspaceChangeCaptureService` 切回旧的 whole-file builder。
3. 保留 serializer 和 value objects 作为后续继续迭代基础。

这能保证算法工作不丢失，同时快速恢复当前产品链路。

## Success Criteria

完成后应满足：

1. 局部一行修改不会再显示为整文件删除再新增。
2. 同一文件内多个相距较远的修改能显示为多个 hunks。
3. `ProposalDockPresenter` 读取到的 add/delete 统计与真实改动匹配。
4. `GitDiffView` 无需重构即可显示更接近 Git 的 patch。
5. 结构化 diff engine 可继续演进到 patience anchors 和边界优化。
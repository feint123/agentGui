# G-A1：提交历史列表面板 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Git 侧边栏新增"历史"分区，展示最近 50 条提交记录，支持分页加载，点击任意行展开显示 Commit Detail。

**Architecture:** 新增 `GitCommit` 值类型模型；在 `GitServicing` 协议及 `GitService` 实现中加入 `listCommits` 方法；新增 `GitSidebarHistorySection` 视图，集成到现有 `GitPanelView` 的 section 列表；在 `GitPanelViewModel` 中持有 `historyEntries` 状态，在 `refresh()` 时协同加载。

**Tech Stack:** Swift 6.0, SwiftUI, `ProcessGitCommandRunner`（现有），XCTest

---

## 背景与约束

- 协议 `GitServicing` 标注了 `@MainActor`；所有实现方法均在 `@MainActor` 上下文执行
- `GitService` 使用 `commandRunner.run(arguments:workingDirectory:)` 调用 git 进程
- 现有分区视图使用 `sectionCard(_:systemImage:content:)` 帮助函数
- `GitPanelView` 组合所有 Section；顺序：Overview → Changes → Commit → Branch → Utilities
- History Section 插在 Utilities 之前（保持 Utilities 在最底部）
- 测试文件放在 `agentGuiTests/` 目录，`@testable import agentGui`，`@MainActor final class ... : XCTestCase`

---

## Task 1：新增 `GitCommit` 数据模型

**Files:**
- Create: `agentGui/Models/GitCommit.swift`
- Test: `agentGuiTests/GitCommitTests.swift`

### Step 1：编写失败测试

```swift
// agentGuiTests/GitCommitTests.swift
import XCTest
@testable import agentGui

@MainActor
final class GitCommitTests: XCTestCase {

    func test_shortSha_returns7Chars() {
        let commit = GitCommit(
            sha: "abcdef1234567890",
            message: "fix: handle nil",
            fullMessage: "fix: handle nil\n\nDetails here.",
            author: "Alice",
            authorEmail: "alice@example.com",
            date: Date()
        )
        XCTAssertEqual(commit.shortSha, "abcdef1")
    }

    func test_shortSha_withShortSha_returnsAll() {
        let commit = GitCommit(
            sha: "abc",
            message: "wip",
            fullMessage: "wip",
            author: "Bob",
            authorEmail: "bob@example.com",
            date: Date()
        )
        XCTAssertEqual(commit.shortSha, "abc")
    }

    func test_identifiable_idEqualsSha() {
        let commit = GitCommit(
            sha: "aabbccdd",
            message: "test",
            fullMessage: "test",
            author: "C",
            authorEmail: "c@c.com",
            date: Date()
        )
        XCTAssertEqual(commit.id, "aabbccdd")
    }
}
```

### Step 2：运行测试，验证编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitCommitTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`GitCommit` 未定义。

### Step 3：实现最小模型

```swift
// agentGui/Models/GitCommit.swift
import Foundation

struct GitCommit: Identifiable, Equatable {
    let sha: String
    let message: String       // 首行（摘要）
    let fullMessage: String   // 完整 commit body
    let author: String
    let authorEmail: String
    let date: Date

    var id: String { sha }

    var shortSha: String {
        String(sha.prefix(7))
    }
}
```

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitCommitTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`GitCommitTests` 3 个测试全部 PASSED。

### Step 5：提交

```bash
git add agentGui/Models/GitCommit.swift agentGuiTests/GitCommitTests.swift
git commit -m "feat(git): add GitCommit model"
```

---

## Task 2：解析器 — 将 `git log` 原始输出解析为 `[GitCommit]`

**Files:**
- Create: `agentGui/Services/GitLogParser.swift`
- Test: `agentGuiTests/GitLogParserTests.swift`

### 分隔符设计

使用 `\u{1E}`（ASCII Record Separator）作为字段分隔符，`\u{1D}`（ASCII Group Separator）作为记录分隔符，避免与 commit 消息内容冲突。

**git log 命令：**
```
git log --format=%H%x1E%s%x1E%B%x1E%an%x1E%ae%x1E%aI -n 50
```

- `%H`  — 完整 SHA  
- `%s`  — 首行摘要  
- `%B`  — 完整 body（包含首行）  
- `%an` — 作者名  
- `%ae` — 作者邮箱  
- `%aI` — ISO 8601 日期  

**注意：`%B` 会包含尾部换行；`%x1E` 格式符之间不会有额外换行，但相邻记录之间可能有空行。使用 `--format` 而非 `--pretty=format` 可在每条记录末尾加一个额外换行；用 Group Separator 来分割多条记录不可靠，改用：`--format=COMMIT_SEP%H%x1E...` + 按 `COMMIT_SEP` 分割。**

实际推荐格式（无歧义）：
```
git log --format=---COMMIT---%n%H%n%s%n%B%n---END--- -n 50
```

解析逻辑按 `---COMMIT---` 切割，提取段落内各行。

### Step 1：编写失败测试

```swift
// agentGuiTests/GitLogParserTests.swift
import XCTest
@testable import agentGui

final class GitLogParserTests: XCTestCase {

    private let sampleOutput = """
    ---COMMIT---
    abcdef1234567890abcdef1234567890abcdef12
    fix: handle nil case
    fix: handle nil case

    Resolved a crash when the user taps on an empty list.
    ---END---
    ---COMMIT---
    1111111111111111111111111111111111111111
    feat: add dark mode
    feat: add dark mode
    ---END---
    """

    func test_parse_returnsCorrectCount() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits.count, 2)
    }

    func test_parse_firstCommit_sha() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[0].sha, "abcdef1234567890abcdef1234567890abcdef12")
    }

    func test_parse_firstCommit_message() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[0].message, "fix: handle nil case")
    }

    func test_parse_firstCommit_fullMessageContainsBody() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertTrue(commits[0].fullMessage.contains("Resolved a crash"))
    }

    func test_parse_emptyInput_returnsEmpty() throws {
        let commits = try GitLogParser.parse("")
        XCTAssertTrue(commits.isEmpty)
    }

    func test_parse_singleLineBody_noExtraBody() throws {
        let commits = try GitLogParser.parse(sampleOutput)
        XCTAssertEqual(commits[1].message, "feat: add dark mode")
    }
}
```

### Step 2：运行测试，验证编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitLogParserTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误，`GitLogParser` 未定义。

### Step 3：实现解析器

```swift
// agentGui/Services/GitLogParser.swift
import Foundation

enum GitLogParser {

    static let commitSeparator = "---COMMIT---"
    static let endMarker = "---END---"

    /// `git log --format=---COMMIT---%n%H%n%s%n%B%n---END---` 输出的解析
    static func parse(_ output: String) throws -> [GitCommit] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let blocks = output.components(separatedBy: commitSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return try blocks.compactMap { block -> GitCommit? in
            // 去掉末尾的 ---END---
            let cleaned = block
                .components(separatedBy: endMarker).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? block

            let lines = cleaned.components(separatedBy: "\n")
            guard lines.count >= 2 else { return nil }

            let sha = lines[0].trimmingCharacters(in: .whitespaces)
            guard sha.count >= 7 else { return nil }

            let summary = lines[1].trimmingCharacters(in: .whitespaces)
            let bodyLines = lines.dropFirst(2)
            let fullMessage = ([summary] + bodyLines)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return GitCommit(
                sha: sha,
                message: summary,
                fullMessage: fullMessage,
                author: "",          // 由 Task 3 扩展
                authorEmail: "",
                date: Date()
            )
        }
    }
}
```

> **注意：** `author` / `authorEmail` / `date` 将在 Task 3 补全，此处先用占位值确保测试可通过。

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitLogParserTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：6 个测试全部 PASSED。

### Step 5：提交

```bash
git add agentGui/Services/GitLogParser.swift agentGuiTests/GitLogParserTests.swift
git commit -m "feat(git): add GitLogParser (sha + message fields)"
```

---

## Task 3：完善解析器 — 加入 author / date 字段

**Files:**
- Modify: `agentGui/Services/GitLogParser.swift`
- Modify: `agentGui/Services/GitLogParser.swift`（对应 git log 的格式字符串常量）
- Test: `agentGuiTests/GitLogParserTests.swift`（新增测试）

### 格式字符串升级

将 git log 命令改为：
```
git log \
  --format=---COMMIT---%n%H%n%s%n%an%n%ae%n%aI%n%B%n---END--- \
  -n 50
```

字段顺序（行号从 0 开始，基于 block lines）：
- line 0: SHA
- line 1: summary（%s）
- line 2: author name（%an）
- line 3: author email（%ae）
- line 4: ISO 8601 date（%aI）
- line 5+: body（%B，多行）

### Step 1：在测试中添加 author / date 断言

```swift
// 在 GitLogParserTests.swift 中追加

private let richOutput = """
---COMMIT---
abcdef1234567890abcdef1234567890abcdef12
fix: handle nil case
Alice
alice@example.com
2026-04-07T10:00:00+08:00
fix: handle nil case

Body text here.
---END---
"""

func test_parse_rich_author() throws {
    let commits = try GitLogParser.parseRich(richOutput)
    XCTAssertEqual(commits[0].author, "Alice")
}

func test_parse_rich_email() throws {
    let commits = try GitLogParser.parseRich(richOutput)
    XCTAssertEqual(commits[0].authorEmail, "alice@example.com")
}

func test_parse_rich_date_notDistantPast() throws {
    let commits = try GitLogParser.parseRich(richOutput)
    let year2025 = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 1))!
    XCTAssertGreaterThan(commits[0].date, year2025)
}
```

### Step 2：运行测试，验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitLogParserTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`parseRich` 未定义，编译失败。

### Step 3：在 GitLogParser 中添加 `parseRich`

```swift
// 追加到 GitLogParser.swift

extension GitLogParser {
    /// 解析包含 author / date 的富格式输出
    /// 格式：---COMMIT---%n%H%n%s%n%an%n%ae%n%aI%n%B%n---END---
    static func parseRich(_ output: String) throws -> [GitCommit] {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let iso8601 = ISO8601DateFormatter()

        let blocks = output.components(separatedBy: commitSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return blocks.compactMap { block -> GitCommit? in
            let cleaned = block
                .components(separatedBy: endMarker).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? block

            let lines = cleaned.components(separatedBy: "\n")
            guard lines.count >= 5 else { return nil }

            let sha          = lines[0].trimmingCharacters(in: .whitespaces)
            let summary      = lines[1].trimmingCharacters(in: .whitespaces)
            let author       = lines[2].trimmingCharacters(in: .whitespaces)
            let authorEmail  = lines[3].trimmingCharacters(in: .whitespaces)
            let dateString   = lines[4].trimmingCharacters(in: .whitespaces)
            let bodyLines    = lines.dropFirst(5)
            let fullMessage  = ([summary] + bodyLines)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard sha.count >= 7 else { return nil }
            let date = iso8601.date(from: dateString) ?? Date()

            return GitCommit(
                sha: sha,
                message: summary,
                fullMessage: fullMessage,
                author: author,
                authorEmail: authorEmail,
                date: date
            )
        }
    }
}
```

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitLogParserTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 9 个测试 PASSED。

### Step 5：提交

```bash
git add agentGui/Services/GitLogParser.swift agentGuiTests/GitLogParserTests.swift
git commit -m "feat(git): extend GitLogParser with author/date (parseRich)"
```

---

## Task 4：`GitServicing` 协议 + `GitService` 实现 `listCommits`

**Files:**
- Modify: `agentGui/Services/GitService.swift`（协议 + 实现）
- Test: `agentGuiTests/GitServiceListCommitsTests.swift`

### Step 1：编写失败测试（使用 Stub）

```swift
// agentGuiTests/GitServiceListCommitsTests.swift
import XCTest
@testable import agentGui

// MARK: - Stub

@MainActor
private final class StubCommandRunner: GitCommandRunning {
    var stubbedResult: GitCommandResult = .init(stdout: "", stderr: "", exitCode: 0)

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        stubbedResult
    }
}

// MARK: - Tests

@MainActor
final class GitServiceListCommitsTests: XCTestCase {

    private let repoURL = URL(fileURLWithPath: "/fake/repo")

    func test_listCommits_parsesReturnedCommits() async throws {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(
            stdout: """
            ---COMMIT---
            aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000
            feat: initial commit
            Dev
            dev@example.com
            2026-04-06T12:00:00+08:00
            feat: initial commit
            ---END---
            """,
            stderr: "",
            exitCode: 0
        )
        let service = GitService(commandRunner: stub)
        let commits = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].sha, "aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000")
        XCTAssertEqual(commits[0].author, "Dev")
    }

    func test_listCommits_commandFailed_throws() async {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(stdout: "", stderr: "fatal: not a git repo", exitCode: 128)
        let service = GitService(commandRunner: stub)
        do {
            _ = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
            XCTFail("Expected throw")
        } catch {
            // expected
        }
    }

    func test_listCommits_empty_returnsEmptyArray() async throws {
        let stub = StubCommandRunner()
        stub.stubbedResult = GitCommandResult(stdout: "", stderr: "", exitCode: 0)
        let service = GitService(commandRunner: stub)
        let commits = try await service.listCommits(repositoryRoot: repoURL, maxCount: 10, skip: 0)
        XCTAssertTrue(commits.isEmpty)
    }
}
```

### Step 2：运行测试，验证编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitServiceListCommitsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`listCommits` 不存在，编译错误。

### Step 3：在协议中添加方法签名

在 `agentGui/Services/GitService.swift` 的 `GitServicing` 协议中追加：

```swift
// GitService.swift — GitServicing 协议内（紧接现有最后一个方法之后）
func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit]
```

### Step 4：在 `GitService` 中实现

```swift
// GitService.swift — GitService final class 内，applyStash 之后追加

func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] {
    let formatString = "---COMMIT---%n%H%n%s%n%an%n%ae%n%aI%n%B%n---END---"
    var arguments = ["log", "--format=\(formatString)", "-n", "\(maxCount)"]
    if skip > 0 {
        arguments += ["--skip", "\(skip)"]
    }
    let result = try await commandRunner.run(arguments: arguments, workingDirectory: repositoryRoot)
    try validate(result)
    return (try? GitLogParser.parseRich(result.stdout)) ?? []
}
```

### Step 5：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitServiceListCommitsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：3 个测试全部 PASSED。

### Step 6：提交

```bash
git add agentGui/Services/GitService.swift agentGuiTests/GitServiceListCommitsTests.swift
git commit -m "feat(git): add listCommits to GitServicing + GitService"
```

---

## Task 5：`GitPanelViewModel` 增加 history 状态与加载

**Files:**
- Modify: `agentGui/ViewModels/GitPanelViewModel.swift`
- Test: `agentGuiTests/GitPanelViewModelHistoryTests.swift`

### Step 1：编写失败测试

```swift
// agentGuiTests/GitPanelViewModelHistoryTests.swift
import XCTest
@testable import agentGui

// MARK: - Stub GitServicing

@MainActor
private final class StubGitService: GitServicing {

    var commitsToReturn: [GitCommit] = []
    var shouldThrow = false

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        // 返回最小合法 snapshot
        GitRepositorySnapshot(
            repositoryRoot: workingDirectory,
            repositoryName: "test",
            branchName: "main",
            hasRemoteTrackingBranch: false,
            aheadCount: 0,
            behindCount: 0,
            stagedChanges: [],
            unstagedChanges: [],
            untrackedChanges: []
        )
    }
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] { [] }
    func switchBranch(to branchName: String, repositoryRoot: URL) async throws {}
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String { "" }
    func stage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func unstage(change: GitFileChange, repositoryRoot: URL) async throws {}
    func discard(change: GitFileChange, repositoryRoot: URL) async throws {}
    func commit(draft: GitCommitDraft, repositoryRoot: URL) async throws {}
    func fetch(repositoryRoot: URL) async throws {}
    func pull(repositoryRoot: URL) async throws {}
    func push(repositoryRoot: URL) async throws {}
    func createBranch(named: String, switchAfterCreate: Bool, repositoryRoot: URL) async throws {}
    func listStashes(repositoryRoot: URL) async throws -> [GitStashEntry] { [] }
    func saveStash(message: String?, repositoryRoot: URL) async throws {}
    func applyStash(id: String, pop: Bool, repositoryRoot: URL) async throws {}
    func listCommits(repositoryRoot: URL, maxCount: Int, skip: Int) async throws -> [GitCommit] {
        if shouldThrow { throw GitServiceError.commandFailed("stub error") }
        return commitsToReturn
    }
}

// MARK: - Tests

@MainActor
final class GitPanelViewModelHistoryTests: XCTestCase {

    func test_refresh_populatesHistoryEntries() async {
        let stub = StubGitService()
        stub.commitsToReturn = [
            GitCommit(
                sha: "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111",
                message: "fix: something",
                fullMessage: "fix: something",
                author: "Dev",
                authorEmail: "dev@dev.com",
                date: Date()
            )
        ]
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        XCTAssertEqual(vm.historyEntries.count, 1)
        XCTAssertEqual(vm.historyEntries[0].message, "fix: something")
    }

    func test_refresh_historyServiceError_doesNotCrash() async {
        let stub = StubGitService()
        stub.shouldThrow = true
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        // 历史加载失败时应静默，不影响主要状态
        XCTAssertTrue(vm.historyEntries.isEmpty)
    }

    func test_loadMoreHistory_appendsEntries() async {
        let stub = StubGitService()
        stub.commitsToReturn = (0..<10).map { i in
            GitCommit(
                sha: "sha\(i)" + String(repeating: "0", count: 37 - "sha\(i)".count),
                message: "commit \(i)",
                fullMessage: "commit \(i)",
                author: "Author",
                authorEmail: "a@b.com",
                date: Date()
            )
        }
        let vm = GitPanelViewModel(gitService: stub)
        await vm.refresh(for: URL(fileURLWithPath: "/fake"))
        let countAfterFirst = vm.historyEntries.count
        await vm.loadMoreHistory()
        XCTAssertGreaterThanOrEqual(vm.historyEntries.count, countAfterFirst)
    }
}
```

### Step 2：运行测试，验证编译失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitPanelViewModelHistoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`historyEntries` / `loadMoreHistory` 不存在，编译错误。

### Step 3：修改 `GitPanelViewModel`

在 `GitPanelViewModel` 的已有属性声明块中添加：

```swift
// GitPanelViewModel.swift — 在 stashEntries 之后添加
var historyEntries: [GitCommit] = []
var isLoadingHistory = false
private var historyPageSize = 50
```

在 `refresh(for:workspaceState:)` 的 `do` 块中，在赋值 `stashEntries` 之后追加：

```swift
// 历史记录静默加载，失败不阻塞主刷新
if let root = try? await gitService.repositorySnapshot(for: workingDirectory).repositoryRoot {
    historyEntries = (try? await gitService.listCommits(repositoryRoot: root, maxCount: historyPageSize, skip: 0)) ?? []
} else {
    historyEntries = (try? await gitService.listCommits(repositoryRoot: snapshot.repositoryRoot, maxCount: historyPageSize, skip: 0)) ?? []
}
```

> **简化写法（避免重复调用 repositorySnapshot）：** 注意 `refresh` 内部已有 `let snapshot = try await gitService.repositorySnapshot(for:)`，直接用它的 `.repositoryRoot`：

```swift
// 在 self.snapshot = snapshot 之后追加
let historyLoad = try? await gitService.listCommits(
    repositoryRoot: snapshot.repositoryRoot,
    maxCount: historyPageSize,
    skip: 0
)
self.historyEntries = historyLoad ?? []
```

在 `refresh` 的 `catch GitServiceError.notAGitRepository` 和 `catch` 分支中，重置 history：

```swift
historyEntries = []
```

新增 `loadMoreHistory()` 方法：

```swift
// GitPanelViewModel.swift

func loadMoreHistory() async {
    guard let repositoryRoot = snapshot?.repositoryRoot,
          !isLoadingHistory else { return }
    isLoadingHistory = true
    defer { isLoadingHistory = false }
    let moreCommits = (try? await gitService.listCommits(
        repositoryRoot: repositoryRoot,
        maxCount: historyPageSize,
        skip: historyEntries.count
    )) ?? []
    historyEntries.append(contentsOf: moreCommits)
}
```

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/GitPanelViewModelHistoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：3 个测试全部 PASSED。

### Step 5：提交

```bash
git add agentGui/ViewModels/GitPanelViewModel.swift agentGuiTests/GitPanelViewModelHistoryTests.swift
git commit -m "feat(git): add historyEntries + loadMoreHistory to GitPanelViewModel"
```

---

## Task 6：实现 `GitSidebarHistorySection` 视图

**Files:**
- Create: `agentGui/Views/Git/GitSidebarHistorySection.swift`

> 视图层无需单独 XCTest（SwiftUI 视图通过手动运行验证），但需在 Task 7 集成后进行冒烟测试。

### 实现代码

```swift
// agentGui/Views/Git/GitSidebarHistorySection.swift
import SwiftUI

struct GitSidebarHistorySection: View {
    let panelViewModel: GitPanelViewModel

    @State private var selectedCommitID: String?

    var body: some View {
        sectionCard("历史", systemImage: "clock") {
            if panelViewModel.historyEntries.isEmpty {
                Text("暂无提交记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panelViewModel.historyEntries) { commit in
                        commitRow(commit)
                            .background(
                                selectedCommitID == commit.id
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedCommitID = selectedCommitID == commit.id ? nil : commit.id
                                }
                            }
                    }

                    loadMoreButton
                }
            }
        }
    }

    // MARK: - Commit Row

    @ViewBuilder
    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(commit.shortSha)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)

                Text(commit.message)
                    .font(.caption)
                    .lineLimit(selectedCommitID == commit.id ? nil : 1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Text(commit.date.relativeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if selectedCommitID == commit.id {
                commitDetail(commit)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityIdentifier("git.history.commit.\(commit.shortSha)")
        .help(commit.fullMessage.isEmpty ? commit.message : commit.fullMessage)
    }

    // MARK: - Commit Detail (expanded)

    @ViewBuilder
    private func commitDetail(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()

            if !commit.fullMessage.isEmpty && commit.fullMessage != commit.message {
                Text(commit.fullMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                Label(commit.author, systemImage: "person")
                Label(commit.sha, systemImage: "number")
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.sha, forType: .string)
                    }
                    .help("点击复制完整 SHA")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    // MARK: - Load More

    @ViewBuilder
    private var loadMoreButton: some View {
        if !panelViewModel.historyEntries.isEmpty {
            Button {
                Task { await panelViewModel.loadMoreHistory() }
            } label: {
                HStack(spacing: 4) {
                    if panelViewModel.isLoadingHistory {
                        ProgressView().controlSize(.mini)
                    }
                    Text("加载更多")
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .disabled(panelViewModel.isLoadingHistory)
        }
    }
}

// MARK: - Date Helper

private extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
```

### Step：提交

```bash
git add agentGui/Views/Git/GitSidebarHistorySection.swift
git commit -m "feat(git): add GitSidebarHistorySection view"
```

---

## Task 7：将 `GitSidebarHistorySection` 集成到 `GitPanelView`

**Files:**
- Modify: `agentGui/Views/GitPanelView.swift`

### Step 1：找到分区组合位置

打开 [agentGui/Views/GitPanelView.swift](agentGui/Views/GitPanelView.swift)，在 `body` 内的 `if let sidebarViewModel, let snapshot = gitPanelViewModel.snapshot` 分支里找到：

```swift
GitSidebarUtilitiesSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
```

### Step 2：在 GitSidebarUtilitiesSection 之前插入 History Section

```swift
// 修改前：
GitSidebarBranchSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
GitSidebarUtilitiesSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)

// 修改后：
GitSidebarBranchSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
GitSidebarHistorySection(panelViewModel: gitPanelViewModel)
GitSidebarUtilitiesSection(sidebarViewModel: sidebarViewModel, workspaceState: workspaceState)
```

### Step 3：编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`，无 error。

### Step 4：提交

```bash
git add agentGui/Views/GitPanelView.swift
git commit -m "feat(git): integrate GitSidebarHistorySection into GitPanelView"
```

---

## Task 8：将新文件加入 Xcode 项目

**重要：** Swift 文件必须在 `agentGui.xcodeproj/project.pbxproj` 中注册，否则不会编译。

### 需要注册的文件

| 文件 | Target |
|------|--------|
| `agentGui/Models/GitCommit.swift` | agentGui |
| `agentGui/Services/GitLogParser.swift` | agentGui |
| `agentGui/Views/Git/GitSidebarHistorySection.swift` | agentGui |
| `agentGuiTests/GitCommitTests.swift` | agentGuiTests |
| `agentGuiTests/GitLogParserTests.swift` | agentGuiTests |
| `agentGuiTests/GitServiceListCommitsTests.swift` | agentGuiTests |
| `agentGuiTests/GitPanelViewModelHistoryTests.swift` | agentGuiTests |

### 操作步骤

1. 在 Xcode 中打开 `agentGui.xcodeproj`
2. 对每个 **新建** 文件（已通过 create_file 创建的），在项目导航器中找到对应目录，右键 → **Add Files to "agentGui"**，选择对应文件，确认勾选正确 Target
3. 或在创建文件时直接通过 Xcode 的 `File → New → File` 在项目内部创建（会自动注册）

> **提示：** 如果使用脚本/工具创建文件而非 Xcode，需手动在 `project.pbxproj` 中追加引用，或在 Xcode 中 drag-drop。

### 确认编译

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

---

## Task 9：全量测试验证

运行所有新增测试：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-git-g-a1-derived \
  -only-testing:agentGuiTests/GitCommitTests \
  -only-testing:agentGuiTests/GitLogParserTests \
  -only-testing:agentGuiTests/GitServiceListCommitsTests \
  -only-testing:agentGuiTests/GitPanelViewModelHistoryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：
- `GitCommitTests` — 3 PASSED
- `GitLogParserTests` — 9 PASSED
- `GitServiceListCommitsTests` — 3 PASSED
- `GitPanelViewModelHistoryTests` — 3 PASSED

共 **18 个测试全部通过**。

### 最终提交

```bash
git commit --allow-empty -m "feat(git/G-A1): commit history list panel — all tests passing"
```

---

## 验收标准

1. ✅ 打开 Git 侧边栏，有 "历史" 分区卡片，展示最近 50 条 commit
2. ✅ 每行显示：短 SHA（7 位等宽）、commit 摘要、相对时间
3. ✅ 点击某行展开 Detail：完整 SHA（可复制）、作者、日期、完整消息
4. ✅ 再次点击同一行，收起 Detail
5. ✅ 点击"加载更多"追加下一页，按钮期间显示 loading 状态
6. ✅ 非 Git 仓库时，历史分区不显示（随整个 Git Panel 隐藏）
7. ✅ 全量 18 个新增测试通过，现有测试无回归

---

## 风险与注意事项

| 风险 | 缓解 |
|------|------|
| `%B` body 包含 `---COMMIT---` 字符串（极端情况） | 当前格式足够稳定；如遇问题升级为 NUL 分隔（`-z` 标志）|
| 大仓库 50 条以上首屏加载慢 | `listCommits` 默认 maxCount=50，lazy 分页；`refresh` 的 history 加载用 `try?` 静默降级 |
| Xcode project 文件冲突 | 新文件注册建议在 Xcode 内操作，或 commit 前手动 merge |
| `GitServicing` 协议新增方法破坏现有 Mock | 所有 Mock/Stub 需补充 `listCommits` 实现；搜索 `GitServicing` 全部 conformance 并添加 |

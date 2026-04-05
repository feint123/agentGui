# S-D1: AgentMemoryScope + AgentMemoryPathResolver Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `AgentMemoryScope` 枚举和 `AgentMemoryPathResolver` 结构体，为子代理记忆系统提供类型安全的 scope 定义和目录路径解析，同时加入路径安全校验阻止路径遍历攻击。

**Architecture:** 两个无副作用的纯 Swift 值类型，不依赖任何现有组件（FileManager 调用仅在测试 helper 中出现），路径解析结果为 `URL` 类型。`AgentMemoryScope` 与现有 `MemoryScope`（会话上下文 scope）语义完全不同——不合并、不继承。`AgentMemoryPathResolver` 通过 `workspaceRoot: URL?` 注入工作区路径，`nil` 时使用 `FileManager.default.currentDirectoryPath`，便于单元测试完全控制路径。

**Tech Stack:** Swift 6, Foundation, XCTest — 无 SwiftData，无 UI。

**参考来源:** Claude Code `src/tools/AgentTool/agentMemory.ts`（`AgentMemoryScope`、`getAgentMemoryDir`、`sanitizeAgentTypeForPath`）

**依赖:** 无前置 Feature 依赖，S-D2/D3/D4 依赖本 Feature。

---

## 背景知识

### 与现有 `MemoryScope` 的区别

| 类型 | 文件 | 语义 |
|------|------|------|
| `MemoryScope` | `Models/MemoryScope.swift` | 记忆条目的**产生上下文**（user/workspace/project/session/thread/workflowRun），用于主代理记忆系统的条目元数据 |
| `AgentMemoryScope`（新建） | `Models/AgentMemoryScope.swift` | 子代理记忆的**存储策略**（user/project/local），决定记忆文件持久化到哪个目录层级，对齐 Claude Code `AgentMemoryScope` |

两者不合并，分别服务于不同的领域模型。

### Claude Code 对应逻辑（`agentMemory.ts`）

```typescript
// 三值 scope，控制目录位置
export type AgentMemoryScope = 'user' | 'project' | 'local'

// 代理类型名路径安全化：将 : 替换为 -（namespaced plugin 格式 "plugin:agent"）
function sanitizeAgentTypeForPath(agentType: string): string {
  return agentType.replace(/:/g, '-')
}

// 目录路径计算
export function getAgentMemoryDir(agentType, scope): string {
  const dirName = sanitizeAgentTypeForPath(agentType)
  switch (scope) {
    case 'project': return join(getCwd(), '.claude', 'agent-memory', dirName) + sep
    case 'local':   return join(getCwd(), '.claude', 'agent-memory-local', dirName) + sep
    case 'user':    return join(getMemoryBaseDir(), 'agent-memory', dirName) + sep
  }
}
```

### agentGui 目录约定

| scope | 对应目录 |
|-------|---------|
| `.user` | `~/.agentgui/agent-memory/<agentType>/` |
| `.project` | `<workspace>/.agentgui/agent-memory/<agentType>/` |
| `.local` | `<workspace>/.agentgui/agent-memory-local/<agentType>/` |

agentGui 使用 `.agentgui/` 而非 Claude Code 的 `.claude/`，其余目录层级与 Claude Code 对齐。

---

## Task 1: `AgentMemoryScope` 枚举（TDD）

**Files:**
- Create: `agentGui/Models/AgentMemoryScope.swift`
- Create: `agentGuiTests/AgentMemoryScopeTests.swift`

---

### Step 1: 写失败测试

新建 `agentGuiTests/AgentMemoryScopeTests.swift`：

```swift
import XCTest
@testable import agentGui

final class AgentMemoryScopeTests: XCTestCase {

    // MARK: - RawValue round-trip（对齐 Claude Code 'user'|'project'|'local'）

    func test_rawValue_user() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "user"), .user)
    }

    func test_rawValue_project() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "project"), .project)
    }

    func test_rawValue_local() {
        XCTAssertEqual(AgentMemoryScope(rawValue: "local"), .local)
    }

    func test_rawValue_unknown_returnsNil() {
        XCTAssertNil(AgentMemoryScope(rawValue: "workspace"))
        XCTAssertNil(AgentMemoryScope(rawValue: "global"))
        XCTAssertNil(AgentMemoryScope(rawValue: ""))
    }

    func test_rawValue_caseSensitive() {
        // rawValue 区分大小写，与 Claude Code 对齐
        XCTAssertNil(AgentMemoryScope(rawValue: "User"))
        XCTAssertNil(AgentMemoryScope(rawValue: "PROJECT"))
    }

    // MARK: - Codable

    func test_codable_roundTrip() throws {
        let scopes: [AgentMemoryScope] = [.user, .project, .local]
        for scope in scopes {
            let encoded = try JSONEncoder().encode(scope)
            let decoded = try JSONDecoder().decode(AgentMemoryScope.self, from: encoded)
            XCTAssertEqual(decoded, scope, "Codable round-trip failed for \(scope)")
        }
    }

    func test_codable_encodeAsString() throws {
        let data = try JSONEncoder().encode(AgentMemoryScope.user)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertEqual(jsonString, "\"user\"")
    }

    // MARK: - Sendable（编译时保证，无运行时断言）
    func test_isSendable() {
        // 编译通过即为通过：AgentMemoryScope: Sendable 合约验证
        let scope: AgentMemoryScope = .project
        let _: @Sendable () -> AgentMemoryScope = { scope }
        _ = scope
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`error: cannot find type 'AgentMemoryScope' in scope`

### Step 3: 实现 `AgentMemoryScope`

新建 `agentGui/Models/AgentMemoryScope.swift`：

```swift
import Foundation

/// 子代理记忆的存储策略 scope。
///
/// 控制子代理 `MEMORY.md` 及话题文件持久化到哪个目录层级：
/// - `.user`：跨工作区，写入 `~/.agentgui/agent-memory/<agentType>/`
/// - `.project`：项目级共享（可纳入 git），写入 `<workspace>/.agentgui/agent-memory/<agentType>/`
/// - `.local`：本机专用（不纳入 git），写入 `<workspace>/.agentgui/agent-memory-local/<agentType>/`
///
/// 与现有 `MemoryScope` 不同：`MemoryScope` 描述记忆条目在哪个**会话上下文**中产生，
/// 本类型描述记忆文件**持久化到哪个目录**。两者语义不同，不合并。
///
/// 对齐 Claude Code `AgentMemoryScope` (`agentMemory.ts`)。
enum AgentMemoryScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// 跨工作区持久化：~/.agentgui/agent-memory/<agentType>/
    case user
    /// 项目级共享（可纳入 git）：<workspace>/.agentgui/agent-memory/<agentType>/
    case project
    /// 本机专用（不纳入 git）：<workspace>/.agentgui/agent-memory-local/<agentType>/
    case local
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 5: 提交

```bash
git add agentGui/Models/AgentMemoryScope.swift \
        agentGuiTests/AgentMemoryScopeTests.swift
git commit -m "feat(S-D1): add AgentMemoryScope enum with Codable/Sendable conformance"
```

---

## Task 2: `AgentMemoryPathResolver` — 路径解析（TDD）

**Files:**
- Create: `agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift`
- Create: `agentGuiTests/AgentMemoryPathResolverTests.swift`

---

### Step 1: 写失败测试

新建 `agentGuiTests/AgentMemoryPathResolverTests.swift`：

```swift
import XCTest
@testable import agentGui

final class AgentMemoryPathResolverTests: XCTestCase {

    // MARK: - 测试用根路径（避免污染真实目录）

    private var fakeHome: URL!
    private var fakeWorkspace: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
        fakeHome = tmp.appendingPathComponent("FakeHome_\(UUID().uuidString)", isDirectory: true)
        fakeWorkspace = tmp.appendingPathComponent("FakeWorkspace_\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - memoryDir — user scope

    func test_memoryDir_userScope_usesAgentguiDir() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "explore", scope: .user)
        // ~fakeHome/.agentgui/agent-memory/explore/
        XCTAssertEqual(
            result.path,
            fakeHome.appendingPathComponent(".agentgui/agent-memory/explore").path
        )
    }

    func test_memoryDir_userScope_trailingDirectoryFlag() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "explore", scope: .user)
        XCTAssertTrue(result.hasDirectoryPath, "memoryDir URL 应有 isDirectory=true 语义")
    }

    // MARK: - memoryDir — project scope

    func test_memoryDir_projectScope_usesWorkspaceRoot() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "worker", scope: .project)
        // <workspace>/.agentgui/agent-memory/worker/
        XCTAssertEqual(
            result.path,
            fakeWorkspace.appendingPathComponent(".agentgui/agent-memory/worker").path
        )
    }

    // MARK: - memoryDir — local scope

    func test_memoryDir_localScope_usesAgentMemoryLocal() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryDir(agentType: "verifier", scope: .local)
        // <workspace>/.agentgui/agent-memory-local/verifier/
        XCTAssertEqual(
            result.path,
            fakeWorkspace.appendingPathComponent(".agentgui/agent-memory-local/verifier").path
        )
    }

    // MARK: - memoryIndexURL

    func test_memoryIndexURL_appendsMEMORYmd() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let result = resolver.memoryIndexURL(agentType: "explore", scope: .user)
        XCTAssertEqual(result.lastPathComponent, "MEMORY.md")
        XCTAssertTrue(result.path.hasSuffix("/explore/MEMORY.md"))
    }

    // MARK: - sanitize — 正常情况

    func test_sanitize_noSpecialChars_returnsUnchanged() {
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("explore"),  "explore")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("worker"),   "worker")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("my-agent"), "my-agent")
    }

    func test_sanitize_colonReplacedWithDash() {
        // 对齐 Claude Code sanitizeAgentTypeForPath: "my-plugin:my-agent" → "my-plugin-my-agent"
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("my-plugin:my-agent"), "my-plugin-my-agent")
        XCTAssertEqual(AgentMemoryPathResolver.sanitize("ns:explore"), "ns-explore")
    }

    // MARK: - sanitize — 路径遍历防护（安全约束）

    func test_sanitize_slashIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("foo/bar"),
                     "含 / 的代理类型名应拒绝（路径遍历防护）")
    }

    func test_sanitize_dotDotIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("../evil"))
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".."))
        XCTAssertNil(AgentMemoryPathResolver.sanitize("a/../b"))
    }

    func test_sanitize_dotPrefixIsRejected() {
        // 防止隐藏文件名攻击，如 ".env"
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".hidden"))
        XCTAssertNil(AgentMemoryPathResolver.sanitize(".agent"))
    }

    func test_sanitize_emptyStringIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize(""))
    }

    func test_sanitize_whitespaceOnlyIsRejected() {
        XCTAssertNil(AgentMemoryPathResolver.sanitize("   "))
    }

    // MARK: - memoryDir 使用 sanitized 名称

    func test_memoryDir_sanitizesAgentType() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        // "ns:explore" 中的 : 被替换为 -
        let result = resolver.memoryDir(agentType: "ns:explore", scope: .user)
        XCTAssertTrue(result.path.hasSuffix("/ns-explore"), "代理类型名应经过 sanitize 处理")
    }

    func test_memoryDir_invalidAgentType_returnsNil() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        // "../evil" 含路径遍历，memoryDir 应返回 nil
        let result = resolver.memoryDirOrNil(agentType: "../evil", scope: .user)
        XCTAssertNil(result, "非法代理类型名应返回 nil，不允许路径遍历")
    }

    // MARK: - workspaceRoot nil 时 fallback 到当前目录

    func test_memoryDir_nilWorkspaceRoot_fallsBackToCwd() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: nil
        )
        // project scope 时 workspaceRoot nil → cwd
        let result = resolver.memoryDir(agentType: "explore", scope: .project)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let expected = cwd.appendingPathComponent(".agentgui/agent-memory/explore")
        XCTAssertEqual(result.path, expected.path)
    }

    // MARK: - Sendable

    func test_isSendable() {
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: fakeHome.appendingPathComponent(".agentgui"),
            workspaceRoot: fakeWorkspace
        )
        let _: @Sendable () -> URL = { resolver.memoryDir(agentType: "explore", scope: .user) }
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`error: cannot find type 'AgentMemoryPathResolver' in scope`

### Step 3: 实现 `AgentMemoryPathResolver`

新建 `agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift`：

```swift
import Foundation

/// 给定代理类型名和 `AgentMemoryScope`，解析代理专用记忆目录及 MEMORY.md 索引文件的 URL。
///
/// **路径约定（对齐 Claude Code `agentMemory.ts`）：**
/// | scope | 目录 |
/// |-------|------|
/// | `.user` | `<agentguiBaseDir>/agent-memory/<sanitizedType>/` |
/// | `.project` | `<workspaceRoot>/.agentgui/agent-memory/<sanitizedType>/` |
/// | `.local` | `<workspaceRoot>/.agentgui/agent-memory-local/<sanitizedType>/` |
///
/// **安全约束：** 代理类型名经过 `sanitize(_:)` 处理，含 `/`、`..` 或以 `.` 开头的名称
/// 被视为非法路径，返回 `nil`（防止路径遍历攻击）。
struct AgentMemoryPathResolver: Sendable {

    /// 全局 agentgui 配置根目录，通常为 `~/.agentgui/`。
    let agentguiBaseDir: URL

    /// 工作区根目录。`nil` 时 project/local scope 使用 `FileManager.default.currentDirectoryPath`。
    let workspaceRoot: URL?

    // MARK: - Public API

    /// 返回代理记忆目录 URL（isDirectory = true）。
    /// 若 `agentType` 违反安全约束，调用方应使用 `memoryDirOrNil(agentType:scope:)` 代替。
    /// - Note: 不保证目录已存在，创建责任由调用方承担。
    func memoryDir(agentType: String, scope: AgentMemoryScope) -> URL {
        let sanitized = Self.sanitizeOrFallback(agentType)
        return buildDir(sanitizedType: sanitized, scope: scope)
    }

    /// 返回代理记忆目录 URL，若 `agentType` 违反安全约束则返回 `nil`。
    func memoryDirOrNil(agentType: String, scope: AgentMemoryScope) -> URL? {
        guard let sanitized = Self.sanitize(agentType) else { return nil }
        return buildDir(sanitizedType: sanitized, scope: scope)
    }

    /// 返回 MEMORY.md 索引文件 URL。
    func memoryIndexURL(agentType: String, scope: AgentMemoryScope) -> URL {
        memoryDir(agentType: agentType, scope: scope)
            .appendingPathComponent("MEMORY.md")
    }

    // MARK: - Sanitization

    /// 对代理类型名进行路径安全处理：
    /// 1. 将 `:` 替换为 `-`（namespaced plugin 格式，对齐 Claude Code `sanitizeAgentTypeForPath`）
    /// 2. 拒绝含 `/`、`..` 或以 `.` 开头、或为空/纯空白的名称（路径遍历防护）
    ///
    /// - Returns: 安全化后的目录名，或 `nil`（非法输入）。
    static func sanitize(_ agentType: String) -> String? {
        let trimmed = agentType.trimmingCharacters(in: .whitespaces)

        // 空字符串或纯空白拒绝
        guard !trimmed.isEmpty else { return nil }

        // 以 . 开头拒绝（防止隐藏文件名攻击，如 ".env"）
        guard !trimmed.hasPrefix(".") else { return nil }

        // 将 : 替换为 -（先于 / 检查，避免误报）
        let colonReplaced = trimmed.replacingOccurrences(of: ":", with: "-")

        // 含 / 拒绝（路径分隔符）
        guard !colonReplaced.contains("/") else { return nil }

        // 含 .. 模式拒绝（路径遍历）
        let components = colonReplaced.components(separatedBy: "/")
        guard !components.contains("..") else { return nil }

        return colonReplaced
    }

    // MARK: - Private

    private func buildDir(sanitizedType: String, scope: AgentMemoryScope) -> URL {
        switch scope {
        case .user:
            return agentguiBaseDir
                .appendingPathComponent("agent-memory", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        case .project:
            return effectiveWorkspaceRoot
                .appendingPathComponent(".agentgui", isDirectory: true)
                .appendingPathComponent("agent-memory", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        case .local:
            return effectiveWorkspaceRoot
                .appendingPathComponent(".agentgui", isDirectory: true)
                .appendingPathComponent("agent-memory-local", isDirectory: true)
                .appendingPathComponent(sanitizedType, isDirectory: true)
        }
    }

    private var effectiveWorkspaceRoot: URL {
        workspaceRoot ?? URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    }

    /// 内部辅助：sanitize 失败时以原始名（去除 : 后）fallback，
    /// 仅用于 `memoryDir`（非安全路径的公开入口，调用方理应传入合法名称）。
    private static func sanitizeOrFallback(_ agentType: String) -> String {
        sanitize(agentType) ?? agentType.replacingOccurrences(of: ":", with: "-")
    }
}
```

### Step 4: 运行 Task 2 测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 5: 运行全部 S-D1 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部通过，无 error。

### Step 6: 提交

```bash
git add agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift \
        agentGuiTests/AgentMemoryPathResolverTests.swift
git commit -m "feat(S-D1): add AgentMemoryPathResolver with path-traversal safety checks"
```

---

## Task 3: 将新文件添加到 Xcode 项目

> Xcode 项目文件 (`project.pbxproj`) 需要手动或通过工具注册新 Swift 文件，否则编译不包含它们。

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

### Step 1: 检查新文件是否已被 Xcode 识别

在 Xcode 中打开项目，查看左侧 Navigator，确认以下两个文件已出现在对应目录组下：
- `agentGui/Models/AgentMemoryScope.swift`
- `agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift`

若不在 Navigator 中，右键各自目录 → "Add Files to agentGui"，勾选 `agentGui` target。

### Step 2: 确认测试文件已加入测试 target

确认 `agentGuiTests/AgentMemoryScopeTests.swift` 和 `agentGuiTests/AgentMemoryPathResolverTests.swift` 属于 `agentGuiTests` target（文件 Inspector → Target Membership）。

### Step 3: 构建验证（无测试）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sd1-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD"
```

预期：`BUILD SUCCEEDED`，无 error。

### Step 4: 提交（若 pbxproj 有变动）

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(S-D1): register AgentMemoryScope and AgentMemoryPathResolver in Xcode project"
```

---

## Task 4: 冒烟测试 — `ConfigDirectoryManager` 集成验证

**目标：** 确认 `AgentMemoryPathResolver` 在 user scope 下生成的路径与 `ConfigDirectoryManager.shared.agentGuiDir` 基目录一致，确保两者不出现路径漂移。

**Files:**
- Create: `agentGuiTests/AgentMemoryPathResolverIntegrationTests.swift`

### Step 1: 写集成验证测试

```swift
import XCTest
@testable import agentGui

/// 验证 AgentMemoryPathResolver 在 user scope 下的基目录与
/// ConfigDirectoryManager 的 agentGuiDir 对齐。
final class AgentMemoryPathResolverIntegrationTests: XCTestCase {

    func test_userScope_baseDir_matchesConfigDirectoryManager() {
        let configBase = ConfigDirectoryManager.shared.agentGuiDir

        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: configBase,
            workspaceRoot: nil
        )
        let memDir = resolver.memoryDir(agentType: "explore", scope: .user)

        // 期望路径：~/.agentgui/agent-memory/explore
        let expected = configBase
            .appendingPathComponent("agent-memory")
            .appendingPathComponent("explore")

        XCTAssertEqual(
            memDir.standardizedFileURL.path,
            expected.standardizedFileURL.path,
            "user scope 记忆目录应位于 ConfigDirectoryManager.agentGuiDir/agent-memory/<agentType>"
        )
    }

    func test_userScope_memoryIndexURL_isUnderAgentguiDir() {
        let configBase = ConfigDirectoryManager.shared.agentGuiDir
        let resolver = AgentMemoryPathResolver(
            agentguiBaseDir: configBase,
            workspaceRoot: nil
        )
        let indexURL = resolver.memoryIndexURL(agentType: "explore", scope: .user)

        XCTAssertTrue(
            indexURL.path.hasPrefix(configBase.path),
            "MEMORY.md 路径应在 ~/.agentgui/ 树下"
        )
        XCTAssertEqual(indexURL.lastPathComponent, "MEMORY.md")
    }

    func test_userScope_doesNotConflictWithGlobalMemoryDir() {
        // 确认子代理记忆目录与主代理记忆目录（~/.agentgui/memory/）不重叠
        let configBase = ConfigDirectoryManager.shared.agentGuiDir
        let globalMemoryDir = ConfigDirectoryManager.shared.memoryDir  // ~/.agentgui/memory/

        let resolver = AgentMemoryPathResolver(agentguiBaseDir: configBase, workspaceRoot: nil)
        let agentMemDir = resolver.memoryDir(agentType: "explore", scope: .user)

        XCTAssertNotEqual(
            agentMemDir.standardizedFileURL.path,
            globalMemoryDir.standardizedFileURL.path,
            "子代理 user scope 目录（agent-memory/）不应与主代理全局记忆目录（memory/）相同"
        )
        XCTAssertFalse(
            agentMemDir.path.hasPrefix(globalMemoryDir.path),
            "子代理记忆目录不应是主代理记忆目录的子目录"
        )
    }
}
```

### Step 2: 运行集成测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-derived \
  -only-testing:agentGuiTests/AgentMemoryPathResolverIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部 PASS。

### Step 3: 提交

```bash
git add agentGuiTests/AgentMemoryPathResolverIntegrationTests.swift
git commit -m "test(S-D1): add integration tests verifying AgentMemoryPathResolver aligns with ConfigDirectoryManager"
```

---

## Task 5: 完整测试套件运行确认（回归）

### Step 1: 运行所有 S-D1 相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-final \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部 PASS，无 error。

### Step 2: 运行现有记忆相关测试，确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd1-regression \
  -only-testing:agentGuiTests/MemoryIndexFileSystemTests \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  -only-testing:agentGuiTests/ConfigDirectoryManagerMemoryDirTests \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部 PASS，无回归。

---

## 新增文件汇总

```
agentGui/
  Models/
    AgentMemoryScope.swift                  ← Task 1（纯枚举，无外部依赖）
  Services/
    SubagentGovernance/
      AgentMemoryPathResolver.swift         ← Task 2（路径解析 + sanitize 安全校验）
agentGuiTests/
  AgentMemoryScopeTests.swift              ← Task 1 测试（rawValue / Codable / Sendable）
  AgentMemoryPathResolverTests.swift        ← Task 2 测试（路径计算 / sanitize / nil workspaceRoot）
  AgentMemoryPathResolverIntegrationTests.swift ← Task 4（与 ConfigDirectoryManager 对齐验证）
```

## 与后续 Feature 的接口约定

S-D2 将直接引用 `AgentMemoryScope` 作为 `AgentDefinitionDocument.memoryScope` 和 `WorkflowRoleDefinition.memoryScope` 的类型；S-D3 和 S-D4 将通过 `AgentMemoryPathResolver` 获取子代理专属记忆目录，传入 `AgentLoopMemoryBootstrapComposer(memoryDir:)` 用于记忆引导注入：

```swift
// S-D3 将如此使用（参考，不在本 plan 实现）：
let resolver = AgentMemoryPathResolver(
    agentguiBaseDir: ConfigDirectoryManager.shared.agentGuiDir,
    workspaceRoot: runtime.workspaceRoot
)
let dir = resolver.memoryDir(agentType: definition.name, scope: scope)
let composer = AgentLoopMemoryBootstrapComposer(memoryDir: dir)
```

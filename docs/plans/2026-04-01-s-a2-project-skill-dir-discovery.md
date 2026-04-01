# S-A2: 项目级技能目录发现 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 扩展 `SkillService.loadSkills()` 使其除扫描 `~/.claude/skills/`（user source）之外，还从当前 workspace 向上遍历到 HOME/git-root，逐层收集 `.claude/skills/` 目录（project source），合并后去重，正确标注 `loadedFrom`。

**Architecture:** 在 `SkillService` 中新增 `loadSkills(workspaceURL:)` 方法和 `projectSkillDirs(startingAt:) -> [URL]` 工具函数；`scanSkills(in:source:)` 提取 source 参数；`loadSkills()` 保持向后兼容（无 workspace 时行为不变）。不引入新文件，不改外部调用接口的默认行为。

**Tech Stack:** Swift 6, Foundation, @Observable SkillService, XCTest

**Source References:**
- Claude Code: `src/skills/loadSkillsDir.ts` → `getSkillDirCommands()`
- Claude Code: `src/utils/markdownConfigLoader.ts` → `getProjectDirsUpToHome()` + `resolveStopBoundary()`
- agentGui: `agentGui/Services/SkillService.swift`
- agentGui: `agentGuiTests/SkillServiceFrontmatterTests.swift`（测试模式参考）

---

## 设计细节

### 优先级规则（高→低）

```
managed  (~/.claude/managed/.claude/skills/)  — 预留，当前保持空
user     (~/.claude/skills/)
project  (workspace → parent → ... → git-root 各层的 .claude/skills/)
         深层（更贴近 workspace）优先于浅层
```

合并顺序：`managed + user + project(deep-first)`。同名同文件（realpath 相同）只保留第一个出现的。

### 向上遍历停止条件

1. 到达 `$HOME`（不含 HOME 本身，因为 HOME 下的 `~/.claude/skills/` 已作为 user source 加载）
2. 到达 git root（找到 `.git` 目录或文件的祖先目录），防止 workspace 外的 `.claude/skills/` 泄漏

### 去重逻辑

Claude Code 使用 `realpath()` 将每个 SKILL.md 解析为 canonical 路径，跳过已见过的路径。Swift 对应使用 `URL.resolvingSymlinksInPath().path`。

### SkillService 修改边界

| 方法 | 修改/新增 | 说明 |
|------|----------|------|
| `init(skillsDirectory:workspaceURL:)` | 新增 `workspaceURL` 参数(默认 nil) | 初始化时存储 workspace |
| `loadSkills()` | 修改 | 调用新的多源加载路径 |
| `loadSkills(workspaceURL:)` | 新增 | 带 workspace 的完整加载 |
| `scanSkills(in:source:)` | 修改签名 | 新增 `source: SkillSource` 参数 |
| `projectSkillDirs(startingAt:)` | 新增（nonisolated static） | 向上遍历，返回存在的 .claude/skills/ 路径列表 |
| `gitRoot(for:)` | 新增（nonisolated static） | 查找距 startURL 最近的 .git 祖先目录 |
| `mergeAndDeduplicate(_:)` | 新增（nonisolated static） | realpath 去重，返回合并后 [Skill] |

---

## Task 1: 新增 `gitRoot(for:)` 工具函数

**Files:**
- Modify: `agentGui/Services/SkillService.swift`
- Test: `agentGuiTests/SkillProjectDiscoveryTests.swift` (新建)

### Step 1: 新建测试文件，写第一个失败测试

```swift
// agentGuiTests/SkillProjectDiscoveryTests.swift
import XCTest
@testable import agentGui

final class SkillProjectDiscoveryTests: XCTestCase {

    // MARK: - gitRoot

    func test_gitRoot_findsGitDir() throws {
        // 创建模拟目录树：tmp/repo/.git  tmp/repo/subdir/
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "gitRootTest-\(UUID().uuidString)")
        let repoDir = tmp.appending(path: "repo")
        let subDir = repoDir.appending(path: "subdir")
        let gitDir = repoDir.appending(path: ".git")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = SkillService.gitRoot(for: subDir)
        XCTAssertEqual(result?.path, repoDir.path)
    }

    func test_gitRoot_returnsNil_whenNoGit() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "gitRootNoGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 孤立目录，无 .git
        let result = SkillService.gitRoot(for: tmp)
        XCTAssertNil(result)
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
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_gitRoot_findsGitDir \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_gitRoot_returnsNil_whenNoGit \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: FAIL — `SkillService` 中没有 `gitRoot(for:)` 方法

### Step 3: 在 `SkillService.swift` 实现 `gitRoot(for:)`

在 `SkillService` 的 `// MARK: - Private` 工具方法区域新增：

```swift
/// 从 `startURL` 向上查找最近的含 `.git` 目录/文件的祖先目录。
/// 到达文件系统根（parent == self）时返回 nil。
/// 不遍历 HOME 本身（调用者应保证 startURL 在 HOME 内部）。
nonisolated internal static func gitRoot(for startURL: URL) -> URL? {
    let fm = FileManager.default
    var current = startURL.standardized

    while true {
        let gitPath = current.appending(path: ".git")
        if fm.fileExists(atPath: gitPath.path) {
            return current
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path {
            // 到达文件系统根
            return nil
        }
        current = parent
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_gitRoot_findsGitDir \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_gitRoot_returnsNil_whenNoGit \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 2 × PASS

### Step 5: Commit

```
git add agentGui/Services/SkillService.swift agentGuiTests/SkillProjectDiscoveryTests.swift
git commit -m "feat(S-A2): add SkillService.gitRoot(for:) walk utility"
```

---

## Task 2: 新增 `projectSkillDirs(startingAt:)` 遍历函数

**Files:**
- Modify: `agentGui/Services/SkillService.swift`
- Test: `agentGuiTests/SkillProjectDiscoveryTests.swift`

### Step 1: 写失败测试

将以下测试追加到 `SkillProjectDiscoveryTests.swift`：

```swift
// MARK: - projectSkillDirs

func test_projectSkillDirs_findsNestedClaudeSkills() throws {
    // 目录树：
    //   tmp/home/                    ← simulated HOME（不含）
    //   tmp/home/repo/.git/          ← git root
    //   tmp/home/repo/.claude/skills/           ← project skills（应收集）
    //   tmp/home/repo/subA/.claude/skills/      ← project skills（应收集）
    //   tmp/home/repo/subA/subB/               ← start here
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "projDirsTest-\(UUID().uuidString)")
    let homeDir  = tmp.appending(path: "home")
    let repoDir  = homeDir.appending(path: "repo")
    let subA     = repoDir.appending(path: "subA")
    let subB     = subA.appending(path: "subB")
    let gitDir   = repoDir.appending(path: ".git")
    let skills1  = repoDir.appending(path: ".claude/skills")
    let skills2  = subA.appending(path: ".claude/skills")
    for dir in [subB, gitDir, skills1, skills2] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = SkillService.projectSkillDirs(startingAt: subB, home: homeDir)
    // subB 无 skills，subA 有，repo 有，repo 是 git root 应包含，repo 的父是 home 停止
    // 返回顺序：deep-first（subA 先于 repo）
    XCTAssertEqual(result.map(\.path), [skills2.path, skills1.path])
}

func test_projectSkillDirs_stopsAtHome() throws {
    // 目录树：
    //   tmp/home/.claude/skills/   ← HOME 层不应收集（由 user source 负责）
    //   tmp/home/project/          ← start here（无 git）
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "projDirsHome-\(UUID().uuidString)")
    let homeDir   = tmp.appending(path: "home")
    let projectDir = homeDir.appending(path: "project")
    let homeSkills = homeDir.appending(path: ".claude/skills")
    for dir in [projectDir, homeSkills] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = SkillService.projectSkillDirs(startingAt: projectDir, home: homeDir)
    // project 无 .claude/skills，HOME 本身不遍历 → 结果为空
    XCTAssertTrue(result.isEmpty)
}

func test_projectSkillDirs_stopsAtGitRoot() throws {
    // 目录树：
    //   tmp/home/outer/.claude/skills/   ← git root 外层，不应出现
    //   tmp/home/outer/repo/.git/
    //   tmp/home/outer/repo/.claude/skills/   ← 应出现（是 git root）
    //   tmp/home/outer/repo/nested/           ← start here
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "projDirsGit-\(UUID().uuidString)")
    let homeDir    = tmp.appending(path: "home")
    let outerDir   = homeDir.appending(path: "outer")
    let repoDir    = outerDir.appending(path: "repo")
    let nestedDir  = repoDir.appending(path: "nested")
    let outerSkills = outerDir.appending(path: ".claude/skills")
    let repoSkills  = repoDir.appending(path: ".claude/skills")
    let gitDir      = repoDir.appending(path: ".git")
    for dir in [nestedDir, outerSkills, repoSkills, gitDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = SkillService.projectSkillDirs(startingAt: nestedDir, home: homeDir)
    // nested 无 skills，repo 有（且是 git root，包含后结束）
    XCTAssertEqual(result.map(\.path), [repoSkills.path])
}

func test_projectSkillDirs_returnsEmpty_whenNoDirsExist() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "projDirsEmpty-\(UUID().uuidString)")
    let homeDir    = tmp.appending(path: "home")
    let projectDir = homeDir.appending(path: "project")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = SkillService.projectSkillDirs(startingAt: projectDir, home: homeDir)
    XCTAssertTrue(result.isEmpty)
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:" | head -20
```

Expected: 4 × FAIL（`projectSkillDirs` 不存在）

### Step 3: 实现 `projectSkillDirs(startingAt:home:)`

在 `SkillService.swift` 中 `gitRoot(for:)` 下方新增：

```swift
/// 从 `startURL` 向上遍历，收集沿途存在的 `.claude/skills/` 目录路径列表。
///
/// 停止条件（与 Claude Code `getProjectDirsUpToHome` 等价）：
/// - 到达 `home`（`home` 本身不检查，其 `.claude/skills/` 由 user source 加载）
/// - 到达 git root 后处理该层并停止（防止 repo 外层路径泄漏）
/// - 到达文件系统根
///
/// 返回顺序：deep-first（最接近 startURL 的目录在最前）。
///
/// - Parameter startURL: 遍历起点（通常是 workspace root）
/// - Parameter home: HOME 目录 URL，用于确定停止边界（测试时可注入）
nonisolated internal static func projectSkillDirs(
    startingAt startURL: URL,
    home: URL? = nil
) -> [URL] {
    let fm = FileManager.default
    let homeURL = (home ?? homeDirectory()).standardized
    let stopAtGit = gitRoot(for: startURL)
    var current = startURL.standardized
    var dirs: [URL] = []

    while true {
        // HOME 本身不遍历（其 user skills 由独立路径负责）
        if current.path == homeURL.path { break }

        let claudeSkills = current.appending(path: ".claude/skills")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: claudeSkills.path, isDirectory: &isDir), isDir.boolValue {
            dirs.append(claudeSkills)
        }

        // 处理完 git root 层后停止——防止 repo 外的父目录渗透
        if let gitRoot = stopAtGit, current.path == gitRoot.path { break }

        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }  // 文件系统根
        current = parent
    }

    return dirs
}

/// 返回当前进程运行的真实 HOME 目录（优先使用 getpwuid 以避免沙箱偏差）。
nonisolated private static func homeDirectory() -> URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
}
```

> **注意：** `homeDirectory()` 与现有的 `defaultSkillsDirectory()` 中的 HOME 解析逻辑相同，可以提取公用，但为避免修改未经测试的代码，本 Task 保留独立实现。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 6 × PASS（含 Task 1 的 2 个）

### Step 5: Commit

```
git add agentGui/Services/SkillService.swift agentGuiTests/SkillProjectDiscoveryTests.swift
git commit -m "feat(S-A2): add projectSkillDirs(startingAt:) walk with git-root boundary"
```

---

## Task 3: 修改 `scanSkills(in:)` → `scanSkills(in:source:)`

**Files:**
- Modify: `agentGui/Services/SkillService.swift`

### Step 1: 修改 `scanSkills` 签名，加入 `source` 参数

将现有：

```swift
nonisolated private static func scanSkills(in skillsDirectory: URL) -> [Skill] {
```

改为：

```swift
nonisolated internal static func scanSkills(in skillsDirectory: URL, source: SkillSource = .user) -> [Skill] {
```

在函数体内，把 `loadedFrom: .user` 改为 `loadedFrom: source`（现在只有一处）：

```swift
return Skill(
    // ...
    loadedFrom: source   // ← 从 .user 改为 source 参数
)
```

### Step 2: 确认现有 frontmatter 测试仍然通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部通过（不应有回归）

### Step 3: Commit

```
git add agentGui/Services/SkillService.swift
git commit -m "feat(S-A2): add source param to scanSkills(in:source:)"
```

---

## Task 4: 新增 `mergeAndDeduplicate(_:)` 去重函数

**Files:**
- Modify: `agentGui/Services/SkillService.swift`
- Test: `agentGuiTests/SkillProjectDiscoveryTests.swift`

### Step 1: 写去重测试

追加到 `SkillProjectDiscoveryTests.swift`：

```swift
// MARK: - mergeAndDeduplicate

func test_mergeAndDeduplicate_removesSymlinkDuplicates() throws {
    // 创建真实 skill 目录和 symlink 指向同一目录
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "dedupTest-\(UUID().uuidString)")
    let realSkillDir = tmp.appending(path: "real-skill")
    let symlinkDir   = tmp.appending(path: "link-skill")
    let skillMD      = realSkillDir.appending(path: "SKILL.md")
    try FileManager.default.createDirectory(at: realSkillDir, withIntermediateDirectories: true)
    try "---\nname: Test Skill\n---\nContent".write(to: skillMD, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realSkillDir)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let skill1 = Skill(
        directoryName: "real-skill",
        name: "Test Skill",
        description: "desc",
        path: realSkillDir,
        contentURL: skillMD,
        loadedFrom: .user
    )
    let skill2 = Skill(
        directoryName: "link-skill",
        name: "Test Skill",
        description: "desc",
        path: symlinkDir,
        contentURL: symlinkDir.appending(path: "SKILL.md"),
        loadedFrom: .project
    )

    let merged = SkillService.mergeAndDeduplicate([skill1, skill2])
    // 仅保留 skill1（先出现）
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.directoryName, "real-skill")
}

func test_mergeAndDeduplicate_keepsBothWhenDifferentFiles() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "dedupDistinct-\(UUID().uuidString)")
    let dir1 = tmp.appending(path: "skill-a")
    let dir2 = tmp.appending(path: "skill-b")
    for dir in [dir1, dir2] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(dir.lastPathComponent)\n---\nContent"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    }
    defer { try? FileManager.default.removeItem(at: tmp) }

    let skill1 = Skill(directoryName: "skill-a", name: "Skill A", description: "", path: dir1, contentURL: dir1.appending(path: "SKILL.md"))
    let skill2 = Skill(directoryName: "skill-b", name: "Skill B", description: "", path: dir2, contentURL: dir2.appending(path: "SKILL.md"))
    let merged = SkillService.mergeAndDeduplicate([skill1, skill2])
    XCTAssertEqual(merged.count, 2)
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_mergeAndDeduplicate_removesSymlinkDuplicates \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_mergeAndDeduplicate_keepsBothWhenDifferentFiles \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: FAIL（`mergeAndDeduplicate` 不存在）

### Step 3: 实现 `mergeAndDeduplicate(_:)`

在 `SkillService.swift` 中新增：

```swift
/// 合并多个来源的 Skill 列表，通过 realpath 过滤 symlink 重复。
///
/// 策略：first-wins by canonical path（入参顺序决定优先级，managed/user/project-deep-first）。
/// 若 SKILL.md 的真实路径已出现，跳过。若 realpath 解析失败（文件不存在），保留（避免因
/// race condition 引发漏加载）。
///
/// - Parameter allSkills: 按优先级排列的技能列表（高优先级在前）
/// - Returns: 去重后的技能列表，保留原始顺序
nonisolated internal static func mergeAndDeduplicate(_ allSkills: [Skill]) -> [Skill] {
    var seenRealPaths: Set<String> = []
    return allSkills.filter { skill in
        let resolved = skill.contentURL.resolvingSymlinksInPath().path
        if seenRealPaths.contains(resolved) {
            return false
        }
        seenRealPaths.insert(resolved)
        return true
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部通过（含 Task 1-2 的测试）

### Step 5: Commit

```
git add agentGui/Services/SkillService.swift agentGuiTests/SkillProjectDiscoveryTests.swift
git commit -m "feat(S-A2): add mergeAndDeduplicate with realpath dedup"
```

---

## Task 5: 修改 `SkillService.loadSkills()` 接入多源加载

**Files:**
- Modify: `agentGui/Services/SkillService.swift`
- Test: `agentGuiTests/SkillProjectDiscoveryTests.swift`

### Step 1: 写集成测试

追加到 `SkillProjectDiscoveryTests.swift`：

```swift
// MARK: - SkillService multi-source integration

func test_loadSkills_discoversProjectSkills() async throws {
    // 目录布局：
    //   tmp/home/.claude/skills/user-skill/SKILL.md    ← user source
    //   tmp/home/workspace/.git/                        ← git root
    //   tmp/home/workspace/.claude/skills/proj-skill/SKILL.md  ← project source
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "multiSrcTest-\(UUID().uuidString)")
    let homeDir    = tmp.appending(path: "home")
    let userSkills = homeDir.appending(path: ".claude/skills/user-skill")
    let workspace  = homeDir.appending(path: "workspace")
    let gitDir     = workspace.appending(path: ".git")
    let projSkills = workspace.appending(path: ".claude/skills/proj-skill")
    for dir in [userSkills, gitDir, projSkills] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try "---\nname: User Skill\ndescription: from user\n---\nUser"
        .write(to: userSkills.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    try "---\nname: Project Skill\ndescription: from project\n---\nProject"
        .write(to: projSkills.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let service = await SkillService(
        skillsDirectory: homeDir.appending(path: ".claude/skills"),
        workspaceURL: workspace
    )
    await service.loadSkills()

    let skills = await service.availableSkills
    let names = skills.map(\.name)
    XCTAssertTrue(names.contains("User Skill"),    "User skill should be loaded")
    XCTAssertTrue(names.contains("Project Skill"), "Project skill should be loaded")

    // 验证 loadedFrom
    let userSkill = skills.first { $0.name == "User Skill" }
    let projSkill = skills.first { $0.name == "Project Skill" }
    XCTAssertEqual(userSkill?.loadedFrom, .user)
    XCTAssertEqual(projSkill?.loadedFrom, .project)
}

func test_loadSkills_projectSkillTakesPrecedenceOverUser_whenSameFile() async throws {
    // 同一 SKILL.md 被 user 和 project 各引用（通过 symlink），只保留 user（先出现）
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "sameFilePriorityTest-\(UUID().uuidString)")
    let homeDir    = tmp.appending(path: "home")
    let workspace  = homeDir.appending(path: "workspace")
    let gitDir     = workspace.appending(path: ".git")
    let realSkills = homeDir.appending(path: ".claude/skills")
    let sharedSkill = realSkills.appending(path: "shared-skill")
    let projSkillsDir = workspace.appending(path: ".claude/skills")
    try FileManager.default.createDirectory(at: sharedSkill, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projSkillsDir, withIntermediateDirectories: true)
    try "---\nname: Shared Skill\ndescription: shared\n---\nShared"
        .write(to: sharedSkill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
    // 在 project skills 中建立指向同一目录的 symlink
    let symlinkSkillDir = projSkillsDir.appending(path: "shared-skill")
    try FileManager.default.createSymbolicLink(at: symlinkSkillDir, withDestinationURL: sharedSkill)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let service = await SkillService(
        skillsDirectory: realSkills,
        workspaceURL: workspace
    )
    await service.loadSkills()
    let skills = await service.availableSkills
    // 通过 realpath 去重后只有一个
    XCTAssertEqual(skills.filter { $0.name == "Shared Skill" }.count, 1)
    // 先加载的是 user（managed 为空），因此保留的是 user
    XCTAssertEqual(skills.first { $0.name == "Shared Skill" }?.loadedFrom, .user)
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_loadSkills_discoversProjectSkills \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests/test_loadSkills_projectSkillTakesPrecedenceOverUser_whenSameFile \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: FAIL（`init(skillsDirectory:workspaceURL:)` 签名不匹配）

### Step 3: 修改 `SkillService`，添加 `workspaceURL` 属性和多源 `loadSkills()`

在 `SkillService.swift` 中：

**3a. 修改 `init`，存储 `workspaceURL`：**

```swift
// Private State 区域新增
private let workspaceURL: URL?

init(skillsDirectory: URL? = nil, workspaceURL: URL? = nil) {
    self.skillsDirectory = skillsDirectory ?? Self.defaultSkillsDirectory()
    self.workspaceURL = workspaceURL
}
```

**3b. 修改 `loadSkills()` 调用多源加载：**

```swift
func loadSkills() async {
    let userDir = skillsDirectory
    let workspace = workspaceURL
    availableSkills = await Task.detached(priority: .userInitiated) { [userDir, workspace] in
        Self.loadAllSkills(userSkillsDir: userDir, workspaceURL: workspace)
    }.value
}
```

**3c. 新增 `loadAllSkills(userSkillsDir:workspaceURL:)` 静态方法：**

```swift
/// 多源加载入口：managed（预留）+ user + project（deep-first）→ 合并去重 → 排序。
nonisolated private static func loadAllSkills(
    userSkillsDir: URL,
    workspaceURL: URL?
) -> [Skill] {
    // 1. User source（原有逻辑）
    let userSkills = scanSkills(in: userSkillsDir, source: .user)

    // 2. Project sources（workspace 向上遍历）
    var projectSkills: [Skill] = []
    if let workspace = workspaceURL {
        let projectDirs = projectSkillDirs(startingAt: workspace)
        for dir in projectDirs {
            let skills = scanSkills(in: dir, source: .project)
            projectSkills.append(contentsOf: skills)
        }
    }

    // 3. 合并去重（user 优先于 project）
    let merged = mergeAndDeduplicate(userSkills + projectSkills)
    return merged.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}
```

### Step 4: 运行所有 Skill 相关测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部通过，0 errors

### Step 5: Commit

```
git add agentGui/Services/SkillService.swift agentGuiTests/SkillProjectDiscoveryTests.swift
git commit -m "feat(S-A2): implement multi-source loadSkills with workspace project dir walk"
```

---

## Task 6: 接入调用方（传递 workspaceURL）

**Files:**
- Modify: 调用 `SkillService.loadSkills()` 的位置（SessionListView 或 ContentView 或 ViewModel）

### Step 1: 找到调用 `loadSkills()` 的位置

```bash
grep -rn "loadSkills\|SkillService" /Volumes/T7/文稿/Projects/agentGui/agentGui/ \
  --include="*.swift" | grep -v "SkillService.swift"
```

### Step 2: 确认 workspace URL 来源

agentGui 当前通过 `AppSettings` 或 `SessionListView` 管理 workspace。找到 workspace root 的来源并传递给 `SkillService`：

```swift
// 示例：若 SkillService 存储在 @Environment 或 ViewModel 中
// 当 workspace 切换时刷新
await skillService.loadSkills(workspaceURL: activeWorkspaceURL)
```

> **注意：** 若当前 app 没有显式 workspace 概念（single-root），可以用 `FileManager.default.currentDirectoryPath` 作为 fallback：
>
> ```swift
> let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
> await skillService.loadSkills(workspaceURL: cwd)
> ```

### Step 3: 添加 `loadSkills(workspaceURL:)` 便捷方法（可选）

若调用方需要动态传 workspace 而不重新 init，新增便捷方法：

```swift
/// 使用新的 workspace 重新加载所有来源的技能。
/// 调用后 `availableSkills` 更新为新的合并结果。
func loadSkills(workspaceURL: URL?) async {
    let userDir = skillsDirectory
    availableSkills = await Task.detached(priority: .userInitiated) { [userDir, workspaceURL] in
        Self.loadAllSkills(userSkillsDir: userDir, workspaceURL: workspaceURL)
    }.value
}
```

### Step 4: 运行全量 Skill 测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a2-derived \
  -only-testing:agentGuiTests/SkillProjectDiscoveryTests \
  -only-testing:agentGuiTests/SkillServiceFrontmatterTests \
  -only-testing:agentGuiTests/SkillManifestTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

Expected: 全部通过

### Step 5: Commit

```
git add agentGui/ agentGuiTests/
git commit -m "feat(S-A2): wire workspaceURL propagation to SkillService call sites"
```

---

## Task 7: 手动验证 + 冒烟测试

### Step 1: 在本地创建一个测试 project skill

```bash
mkdir -p /Volumes/T7/文稿/Projects/agentGui/.claude/skills/test-project-skill
cat > /Volumes/T7/文稿/Projects/agentGui/.claude/skills/test-project-skill/SKILL.md << 'EOF'
---
name: Test Project Skill
description: 验证项目级技能发现
when_to_use: 用于验证 S-A2 功能
---
# Test Project Skill
这是一个仅存在于本项目中的测试技能。
EOF
```

### Step 2: 启动 app，检查 SkillsView

在 agentGui 应用中打开技能管理面板，确认 "Test Project Skill" 出现在列表中，且来源标识为 project。

### Step 3: 清理测试 skill（可选）

```bash
rm -rf /Volumes/T7/文稿/Projects/agentGui/.claude/skills/test-project-skill
```

### Step 4: 最终 commit

```
git add .
git commit -m "feat(S-A2): complete project-level skill directory discovery"
```

---

## 验收标准汇总

| 验收条件 | 测试覆盖 |
|---------|---------|
| workspace 下有 `.claude/skills/` 时，那里的 skill 出现在 `availableSkills` | `test_loadSkills_discoversProjectSkills` |
| `loadedFrom == .project` 对于 project 来源 | `test_loadSkills_discoversProjectSkills` |
| 与 user skills 不冲突，project 优先（通过去重顺序）或 user 优先（user 先加载） | `test_loadSkills_projectSkillTakesPrecedenceOverUser_whenSameFile` |
| symlink 指向同一文件时只加载一次 | `test_mergeAndDeduplicate_removesSymlinkDuplicates` |
| 遍历在 git root 处停止，不泄漏 repo 外目录 | `test_projectSkillDirs_stopsAtGitRoot` |
| 遍历在 HOME 处停止，HOME 的 `.claude/skills/` 不被重复收集 | `test_projectSkillDirs_stopsAtHome` |
| 没有 `.claude/skills/` 时返回空，不报错 | `test_projectSkillDirs_returnsEmpty_whenNoDirsExist` |
| 现有 user skill 功能无回归 | `SkillServiceFrontmatterTests`（全量） |

---

## 依赖

- **S-A1** (SkillManifest 扩展) ✅ 已完成 — `Skill.swift` 已包含 `loadedFrom: SkillSource` 字段，`SkillSource` 枚举已定义 `.project` case
- 无其他依赖

---

## 不在本计划范围内

- **S-A3**（动态目录发现，工具执行后触发）— 独立 Feature
- **S-A4**（条件激活 paths frontmatter）— 依赖 S-A2，独立 Feature
- **S-A5**（去重已包含在本计划 Task 4 中）
- managed source 路径从 `~/.claude/managed/.claude/skills/` 加载 — 预留接口但不在本次实现

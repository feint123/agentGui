//
//  SkillProjectDiscoveryTests.swift
//  agentGuiTests
//

import XCTest
@testable import agentGui

/// 测试 SkillService 的文件系统发现逻辑（nonisolated static 方法）。
///
/// 所有测试均为同步 throws，直接调用 nonisolated static 方法，
/// 避免通过 @MainActor SkillService 实例 + async/await，防止 XCTest 死锁。
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
        // 创建一个不在任何 git 仓库内的隔离目录
        // 使用 /private/tmp 确保路径不在项目目录内
        let isolatedDir = URL(fileURLWithPath: "/private/tmp/gitRootNoGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolatedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedDir) }
        XCTAssertNil(try? tmp.checkResourceIsReachable())

        let result = SkillService.gitRoot(for: isolatedDir)
        XCTAssertNil(result)
    }

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
        XCTAssertEqual(result.map(\.path), [skills2.path, skills1.path])
    }

    func test_projectSkillDirs_stopsAtHome() throws {
        // 目录树：
        //   tmp/home/.claude/skills/   ← HOME 层不应收集
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

    // MARK: - mergeAndDeduplicate

    func test_mergeAndDeduplicate_removesSymlinkDuplicates() throws {
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

    // MARK: - Multi-source integration（不使用 SkillService 实例，避免 @MainActor 死锁）

    func test_discoversProjectSkills() throws {
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

        let userSource = SkillService.scanSkills(in: homeDir.appending(path: ".claude/skills"), source: .user)
        let projectDirs = SkillService.projectSkillDirs(startingAt: workspace, home: homeDir)
        let projectSource = projectDirs.flatMap { SkillService.scanSkills(in: $0, source: .project) }
        let skills = SkillService.mergeAndDeduplicate(userSource + projectSource)

        let names = skills.map(\.name)
        XCTAssertTrue(names.contains("User Skill"),    "User skill should be loaded")
        XCTAssertTrue(names.contains("Project Skill"), "Project skill should be loaded")

        let userSkill = skills.first { $0.name == "User Skill" }
        let projSkill = skills.first { $0.name == "Project Skill" }
        XCTAssertEqual(userSkill?.loadedFrom, .user)
        XCTAssertEqual(projSkill?.loadedFrom, .project)
    }

    func test_userSkillTakesPrecedenceOverProject_whenSamePhysicalFile() throws {
        // 同一 SKILL.md 被 user 和 project 各引用（通过 symlink），只保留 user（先出现）
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "sameFilePriorityTest-\(UUID().uuidString)")
        let homeDir       = tmp.appending(path: "home")
        let workspace     = homeDir.appending(path: "workspace")
        let gitDir        = workspace.appending(path: ".git")
        let realSkills    = homeDir.appending(path: ".claude/skills")
        let sharedSkill   = realSkills.appending(path: "shared-skill")
        let projSkillsDir = workspace.appending(path: ".claude/skills")
        try FileManager.default.createDirectory(at: sharedSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projSkillsDir, withIntermediateDirectories: true)
        try "---\nname: Shared Skill\ndescription: shared\n---\nShared"
            .write(to: sharedSkill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let symlinkSkillDir = projSkillsDir.appending(path: "shared-skill")
        try FileManager.default.createSymbolicLink(at: symlinkSkillDir, withDestinationURL: sharedSkill)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let userSource = SkillService.scanSkills(in: realSkills, source: .user)
        let projectDirs = SkillService.projectSkillDirs(startingAt: workspace, home: homeDir)
        let projectSource = projectDirs.flatMap { SkillService.scanSkills(in: $0, source: .project) }
        let skills = SkillService.mergeAndDeduplicate(userSource + projectSource)

        // realpath 去重后只有一个
        XCTAssertEqual(skills.filter { $0.name == "Shared Skill" }.count, 1)
        // user 先加载，first-wins 保留 user
        XCTAssertEqual(skills.first { $0.name == "Shared Skill" }?.loadedFrom, .user)
    }
}

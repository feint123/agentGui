import XCTest
@testable import agentGui

final class MemoryIndexFileSystemTests: XCTestCase {

    private var tempDir: URL!
    private var sut: MemoryIndexFileSystem!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndexFSTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sut = MemoryIndexFileSystem(memoryDir: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - rebuildFromDirectory

    func test_rebuildFromDirectory_emptyDir_doesNotCreateMemoryMd() async throws {
        // tempDir 里没有任何 .md 文件
        try await sut.rebuildFromDirectory()
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                       "空目录重建不应创建 MEMORY.md")
    }

    func test_rebuildFromDirectory_withTopicFile_createsMemoryMd() async throws {
        // 准备：手动写一个话题文件
        let topicContent = """
        ---
        name: "User Role"
        description: "Senior iOS developer"
        type: user
        created: 2025-01-01T00:00:00Z
        ---

        User is a senior iOS developer.
        """
        let topicURL = tempDir.appendingPathComponent("user_role_abcd1234.md")
        try topicContent.write(to: topicURL, atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "有话题文件时应创建 MEMORY.md")
        let content = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(content.contains("User Role"), "MEMORY.md 应包含话题标题")
        XCTAssertTrue(content.contains("user_role_abcd1234.md"), "MEMORY.md 应包含文件名引用")
    }

    func test_rebuildFromDirectory_excludesMemoryMdItself() async throws {
        // 准备：已有 MEMORY.md（旧索引）+ 一个话题文件
        let oldIndexURL = tempDir.appendingPathComponent("MEMORY.md")
        try "- [Old](old.md) — stale".write(to: oldIndexURL, atomically: true, encoding: .utf8)

        let topicContent = """
        ---
        name: "New Topic"
        description: "Fresh hook"
        type: project
        created: 2025-01-01T00:00:00Z
        ---

        New content.
        """
        let topicURL = tempDir.appendingPathComponent("new_topic_xyz.md")
        try topicContent.write(to: topicURL, atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let rebuiltContent = try String(contentsOf: oldIndexURL, encoding: .utf8)
        XCTAssertTrue(rebuiltContent.contains("New Topic"), "重建后应包含新话题")
        XCTAssertFalse(rebuiltContent.contains("MEMORY.md"), "MEMORY.md 不应引用自身")
    }

    func test_rebuildFromDirectory_createsDirectoryIfNeeded() async throws {
        let nested = tempDir.appendingPathComponent("new/sub/memory", isDirectory: true)
        let nestedFS = MemoryIndexFileSystem(memoryDir: nested)

        // 写一个话题文件到嵌套目录（先手动创建目录）
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let topicContent = "---\nname: \"T\"\ndescription: \"d\"\ntype: project\ncreated: 2025-01-01T00:00:00Z\n---\nBody"
        try topicContent.write(to: nested.appendingPathComponent("t_12345678.md"),
                               atomically: true, encoding: .utf8)

        do {
            try await nestedFS.rebuildFromDirectory()
        } catch {
            XCTFail("rebuildFromDirectory() 不应抛出错误: \(error)")
        }
    }

    // MARK: - 行格式：无描述文件

    func test_indexLine_withDescription_includesSeparatorAndDesc() async throws {
        let topicContent = """
        ---
        name: "Auth Flow"
        description: "OAuth 2.0 PKCE login flow"
        type: project
        created: 2025-01-01T00:00:00Z
        ---

        Details.
        """
        try topicContent.write(
            to: tempDir.appendingPathComponent("auth_flow_12345678.md"),
            atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(
            content.contains("- [Auth Flow](auth_flow_12345678.md) — OAuth 2.0 PKCE login flow"),
            "有描述时应包含 ' — description'，实际：\(content)")
    }

    func test_indexLine_withoutDescription_noTrailingSeparator() async throws {
        let topicContent = """
        ---
        name: "Bare Title"
        type: project
        created: 2025-01-01T00:00:00Z
        ---

        No description in frontmatter.
        """
        try topicContent.write(
            to: tempDir.appendingPathComponent("bare_title_12345678.md"),
            atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        // 不应有尾迹 "— "
        XCTAssertFalse(
            content.contains("— \n") || content.hasSuffix("— "),
            "无描述时行末不应有 '— '，实际：\(content)")
        XCTAssertTrue(
            content.contains("- [Bare Title](bare_title_12345678.md)"),
            "无描述文件应有简洁行，实际：\(content)")
    }
}


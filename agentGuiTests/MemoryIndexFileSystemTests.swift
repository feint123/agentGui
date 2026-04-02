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

    // MARK: - mtime 排序

    func test_mtimeSorting_newerFileAppearsFirst() async throws {
        // 写两个话题文件，间隔 1 秒以确保 mtime 差异
        let olderContent = """
        ---
        name: "Older Topic"
        description: "Written first"
        type: project
        created: 2025-01-01T00:00:00Z
        ---
        Body
        """
        let olderURL = tempDir.appendingPathComponent("older_abcd1234.md")
        try olderContent.write(to: olderURL, atomically: true, encoding: .utf8)

        // 人为设置旧 mtime（30 秒前）
        let oldDate = Date(timeIntervalSinceNow: -30)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: olderURL.path)

        let newerContent = """
        ---
        name: "Newer Topic"
        description: "Written second"
        type: project
        created: 2025-01-01T00:00:00Z
        ---
        Body
        """
        let newerURL = tempDir.appendingPathComponent("newer_efgh5678.md")
        try newerContent.write(to: newerURL, atomically: true, encoding: .utf8)
        // newerURL 的 mtime 是当前时间，比 oldDate 更新

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        let newerRange = content.range(of: "Newer Topic")
        let olderRange = content.range(of: "Older Topic")
        XCTAssertNotNil(newerRange, "MEMORY.md 应包含 Newer Topic")
        XCTAssertNotNil(olderRange, "MEMORY.md 应包含 Older Topic")
        XCTAssertLessThan(
            newerRange!.lowerBound, olderRange!.lowerBound,
            "较新文件应排在较旧文件前面")
    }

    // MARK: - 描述超长截断

    func test_descriptionTruncation_over150Chars_appendsEllipsis() async throws {
        let longDesc = String(repeating: "a", count: 200)  // 200 chars，远超 150
        let topicContent = """
        ---
        name: "Long Desc"
        description: "\(longDesc)"
        type: project
        created: 2025-01-01T00:00:00Z
        ---
        Body
        """
        try topicContent.write(
            to: tempDir.appendingPathComponent("long_desc_12345678.md"),
            atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        // 截断后应是 149 个 'a' + '…'
        let expected = String(repeating: "a", count: 149) + "…"
        XCTAssertTrue(
            content.contains(expected),
            "超过 150 字符的描述应在 149 处截断并附加 '…'")
    }

    // MARK: - 200 行截断

    func test_200LineTruncation_appendsWarningAndCapsAtLimit() async throws {
        // 写 201 个话题文件
        for i in 1...201 {
            let suffix = String(format: "%08d", i)
            let content = """
            ---
            name: "Topic \(i)"
            description: "Hook \(i)"
            type: project
            created: 2025-01-01T00:00:00Z
            ---
            Body
            """
            try content.write(
                to: tempDir.appendingPathComponent("topic_\(suffix).md"),
                atomically: true, encoding: .utf8)
            // 人为设置不同 mtime，让排序稳定
            let d = Date(timeIntervalSinceNow: Double(i) * -1)
            try FileManager.default.setAttributes(
                [.modificationDate: d],
                ofItemAtPath: tempDir.appendingPathComponent("topic_\(suffix).md").path)
        }

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
        XCTAssertLessThanOrEqual(lines.count, 200, "索引行数不应超过 200")
        XCTAssertTrue(content.contains("WARNING"), "超出行数时应追加 WARNING 说明")
    }

    // MARK: - 无标题回退到文件名

    func test_titleFallback_noNameInFrontmatter_usesFilename() async throws {
        // frontmatter 没有 name: 字段
        let topicContent = """
        ---
        description: "Some hook"
        type: project
        created: 2025-01-01T00:00:00Z
        ---
        Body
        """
        let filename = "no_name_abcd1234.md"
        try topicContent.write(
            to: tempDir.appendingPathComponent(filename),
            atomically: true, encoding: .utf8)

        try await sut.rebuildFromDirectory()

        let content = try String(
            contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(
            content.contains("- [\(filename)](\(filename))"),
            "无 name: 时应用文件名作为链接文本，实际：\(content)")
    }
}


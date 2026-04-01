import XCTest
@testable import agentGui

final class MemoryIndexWriterTests: XCTestCase {

    private let writer = MemoryIndexWriter()

    private func makeRecord(
        id: String,
        title: String,
        summary: String = "A summary",
        retentionPolicy: MemoryRecord.RetentionPolicy = .persistent
    ) -> MemoryRecord {
        MemoryRecord.fixture(
            id: id, title: title, summary: summary,
            retentionPolicy: retentionPolicy,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Empty records

    func test_build_emptyRecords_returnsEmptyIndex() {
        let output = writer.build(records: [])
        XCTAssertTrue(output.indexContent.isEmpty,
                      "空记录应返回空索引")
        XCTAssertTrue(output.topicFiles.isEmpty)
    }

    // MARK: - Single record

    func test_build_singleRecord_indexHasOneEntry() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        let lines = output.indexContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "单条记录应生成 1 行索引")
    }

    func test_build_singleRecord_indexEntryFormat() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role", summary: "Senior iOS dev")
        let output = writer.build(records: [record])
        // 格式: - [Title](filename.md) — hook
        XCTAssertTrue(output.indexContent.hasPrefix("- [User Role]"),
                      "索引行应以 '- [Title]' 开头")
        XCTAssertTrue(output.indexContent.contains(".md)"),
                      "索引行应包含 .md 文件链接")
        XCTAssertTrue(output.indexContent.contains(" — "),
                      "索引行应包含 ' — ' 分隔符")
    }

    func test_build_singleRecord_topicFileGenerated() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        XCTAssertEqual(output.topicFiles.count, 1)
        XCTAssertEqual(output.topicFiles[0].filename,
                       MemoryTopicFilename.filename(for: record))
    }

    func test_build_singleRecord_topicFileContentHasFrontmatter() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role")
        let output = writer.build(records: [record])
        XCTAssertTrue(output.topicFiles[0].content.hasPrefix("---"),
                      "话题文件内容应以 frontmatter 开头")
    }

    // MARK: - Archived records excluded

    func test_build_archivedRecordsExcluded() {
        let active = makeRecord(id: "aaa", title: "Active", retentionPolicy: .persistent)
        let archived = makeRecord(id: "bbb", title: "Archived", retentionPolicy: .archiveOnly)
        let output = writer.build(records: [active, archived])
        XCTAssertEqual(output.topicFiles.count, 1,
                       "archiveOnly 记录不应生成话题文件")
        XCTAssertFalse(output.indexContent.contains("Archived"),
                       "archiveOnly 记录不应出现在索引中")
    }

    // MARK: - Line truncation

    func test_build_over200Lines_truncatesAndAppendsWarning() {
        let records = (0..<210).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))", title: "Record \(i)")
        }
        let output = writer.build(records: records)
        let lines = output.indexContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(lines.count, MemoryIndexWriter.maxLines + 2,
                                 "超出 200 行时应截断（最多附加 1-2 个 warning 行）")
        XCTAssertTrue(output.indexContent.contains("WARNING"),
                      "截断后应包含 WARNING 提示")
        XCTAssertTrue(output.wasTruncated, "wasTruncated 应为 true")
    }

    func test_build_exactly200Lines_notTruncated() {
        let records = (0..<200).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))", title: "Record \(i)")
        }
        let output = writer.build(records: records)
        XCTAssertFalse(output.wasTruncated,
                       "恰好 200 条记录不应触发截断")
    }

    // MARK: - Byte truncation

    func test_build_over25KBBytes_truncatesAndAppendsWarning() {
        // 生成每行约 200 字符的记录（超过 25KB 约需 125+ 条）
        let longTitle = String(repeating: "a", count: 60)
        let longHook = String(repeating: "b", count: 120)
        let records = (0..<130).map { i in
            makeRecord(id: "id\(String(format: "%04d", i))",
                       title: "\(longTitle)\(i)",
                       summary: longHook)
        }
        let output = writer.build(records: records)
        XCTAssertLessThanOrEqual(output.indexContent.utf8.count, MemoryIndexWriter.maxBytes + 500,
                                 "字节截断后不应超过 maxBytes + 一行 warning 余量")
        XCTAssertTrue(output.indexContent.contains("WARNING"))
        XCTAssertTrue(output.wasTruncated)
    }

    // MARK: - Hook text

    func test_build_hookTextIsSummary() {
        let record = makeRecord(id: "abcd1234-x", title: "User Role",
                                summary: "Senior iOS developer, Swift 6 focus")
        let output = writer.build(records: [record])
        XCTAssertTrue(output.indexContent.contains("Senior iOS developer"),
                      "hook 文本应包含 summary")
    }

    func test_build_hookTextTruncatedAt120Chars() {
        let longSummary = String(repeating: "x", count: 200)
        let record = makeRecord(id: "abcd1234-x", title: "T", summary: longSummary)
        let output = writer.build(records: [record])
        // 整行：- [T](t_abcd1234.md) — <hook>
        // hook 部分 ≤ 120 字符
        let entryLine = output.indexContent.components(separatedBy: "\n").first ?? ""
        let hookPart = entryLine.components(separatedBy: " — ").last ?? ""
        XCTAssertLessThanOrEqual(hookPart.count, 120,
                                 "hook 文本不应超过 120 字符")
    }
}

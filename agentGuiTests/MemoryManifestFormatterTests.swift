import XCTest
@testable import agentGui

final class MemoryManifestFormatterTests: XCTestCase {

    func test_format_emptyList_returnsEmptyString() {
        XCTAssertTrue(MemoryManifestFormatter().format([]).isEmpty)
    }

    func test_format_withDescription_includesTypeFilenameDateDesc() {
        let header = MemoryTopicHeader(
            filename: "test_topic_abc12345.md",
            filePath: URL(fileURLWithPath: "/tmp/test_topic_abc12345.md"),
            mtimeMs: 1_700_000_000_000,
            title: "Test Topic",
            description: "A brief description",
            memoryType: "feedback"
        )
        let output = MemoryManifestFormatter().format([header])
        XCTAssertTrue(output.contains("[feedback]"), "应含 [type] 标签")
        XCTAssertTrue(output.contains("test_topic_abc12345.md"), "应含文件名")
        XCTAssertTrue(output.contains("A brief description"), "应含 description")
        XCTAssertTrue(output.contains("2023-"), "应含 ISO 时间戳年份")
    }

    func test_format_withoutDescription_omitsDescPart() {
        let header = MemoryTopicHeader(
            filename: "no_desc_abc12345.md",
            filePath: URL(fileURLWithPath: "/tmp/no_desc_abc12345.md"),
            mtimeMs: 1_700_000_000_000,
            title: nil,
            description: nil,
            memoryType: nil
        )
        let output = MemoryManifestFormatter().format([header])
        XCTAssertTrue(output.contains("no_desc_abc12345.md"))
        // 没有 type 标签
        XCTAssertFalse(output.contains("["))
    }

    func test_format_multipleHeaders_oneLineEach() {
        let headers = (0..<3).map { i in
            MemoryTopicHeader(
                filename: "file_\(i)_aabbccdd.md",
                filePath: URL(fileURLWithPath: "/tmp/file_\(i)_aabbccdd.md"),
                mtimeMs: Double(i) * 1_000,
                title: "Title \(i)",
                description: "Desc \(i)",
                memoryType: nil
            )
        }
        let output = MemoryManifestFormatter().format(headers)
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }
}

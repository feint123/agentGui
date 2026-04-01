import XCTest
@testable import agentGui

final class MemoryIndexReaderTests: XCTestCase {

    private let reader = MemoryIndexReader()
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndexReaderTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeIndex(_ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - File not found

    func test_read_nonExistentFile_returnsNil() {
        let url = tempDir.appendingPathComponent("does_not_exist.md")
        let result = reader.read(from: url)
        XCTAssertNil(result, "不存在的文件应返回 nil")
    }

    // MARK: - Normal read

    func test_read_normalContent_returnsContent() throws {
        let content = "- [User Role](user_role_abc.md) — Senior iOS dev"
        let url = try writeIndex(content)
        let result = reader.read(from: url)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.content, content)
        XCTAssertFalse(result?.wasTruncated ?? true)
    }

    func test_read_emptyFile_returnsNilOrEmpty() throws {
        let url = try writeIndex("")
        let result = reader.read(from: url)
        // 空文件可返回 nil 或 wasTruncated=false 的空内容
        if let r = result {
            XCTAssertFalse(r.wasTruncated)
        }
    }

    // MARK: - Line count

    func test_read_lineCount_isAccurate() throws {
        let lines = (1...10).map { "- [Record \($0)](r\($0).md) — Hook \($0)" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertEqual(result?.lineCount, 10)
    }

    // MARK: - Byte count

    func test_read_byteCount_isAccurate() throws {
        let content = "- [A](a.md) — hook"
        let url = try writeIndex(content)
        let result = reader.read(from: url)
        XCTAssertEqual(result?.byteCount, content.utf8.count)
    }

    func test_read_over200Lines_wasTruncatedIsTrue() throws {
        let lines = (1...210).map { "- [Record \($0)](r\($0).md) — hook" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertTrue(result?.wasTruncated ?? false,
                      "超过 200 行时 wasTruncated 应为 true")
    }

    func test_read_over200Lines_contentHasWarning() throws {
        let lines = (1...210).map { "- [Record \($0)](r\($0).md) — hook" }
        let url = try writeIndex(lines.joined(separator: "\n"))
        let result = reader.read(from: url)
        XCTAssertTrue(result?.content.contains("WARNING") ?? false)
    }
}

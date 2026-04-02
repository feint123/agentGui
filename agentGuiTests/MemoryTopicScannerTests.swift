import XCTest
@testable import agentGui

final class MemoryTopicScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryTopicScannerTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_scan_emptyDir_returnsEmpty() async throws {
        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertTrue(headers.isEmpty)
    }

    func test_scan_excludesMEMORYmd() async throws {
        let memoryMd = tempDir.appendingPathComponent("MEMORY.md")
        try "# Index\n- [foo](foo.md) — hook".write(to: memoryMd, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertTrue(headers.isEmpty, "MEMORY.md は除外されるべき")
    }

    func test_scan_parsesNameAndDescription() async throws {
        let content = """
        ---
        name: "My Title"
        description: "A summary of the topic"
        type: "feedback"
        ---
        Body content here.
        """
        let file = tempDir.appendingPathComponent("my_title_abc12345.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers[0].filename, "my_title_abc12345.md")
        XCTAssertEqual(headers[0].title, "My Title")
        XCTAssertEqual(headers[0].description, "A summary of the topic")
        XCTAssertEqual(headers[0].memoryType, .feedback)
    }

    func test_scan_unknownType_returnsNilType() async throws {
        let content = """
        ---
        name: "Unknown Type Memory"
        type: "bogus_type"
        ---
        Body.
        """
        let file = tempDir.appendingPathComponent("unknown_type_abc12345.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertEqual(headers.count, 1)
        XCTAssertNil(headers[0].memoryType,
                     "未知 type 值应静默降级为 nil，不报错")
    }

    func test_scan_fileMissingDescription_descriptionNil() async throws {
        let content = """
        ---
        name: "No Desc"
        ---
        Body.
        """
        let file = tempDir.appendingPathComponent("no_desc_abc12345.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertEqual(headers.count, 1)
        XCTAssertNil(headers[0].description)
    }

    func test_scan_capsAt200Files() async throws {
        for i in 0..<210 {
            let content = "---\nname: \"File \(i)\"\n---\nbody"
            let file = tempDir.appendingPathComponent("file_\(String(format: "%04d", i))_aaaabbbb.md")
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let headers = try await MemoryTopicScanner().scan(memoryDir: tempDir)
        XCTAssertLessThanOrEqual(headers.count, 200)
    }
}

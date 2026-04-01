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

    func test_rebuild_writesMemoryMd() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "rebuild 后应生成 MEMORY.md")
    }

    func test_rebuild_writesTopicFile() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let expectedName = MemoryTopicFilename.filename(for: record)
        let topicURL = tempDir.appendingPathComponent(expectedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: topicURL.path),
                      "rebuild 后应生成话题文件 \(expectedName)")
    }

    func test_rebuild_memoryMdContainsEntry() throws {
        let record = MemoryRecord.fixture(id: "abcd1234-x", title: "User Role",
                                          summary: "Senior iOS dev", retentionPolicy: .persistent)
        try sut.rebuild(with: [record])

        let content = try String(contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("User Role"), "MEMORY.md 应包含记录标题")
        XCTAssertTrue(content.contains("Senior iOS dev"), "MEMORY.md 应包含 hook")
    }

    func test_rebuild_emptyRecords_doesNotWriteMemoryMd() throws {
        try sut.rebuild(with: [])
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path),
                       "空记录时不应创建 MEMORY.md")
    }

    func test_rebuild_createsDirectoryIfNeeded() throws {
        let nonExistentDir = tempDir.appendingPathComponent("sub/memory", isDirectory: true)
        let fs = MemoryIndexFileSystem(memoryDir: nonExistentDir)
        let record = MemoryRecord.fixture(id: "xyz", title: "T", retentionPolicy: .persistent)
        XCTAssertNoThrow(try fs.rebuild(with: [record]),
                         "rebuild 应自动创建目录")
    }

    func test_rebuild_overwritesExistingMemoryMd() throws {
        let record1 = MemoryRecord.fixture(id: "id1", title: "Old Title", retentionPolicy: .persistent)
        try sut.rebuild(with: [record1])
        let record2 = MemoryRecord.fixture(id: "id2", title: "New Title", retentionPolicy: .persistent)
        try sut.rebuild(with: [record2])

        let content = try String(contentsOf: tempDir.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("New Title"))
        XCTAssertFalse(content.contains("Old Title"),
                       "重建后旧标题不应出现在 MEMORY.md 中")
    }
}

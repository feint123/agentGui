import XCTest
import SwiftAnthropic
@testable import agentGui

/// 验证 executeFileMemoryWrite (through public test hook) 正确写 .md 文件并重建 MEMORY.md
@MainActor
final class MemoryWriteToFileTests: XCTestCase {

    private var tempMemoryDir: URL!

    override func setUpWithError() throws {
        tempMemoryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryWriteTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempMemoryDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempMemoryDir)
    }

    // MARK: - helpers

    private func buildInput(
        content: String,
        title: String? = nil,
        type: String? = nil,
        description: String? = nil
    ) -> MessageResponse.Content.Input {
        var dict: MessageResponse.Content.Input = ["content": .string(content)]
        if let t = title { dict["title"] = .string(t) }
        if let tp = type { dict["type"] = .string(tp) }
        if let d = description { dict["description"] = .string(d) }
        return dict
    }

    func test_execute_createsTopicFileInMemoryDir() async throws {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "User prefers bun over npm.", title: "Bun Preference"),
            memoryDir: tempMemoryDir
        )

        XCTAssertFalse(result.hasPrefix("Error:"), "调用不应返回错误: \(result)")
        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        XCTAssertEqual(files.count, 1, "应创建一个话题文件")
    }

    func test_execute_createdFileContainsFrontmatter() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(
                content: "Use SwiftData, not CoreData.",
                title: "SwiftData Preference",
                type: "project"
            ),
            memoryDir: tempMemoryDir
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---"), "话题文件应以 frontmatter 开头")
        XCTAssertTrue(content.contains("name:"), "frontmatter 应包含 name 字段")
        XCTAssertTrue(content.contains("type: project"), "frontmatter 应包含 type 字段")
        XCTAssertTrue(content.contains("Use SwiftData"), "文件体应包含输入内容")
    }

    func test_execute_rebuildsMemoryMdIndex() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(
                content: "User is a senior iOS developer.",
                title: "User Background",
                type: "user"
            ),
            memoryDir: tempMemoryDir
        )

        let indexURL = tempMemoryDir.appendingPathComponent("MEMORY.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path),
                      "执行后应创建或更新 MEMORY.md 索引")
        let indexContent = try String(contentsOf: indexURL, encoding: .utf8)
        XCTAssertTrue(indexContent.contains("User Background"),
                      "MEMORY.md 应包含话题标题")
    }

    func test_execute_missingContent_returnsError() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: [:],
            memoryDir: tempMemoryDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "缺少 content 参数应返回 Error")
    }

    func test_execute_returnsFilename() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Remember X.", title: "Fact X"),
            memoryDir: tempMemoryDir
        )
        XCTAssertTrue(result.hasPrefix("Memory saved:"), "成功时应返回 'Memory saved: <filename>'")
    }

    func test_execute_defaultType_isProject() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Something important.", title: "Important Thing"),
            memoryDir: tempMemoryDir
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: tempMemoryDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("type: project"),
                      "未提供 type 时应默认为 project")
    }
}

import XCTest
@testable import agentGui

final class ConfigDirectoryManagerMemoryDirTests: XCTestCase {

    func test_memoryDir_isInsideAgentGuiDir() {
        let mgr = ConfigDirectoryManager.shared
        let memPath = mgr.memoryDir.path
        let basePath = mgr.agentGuiDir.path
        XCTAssertTrue(memPath.hasPrefix(basePath),
                      "memoryDir 应在 agentGuiDir 内")
    }

    func test_memoryDir_lastPathComponentIsMemory() {
        XCTAssertEqual(ConfigDirectoryManager.shared.memoryDir.lastPathComponent, "memory")
    }

    func test_memoryIndexURL_filenameIsMEMORY_md() {
        XCTAssertEqual(ConfigDirectoryManager.shared.memoryIndexURL.lastPathComponent, "MEMORY.md")
    }

    func test_memoryIndexURL_isInsideMemoryDir() {
        let mgr = ConfigDirectoryManager.shared
        XCTAssertTrue(mgr.memoryIndexURL.path.hasPrefix(mgr.memoryDir.path))
    }
}

import Foundation
import Testing
@testable import agentGui

struct FileNodeAutoFoldTests {

    // MARK: - 基础折叠字段

    @Test func nonFoldedNodeHasEmptySegments() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil
        )
        #expect(node.foldedSegments.isEmpty)
        #expect(node.foldedTerminalURL == nil)
    }

    @Test func foldedNodeHasSegments() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil,
            childrenLoadState: .notLoaded,
            foldedSegments: ["src", "main", "java"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main/java")
        )
        #expect(node.foldedSegments == ["src", "main", "java"])
        #expect(node.foldedTerminalURL?.path == "/tmp/src/main/java")
    }

    @Test func isFoldedReturnsTrueWhenSegmentsCountGT1() {
        let folded = FileNode(
            id: URL(fileURLWithPath: "/tmp/a"),
            name: "a",
            isDirectory: true,
            children: nil,
            foldedSegments: ["a", "b"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/a/b")
        )
        let plain = FileNode(
            id: URL(fileURLWithPath: "/tmp/a"),
            name: "a",
            isDirectory: true,
            children: nil
        )
        #expect(folded.isFolded == true)
        #expect(plain.isFolded == false)
    }

    @Test func foldDisplayPathJoinsSegmentsWithSlash() {
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/src"),
            name: "src",
            isDirectory: true,
            children: nil,
            foldedSegments: ["src", "main", "java"],
            foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main/java")
        )
        // "src / main / java"（两侧有空格的 /）
        #expect(node.foldDisplayPath == "src / main / java")
    }

    // MARK: - Hashable / Equatable 不受折叠字段影响

    @Test func hashableIgnoresFoldFields() {
        let url = URL(fileURLWithPath: "/tmp/src")
        let plain = FileNode(id: url, name: "src", isDirectory: true, children: nil)
        let folded = FileNode(
            id: url, name: "src", isDirectory: true, children: nil,
            foldedSegments: ["src", "main"], foldedTerminalURL: URL(fileURLWithPath: "/tmp/src/main")
        )
        #expect(plain == folded)
        #expect(plain.hashValue == folded.hashValue)
    }

    // MARK: - 默认值向后兼容（现有调用处不传新字段也能编译）

    @Test func legacyInitUsesDefaults() {
        // 使用旧签名（不传 foldedSegments / foldedTerminalURL）
        let node = FileNode(
            id: URL(fileURLWithPath: "/tmp/x"),
            name: "x",
            isDirectory: false,
            children: nil
        )
        #expect(node.foldedSegments.isEmpty)
        #expect(node.foldedTerminalURL == nil)
    }
}

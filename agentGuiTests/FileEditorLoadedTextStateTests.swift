import Foundation
import Testing
@testable import agentGui

struct FileEditorTextLoadingStrategyTests {

    @Test func customLoaderReceivesStandardizedURL() async throws {
        let receivedURL = LockedURLBox()
        let strategy = FileEditorTextLoadingStrategy(loadText: { url in
            await receivedURL.set(url)
            return "ok"
        })
        let rawURL = URL(fileURLWithPath: "/tmp/workspace/folder/../note.md")

        let text = try await strategy.loadNormalizedText(from: rawURL)

        #expect(text == "ok")
        #expect(await receivedURL.value == rawURL.standardizedFileURL)
    }

    @Test func canonicalLoadedTextMatchesEditorSerializationForMarkdownFiles() {
        let fileURL = URL(fileURLWithPath: "/tmp/note.md")
        let diskText = "第一行\n"

        let normalized = FileEditorTextLoadingStrategy.normalizedTextForInitialLoad(diskText, fileURL: fileURL)

        #expect(normalized == "第一行")
    }

    @Test func canonicalLoadedTextMatchesEditorSerializationForSourceFiles() {
        let fileURL = URL(fileURLWithPath: "/tmp/demo.swift")
        let diskText = "struct Demo {}\n"

        let normalized = FileEditorTextLoadingStrategy.normalizedTextForInitialLoad(diskText, fileURL: fileURL)

        #expect(normalized == "struct Demo {}")
    }

    @Test func asyncLoadNormalizesTextReadFromDisk() async throws {
        let fileURL = try makeTemporaryTextFile(named: "note.md", contents: "第一行\n")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let normalized = try await FileEditorTextLoadingStrategy.live.loadNormalizedText(from: fileURL)

        #expect(normalized == "第一行")
    }

    @Test func asyncLoadFallsBackToLatin1WhenUTF8Fails() async throws {
        let fileURL = try makeTemporaryTextFile(named: "legacy.txt", data: Data([0x63, 0x61, 0x66, 0xE9]))
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let normalized = try await FileEditorTextLoadingStrategy.live.loadNormalizedText(from: fileURL)

        #expect(normalized == "café")
    }

    @Test func readTextFromDiskThrowsWhenFileIsMissing() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/agentgui-missing-\(UUID().uuidString).txt")

        #expect(throws: Error.self) {
            try FileEditorTextLoadingStrategy.readTextFromDisk(at: fileURL)
        }
    }
}

private func makeTemporaryTextFile(named name: String, contents: String) throws -> URL {
    try makeTemporaryTextFile(named: name, data: Data(contents.utf8))
}

private func makeTemporaryTextFile(named name: String, data: Data) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentgui-loaded-text-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let fileURL = directoryURL.appendingPathComponent(name)
    try data.write(to: fileURL)
    return fileURL
}

private actor LockedURLBox {
    private(set) var value: URL?

    func set(_ url: URL) {
        value = url
    }
}
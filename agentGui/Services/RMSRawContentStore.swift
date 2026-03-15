import Foundation

protocol RMSRawContentStoring {
    func persistInsightRawContent(_ content: String, insightID: String) throws -> String
    func persistDeltaRawContent(_ content: String, sessionID: String, roundIndex: Int) throws -> String
}

struct RMSRawContentStore: RMSRawContentStoring {
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(
        baseDirectory: URL = RMSRawContentStore.defaultBaseDirectory(),
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory.appending(path: "rms-raw", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    func persistInsightRawContent(_ content: String, insightID: String) throws -> String {
        try persist(
            content: content,
            directory: baseDirectory.appending(path: "insights", directoryHint: .isDirectory),
            fileName: sanitizedFileName(insightID)
        )
    }

    func persistDeltaRawContent(_ content: String, sessionID: String, roundIndex: Int) throws -> String {
        try persist(
            content: content,
            directory: baseDirectory
                .appending(path: "deltas", directoryHint: .isDirectory)
                .appending(path: sanitizedFileName(sessionID), directoryHint: .isDirectory),
            fileName: "round-\(roundIndex)"
        )
    }

    private static func defaultBaseDirectory() -> URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appending(path: "agentgui-rms-raw-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return ConfigDirectoryManager.shared.agentGuiDir
    }

    private func persist(content: String, directory: URL, fileName: String) throws -> String {
        try ensureDirectoryExists(directory)
        let fileURL = directory.appending(path: "\(fileName).md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    private func ensureDirectoryExists(_ directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func sanitizedFileName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}
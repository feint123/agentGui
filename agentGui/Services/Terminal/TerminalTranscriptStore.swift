import Foundation

final class TerminalTranscriptStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func createTranscript(taskId: String) throws {
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = transcriptURL(taskId: taskId)
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
    }

    func append(_ text: String, to taskId: String) throws {
        let url = transcriptURL(taskId: taskId)
        if !fileManager.fileExists(atPath: url.path) {
            try createTranscript(taskId: taskId)
        }

        guard let data = text.data(using: .utf8) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func readTail(taskId: String, lineCount: Int) throws -> String {
        let data = try Data(contentsOf: transcriptURL(taskId: taskId))
        let text = String(decoding: data, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let normalizedLines = lines.last == "" ? Array(lines.dropLast()) : lines
        return normalizedLines.suffix(max(lineCount, 0)).joined(separator: "\n")
    }

    func transcriptURL(taskId: String) -> URL {
        baseDirectory.appendingPathComponent(taskId).appendingPathExtension("log")
    }
}
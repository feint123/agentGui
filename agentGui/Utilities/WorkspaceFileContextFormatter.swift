import Foundation

struct FileLineRange: Equatable, Codable, Hashable {
    let startLine: Int
    let endLine: Int

    init(startLine: Int, endLine: Int) {
        self.startLine = max(1, startLine)
        self.endLine = max(self.startLine, endLine)
    }

    var displayText: String {
        startLine == endLine ? "\(startLine)" : "\(startLine)-\(endLine)"
    }
}

struct EditorSelectionSnapshot: Equatable {
    let text: String?
    let lineRange: FileLineRange?
}

enum WorkspaceFileContextFormatter {
    static func displayLabel(for fileURL: URL, lineRange: FileLineRange? = nil) -> String {
        let baseName = fileURL.lastPathComponent
        guard let lineRange else { return baseName }
        return "\(baseName):\(lineRange.displayText)"
    }

    static func inlineReference(for fileURL: URL, lineRange: FileLineRange? = nil) -> String {
        let path = fileURL.path
        guard let lineRange else { return path }
        return "\(path):\(lineRange.displayText)"
    }
}
import Foundation

enum FileEditorLoadedTextState {

    static func loadNormalizedText(from fileURL: URL) async throws -> String {
        let standardizedURL = fileURL.standardizedFileURL
        return try await Task.detached(priority: .userInitiated) {
            let loadedText = try readTextFromDisk(at: standardizedURL)
            return normalizedTextForInitialLoad(loadedText, fileURL: standardizedURL)
        }.value
    }

    static func normalizedTextForInitialLoad(_ diskText: String, fileURL: URL) -> String {
        let document = BlockMarkdownCodec.parse(diskText, fileURL: fileURL)
        return BlockMarkdownCodec.serialize(document, fileURL: fileURL)
    }

    private static func readTextFromDisk(at fileURL: URL) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            if let text = try? String(contentsOf: fileURL, encoding: .isoLatin1) {
                return text
            }
            throw error
        }
    }
}
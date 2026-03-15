import Foundation

struct FileEditorTextLoadingStrategy: Sendable {
    private enum Loader: Sendable {
        case live
        case custom(@Sendable (URL) async throws -> String)
    }

    private let loader: Loader

    init(loadText: @escaping @Sendable (URL) async throws -> String) {
        self.loader = .custom(loadText)
    }

    private init(loader: Loader) {
        self.loader = loader
    }

    static let live = FileEditorTextLoadingStrategy(loader: .live)

    func loadNormalizedText(from fileURL: URL) async throws -> String {
        let standardizedURL = fileURL.standardizedFileURL

        switch loader {
        case .live:
            return try await Self.liveLoadText(standardizedURL)
        case .custom(let loadText):
            return try await loadText(standardizedURL)
        }
    }

    static func normalizedTextForInitialLoad(_ diskText: String, fileURL: URL) -> String {
        let document = BlockMarkdownCodec.parse(diskText, fileURL: fileURL)
        return BlockMarkdownCodec.serialize(document, fileURL: fileURL)
    }

    static func readTextFromDisk(at fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        for encoding in [String.Encoding.utf8, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private static func liveLoadText(_ fileURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let loadedText = try readTextFromDisk(at: fileURL)
            return normalizedTextForInitialLoad(loadedText, fileURL: fileURL)
        }.value
    }
}
import Foundation

struct FileEditorRequestToken: Equatable {
    let generation: Int
    let fileURL: URL
}

@MainActor
struct FileEditorRequestTracker {
    private var generation = 0

    mutating func beginRequest(for url: URL) -> FileEditorRequestToken {
        generation += 1
        return FileEditorRequestToken(generation: generation, fileURL: url.standardizedFileURL)
    }

    mutating func invalidate() {
        generation += 1
    }

    func snapshot(for url: URL) -> FileEditorRequestToken {
        FileEditorRequestToken(generation: generation, fileURL: url.standardizedFileURL)
    }

    func isCurrent(_ token: FileEditorRequestToken, for url: URL?) -> Bool {
        guard let url else { return false }
        return token.generation == generation && token.fileURL == url.standardizedFileURL
    }
}
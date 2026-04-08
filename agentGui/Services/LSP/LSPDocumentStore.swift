import Foundation

final class LSPDocumentStore {
    private struct Entry {
        var snapshot: LSPDocumentSnapshot
        var lineIndex: CodeEditorLineIndex
    }

    private var entries: [String: Entry] = [:]

    // MARK: - Lifecycle

    @discardableResult
    func openDocument(uri: String, languageID: String, text: String) -> LSPDocumentSnapshot {
        let snapshot = LSPDocumentSnapshot(uri: uri, languageID: languageID, text: text, version: 1)
        entries[uri] = Entry(snapshot: snapshot, lineIndex: CodeEditorLineIndex(text: text))
        return snapshot
    }

    @discardableResult
    func updateDocument(uri: String, text: String) -> LSPDocumentSnapshot? {
        guard let current = entries[uri] else { return nil }
        let snapshot = LSPDocumentSnapshot(
            uri: current.snapshot.uri,
            languageID: current.snapshot.languageID,
            text: text,
            version: current.snapshot.version + 1
        )
        entries[uri] = Entry(snapshot: snapshot, lineIndex: CodeEditorLineIndex(text: text))
        return snapshot
    }

    func closeDocument(uri: String) {
        entries.removeValue(forKey: uri)
    }

    func snapshot(for uri: String) -> LSPDocumentSnapshot? {
        entries[uri]?.snapshot
    }

    // MARK: - Incremental range conversion

    /// Converts an NSRange (UTF-16 character offsets in the **current** document text)
    /// to an LSP `range` dictionary with 0-based `line`/`character` values.
    ///
    /// Returns `nil` if the URI is not currently open.
    /// Must be called **before** `updateDocument(uri:text:)` to use the old text for position calculation.
    func lspRange(for nsRange: NSRange, uri: String) -> [String: Any]? {
        guard let entry = entries[uri] else { return nil }
        let index = entry.lineIndex

        // CodeEditorLineIndex.location(ofUTF16Offset:) is 1-based → subtract 1 for LSP (0-based).
        let startLocation = index.location(ofUTF16Offset: nsRange.location)
        let endLocation   = index.location(ofUTF16Offset: nsRange.location + nsRange.length)

        return [
            "start": [
                "line":      startLocation.line - 1,
                "character": startLocation.column - 1
            ],
            "end": [
                "line":      endLocation.line - 1,
                "character": endLocation.column - 1
            ]
        ]
    }
}
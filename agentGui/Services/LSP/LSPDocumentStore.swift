import Foundation

final class LSPDocumentStore {
    private var snapshotsByURI: [String: LSPDocumentSnapshot] = [:]

    func openDocument(uri: String, languageID: String, text: String) -> LSPDocumentSnapshot {
        let snapshot = LSPDocumentSnapshot(uri: uri, languageID: languageID, text: text, version: 1)
        snapshotsByURI[uri] = snapshot
        return snapshot
    }

    func updateDocument(uri: String, text: String) -> LSPDocumentSnapshot? {
        guard let current = snapshotsByURI[uri] else { return nil }
        let snapshot = LSPDocumentSnapshot(
            uri: current.uri,
            languageID: current.languageID,
            text: text,
            version: current.version + 1
        )
        snapshotsByURI[uri] = snapshot
        return snapshot
    }

    func closeDocument(uri: String) {
        snapshotsByURI.removeValue(forKey: uri)
    }

    func snapshot(for uri: String) -> LSPDocumentSnapshot? {
        snapshotsByURI[uri]
    }
}
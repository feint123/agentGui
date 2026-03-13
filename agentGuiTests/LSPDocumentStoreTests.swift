import Foundation
import Testing
@testable import agentGui

struct LSPDocumentStoreTests {

    @Test func openingDocumentStartsVersionAtOne() {
        let store = LSPDocumentStore()

        let snapshot = store.openDocument(
            uri: "file:///repo/src/app.ts",
            languageID: "typescript",
            text: "const x = 1"
        )

        #expect(snapshot.version == 1)
        #expect(snapshot.languageID == "typescript")
        #expect(snapshot.text == "const x = 1")
    }

    @Test func updatingDocumentIncrementsVersion() throws {
        let store = LSPDocumentStore()
        _ = store.openDocument(uri: "file:///repo/src/app.ts", languageID: "typescript", text: "const x = 1")

        let updated = try #require(
            store.updateDocument(uri: "file:///repo/src/app.ts", text: "const x = 2")
        )

        #expect(updated.version == 2)
        #expect(updated.text == "const x = 2")
    }

    @Test func repeatedUpdatesKeepIncrementingVersions() throws {
        let store = LSPDocumentStore()
        _ = store.openDocument(uri: "file:///repo/src/app.ts", languageID: "typescript", text: "const x = 1")
        _ = store.updateDocument(uri: "file:///repo/src/app.ts", text: "const x = 2")

        let updated = try #require(
            store.updateDocument(uri: "file:///repo/src/app.ts", text: "const x = 2")
        )

        #expect(updated.version == 3)
    }

    @Test func closingDocumentRemovesSnapshot() {
        let store = LSPDocumentStore()
        _ = store.openDocument(uri: "file:///repo/src/app.ts", languageID: "typescript", text: "const x = 1")

        store.closeDocument(uri: "file:///repo/src/app.ts")

        #expect(store.snapshot(for: "file:///repo/src/app.ts") == nil)
    }
}
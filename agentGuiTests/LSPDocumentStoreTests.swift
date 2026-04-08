import Testing
import Foundation
@testable import agentGui

struct LSPDocumentStoreTests {

    @Test func lspRangeConvertsSimpleSingleLineInsertion() {
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///a.py", languageID: "python", text: "hello world")
        // replace "world" (offset 6, length 5) → LSP range
        let range = store.lspRange(for: NSRange(location: 6, length: 5), uri: "file:///a.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 6)
        #expect(end?["line"] as? Int == 0)
        #expect(end?["character"] as? Int == 11)
    }

    @Test func lspRangeConvertsMultiLineRange() {
        // "abc\nxyz": line 0 = "abc\n" (4 UTF-16 units), line 1 = "xyz" (3 UTF-16 units)
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///b.py", languageID: "python", text: "abc\nxyz")
        // full range: offset 0 len 7
        let range = store.lspRange(for: NSRange(location: 0, length: 7), uri: "file:///b.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 0)
        #expect(end?["line"] as? Int == 1)
        #expect(end?["character"] as? Int == 3)
    }

    @Test func lspRangeConvertsEndOfFirstLine() {
        // "abc\nxyz" — range covering "c\n" (offset 2, length 2)
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///c.py", languageID: "python", text: "abc\nxyz")
        let range = store.lspRange(for: NSRange(location: 2, length: 2), uri: "file:///c.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 2)
        #expect(end?["line"] as? Int == 1)
        #expect(end?["character"] as? Int == 0)
    }

    @Test func lspRangeReturnsNilForUnknownURI() {
        let store = LSPDocumentStore()
        let range = store.lspRange(for: NSRange(location: 0, length: 1), uri: "file:///unknown.py")
        #expect(range == nil)
    }

    @Test func lspRangeUsesOldTextBeforeUpdate() {
        // verifies that range is computed before the snapshot text is replaced
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///d.py", languageID: "python", text: "hello world")
        // compute range on the OLD text
        let range = store.lspRange(for: NSRange(location: 6, length: 5), uri: "file:///d.py")
        // now update
        _ = store.updateDocument(uri: "file:///d.py", text: "hello Swift")
        // range should still be based on old text ("world" at 6..11)
        let end = range?["end"] as? [String: Any]
        #expect(end?["character"] as? Int == 11)
    }
}

import Foundation

struct LSPDocumentSnapshot: Equatable, Sendable {
    let uri: String
    let languageID: String
    let text: String
    let version: Int
}
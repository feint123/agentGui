import Foundation

enum EditorChangeOrigin: Equatable {
    case userEdit
    case externalReload
}

struct EditorChangeSet: Equatable {
    let version: Int
    let replacedRange: NSRange
    let insertedText: String
    let selectedRange: NSRange
    let origin: EditorChangeOrigin
}
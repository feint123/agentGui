import Foundation

enum FileEditorLoadedTextState {

    static func normalizedTextForInitialLoad(_ diskText: String, fileURL: URL) -> String {
        let document = BlockMarkdownCodec.parse(diskText, fileURL: fileURL)
        return BlockMarkdownCodec.serialize(document, fileURL: fileURL)
    }
}
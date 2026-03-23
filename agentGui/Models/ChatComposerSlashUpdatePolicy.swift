import Foundation

struct ChatComposerSlashUpdatePolicy {
    enum Action: Equatable {
        case ignore
        case clear
        case debouncedSync(ChatInputCommandParser.DetectedSlashQuery)
    }

    static func action(for text: String, currentQuery: String?) -> Action {
        guard let detected = ChatInputCommandParser.detectSlashQuery(in: text) else {
            return currentQuery == nil ? .ignore : .clear
        }

        guard detected.query != currentQuery else {
            return .ignore
        }

        return .debouncedSync(detected)
    }
}

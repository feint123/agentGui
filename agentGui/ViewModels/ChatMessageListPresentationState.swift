import Foundation

enum ChatMessageListPresentationState: Equatable {
    case loading
    case empty
    case content

    static func resolve(
        isInitialLoadInFlight: Bool,
        isClearingMessages: Bool,
        snapshot: ChatMessageListSnapshot
    ) -> ChatMessageListPresentationState {
        if isInitialLoadInFlight {
            return .loading
        }
        if isClearingMessages || snapshot.rows.isEmpty {
            return .empty
        }
        return .content
    }
}
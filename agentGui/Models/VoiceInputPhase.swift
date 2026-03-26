import Foundation

enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case recording
    case finalizing
    case failed(String)
}
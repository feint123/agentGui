import Foundation

enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case installingModel(progress: Double?, message: String)
    case recording
    case finalizing
    case failed(String)
}
import Foundation

enum StoryMemoryTaskType: String, Codable, Equatable, Sendable {
    case retrieveContext
    case evaluateWriteback
    case verifyContinuity
    case resolveProjectBinding
}

enum StoryMemoryDelegationStatus: String, Codable, Equatable, Sendable {
    case ready
    case projectNotBound
    case ambiguousProject
    case fallbackOnly
    case failed
}

enum StoryMemoryRiskLevel: String, Codable, Equatable, Sendable {
    case info
    case warning
    case critical
}

enum StoryMemoryWriteAction: String, Codable, Equatable, Sendable {
    case write
    case confirm
    case skip
}

struct StoryMemoryFactSlice: Codable, Equatable, Sendable {
    var title: String
    var detail: String
    var source: String
}

struct StoryMemoryRiskItem: Codable, Equatable, Sendable {
    var level: StoryMemoryRiskLevel
    var message: String
    var needsUserConfirmation: Bool
}

struct StoryMemoryWriteDecision: Codable, Equatable, Sendable {
    var action: StoryMemoryWriteAction
    var reason: String
    var candidateFacts: [StoryMemoryFactSlice]
}

struct StoryMemoryDelegationRequest: Codable, Equatable, Sendable {
    var projectId: String
    var projectTitle: String
    var taskType: StoryMemoryTaskType
    var userRequest: String
    var candidateText: String?
}

struct StoryMemoryDelegationResponse: Codable, Equatable, Sendable {
    var status: StoryMemoryDelegationStatus
    var taskType: StoryMemoryTaskType
    var facts: [StoryMemoryFactSlice]
    var inferences: [String]
    var risks: [StoryMemoryRiskItem]
    var writeDecision: StoryMemoryWriteDecision?
    var fallbackNote: String?
}

struct StoryMemoryDelegationPreparation: Equatable, Sendable {
    var request: StoryMemoryDelegationRequest?
    var preflightResponse: StoryMemoryDelegationResponse?
}
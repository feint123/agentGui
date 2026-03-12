import Foundation

struct AgentDefinitionDocument: Sendable, Equatable {
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let toolGroupNames: [String]
    let maxTurns: Int
    let userInvocable: Bool
    let subagentInvocable: Bool
    let outputContract: String
    let body: String
}
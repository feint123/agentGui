import Foundation

struct AgentDefinitionDocument: Sendable, Equatable {

    // MARK: - Required fields
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

    // MARK: - Optional execution-trait fields (S-A1)
    let modelPreference: SubagentModelPreference   // default: .inherit
    let effort: SubagentEffort?                    // default: nil
    let background: Bool                           // default: false
    let omitMainContext: Bool                      // default: false
    let initialPrompt: String?                     // default: nil
    let criticalReminder: String?                  // default: nil
    let color: String?                             // default: nil
    let disallowedToolNames: [String]              // default: []

    // MARK: - S-A2 One-Shot
    /// `true` 时子代理执行完成后不附加执行元数据 trailer，节省 token。
    let isOneShot: Bool                        // frontmatter: one-shot (default: false)
}
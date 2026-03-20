import Foundation

struct OpenCodeCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var defaultApprovalMode: String
    var environment: [String: String]
    var useACPStdIO: Bool

    static let `default` = OpenCodeCLIConfiguration(
        executablePath: "opencode",
        defaultModel: "",
        defaultApprovalMode: "default",
        environment: [:],
        useACPStdIO: true
    )
}
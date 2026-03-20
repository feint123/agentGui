import Foundation
import Observation

@MainActor
@Observable
final class ChatExecutionProviderAvailabilityModel {
    @ObservationIgnored private let probe: @Sendable (GitHubCopilotCLIConfiguration) async -> GitHubCopilotCLIAvailabilityStatus

    var copilotStatus: GitHubCopilotCLIAvailabilityStatus = .unknown

    init(
        probe: @escaping @Sendable (GitHubCopilotCLIConfiguration) async -> GitHubCopilotCLIAvailabilityStatus = ChatExecutionProviderAvailabilityModel.defaultProbe
    ) {
        self.probe = probe
    }

    func refreshCopilotStatus(configuration: GitHubCopilotCLIConfiguration) async {
        let status = await probe(configuration)
        if copilotStatus != status {
            copilotStatus = status
        }
    }

    private static func defaultProbe(configuration: GitHubCopilotCLIConfiguration) async -> GitHubCopilotCLIAvailabilityStatus {
        do {
            return try await GitHubCopilotCLIAvailabilityService().checkStatus(configuration: configuration)
        } catch {
            return GitHubCopilotCLIAvailabilityStatus(kind: .failed(error.localizedDescription), version: nil)
        }
    }
}
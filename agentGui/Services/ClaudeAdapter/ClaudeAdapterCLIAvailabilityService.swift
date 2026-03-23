import Foundation

typealias ClaudeAdapterCLIAvailabilityStatus = ACPCLIAvailabilityStatus

struct ClaudeAdapterCLIAvailabilityService {
    private let sharedService: ACPCLIAvailabilityService

    init(sharedService: ACPCLIAvailabilityService = ACPCLIAvailabilityService()) {
        self.sharedService = sharedService
    }

    func quickStatus(configuration: ClaudeAdapterCLIConfiguration) -> ClaudeAdapterCLIAvailabilityStatus {
        sharedService.quickStatus(
            executablePath: configuration.executablePath,
            displayName: "Claude Code"
        )
    }

    func checkStatus(configuration: ClaudeAdapterCLIConfiguration) async throws -> ClaudeAdapterCLIAvailabilityStatus {
        try await sharedService.checkStatus(
            executablePath: configuration.executablePath,
            displayName: "Claude Code"
        )
    }
}
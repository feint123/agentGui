import Foundation

typealias OpenCodeCLIAvailabilityStatus = ACPCLIAvailabilityStatus

struct OpenCodeCLIAvailabilityService {
    private let sharedService: ACPCLIAvailabilityService

    init(sharedService: ACPCLIAvailabilityService = ACPCLIAvailabilityService()) {
        self.sharedService = sharedService
    }

    func quickStatus(configuration: OpenCodeCLIConfiguration) -> OpenCodeCLIAvailabilityStatus {
        sharedService.quickStatus(
            executablePath: configuration.executablePath,
            displayName: "OpenCode"
        )
    }

    func checkStatus(configuration: OpenCodeCLIConfiguration) async throws -> OpenCodeCLIAvailabilityStatus {
        try await sharedService.checkStatus(
            executablePath: configuration.executablePath,
            displayName: "OpenCode"
        )
    }
}
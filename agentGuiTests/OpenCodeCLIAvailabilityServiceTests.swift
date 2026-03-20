import Foundation
import Testing
@testable import agentGui

struct OpenCodeCLIAvailabilityServiceTests {
    @Test func quickStatusReportsAvailableForResolvedExecutable() {
        let service = OpenCodeCLIAvailabilityService(
            sharedService: ACPCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            )
        )

        let status = service.quickStatus(
            configuration: OpenCodeCLIConfiguration(
                executablePath: "/usr/bin/env",
                defaultModel: "",
                defaultApprovalMode: "default",
                environment: [:],
                useACPStdIO: true
            )
        )

        #expect(status.kind == .available)
        #expect(status.displayName == "OpenCode")
    }

    @Test func quickStatusReportsMissingExecutable() {
        let service = OpenCodeCLIAvailabilityService(
            sharedService: ACPCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            )
        )

        let status = service.quickStatus(
            configuration: OpenCodeCLIConfiguration(
                executablePath: "/tmp/does-not-exist-opencode",
                defaultModel: "",
                defaultApprovalMode: "default",
                environment: [:],
                useACPStdIO: true
            )
        )

        #expect(status.kind == .notInstalled)
        #expect(status.summaryText == "未检测到 OpenCode 可执行文件")
    }
}
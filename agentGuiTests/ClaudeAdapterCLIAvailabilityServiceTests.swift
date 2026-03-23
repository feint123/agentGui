import Foundation
import Testing
@testable import agentGui

struct ClaudeAdapterCLIAvailabilityServiceTests {
    @Test func quickStatusReportsAvailableForResolvedExecutable() {
        let service = ClaudeAdapterCLIAvailabilityService(
            sharedService: ACPCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            )
        )

        let status = service.quickStatus(
            configuration: ClaudeAdapterCLIConfiguration(
                executablePath: "/usr/bin/env",
                defaultModel: "",
                defaultApprovalMode: "default",
                environment: [:],
                useACPStdIO: true
            )
        )

        #expect(status.kind == .available)
        #expect(status.displayName == "Claude Code")
    }

    @Test func quickStatusReportsMissingExecutable() {
        let service = ClaudeAdapterCLIAvailabilityService(
            sharedService: ACPCLIAvailabilityService(
                fileManager: .default,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                loginShellPathResolver: { _ in nil }
            )
        )

        let status = service.quickStatus(
            configuration: ClaudeAdapterCLIConfiguration(
                executablePath: "/tmp/does-not-exist-claude-adapter",
                defaultModel: "",
                defaultApprovalMode: "default",
                environment: [:],
                useACPStdIO: true
            )
        )

        #expect(status.kind == .notInstalled)
        #expect(status.summaryText == "未检测到 Claude Code 可执行文件")
    }
}
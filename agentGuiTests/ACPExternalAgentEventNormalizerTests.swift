import Foundation
import Testing
@testable import agentGui

struct ACPExternalAgentEventNormalizerTests {
    @Test func normalizerProjectsToolCallsAndPermissionsWithoutCopilotSpecificNames() {
        let normalizer = ACPExternalAgentEventNormalizer()
        let events = normalizer.normalize(update: .permission(samplePermissionRequest()))

        let expected: [ACPExternalAgentNormalizedEvent] = [
            .permissionRequested(id: "tool-1", kind: .execute, title: "run command", reason: "Need approval")
        ]

        #expect(events == expected)
    }

    @Test func normalizerIgnoresAvailableCommandsUpdate() {
        let normalizer = ACPExternalAgentEventNormalizer()

        let events = normalizer.normalize(
            update: .session(
                .availableCommandsUpdate(
                    ACPAvailableCommandsUpdatePayload(
                        availableCommands: [
                            ACPAvailableCommand(description: "Run review", input: nil, name: "review")
                        ]
                    )
                )
            )
        )

        #expect(events.isEmpty)
    }

    @Test func normalizerIgnoresPlanUpdate() {
        let normalizer = ACPExternalAgentEventNormalizer()

        let events = normalizer.normalize(
            update: .session(
                .plan(
                    ACPPlanUpdatePayload(
                        entries: [
                            ACPPlanEntry(content: "Inspect code", priority: .high, status: .inProgress)
                        ]
                    )
                )
            )
        )

        #expect(events.isEmpty)
    }

    private func samplePermissionRequest() -> ACPRequestPermissionRequest {
        ACPRequestPermissionRequest(
            meta: nil,
            options: [
                ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Need approval", optionID: "allow-once")
            ],
            sessionID: "remote-1",
            toolCall: ACPToolCallUpdatePayload(
                meta: nil,
                content: .object(["reason": .string("Need approval")]),
                kind: "run_in_terminal",
                locations: nil,
                rawInput: nil,
                rawOutput: nil,
                status: "pending",
                title: "run command",
                toolCallID: "tool-1"
            )
        )
    }
}
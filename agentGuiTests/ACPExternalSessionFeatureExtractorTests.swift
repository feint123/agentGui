import Foundation
import Testing
@testable import agentGui

struct ACPExternalSessionFeatureExtractorTests {
    @Test func extractorBuildsReplaceCommandsEventFromSessionUpdate() {
        let extractor = ACPExternalSessionFeatureExtractor()
        let events = extractor.extract(
            update: .session(
                .availableCommandsUpdate(
                    ACPAvailableCommandsUpdatePayload(
                        availableCommands: [
                            ACPAvailableCommand(
                                description: "Run review",
                                input: ACPAvailableCommandInput(hint: "scope"),
                                name: "review"
                            )
                        ]
                    )
                )
            ),
            providerID: .openCodeCLI,
            remoteSessionID: "remote-1"
        )

        #expect(events.count == 1)
        guard case .replaceCommands(let commands) = events[0] else {
            Issue.record("Expected replaceCommands event")
            return
        }

        #expect(commands.count == 1)
        #expect(commands[0].providerID == .openCodeCLI)
        #expect(commands[0].remoteSessionID == "remote-1")
        #expect(commands[0].name == "review")
        #expect(commands[0].description == "Run review")
        #expect(commands[0].inputHint == "scope")
    }

    @Test func extractorBuildsReplacePlanEventFromSessionUpdate() {
        let extractor = ACPExternalSessionFeatureExtractor()
        let events = extractor.extract(
            update: .session(
                .plan(
                    ACPPlanUpdatePayload(
                        entries: [
                            ACPPlanEntry(content: "Inspect code", priority: .high, status: .inProgress)
                        ]
                    )
                )
            ),
            providerID: .githubCopilotCLI,
            remoteSessionID: "remote-2"
        )

        #expect(events.count == 1)
        guard case .replacePlan(let snapshot) = events[0] else {
            Issue.record("Expected replacePlan event")
            return
        }

        #expect(snapshot.providerID == .githubCopilotCLI)
        #expect(snapshot.remoteSessionID == "remote-2")
        #expect(snapshot.entries == [ACPPlanEntry(content: "Inspect code", priority: .high, status: .inProgress)])
    }

    @Test func extractorIgnoresNonFeatureUpdates() {
        let extractor = ACPExternalSessionFeatureExtractor()
        let sessionEvents = extractor.extract(
            update: .session(
                .agentMessageChunk(
                    ACPContentChunk(
                        meta: nil,
                        content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "hello"))
                    )
                )
            ),
            providerID: .openCodeCLI,
            remoteSessionID: "remote-3"
        )
        let permissionEvents = extractor.extract(
            update: .permission(
                ACPRequestPermissionRequest(
                    meta: nil,
                    options: [
                        ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow", optionID: "allow-once")
                    ],
                    sessionID: "remote-3",
                    toolCall: ACPToolCallUpdatePayload(
                        meta: nil,
                        content: nil,
                        kind: "run_in_terminal",
                        locations: nil,
                        rawInput: nil,
                        rawOutput: nil,
                        status: "pending",
                        title: "run",
                        toolCallID: "tool-1"
                    )
                )
            ),
            providerID: .openCodeCLI,
            remoteSessionID: "remote-3"
        )

        #expect(sessionEvents.isEmpty)
        #expect(permissionEvents.isEmpty)
    }
}

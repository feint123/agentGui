import Foundation
import Testing
@testable import agentGui

struct ACPModelTests {

    @Test func initializeRequestEncodesCamelCaseProtocolFields() throws {
        let request = ACPInitializeRequest(
            meta: ["trace": .string("abc")],
            clientCapabilities: ACPClientCapabilities(
                meta: nil,
                filesystem: ACPFileSystemCapability(meta: nil, readTextFile: true, writeTextFile: false),
                terminal: true
            ),
            clientInfo: ACPImplementation(meta: nil, name: "agentGui", title: "Agent GUI", version: "1.0.0"),
            protocolVersion: ACPMethodCatalog.protocolVersion
        )

        let encoded = try ACPJSONValue.fromEncodable(request)
        let payload = try #require(encoded.objectValue)

        #expect(payload["protocolVersion"] == .number(1))
        #expect(payload["clientInfo"]?.objectValue?["name"] == .string("agentGui"))
        #expect(payload["clientCapabilities"]?.objectValue?["fs"]?.objectValue?["readTextFile"] == .bool(true))
        #expect(payload["_meta"]?.objectValue?["trace"] == .string("abc"))
    }

    @Test func sessionNotificationDecodesAgentMessageChunk() throws {
        let raw = Data("""
        {
          \"sessionId\": \"session-1\",
          \"update\": {
            \"sessionUpdate\": \"agent_message_chunk\",
            \"content\": {
              \"type\": \"text\",
              \"text\": \"hello\"
            }
          }
        }
        """.utf8)

        let notification = try JSONDecoder().decode(ACPSessionNotification.self, from: raw)

        #expect(notification.sessionID == "session-1")
        switch notification.update {
        case .agentMessageChunk(let chunk):
            switch chunk.content {
            case .text(let block):
                #expect(block.text == "hello")
            default:
                Issue.record("Expected text block in agent message chunk")
            }
        default:
            Issue.record("Expected agent message chunk session update")
        }
    }

        @Test func sessionUpdateDecodesAvailableCommandsUpdate() throws {
                let raw = Data("""
                {
                    "sessionId": "session-commands",
                    "update": {
                        "sessionUpdate": "available_commands_update",
                        "availableCommands": [
                            {
                                "name": "plan",
                                "description": "Create an implementation plan",
                                "input": {
                                    "hint": "what to plan"
                                }
                            }
                        ]
                    }
                }
                """.utf8)

                let notification = try JSONDecoder().decode(ACPSessionNotification.self, from: raw)

                switch notification.update {
                case .availableCommandsUpdate(let payload):
                        #expect(payload.availableCommands.count == 1)
                        #expect(payload.availableCommands.first?.name == "plan")
                        #expect(payload.availableCommands.first?.description == "Create an implementation plan")
                        #expect(payload.availableCommands.first?.input?.hint == "what to plan")
                default:
                        Issue.record("Expected available commands update")
                }
        }

        @Test func sessionUpdateDecodesPlanUpdate() throws {
                let raw = Data("""
                {
                    "sessionId": "session-plan",
                    "update": {
                        "sessionUpdate": "plan",
                        "entries": [
                            {
                                "content": "Inspect codebase",
                                "priority": "high",
                                "status": "pending"
                            },
                            {
                                "content": "Write tests",
                                "priority": "medium",
                                "status": "in_progress"
                            },
                            {
                                "content": "Ship feature",
                                "priority": "low",
                                "status": "completed"
                            }
                        ]
                    }
                }
                """.utf8)

                let notification = try JSONDecoder().decode(ACPSessionNotification.self, from: raw)

                switch notification.update {
                case .plan(let payload):
                        #expect(payload.entries.map(\.content) == ["Inspect codebase", "Write tests", "Ship feature"])
                        #expect(payload.entries.map(\.priority) == [.high, .medium, .low])
                        #expect(payload.entries.map(\.status) == [.pending, .inProgress, .completed])
                default:
                        Issue.record("Expected plan update")
                }
        }

        @Test func sessionUpdateEncodesPlanUpdate() throws {
                let update = ACPSessionUpdate.plan(
                        ACPPlanUpdatePayload(
                                entries: [
                                        ACPPlanEntry(content: "Inspect codebase", priority: .high, status: .inProgress)
                                ]
                        )
                )

                let encoded = try ACPJSONValue.fromEncodable(update)
                let payload = try #require(encoded.objectValue)

                #expect(payload["sessionUpdate"] == .string("plan"))
                let entries = try #require(payload["entries"]?.arrayValue)
                let entry = try #require(entries.first?.objectValue)
                #expect(entry["content"] == .string("Inspect codebase"))
                #expect(entry["priority"] == .string("high"))
                #expect(entry["status"] == .string("in_progress"))
        }

    @Test func promptRequestRoundTripsTextAndResourceLinkBlocks() throws {
        let request = ACPPromptRequest(
            meta: nil,
            prompt: [
                .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "ping")),
                .resourceLink(
                    ACPResourceLinkContentBlock(
                        meta: nil,
                        annotations: nil,
                        description: "workspace file",
                        mimeType: "text/plain",
                        name: "README.md",
                        size: 120,
                        title: "Readme",
                        uri: "file:///tmp/README.md"
                    )
                )
            ],
            sessionID: "session-2"
        )

        let encoded = try ACPJSONValue.fromEncodable(request)
        let decoded = try encoded.decode(ACPPromptRequest.self)

        #expect(decoded.sessionID == "session-2")
        #expect(decoded.prompt.count == 2)
        switch decoded.prompt[0] {
        case .text(let block):
            #expect(block.text == "ping")
        default:
            Issue.record("Expected first prompt block to be text")
        }
    }

    @Test func loadSessionRequestEncodesSessionIdentity() throws {
        let request = ACPLoadSessionRequest(
            meta: ["trace": .string("load-1")],
            cwd: "/tmp/workspace",
            mcpServers: [.object(["name": .string("local")])],
            sessionID: "session-3"
        )

        let encoded = try ACPJSONValue.fromEncodable(request)
        let payload = try #require(encoded.objectValue)

        #expect(payload["cwd"] == .string("/tmp/workspace"))
        #expect(payload["sessionId"] == .string("session-3"))
        #expect(payload["mcpServers"]?.objectValue == nil)
        #expect(payload["mcpServers"] == .array([.object(["name": .string("local")])]))
        #expect(payload["_meta"]?.objectValue?["trace"] == .string("load-1"))
    }

    @Test func permissionResponseRoundTripsSelectedOutcome() throws {
        let response = ACPRequestPermissionResponse(
            meta: nil,
            outcome: .selected(ACPSelectedPermissionOutcome(meta: nil, optionID: "allow-once"))
        )

        let encoded = try ACPJSONValue.fromEncodable(response)
        let decoded = try encoded.decode(ACPRequestPermissionResponse.self)

        switch decoded.outcome {
        case .selected(let outcome):
            #expect(outcome.optionID == "allow-once")
            #expect(outcome.outcome == "selected")
        default:
            Issue.record("Expected selected permission outcome")
        }
    }

    @Test func createTerminalRequestEncodesOutputByteLimitAndEnv() throws {
        let request = ACPCreateTerminalRequest(
            meta: nil,
            args: ["-lc", "echo hi"],
            command: "/bin/zsh",
            cwd: "/tmp/workspace",
            env: [ACPEnvVariable(meta: nil, name: "FOO", value: "bar")],
            outputByteLimit: 4096,
            sessionID: "session-4"
        )

        let encoded = try ACPJSONValue.fromEncodable(request)
        let payload = try #require(encoded.objectValue)

        #expect(payload["command"] == .string("/bin/zsh"))
        #expect(payload["outputByteLimit"] == .number(4096))
        #expect(payload["sessionId"] == .string("session-4"))
        #expect(payload["env"] == .array([.object(["name": .string("FOO"), "value": .string("bar")])]))
    }

        @Test func listSessionsResponseDecodesSessionInfoAndCursor() throws {
                let raw = Data("""
                {
                    "nextCursor": "cursor-2",
                    "sessions": [
                        {
                            "cwd": "/tmp/workspace",
                            "sessionId": "session-5",
                            "title": "Demo",
                            "updatedAt": "2026-03-19T12:00:00Z"
                        }
                    ]
                }
                """.utf8)

                let response = try JSONDecoder().decode(ACPListSessionsResponse.self, from: raw)

                #expect(response.nextCursor == "cursor-2")
                #expect(response.sessions.count == 1)
                #expect(response.sessions[0].sessionID == "session-5")
                #expect(response.sessions[0].cwd == "/tmp/workspace")
        }

        @Test func setSessionModeRequestEncodesModeAndSessionIdentifiers() throws {
                let request = ACPSetSessionModeRequest(meta: nil, modeID: "plan", sessionID: "session-6")

                let encoded = try ACPJSONValue.fromEncodable(request)
                let payload = try #require(encoded.objectValue)

                #expect(payload["modeId"] == .string("plan"))
                #expect(payload["sessionId"] == .string("session-6"))
        }

        @Test func authenticateRequestEncodesMethodIdentifier() throws {
                let request = ACPAuthenticateRequest(meta: ["trace": .string("auth-1")], methodID: "oauth")

                let encoded = try ACPJSONValue.fromEncodable(request)
                let payload = try #require(encoded.objectValue)

                #expect(payload["methodId"] == .string("oauth"))
                #expect(payload["_meta"]?.objectValue?["trace"] == .string("auth-1"))
        }
}
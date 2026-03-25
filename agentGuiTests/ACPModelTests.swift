import Foundation
import Testing
@testable import agentGui

struct ACPModelTests {

        @Test func agentCapabilitiesDecodeTypedCapabilityObjects() throws {
                let raw = Data("""
                {
                    "loadSession": true,
                    "mcpCapabilities": {
                        "http": true,
                        "sse": false
                    },
                    "sessionCapabilities": {
                        "list": {
                            "pageSize": 20
                        }
                    }
                }
                """.utf8)

                let capabilities = try JSONDecoder().decode(ACPAgentCapabilities.self, from: raw)

                #expect(capabilities.loadSession == true)
                #expect(capabilities.mcpCapabilities?.http == true)
                #expect(capabilities.mcpCapabilities?.sse == false)
                #expect(capabilities.sessionCapabilities?.list?.pageSize == 20)
        }

        @Test func newSessionResponseIgnoresNonStandardModelField() throws {
                let raw = Data("""
                {
                    "sessionId": "session-typed",
                    "configOptions": [
                        {
                            "type": "select",
                            "category": "model",
                            "currentValue": "gpt-5",
                            "options": [
                                {
                                    "name": "GPT-5",
                                    "value": "gpt-5"
                                }
                            ]
                        }
                    ],
                    "modes": {
                        "availableModes": [
                            {
                                "id": "ask",
                                "name": "Ask"
                            }
                        ],
                        "currentModeId": "ask"
                    },
                    "models": {
                        "currentModelId": "gpt-5"
                    }
                }
                """.utf8)

                let response = try JSONDecoder().decode(ACPNewSessionResponse.self, from: raw)

                #expect(response.sessionID == "session-typed")
                #expect(response.configOptions?.count == 1)
                #expect(response.configOptions?.first?.category == .model)
                #expect(response.configOptions?.first?.currentValue == "gpt-5")
                #expect(response.modes?.currentModeID == "ask")
                #expect(response.modes?.availableModes.first?.id == "ask")
        }

        @Test func loadSessionResponseDecodesTypedConfigOptionsAndModeState() throws {
                let raw = Data("""
                {
                    "configOptions": [
                        {
                            "type": "select",
                            "currentValue": "balanced",
                            "options": [
                                {
                                    "group": "reasoning",
                                    "name": "Reasoning",
                                    "options": [
                                        {
                                            "name": "Balanced",
                                            "value": "balanced",
                                            "description": "Default reasoning level"
                                        }
                                    ]
                                }
                            ]
                        }
                    ],
                    "modes": {
                        "availableModes": [
                            {
                                "id": "plan",
                                "name": "Plan",
                                "description": "Planning mode"
                            },
                            {
                                "id": "code",
                                "name": "Code"
                            }
                        ],
                        "currentModeId": "plan"
                    }
                }
                """.utf8)

                let response = try JSONDecoder().decode(ACPLoadSessionResponse.self, from: raw)

                #expect(response.configOptions?.count == 1)
                switch response.configOptions?.first?.options {
                case .grouped(let groups):
                        #expect(groups.count == 1)
                        #expect(groups.first?.group == "reasoning")
                        #expect(groups.first?.options.first?.value == "balanced")
                default:
                        Issue.record("Expected grouped config options")
                }
                #expect(response.modes?.currentModeID == "plan")
                #expect(response.modes?.availableModes.count == 2)
        }

        @Test func promptContentBlockDecodesExtendedContentTypes() throws {
                let imageRaw = ACPJSONValue.object([
                        "type": .string("image"),
                        "mimeType": .string("image/png"),
                        "data": .string("abcd")
                ])
                let audioRaw = ACPJSONValue.object([
                        "type": .string("audio"),
                        "mimeType": .string("audio/wav"),
                        "data": .string("efgh")
                ])

                let image = try imageRaw.decode(ACPPromptContentBlock.self)
                let audio = try audioRaw.decode(ACPPromptContentBlock.self)

                switch image {
                case .image(let block):
                        #expect(block.mimeType == "image/png")
                        #expect(block.data == "abcd")
                default:
                        Issue.record("Expected image content block")
                }

                switch audio {
                case .audio(let block):
                        #expect(block.mimeType == "audio/wav")
                        #expect(block.data == "efgh")
                default:
                        Issue.record("Expected audio content block")
                }
        }

        @Test func toolCallUpdateDecodesTypedKindAndStatus() throws {
                let raw = Data("""
                {
                    "toolCallId": "tool-typed",
                    "title": "Run command",
                    "kind": "execute",
                    "status": "in_progress",
                    "content": {
                        "type": "text",
                        "text": "running"
                    },
                    "locations": [
                        {
                            "path": "/tmp/project/main.swift",
                            "line": 3
                        }
                    ]
                }
                """.utf8)

                let payload = try JSONDecoder().decode(ACPToolCallUpdatePayload.self, from: raw)

                #expect(payload.toolCallID == "tool-typed")
                #expect(payload.kind == .execute)
                #expect(payload.status == .inProgress)
                #expect(payload.locations?.first?.path == "/tmp/project/main.swift")
                #expect(payload.locations?.first?.line == 3)
        }

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

            @Test func sessionUpdateDecodesCurrentModeConfigOptionAndSessionInfoUpdates() throws {
                let currentModeRaw = Data("""
                {
                    "sessionId": "session-mode",
                    "update": {
                    "sessionUpdate": "current_mode_update",
                    "currentModeId": "plan"
                    }
                }
                """.utf8)
                let configOptionRaw = Data("""
                {
                    "sessionId": "session-config",
                    "update": {
                    "sessionUpdate": "config_option_update",
                    "configOptions": [
                        {
                        "type": "select",
                        "category": "model",
                        "currentValue": "gpt-5",
                        "options": [
                            {
                                "name": "GPT-5",
                                "value": "gpt-5"
                            }
                        ]
                        }
                    ]
                    }
                }
                """.utf8)
                let sessionInfoRaw = Data("""
                {
                    "sessionId": "session-info",
                    "update": {
                    "sessionUpdate": "session_info_update",
                    "title": "Refactor Session",
                    "updatedAt": "2026-03-25T12:00:00Z"
                    }
                }
                """.utf8)

                let currentMode = try JSONDecoder().decode(ACPSessionNotification.self, from: currentModeRaw)
                let configOption = try JSONDecoder().decode(ACPSessionNotification.self, from: configOptionRaw)
                let sessionInfo = try JSONDecoder().decode(ACPSessionNotification.self, from: sessionInfoRaw)

                switch currentMode.update {
                case .currentModeUpdate(let payload):
                    #expect(payload.currentModeID == "plan")
                default:
                    Issue.record("Expected current mode update")
                }

                switch configOption.update {
                case .configOptionUpdate(let payload):
                    #expect(payload.configOptions.count == 1)
                    #expect(payload.configOptions.first?.type == "select")
                    #expect(payload.configOptions.first?.currentValue == "gpt-5")
                default:
                    Issue.record("Expected config option update")
                }

                switch sessionInfo.update {
                case .sessionInfoUpdate(let payload):
                    #expect(payload.title == "Refactor Session")
                    #expect(payload.updatedAt == "2026-03-25T12:00:00Z")
                default:
                    Issue.record("Expected session info update")
                }
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

        switch decoded.prompt[1] {
        case .resourceLink(let block):
            #expect(block.uri == "file:///tmp/README.md")
        default:
            Issue.record("Expected second prompt block to be resource link")
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

    @Test func setSessionConfigOptionResponseRoundTripsTypedOptions() throws {
        let response = ACPSetSessionConfigOptionResponse(
            meta: nil,
            configOptions: [
                ACPSessionConfigOption(
                    meta: nil,
                    category: .model,
                    currentValue: "gpt-5",
                    options: .ungrouped([
                        ACPSessionConfigSelectOption(
                            meta: nil,
                            description: "Primary model",
                            name: "GPT-5",
                            value: "gpt-5"
                        )
                    ]),
                    type: "select"
                )
            ]
        )

        let encoded = try ACPJSONValue.fromEncodable(response)
        let decoded = try encoded.decode(ACPSetSessionConfigOptionResponse.self)

        #expect(decoded.configOptions.count == 1)
        #expect(decoded.configOptions.first?.category == .model)
        switch decoded.configOptions.first?.options {
        case .ungrouped(let options):
            #expect(options.first?.value == "gpt-5")
            #expect(options.first?.description == "Primary model")
        default:
            Issue.record("Expected ungrouped config options")
        }
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
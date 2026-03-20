import Testing
@testable import agentGui

struct CopilotACPEventNormalizerTests {
    @Test func normalizesAssistantAndThinkingChunks() {
        let normalizer = CopilotACPEventNormalizer()

        let assistantEvents = normalizer.normalize(
            update: .session(
                .agentMessageChunk(
                    ACPContentChunk(
                        meta: nil,
                        content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "hello"))
                    )
                )
            )
        )
        let thinkingEvents = normalizer.normalize(
            update: .session(
                .agentThoughtChunk(
                    ACPContentChunk(
                        meta: nil,
                        content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "plan first"))
                    )
                )
            )
        )

        #expect(assistantEvents == [.assistantTextDelta("hello")])
        #expect(thinkingEvents == [.thinkingDelta("plan first")])
    }

    @Test func normalizesToolCallLifecycleAndPermissionRequest() {
        let normalizer = CopilotACPEventNormalizer()

        let startEvents = normalizer.normalize(
            update: .session(
                .toolCall(
                    ACPToolCall(
                        meta: nil,
                        content: nil,
                        kind: "execute",
                        locations: .object(["path": .string("/tmp/project")]),
                        rawInput: nil,
                        rawOutput: nil,
                        status: "in_progress",
                        title: "run tests",
                        toolCallID: "tool-1"
                    )
                )
            )
        )
        let updateEvents = normalizer.normalize(
            update: .session(
                .toolCallUpdate(
                    ACPToolCallUpdatePayload(
                        meta: nil,
                        content: nil,
                        kind: "execute",
                        locations: nil,
                        rawInput: nil,
                        rawOutput: .string("swift test"),
                        status: "success",
                        title: "run tests",
                        toolCallID: "tool-1"
                    )
                )
            )
        )
        let permissionEvents = normalizer.normalize(
            update: .permission(
                ACPRequestPermissionRequest(
                    meta: nil,
                    options: [
                        ACPPermissionOption(meta: nil, kind: .allowOnce, name: "Allow once", optionID: "allow")
                    ],
                    sessionID: "remote-1",
                    toolCall: ACPToolCallUpdatePayload(
                        meta: nil,
                        content: .object(["reason": .string("needs shell")]),
                        kind: "execute",
                        locations: nil,
                        rawInput: nil,
                        rawOutput: nil,
                        status: "pending",
                        title: "run tests",
                        toolCallID: "tool-1"
                    )
                )
            )
        )

        #expect(startEvents.contains(.toolCallStarted(id: "tool-1", kind: .execute, title: "run tests", filePath: "/tmp/project")))
        #expect(updateEvents == [.toolCallUpdated(id: "tool-1", kind: .execute, title: "run tests", filePath: nil, status: .success, rawOutput: "swift test")])
        #expect(permissionEvents == [.permissionRequested(id: "tool-1", kind: .execute, title: "run tests", reason: "needs shell")])
    }

    @Test func normalizesACPToolAliasesAcrossKindsAndTerminalStates() {
        let normalizer = CopilotACPEventNormalizer()

        let readEvents = normalizer.normalize(
            update: .session(
                .toolCall(
                    ACPToolCall(
                        meta: nil,
                        content: nil,
                        kind: "read_file",
                        locations: nil,
                        rawInput: .object(["file_path": .string("/tmp/notes.txt")]),
                        rawOutput: nil,
                        status: "completed",
                        title: "read notes",
                        toolCallID: "tool-read"
                    )
                )
            )
        )
        let editEvents = normalizer.normalize(
            update: .session(
                .toolCallUpdate(
                    ACPToolCallUpdatePayload(
                        meta: nil,
                        content: nil,
                        kind: "str_replace",
                        locations: nil,
                        rawInput: .object(["path": .string("/tmp/notes.txt")]),
                        rawOutput: .string("patched"),
                        status: "done",
                        title: "patch notes",
                        toolCallID: "tool-edit"
                    )
                )
            )
        )
        let searchEvents = normalizer.normalize(
            update: .session(
                .toolCallUpdate(
                    ACPToolCallUpdatePayload(
                        meta: nil,
                        content: nil,
                        kind: "grep_search",
                        locations: nil,
                        rawInput: nil,
                        rawOutput: .string("match"),
                        status: "errored",
                        title: "search notes",
                        toolCallID: "tool-search"
                    )
                )
            )
        )
        let askUserEvents = normalizer.normalize(
            update: .session(
                .toolCallUpdate(
                    ACPToolCallUpdatePayload(
                        meta: nil,
                        content: nil,
                        kind: "vscode_askQuestions",
                        locations: nil,
                        rawInput: nil,
                        rawOutput: nil,
                        status: "canceled",
                        title: "ask user",
                        toolCallID: "tool-ask"
                    )
                )
            )
        )

        #expect(readEvents.contains(.toolCallStarted(id: "tool-read", kind: .read, title: "read notes", filePath: "/tmp/notes.txt")))
        #expect(readEvents.contains(.toolCallUpdated(id: "tool-read", kind: .read, title: "read notes", filePath: "/tmp/notes.txt", status: .success, rawOutput: nil)))
        #expect(editEvents == [.toolCallUpdated(id: "tool-edit", kind: .edit, title: "patch notes", filePath: "/tmp/notes.txt", status: .success, rawOutput: "patched")])
        #expect(searchEvents == [.toolCallUpdated(id: "tool-search", kind: .search, title: "search notes", filePath: nil, status: .failed, rawOutput: "match")])
        #expect(askUserEvents == [.toolCallUpdated(id: "tool-ask", kind: .askUser, title: "ask user", filePath: nil, status: .cancelled, rawOutput: nil)])
    }
}
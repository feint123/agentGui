import Foundation

enum ACPExternalAgentUpdate: Equatable, Sendable {
    case session(ACPSessionUpdate)
    case sessionNotification(ACPSessionNotification)
    case permission(ACPRequestPermissionRequest)
}

enum ACPExternalAgentNormalizedEvent: Equatable, Sendable {
    case assistantTextDelta(String)
    case thinkingDelta(String)
    case toolCallStarted(id: String, kind: ToolKind, title: String?, filePath: String?)
    case toolCallUpdated(id: String, kind: ToolKind?, title: String?, filePath: String?, status: ToolStatus?, rawOutput: String?)
    case permissionRequested(id: String, kind: ToolKind, title: String?, reason: String?)
}

struct ACPExternalAgentEventNormalizer {
    func normalize(update: ACPExternalAgentUpdate) -> [ACPExternalAgentNormalizedEvent] {
        switch update {
        case .session(let sessionUpdate):
            return normalize(sessionUpdate: sessionUpdate)
        case .sessionNotification(let notification):
            return normalize(sessionUpdate: notification.update)
        case .permission(let request):
            return [
                .permissionRequested(
                    id: request.toolCall.toolCallID,
                    kind: toolKind(from: request.toolCall.kind),
                    title: request.toolCall.title,
                    reason: permissionReason(in: request)
                )
            ]
        }
    }

    private func normalize(sessionUpdate: ACPSessionUpdate) -> [ACPExternalAgentNormalizedEvent] {
        switch sessionUpdate {
        case .agentMessageChunk(let chunk):
            guard let text = text(from: chunk.content), !text.isEmpty else { return [] }
            return [.assistantTextDelta(text)]
        case .agentThoughtChunk(let chunk):
            guard let text = text(from: chunk.content), !text.isEmpty else { return [] }
            return [.thinkingDelta(text)]
        case .toolCall(let toolCall):
            return [
                .toolCallStarted(
                    id: toolCall.toolCallID,
                    kind: toolKind(from: toolCall.kind),
                    title: toolCall.title,
                    filePath: filePath(from: toolCall.locations) ?? filePath(from: toolCall.rawInput)
                ),
                .toolCallUpdated(
                    id: toolCall.toolCallID,
                    kind: toolKind(from: toolCall.kind),
                    title: toolCall.title,
                    filePath: filePath(from: toolCall.locations) ?? filePath(from: toolCall.rawInput),
                    status: toolStatus(from: toolCall.status),
                    rawOutput: string(from: toolCall.rawOutput) ?? string(from: toolCall.content)
                )
            ]
        case .toolCallUpdate(let payload):
            return [
                .toolCallUpdated(
                    id: payload.toolCallID,
                    kind: payload.kind.map(toolKind(from:)),
                    title: payload.title,
                    filePath: filePath(from: payload.locations) ?? filePath(from: payload.rawInput),
                    status: toolStatus(from: payload.status),
                    rawOutput: string(from: payload.rawOutput) ?? string(from: payload.content)
                )
            ]
        case .availableCommandsUpdate:
            return []
        case .plan:
            return []
        case .currentModeUpdate:
            return []
        case .configOptionUpdate:
            return []
        case .sessionInfoUpdate:
            return []
        case .usageUpdate:
            return []
        case .userMessageChunk:
            return []
        case .other:
            return []
        }
    }

    private func text(from block: ACPPromptContentBlock) -> String? {
        switch block {
        case .text(let value):
            return value.text
        case .resourceLink(let value):
            return value.description ?? value.title ?? value.name
        case .embeddedResource, .image, .audio, .other:
            return nil
        }
    }

    private func toolKind(from rawValue: ACPToolKind?) -> ToolKind {
        ToolKind.classify(rawName: rawValue?.rawValue)
    }

    private func toolStatus(from rawValue: ACPToolCallStatus?) -> ToolStatus? {
        ToolStatus.normalizedACPStatus(from: rawValue?.rawValue)
    }

    func permissionReason(in request: ACPRequestPermissionRequest) -> String? {
        if let reason = string(from: request.toolCall.content), !reason.isEmpty {
            return reason
        }

        return request.options.first?.name
    }

    private func filePath(from value: [ACPToolCallLocation]?) -> String? {
        guard let value else { return nil }

        for location in value {
            if let path = location.path, !path.isEmpty {
                return path
            }
            if let uri = location.uri, uri.hasPrefix("file://") {
                return URL(string: uri)?.path
            }
        }

        return nil
    }

    private func filePath(from value: ACPJSONValue?) -> String? {
        guard let value else { return nil }

        if let object = value.objectValue {
            for key in ["path", "filePath", "file_path", "targetPath", "target_path", "sourcePath", "source_path", "old_path", "new_path"] {
                if let path = object[key]?.stringValue, !path.isEmpty {
                    return path
                }
            }
            if let uri = object["uri"]?.stringValue, uri.hasPrefix("file://") {
                return URL(string: uri)?.path
            }
        }

        if case .array(let array) = value {
            for entry in array {
                if let path = filePath(from: entry) {
                    return path
                }
            }
        }

        return nil
    }

    private func string(from value: [ACPToolCallContent]?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.compactMap { item -> String? in
            switch item {
            case .content(let block): return text(from: block)
            case .diff(let diff): return diff.path
            case .terminal, .other: return nil
            }
        }.first
    }

    private func resourceLink(from value: ACPJSONValue) -> String? {
        if let object = value.objectValue {
            if let uri = object["uri"]?.stringValue, !uri.isEmpty {
                return uri
            }
            if let mimeType = object["mimeType"]?.stringValue, !mimeType.isEmpty {
                return mimeType
            }
            if let name = object["name"]?.stringValue, !name.isEmpty {
                return name
            }
        }

        return value.stringValue
    }

    private func string(from value: ACPJSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue {
            return text
        }
        if let object = value.objectValue {
            if let text = object["text"]?.stringValue {
                return text
            }
            if let content = object["content"]?.stringValue {
                return content
            }
            if let reason = object["reason"]?.stringValue {
                return reason
            }
        }
        return nil
    }
}
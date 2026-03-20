import Foundation

@MainActor
@Observable
final class ACPPermissionCenter: @unchecked Sendable {
    struct RequestSource: Equatable, Sendable {
        let providerID: ConversationExecutionProviderID
        let providerDisplayName: String
        let localSessionID: String

        init(providerID: ConversationExecutionProviderID, localSessionID: String) {
            self.providerID = providerID
            self.providerDisplayName = providerID.displayName
            self.localSessionID = localSessionID
        }
    }

    struct PendingOption: Identifiable, Equatable, Sendable {
        let id: String
        let kind: ACPPermissionOptionKind
        let name: String

        var isAllowOption: Bool {
            switch kind {
            case .allowOnce, .allowAlways:
                return true
            case .rejectOnce, .rejectAlways:
                return false
            }
        }
    }

    struct PendingRequest: Identifiable, Equatable, Sendable {
        let id: String
        let source: RequestSource
        let remoteSessionID: String
        let toolCallID: String
        let toolKind: ToolKind
        let title: String
        let reason: String?
        let options: [PendingOption]
        let requestedAt: Date
    }

    var pendingRequests: [PendingRequest] = []

    @ObservationIgnored
    private var continuations: [String: CheckedContinuation<ACPRequestPermissionResponse?, Never>] = [:]

    func resolve(
        request: ACPRequestPermissionRequest,
        source: RequestSource,
        policy: ToolAuthorizationPolicy
    ) async -> ACPRequestPermissionResponse? {
        guard ACPPermissionPolicyEvaluator.allowsToolCall(request.toolCall.kind, policy: policy) else {
            return ACPPermissionPolicyEvaluator.cancellationResponse()
        }

        guard policy.approvalMode == .alwaysRequireHuman else {
            return ACPPermissionPolicyEvaluator.defaultResponse(for: request, policy: policy)
        }

        let pendingRequest = PendingRequest(
            id: UUID().uuidString,
            source: source,
            remoteSessionID: request.sessionID,
            toolCallID: request.toolCall.toolCallID,
            toolKind: ToolKind.classify(rawName: request.toolCall.kind),
            title: Self.nonEmpty(request.toolCall.title) ?? ToolKind.classify(rawName: request.toolCall.kind).displayName,
            reason: Self.reason(from: request),
            options: request.options.map {
                PendingOption(id: $0.optionID, kind: $0.kind, name: $0.name)
            },
            requestedAt: Date()
        )

        pendingRequests.append(pendingRequest)

        return await withCheckedContinuation { continuation in
            continuations[pendingRequest.id] = continuation
        }
    }

    func pendingRequest(localSessionID: String, toolCallID: String) -> PendingRequest? {
        pendingRequests.last(where: {
            $0.source.localSessionID == localSessionID && $0.toolCallID == toolCallID
        })
    }

    func pendingRequestCount(for localSessionID: String) -> Int {
        pendingRequests.filter { $0.source.localSessionID == localSessionID }.count
    }

    func selectOption(requestID: String, optionID: String) {
        finish(
            requestID: requestID,
            response: ACPRequestPermissionResponse(
                meta: nil,
                outcome: .selected(ACPSelectedPermissionOutcome(meta: nil, optionID: optionID))
            )
        )
    }

    func cancel(requestID: String) {
        finish(requestID: requestID, response: ACPPermissionPolicyEvaluator.cancellationResponse())
    }

    func cancelRequests(for localSessionID: String) {
        let matchingIDs = pendingRequests
            .filter { $0.source.localSessionID == localSessionID }
            .map(\.id)

        for requestID in matchingIDs {
            finish(requestID: requestID, response: ACPPermissionPolicyEvaluator.cancellationResponse())
        }
    }

    private func finish(requestID: String, response: ACPRequestPermissionResponse?) {
        pendingRequests.removeAll { $0.id == requestID }
        continuations.removeValue(forKey: requestID)?.resume(returning: response)
    }

    private static func reason(from request: ACPRequestPermissionRequest) -> String? {
        if let content = request.toolCall.content {
            if let direct = string(from: content), !direct.isEmpty {
                return direct
            }
            if let object = content.objectValue {
                if let reason = object["reason"]?.stringValue, !reason.isEmpty {
                    return reason
                }
                if let text = object["text"]?.stringValue, !text.isEmpty {
                    return text
                }
            }
        }

        return Self.nonEmpty(request.options.first?.name)
    }

    private static func string(from value: ACPJSONValue) -> String? {
        value.stringValue
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
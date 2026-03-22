import Foundation
import SwiftAnthropic

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

    @ObservationIgnored
    private var requestScopes: [String: ToolApprovalScope] = [:]

    @ObservationIgnored
    private var rememberedSessionApprovals: [String: Set<ToolApprovalScope>] = [:]

    func resolve(
        request: ACPRequestPermissionRequest,
        source: RequestSource,
        policy: ToolAuthorizationPolicy
    ) async -> ACPRequestPermissionResponse? {
        guard ACPPermissionPolicyEvaluator.allowsToolCall(request.toolCall.kind, policy: policy) else {
            return ACPPermissionPolicyEvaluator.cancellationResponse()
        }

        let scope = ACPPermissionPolicyEvaluator.approvalScope(for: request.toolCall.kind)
        guard shouldQueueApproval(
            for: source.localSessionID,
            scope: scope,
            approvalMode: policy.approvalMode
        ) else {
            return ACPPermissionPolicyEvaluator.defaultResponse(
                for: request,
                policy: policy,
                preferPersistentGrant: hasRememberedApproval(for: source.localSessionID, scope: scope)
            )
        }

        let pendingRequest = PendingRequest(
            id: UUID().uuidString,
            source: source,
            remoteSessionID: request.sessionID,
            toolCallID: request.toolCall.toolCallID,
            toolKind: ToolKind.classify(rawName: request.toolCall.kind),
            title: Self.nonEmpty(request.toolCall.title) ?? ToolKind.classify(rawName: request.toolCall.kind).displayName,
            reason: Self.reason(from: request),
            options: ACPPermissionOptionPresentation.normalizedPendingOptions(from: request.options),
            requestedAt: Date()
        )

        return await enqueuePendingRequest(pendingRequest, scope: scope)
    }

    func resolveBuiltInToolApproval(
        toolName: String,
        input: MessageResponse.Content.Input,
        source: RequestSource,
        toolCallID: String,
        title: String?,
        approvalMode: ToolApprovalMode
    ) async -> ACPRequestPermissionResponse? {
        let scope = ACPPermissionPolicyEvaluator.approvalScope(
            for: toolName,
            command: input["command"]?.stringValue
        )
        let options = Self.defaultBuiltInOptions()

        guard shouldQueueApproval(
            for: source.localSessionID,
            scope: scope,
            approvalMode: approvalMode
        ) else {
            return Self.defaultBuiltInResponse(
                options: options,
                preferPersistentGrant: hasRememberedApproval(for: source.localSessionID, scope: scope)
            )
        }

        let pendingRequest = PendingRequest(
            id: UUID().uuidString,
            source: source,
            remoteSessionID: source.localSessionID,
            toolCallID: toolCallID,
            toolKind: ToolKind.classify(rawName: toolName, command: input["command"]?.stringValue),
            title: Self.nonEmpty(title) ?? ToolKind.classify(rawName: toolName).displayName,
            reason: Self.builtInReason(for: toolName, input: input),
            options: ACPPermissionOptionPresentation.normalizedPendingOptions(from: options),
            requestedAt: Date()
        )

        return await enqueuePendingRequest(pendingRequest, scope: scope)
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
        if let pendingRequest = pendingRequests.first(where: { $0.id == requestID }),
           let selectedOption = pendingRequest.options.first(where: { $0.id == optionID }),
           selectedOption.kind == .allowAlways,
           let scope = requestScopes[requestID] {
            rememberedSessionApprovals[pendingRequest.source.localSessionID, default: []].insert(scope)
        }

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
        requestScopes.removeValue(forKey: requestID)
        pendingRequests.removeAll { $0.id == requestID }
        continuations.removeValue(forKey: requestID)?.resume(returning: response)
    }

    private func enqueuePendingRequest(
        _ pendingRequest: PendingRequest,
        scope: ToolApprovalScope?
    ) async -> ACPRequestPermissionResponse? {
        return await withCheckedContinuation { continuation in
            continuations[pendingRequest.id] = continuation
            if let scope {
                requestScopes[pendingRequest.id] = scope
            }
            pendingRequests.append(pendingRequest)
        }
    }

    private func shouldQueueApproval(
        for localSessionID: String,
        scope: ToolApprovalScope?,
        approvalMode: ToolApprovalMode
    ) -> Bool {
        guard approvalMode == .defaultApprovals,
              let scope else {
            return false
        }

        return hasRememberedApproval(for: localSessionID, scope: scope) == false
    }

    private func hasRememberedApproval(
        for localSessionID: String,
        scope: ToolApprovalScope?
    ) -> Bool {
        guard let scope else {
            return false
        }

        return rememberedSessionApprovals[localSessionID]?.contains(scope) == true
    }

    private static func defaultBuiltInResponse(
        options: [ACPPermissionOption],
        preferPersistentGrant: Bool
    ) -> ACPRequestPermissionResponse {
        let preferredKinds: [ACPPermissionOptionKind] = preferPersistentGrant
            ? [.allowAlways, .allowOnce]
            : [.allowOnce, .allowAlways]

        for kind in preferredKinds {
            if let option = options.first(where: { $0.kind == kind }) {
                return ACPPermissionPolicyEvaluator.selectedResponse(optionID: option.optionID)
            }
        }

        return ACPPermissionPolicyEvaluator.cancellationResponse()
    }

    private static func defaultBuiltInOptions() -> [ACPPermissionOption] {
        [
            ACPPermissionOption(meta: nil, kind: .rejectOnce, name: "拒绝", optionID: "reject-once"),
            ACPPermissionOption(meta: nil, kind: .allowOnce, name: "允许一次", optionID: "allow-once"),
            ACPPermissionOption(meta: nil, kind: .allowAlways, name: "本会话始终允许", optionID: "allow-always")
        ]
    }

    private static func builtInReason(for toolName: String, input: MessageResponse.Content.Input) -> String? {
        switch toolName {
        case "bash":
            return Self.nonEmpty(input["command"]?.stringValue)
        case "web_search":
            return Self.nonEmpty(input["query"]?.stringValue)
        case "web_fetch":
            return Self.nonEmpty(input["url"]?.stringValue)
        default:
            return nil
        }
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
import Foundation

struct ACPPermissionPolicyEvaluator {
    nonisolated static func defaultResponse(
        for request: ACPRequestPermissionRequest,
        policy: ToolAuthorizationPolicy,
        preferPersistentGrant: Bool = false
    ) -> ACPRequestPermissionResponse {
        guard let selectedOption = bestAllowOption(
            from: request.options,
            policy: policy,
            toolKind: request.toolCall.kind,
            preferPersistentGrant: preferPersistentGrant
        ) else {
            return cancellationResponse()
        }

        return selectedResponse(optionID: selectedOption.optionID)
    }

    nonisolated static func defaultResponse(
        from options: [ACPPermissionOption],
        toolKind: String?,
        policy: ToolAuthorizationPolicy,
        preferPersistentGrant: Bool = false
    ) -> ACPRequestPermissionResponse {
        guard let selectedOption = bestAllowOption(
            from: options,
            policy: policy,
            toolKind: toolKind,
            preferPersistentGrant: preferPersistentGrant
        ) else {
            return cancellationResponse()
        }

        return selectedResponse(optionID: selectedOption.optionID)
    }

    nonisolated static func selectedResponse(optionID: String) -> ACPRequestPermissionResponse {
        ACPRequestPermissionResponse(
            meta: nil,
            outcome: .selected(ACPSelectedPermissionOutcome(meta: nil, optionID: optionID))
        )
    }

    nonisolated static func cancellationResponse() -> ACPRequestPermissionResponse {
        ACPRequestPermissionResponse(meta: nil, outcome: .cancelled(ACPDeniedPermissionOutcome()))
    }

    nonisolated static func allowsToolCall(_ toolKind: String?, policy: ToolAuthorizationPolicy) -> Bool {
        let classifiedKind = ToolKind.classify(rawName: toolKind)
        let normalizedKind = normalizedToolToken(toolKind)

        switch classifiedKind {
        case .read:
            return policy.level(for: .fileSystem) >= .observe
        case .edit, .delete:
            return policy.level(for: .fileSystem) >= .mutate
        case .execute:
            return policy.level(for: .shell) >= .execute
        case .fetch:
            return policy.level(for: .network) >= .observe
        case .search:
            if normalizedKind?.contains("web") == true || normalizedKind?.contains("github") == true {
                return policy.level(for: .network) >= .observe
            }
            return policy.level(for: .fileSystem) >= .observe
        default:
            if normalizedKind == "move" || normalizedKind == "rename" {
                return policy.level(for: .fileSystem) >= .mutate
            }
            return false
        }
    }

    nonisolated static func allowsToolCall(_ toolKind: ACPToolKind?, policy: ToolAuthorizationPolicy) -> Bool {
        allowsToolCall(toolKind?.rawValue, policy: policy)
    }

    nonisolated static func bestAllowOption(
        from options: [ACPPermissionOption],
        policy: ToolAuthorizationPolicy,
        toolKind: String?,
        preferPersistentGrant: Bool = false
    ) -> ACPPermissionOption? {
        guard allowsToolCall(toolKind, policy: policy) else {
            return nil
        }

        let preferredKinds: [ACPPermissionOptionKind] = preferPersistentGrant
            ? [.allowAlways, .allowOnce]
            : [.allowOnce, .allowAlways]

        for kind in preferredKinds {
            if let option = options.first(where: { $0.kind == kind }) {
                return option
            }
        }

        return nil
    }

    nonisolated static func bestAllowOption(
        from options: [ACPPermissionOption],
        policy: ToolAuthorizationPolicy,
        toolKind: ACPToolKind?,
        preferPersistentGrant: Bool = false
    ) -> ACPPermissionOption? {
        bestAllowOption(
            from: options,
            policy: policy,
            toolKind: toolKind?.rawValue,
            preferPersistentGrant: preferPersistentGrant
        )
    }

    nonisolated static func approvalScope(
        for toolKind: String?,
        command rawCommand: String? = nil
    ) -> ToolApprovalScope? {
        let classifiedKind = ToolKind.classify(rawName: toolKind, command: rawCommand)
        let normalizedKind = normalizedToolToken(toolKind)

        switch classifiedKind {
        case .execute:
            return .shell
        case .fetch:
            return .web
        case .search:
            if normalizedKind?.contains("web") == true || normalizedKind?.contains("browser") == true {
                return .web
            }
            return nil
        default:
            return nil
        }
    }

    nonisolated static func approvalScope(
        for toolKind: ACPToolKind?,
        command rawCommand: String? = nil
    ) -> ToolApprovalScope? {
        approvalScope(for: toolKind?.rawValue, command: rawCommand)
    }

    private nonisolated static func normalizedToolToken(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalized = value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
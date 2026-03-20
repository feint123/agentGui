import Foundation

struct ACPPermissionPolicyEvaluator {
    nonisolated static func defaultResponse(
        for request: ACPRequestPermissionRequest,
        policy: ToolAuthorizationPolicy
    ) -> ACPRequestPermissionResponse {
        guard policy.approvalMode != .alwaysRequireHuman,
              let selectedOption = bestAllowOption(from: request.options, policy: policy, toolKind: request.toolCall.kind) else {
            return cancellationResponse()
        }

        return ACPRequestPermissionResponse(
            meta: nil,
            outcome: .selected(ACPSelectedPermissionOutcome(meta: nil, optionID: selectedOption.optionID))
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

    nonisolated static func bestAllowOption(
        from options: [ACPPermissionOption],
        policy: ToolAuthorizationPolicy,
        toolKind: String?
    ) -> ACPPermissionOption? {
        guard allowsToolCall(toolKind, policy: policy) else {
            return nil
        }

        return options.first(where: { $0.kind == .allowOnce })
            ?? options.first(where: { $0.kind == .allowAlways })
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
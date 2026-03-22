import Foundation

enum ACPPermissionOptionPresentation {
    static func normalizedPendingOptions(
        from options: [ACPPermissionOption]
    ) -> [ACPPermissionCenter.PendingOption] {
        options
            .sorted { lhs, rhs in
                let lhsOrder = sortOrder(for: lhs.kind)
                let rhsOrder = sortOrder(for: rhs.kind)
                if lhsOrder == rhsOrder {
                    return lhs.optionID < rhs.optionID
                }
                return lhsOrder < rhsOrder
            }
            .map {
                ACPPermissionCenter.PendingOption(
                    id: $0.optionID,
                    kind: $0.kind,
                    name: displayName(for: $0.kind, fallback: $0.name)
                )
            }
    }

    static func displayName(
        for kind: ACPPermissionOptionKind,
        fallback: String
    ) -> String {
        switch kind {
        case .rejectOnce:
            return "拒绝"
        case .rejectAlways:
            return "本会话始终拒绝"
        case .allowOnce:
            return "允许一次"
        case .allowAlways:
            return "本会话始终允许"
        }
    }

    private static func sortOrder(for kind: ACPPermissionOptionKind) -> Int {
        switch kind {
        case .rejectOnce:
            return 0
        case .rejectAlways:
            return 1
        case .allowOnce:
            return 2
        case .allowAlways:
            return 3
        }
    }
}
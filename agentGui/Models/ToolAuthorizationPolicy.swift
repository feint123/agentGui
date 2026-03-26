import Foundation

enum ToolCapabilityID: String, Codable, CaseIterable, Hashable, Sendable {
    case fileSystem
    case shell
    case network
    case memory
    case lsp
    case workflowArtifacts
    case desktopObserve
    case desktopAct
}

enum ToolCapabilityLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case disabled
    case observe
    case execute
    case mutate

    private var rank: Int {
        switch self {
        case .disabled:
            return 0
        case .observe:
            return 1
        case .execute:
            return 2
        case .mutate:
            return 3
        }
    }

    static func < (lhs: ToolCapabilityLevel, rhs: ToolCapabilityLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    static func min(_ lhs: ToolCapabilityLevel, _ rhs: ToolCapabilityLevel) -> ToolCapabilityLevel {
        lhs < rhs ? lhs : rhs
    }
}

enum ToolAuthorizationPreset: String, Codable, CaseIterable, Sendable {
    case observeOnly
    case maintain
    case actLimited
    case custom

    var displayName: String {
        switch self {
        case .observeOnly:
            return "Observe Only"
        case .maintain:
            return "Maintain"
        case .actLimited:
            return "Act Limited"
        case .custom:
            return "Custom"
        }
    }
}

enum ToolApprovalMode: String, Sendable {
    case defaultApprovals = "default"
    case bypassApprovals = "never"

    static func resolved(from rawValue: String?) -> ToolApprovalMode {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "never", "none", "bypass":
            return .bypassApprovals
        default:
            return .defaultApprovals
        }
    }
}

extension ToolApprovalMode: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.resolved(from: rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ToolApprovalScope: String, Hashable, Sendable {
    case shell
    case web
}

struct ToolAuthorizationPolicy: Codable, Equatable, Sendable {
    var preset: ToolAuthorizationPreset
    var capabilityLevels: [ToolCapabilityID: ToolCapabilityLevel]
    var approvalMode: ToolApprovalMode

    nonisolated
    init(
        preset: ToolAuthorizationPreset = .observeOnly,
        capabilityLevels: [ToolCapabilityID: ToolCapabilityLevel]? = nil,
        approvalMode: ToolApprovalMode = .bypassApprovals
    ) {
        self.preset = preset
        self.capabilityLevels = capabilityLevels ?? Self.defaultCapabilityLevels(for: preset)
        self.approvalMode = approvalMode
        normalizePresetIfNeeded()
    }

    func level(for capabilityID: ToolCapabilityID) -> ToolCapabilityLevel {
        capabilityLevels[capabilityID] ?? .disabled
    }

    mutating func applyPreset(_ preset: ToolAuthorizationPreset) {
        self.preset = preset
        capabilityLevels = Self.defaultCapabilityLevels(for: preset)
    }

    mutating func setLevel(_ level: ToolCapabilityLevel, for capabilityID: ToolCapabilityID) {
        capabilityLevels[capabilityID] = level
        normalizePresetIfNeeded()
    }

    mutating func normalizePresetIfNeeded() {
        if capabilityLevels == Self.defaultCapabilityLevels(for: .observeOnly) {
            preset = .observeOnly
        } else if capabilityLevels == Self.defaultCapabilityLevels(for: .maintain) {
            preset = .maintain
        } else if capabilityLevels == Self.defaultCapabilityLevels(for: .actLimited) {
            preset = .actLimited
        } else {
            preset = .custom
        }
    }

    nonisolated
    static func defaultCapabilityLevels(for preset: ToolAuthorizationPreset) -> [ToolCapabilityID: ToolCapabilityLevel] {
        var levels = Dictionary(uniqueKeysWithValues: ToolCapabilityID.allCases.map { ($0, ToolCapabilityLevel.disabled) })

        switch preset {
        case .observeOnly:
            levels[.network] = .observe
        case .maintain:
            levels[.network] = .observe
            levels[.memory] = .mutate
        case .actLimited:
            levels[.fileSystem] = .mutate
            levels[.shell] = .execute
            levels[.network] = .observe
            levels[.memory] = .mutate
        case .custom:
            break
        }

        return levels
    }
}

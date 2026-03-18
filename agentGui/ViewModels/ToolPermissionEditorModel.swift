import Foundation

struct ToolPermissionEditorModel {
    enum Option {
        case allowFileWrite
        case allowBash
        case allowMemoryMutation
        case allowNetworkAccess
    }

    var policy: ToolAuthorizationPolicy

    mutating func setPreset(_ preset: ToolAuthorizationPreset) {
        policy.applyPreset(preset)
    }

    func presetDescription(for preset: ToolAuthorizationPreset) -> String {
        switch preset {
        case .observeOnly:
            return "只读巡检模式。允许受控联网查询，不允许文件写入、Bash 或记忆写入。"
        case .maintain:
            return "维护模式。适合摘要、整理和记忆维护，仍不允许文件写入或 Bash。"
        case .actLimited:
            return "受限执行模式。可按下方开关开放文件写入、Bash、记忆和联网工具。"
        case .custom:
            return "自定义模式。当前工具权限组合已偏离预设档位。"
        }
    }

    func isOptionAvailable(_ option: Option) -> Bool {
        switch (policy.preset, option) {
        case (.observeOnly, .allowFileWrite), (.observeOnly, .allowBash), (.observeOnly, .allowMemoryMutation):
            return false
        case (.maintain, .allowFileWrite), (.maintain, .allowBash):
            return false
        default:
            return true
        }
    }

    func restrictionExplanation(for option: Option) -> String? {
        guard !isOptionAvailable(option) else { return nil }

        switch (policy.preset, option) {
        case (.observeOnly, .allowFileWrite):
            return "Observe Only 只允许只读巡检，不能写文件。"
        case (.observeOnly, .allowBash):
            return "Observe Only 禁止执行 Bash。"
        case (.observeOnly, .allowMemoryMutation):
            return "Observe Only 禁止修改记忆。"
        case (.maintain, .allowFileWrite):
            return "Maintain 侧重整理与维护，不允许直接写文件。"
        case (.maintain, .allowBash):
            return "Maintain 不允许执行 Bash。"
        default:
            return nil
        }
    }

    func isEnabled(_ option: Option) -> Bool {
        switch option {
        case .allowFileWrite:
            return policy.level(for: .fileSystem) >= .mutate
        case .allowBash:
            return policy.level(for: .shell) >= .execute
        case .allowMemoryMutation:
            return policy.level(for: .memory) >= .mutate
        case .allowNetworkAccess:
            return policy.level(for: .network) >= .observe
        }
    }

    mutating func setEnabled(_ enabled: Bool, for option: Option) {
        switch option {
        case .allowFileWrite:
            policy.setLevel(enabled ? .mutate : .disabled, for: .fileSystem)
        case .allowBash:
            policy.setLevel(enabled ? .execute : .disabled, for: .shell)
        case .allowMemoryMutation:
            policy.setLevel(enabled ? .mutate : .disabled, for: .memory)
        case .allowNetworkAccess:
            policy.setLevel(enabled ? .observe : .disabled, for: .network)
        }
    }
}

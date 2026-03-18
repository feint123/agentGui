import SwiftUI

struct ToolPermissionSectionView: View {
    @Binding var policy: ToolAuthorizationPolicy
    var headerTitle: String = "工具权限"
    var footerText: String = "信任等级会约束下方工具上限。降低等级时，超出该等级允许范围的工具开关会自动关闭。"

    private var editorModel: ToolPermissionEditorModel {
        ToolPermissionEditorModel(policy: policy)
    }

    var body: some View {
        Section {
            Picker("信任等级", selection: Binding(
                get: { policy.preset },
                set: {
                    var updated = ToolPermissionEditorModel(policy: policy)
                    updated.setPreset($0)
                    policy = updated.policy
                }
            )) {
                Text(ToolAuthorizationPreset.observeOnly.displayName).tag(ToolAuthorizationPreset.observeOnly)
                Text(ToolAuthorizationPreset.maintain.displayName).tag(ToolAuthorizationPreset.maintain)
                Text(ToolAuthorizationPreset.actLimited.displayName).tag(ToolAuthorizationPreset.actLimited)
                if policy.preset == .custom {
                    Text(ToolAuthorizationPreset.custom.displayName).tag(ToolAuthorizationPreset.custom)
                }
            }

            Text(editorModel.presetDescription(for: policy.preset))
                .font(.caption)
                .foregroundStyle(.secondary)

            optionToggle("允许文件写入", option: .allowFileWrite)
            optionToggle("允许 Bash", option: .allowBash)
            optionToggle("允许修改记忆", option: .allowMemoryMutation)
            optionToggle("允许联网工具", option: .allowNetworkAccess)
        } header: {
            Text(headerTitle)
        } footer: {
            Text(footerText)
        }
    }

    @ViewBuilder
    private func optionToggle(_ title: String, option: ToolPermissionEditorModel.Option) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { editorModel.isEnabled(option) },
                set: {
                    var updated = ToolPermissionEditorModel(policy: policy)
                    updated.setEnabled($0, for: option)
                    policy = updated.policy
                }
            ))
            .disabled(!editorModel.isOptionAvailable(option))

            if let explanation = editorModel.restrictionExplanation(for: option) {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
import SwiftUI

struct ACPProviderListSection: View {
    let profiles: [ACPProviderProfile]

    var body: some View {
        Section {
            if profiles.isEmpty {
                Text("还没有可用的 ACP Provider。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { _, profile in
                    NavigationLink(value: ACPProviderEditorRoute.provider(profile.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(profile.displayName)
                                    Text(profile.isEnabled ? "已启用" : "已停用")
                                        .font(.caption)
                                        .foregroundStyle(profile.isEnabled ? Color.green : Color.secondary)
                                }
                                Text(profile.executablePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let snapshot = profile.validationSnapshot,
                                   !snapshot.message.isEmpty {
                                    Text(snapshot.message)
                                        .font(.caption)
                                        .foregroundStyle(snapshot.status == .ready ? Color.secondary : Color.red)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.executors.providerRow.\(profile.id.uuidString)")
                }
            }
        } header: {
            Text("ACP Providers")
        } footer: {
            Text("启用的 Provider 会出现在默认执行器选择里；点击列表进入详情页编辑，保存启用状态时会先执行可执行文件和 initialize 校验。")
        }
    }
}
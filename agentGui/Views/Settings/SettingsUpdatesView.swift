import SwiftUI

struct SettingsUpdatesView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            updateChannelSection
            automaticBehaviorSection
        }
        .formStyle(.grouped)
        .navigationTitle("更新")
    }

    private var updateChannelSection: some View {
        Section {
            Picker("更新渠道", selection: store.updateChannelSelectionBinding()) {
                Text("稳定版").tag(SparkleUpdateChannel.stable)
                Text("Beta").tag(SparkleUpdateChannel.beta)
            }
        } header: {
            Text("接收版本")
        } footer: {
            Text("切换渠道会保存到应用设置，并通知更新服务刷新下一次检查周期。")
        }
    }

    private var automaticBehaviorSection: some View {
        Section {
            Toggle("自动检查更新", isOn: store.automaticUpdateChecksBinding())
            Toggle("自动下载更新", isOn: store.automaticUpdateDownloadsBinding())
        } header: {
            Text("Sparkle 管理")
        } footer: {
            Text(store.canConfigureAutomaticUpdates ? "这些选项直接映射到 Sparkle 的运行时偏好，不会额外写入应用设置模型。" : "当前构建尚未接入可用的 Sparkle 运行时，自动更新选项暂不可用。")
        }
        .disabled(!store.canConfigureAutomaticUpdates)
    }
}
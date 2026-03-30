import SwiftUI

struct AgentTeamSessionView: View {
    static let panelAccessibilityIdentifier = "panel.agentTeam"
    static let placeholderAccessibilityIdentifier = "agentTeam.placeholder"
    static let titleAccessibilityIdentifier = "agentTeam.title"

    let session: Session
    let state: AgentTeamSessionState?

    init(session: Session, state: AgentTeamSessionState? = nil) {
        self.session = session
        self.state = state ?? session.agentTeamState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(session.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier(Self.titleAccessibilityIdentifier)

                Text("Feature 1 壳层已启用。该会话使用独立 Agent Team surface，不显示普通消息列表或输入框。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(Self.placeholderAccessibilityIdentifier)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    metadataLabel("来源")
                    Text(sourceTitle)
                }
                GridRow {
                    metadataLabel("模式")
                    Text(modeTitle)
                }
                GridRow {
                    metadataLabel("状态")
                    Text(statusTitle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
        .accessibilityIdentifier(Self.panelAccessibilityIdentifier)
    }

    private var sourceTitle: String {
        let source = state?.sourceSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source.isEmpty ? "无来源聊天" : source
    }

    private var modeTitle: String {
        switch state?.mode ?? .executionDelivery {
        case .executionDelivery:
            return "Execution Delivery"
        }
    }

    private var statusTitle: String {
        switch state?.status ?? .created {
        case .created:
            return "Created"
        case .active:
            return "Active"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    private func metadataLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
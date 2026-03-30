import SwiftUI

struct AgentTeamSessionView: View {
    static let panelAccessibilityIdentifier = "panel.agentTeam"
    static let missionHeaderAccessibilityIdentifier = "agentTeam.missionHeader"
    static let rosterAccessibilityIdentifier = "agentTeam.roster"
    static let boardAccessibilityIdentifier = "agentTeam.board"
    static let inspectorAccessibilityIdentifier = "agentTeam.inspector"
    static let placeholderAccessibilityIdentifier = "agentTeam.placeholder"
    static let titleAccessibilityIdentifier = "agentTeam.title"

    let session: Session
    let state: AgentTeamSessionState?

    init(session: Session, state: AgentTeamSessionState? = nil) {
        self.session = session
        self.state = state ?? session.agentTeamState
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AgentTeamMissionHeaderView(presentation: presentation.header)
                    .accessibilityIdentifier(Self.missionHeaderAccessibilityIdentifier)

                ViewThatFits(in: .horizontal) {
                    horizontalShell
                    verticalShell
                }

                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
        .accessibilityIdentifier(Self.panelAccessibilityIdentifier)
    }

    private var presentation: AgentTeamWorkbenchPresentation {
        .make(session: session, state: state)
    }

    private var horizontalShell: some View {
        HStack(alignment: .top, spacing: 16) {
            AgentTeamRosterPanelView(items: presentation.roster)
                .frame(width: 260, alignment: .topLeading)
                .accessibilityIdentifier(Self.rosterAccessibilityIdentifier)

            AgentTeamBoardPanelView(columns: presentation.boardColumns)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .accessibilityIdentifier(Self.boardAccessibilityIdentifier)

            AgentTeamInspectorPanelView(summary: presentation.inspector)
                .frame(width: 300, alignment: .topLeading)
                .accessibilityIdentifier(Self.inspectorAccessibilityIdentifier)
        }
    }

    private var verticalShell: some View {
        VStack(alignment: .leading, spacing: 16) {
            AgentTeamRosterPanelView(items: presentation.roster)
                .accessibilityIdentifier(Self.rosterAccessibilityIdentifier)

            AgentTeamBoardPanelView(columns: presentation.boardColumns)
                .accessibilityIdentifier(Self.boardAccessibilityIdentifier)

            AgentTeamInspectorPanelView(summary: presentation.inspector)
                .accessibilityIdentifier(Self.inspectorAccessibilityIdentifier)
        }
    }
}
import SwiftUI
import SwiftData

struct AgentTeamSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService

    static let panelAccessibilityIdentifier = "panel.agentTeam"
    static let missionHeaderAccessibilityIdentifier = "agentTeam.missionHeader"
    static let rosterAccessibilityIdentifier = "agentTeam.roster"
    static let boardAccessibilityIdentifier = "agentTeam.claimBoard"
    static let inspectorAccessibilityIdentifier = "agentTeam.inspector"
    static let placeholderAccessibilityIdentifier = "agentTeam.placeholder"
    static let titleAccessibilityIdentifier = "agentTeam.title"
    static let constraintsAccessibilityIdentifier = "agentTeam.brief.constraintsList"
    static let acceptanceAccessibilityIdentifier = "agentTeam.brief.acceptanceList"
    static let contextSummaryAccessibilityIdentifier = "agentTeam.brief.contextSummary"
    static let claimOwnerAccessibilityIdentifier = "agentTeam.claim.owner"
    static let claimStatusAccessibilityIdentifier = "agentTeam.claim.status"
    static let taskDependencyAccessibilityIdentifier = "agentTeam.task.dependencies"
    static let taskBlockerAccessibilityIdentifier = "agentTeam.task.blocker"
    static let commitBarAccessibilityIdentifier = "agentTeam.commitBar"
    static let launchButtonAccessibilityIdentifier = "agentTeam.commitBar.launch"
    static let stopButtonAccessibilityIdentifier = "agentTeam.commitBar.stop"

    let session: Session
    let state: AgentTeamSessionState?

    @State private var isLaunching = false
    @State private var launchError: String?

    init(session: Session, state: AgentTeamSessionState? = nil) {
        self.session = session
        self.state = state ?? session.agentTeamState
    }

    var body: some View {
        VStack(spacing: 0) {
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

            AgentTeamCommitBarView(
                status: state?.status ?? .created,
                isLaunching: isLaunching,
                commitBarState: presentation.commitBarState,
                onLaunch: { Task { await launchTeam() } },
                onStop: { Task { await claudeService.stopTeamMission(session: session, modelContext: modelContext) } }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.textBackgroundColor))
        .alert("Team 启动失败", isPresented: .constant(launchError != nil)) {
            Button("确定") { launchError = nil }
        } message: {
            if let launchError { Text(launchError) }
        }
        .accessibilityIdentifier(Self.panelAccessibilityIdentifier)
        .task(id: session.sessionId) {
            let settings = AppSettings.getOrCreate(in: modelContext)
            let providerReference = session.agentTeamState?.claimBoardState?.preferredExecutionTarget()?.providerReference
                ?? ConversationExecutionProviderRegistry.resolveProviderReference(for: session, settings: settings)
            await claudeService.handleExecutionProviderSelectionChange(
                session: session,
                selectedProviderReference: providerReference,
                modelContext: modelContext,
                trigger: .sessionBootstrap
            )
        }
    }

    private var presentation: AgentTeamWorkbenchPresentation {
        .make(session: session, state: state, modelContext: modelContext)
    }

    private var horizontalShell: some View {
        HStack(alignment: .top, spacing: 16) {
            AgentTeamRosterPanelView(items: presentation.roster)
                .frame(width: 260, alignment: .topLeading)
                .accessibilityIdentifier(Self.rosterAccessibilityIdentifier)

            AgentTeamBoardPanelView(columns: presentation.boardColumns, onCardDone: handleCardDone)
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

            AgentTeamBoardPanelView(columns: presentation.boardColumns, onCardDone: handleCardDone)
                .accessibilityIdentifier(Self.boardAccessibilityIdentifier)

            AgentTeamInspectorPanelView(summary: presentation.inspector)
                .accessibilityIdentifier(Self.inspectorAccessibilityIdentifier)
        }
    }

    // MARK: - Actions

    private func launchTeam() async {
        isLaunching = true
        launchError = nil
        do {
            try await claudeService.launchTeamMission(session: session, modelContext: modelContext)
        } catch {
            launchError = error.localizedDescription
        }
        isLaunching = false
    }

    private func handleCardDone(_ cardIDString: String) {
        guard let cardID = UUID(uuidString: cardIDString),
              let state else { return }
        do {
            try AgentTeamLaunchCoordinator().markCardDone(cardID, in: state)
            try? modelContext.save()
        } catch {
            launchError = error.localizedDescription
        }
    }
}
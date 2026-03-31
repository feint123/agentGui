import Foundation
import SwiftData

extension ClaudeService {

    /// Launches a team mission for the given session:
    ///   1. Calls `AgentTeamLaunchCoordinator.launch` to auto-claim the first
    ///      briefed card and advance status to `.active`.
    ///   2. Persists the updated state.
    ///   3. Dispatches the generated mission prompt via the normal execution path,
    ///      which already reads `claimBoardState` to resolve the correct provider
    ///      reference and team context.
    func launchTeamMission(
        session: Session,
        modelContext: ModelContext
    ) async throws {
        lastError = nil
        do {
            guard let state = session.agentTeamState else { return }
            let launchResult = try AgentTeamLaunchCoordinator().launch(state: state)
            try? modelContext.save()

            let settings = AppSettings.getOrCreate(in: modelContext)
            let modelId = SessionExecutionPreferencesResolver.builtInModelID(
                for: session,
                settings: settings
            )
            try await sendMessage(
                text: launchResult.missionPrompt,
                session: session,
                modelId: modelId,
                modelContext: modelContext
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Stops an active team mission:
    ///   1. Updates `AgentTeamRunStatus` to `.failed`.
    ///   2. Cancels any in-flight execution for the session.
    func stopTeamMission(
        session: Session,
        modelContext: ModelContext
    ) async {
        if let state = session.agentTeamState {
            AgentTeamLaunchCoordinator().stop(state: state)
            try? modelContext.save()
        }
        await cancelExecution(session: session, modelContext: modelContext)
    }
}

import Foundation
import SwiftData

extension ClaudeService {

    /// Launches a team mission for the given session using a two-phase approach:
    ///   Phase 1: Auto-claim the primary card (card → .claimed), save, yield to SwiftUI
    ///            so the "Claimed" column becomes visible to the user.
    ///   Phase 2: Advance card to .working, save, then dispatch the mission prompt.
    func launchTeamMission(
        session: Session,
        modelContext: ModelContext
    ) async throws {
        lastError = nil
        do {
            guard let state = session.agentTeamState else { return }
            let coordinator = AgentTeamLaunchCoordinator()

            // Phase 1: claim — persists .claimed state so SwiftUI can render it
            let claimResult = try coordinator.claimPrimaryCard(state: state)
            try? modelContext.save()

            // Brief yield so SwiftUI observes the Claimed column before execution
            try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms

            // Phase 2: advance to .working, then dispatch
            try coordinator.beginWorking(cardID: claimResult.primaryCardID, in: state)
            try? modelContext.save()

            let settings = AppSettings.getOrCreate(in: modelContext)
            let modelId = SessionExecutionPreferencesResolver.builtInModelID(
                for: session,
                settings: settings
            )
            try await sendMessage(
                text: claimResult.missionPrompt,
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

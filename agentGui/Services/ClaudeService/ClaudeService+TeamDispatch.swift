import Foundation
import SwiftData

extension ClaudeService {

    /// Launches all ready task cards in waves:
    ///   Wave N:
    ///     1. claimBatch — claim all dispatchable `.briefed` cards (dependency-clear, within budget)
    ///     2. Save + 400ms yield — SwiftUI renders "Claimed" column
    ///     3. beginWorking for each card
    ///     4. Save
    ///     5. Dispatch each card sequentially via sendMessage
    ///     6. After each sendMessage returns, markCardDone + save
    ///   Repeat until claimBatch returns [] (no more eligible cards).
    func launchTeamMission(
        session: Session,
        modelContext: ModelContext
    ) async throws {
        lastError = nil
        do {
            guard let state = session.agentTeamState else { return }
            let coordinator = AgentTeamLaunchCoordinator()
            let settings = AppSettings.getOrCreate(in: modelContext)
            let modelId = SessionExecutionPreferencesResolver.builtInModelID(
                for: session,
                settings: settings
            )

            // Wave dispatch loop
            while true {
                let batch = try coordinator.claimBatch(state: state)
                guard !batch.isEmpty else { break }

                // Persist claimed state so SwiftUI sees "Claimed" column
                try? modelContext.save()
                try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms

                // Advance all claimed cards to .working
                for result in batch {
                    try coordinator.beginWorking(cardID: result.primaryCardID, in: state)
                }
                try? modelContext.save()

                // Dispatch each card sequentially; mark done after each execution completes
                for result in batch {
                    try await sendMessage(
                        text: result.missionPrompt,
                        session: session,
                        modelId: modelId,
                        modelContext: modelContext
                    )
                    try? coordinator.markCardDone(result.primaryCardID, in: state)
                    try? modelContext.save()
                }
                // Loop again — newly dependency-unlocked cards (if any) will be claimed next wave
            }
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

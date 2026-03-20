import Foundation

@MainActor
final class ACPExternalSessionTurnRouter {
    enum Phase: Equatable {
        case idle
        case restoring
        case liveTurn
    }

    private var phases: [String: Phase] = [:]

    func beginRestore(sessionID: String) {
        phases[sessionID] = .restoring
    }

    func finishRestore(sessionID: String) {
        guard phases[sessionID] == .restoring else { return }
        phases[sessionID] = .idle
    }

    func beginLiveTurn(sessionID: String) {
        phases[sessionID] = .liveTurn
    }

    func finishLiveTurn(sessionID: String) {
        guard phases[sessionID] == .liveTurn else { return }
        phases[sessionID] = .idle
    }

    func shouldProjectIncomingUpdate(for sessionID: String) -> Bool {
        phases[sessionID] == .liveTurn
    }

    func reset(sessionID: String) {
        phases.removeValue(forKey: sessionID)
    }
}
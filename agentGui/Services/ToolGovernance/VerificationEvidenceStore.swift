import Foundation

// MARK: - VerificationEvidenceSummary

/// Lightweight record of a test run detected in a bash tool result.
/// Stored per session in `VerificationEvidenceStore`.
struct VerificationEvidenceSummary: Sendable, Equatable {
    /// The exact test command string (or a truncation up to 200 chars).
    let command: String
    /// Number of passing tests parsed from output. `nil` if unable to extract.
    let passCount: Int?
    /// Number of failing tests parsed from output. `nil` if unable to extract.
    let failCount: Int?
    /// First failing test name / error excerpt, up to 120 chars.
    let failureSummary: String?
    /// Whether the process exited with code 0 (success).
    let exitedZero: Bool
    let capturedAt: Date
}

// MARK: - VerificationEvidenceStore

/// Per-session, in-memory store of test-run verification evidence.
/// Scoped to the process lifetime; not persisted to SwiftData.
///
/// Thread-safe via actor isolation.
actor VerificationEvidenceStore {
    private var evidenceBySession: [String: [VerificationEvidenceSummary]] = [:]

    /// Record one piece of test evidence for the given session.
    func record(_ summary: VerificationEvidenceSummary, sessionID: String) {
        evidenceBySession[sessionID, default: []].append(summary)
    }

    /// Whether the session has at least one recorded test run.
    func hasEvidence(for sessionID: String) -> Bool {
        !(evidenceBySession[sessionID]?.isEmpty ?? true)
    }

    /// All recorded evidence for a session (for UI / debugging).
    func evidence(for sessionID: String) -> [VerificationEvidenceSummary] {
        evidenceBySession[sessionID] ?? []
    }

    /// Clear evidence for a session (e.g. on session close / reset).
    func clearEvidence(for sessionID: String) {
        evidenceBySession.removeValue(forKey: sessionID)
    }
}

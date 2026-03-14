import Foundation

enum VerificationDecision: String, Codable, Equatable, Sendable {
    case pass
    case revise
    case fail
    case abstain
}

enum VerificationClaimType: String, Codable, Equatable, Sendable {
    case execution
    case fileState
    case behavioral
    case factual
    case coverage
    case policy
    case citation
}

enum VerificationClaimStatus: String, Codable, Equatable, Sendable {
    case supported
    case contradicted
    case open
}

struct VerificationClaim: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var claimType: VerificationClaimType
    var importance: Double
    var verifiability: Double
    var status: VerificationClaimStatus
    var evidenceRefs: [String]
}

struct VerificationEvidence: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var source: String
    var summary: String
    var strength: Double
    var sourceRefs: [String]
}

struct VerificationFrontierItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var claimID: String
    var claimType: VerificationClaimType
    var openQuestion: String
    var recommendedProbe: String
    var riskScore: Double
}

struct ConvergenceCertificate: Codable, Equatable, Sendable {
    var decision: VerificationDecision
    var supportedClaims: [String]
    var contradictedClaims: [String]
    var openClaims: [String]
    var residualRisks: [String]
    var expectedValueOfMoreVerification: Double
    var stopReason: String
}

struct VerificationState: Codable, Equatable, Sendable {
    var riskScore: Double
    var claims: [VerificationClaim]
    var evidence: [VerificationEvidence]
    var frontier: [VerificationFrontierItem]
    var repairQueue: [String]
    var openQuestions: [String]
    var certificate: ConvergenceCertificate?

    init(
        riskScore: Double = 0,
        claims: [VerificationClaim] = [],
        evidence: [VerificationEvidence] = [],
        frontier: [VerificationFrontierItem] = [],
        repairQueue: [String] = [],
        openQuestions: [String] = [],
        certificate: ConvergenceCertificate? = nil
    ) {
        self.riskScore = riskScore
        self.claims = claims
        self.evidence = evidence
        self.frontier = frontier
        self.repairQueue = repairQueue
        self.openQuestions = openQuestions
        self.certificate = certificate
    }
}
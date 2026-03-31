import Foundation

struct AgentTeamClaimExecutionGate {
    enum Error: LocalizedError, Equatable {
        case missingTeamContext
        case missingClaimBoard
        case taskCardNotFound(UUID)
        case claimNotFound(UUID)
        case claimNotRegisteredOnTaskCard(claimID: UUID, taskCardID: UUID)
        case claimDoesNotMatchTaskCard(claimID: UUID, taskCardID: UUID)
        case taskCardUnclaimed(UUID)
        case claimNotAccepted(claimID: UUID, acceptedClaimID: UUID)
        case providerIsNotCurrentOwner(taskCardID: UUID, expected: ExecutionProviderReference, actual: ExecutionProviderReference)

        var errorDescription: String? {
            switch self {
            case .missingTeamContext:
                return "Agent Team 执行缺少 claim 上下文。"
            case .missingClaimBoard:
                return "Agent Team 会话缺少 claim board，无法验证执行 owner。"
            case let .taskCardNotFound(taskCardID):
                return "未找到 task card: \(taskCardID.uuidString.lowercased())。"
            case let .claimNotFound(claimID):
                return "未找到 claim: \(claimID.uuidString.lowercased())。"
            case let .claimNotRegisteredOnTaskCard(claimID, taskCardID):
                return "claim \(claimID.uuidString.lowercased()) 未注册到 task card \(taskCardID.uuidString.lowercased())。"
            case let .claimDoesNotMatchTaskCard(claimID, taskCardID):
                return "claim \(claimID.uuidString.lowercased()) 不属于 task card \(taskCardID.uuidString.lowercased())。"
            case let .taskCardUnclaimed(taskCardID):
                return "task card \(taskCardID.uuidString.lowercased()) 尚未认领。"
            case let .claimNotAccepted(claimID, acceptedClaimID):
                return "claim \(claimID.uuidString.lowercased()) 不是当前 accepted claim；当前 accepted claim 为 \(acceptedClaimID.uuidString.lowercased())。"
            case let .providerIsNotCurrentOwner(taskCardID, expected, actual):
                return "provider \(actual.persistedValue) 不是 task card \(taskCardID.uuidString.lowercased()) 的当前 owner；期望 \(expected.persistedValue)。"
            }
        }
    }

    func validate(
        session: Session,
        state: AgentTeamSessionState?,
        providerReference: ExecutionProviderReference,
        teamContext: AgentTeamExecutionContext?
    ) throws {
        guard session.kind == .agentTeam else {
            return
        }

        guard let teamContext else {
            throw Error.missingTeamContext
        }
        guard let board = state?.claimBoardState else {
            throw Error.missingClaimBoard
        }
        guard let card = board.card(id: teamContext.taskCardID) else {
            throw Error.taskCardNotFound(teamContext.taskCardID)
        }
        guard let claim = board.claim(id: teamContext.claimID) else {
            throw Error.claimNotFound(teamContext.claimID)
        }
        guard card.claimIDs.contains(claim.id) else {
            throw Error.claimNotRegisteredOnTaskCard(claimID: claim.id, taskCardID: card.id)
        }
        guard claim.taskCardID == card.id else {
            throw Error.claimDoesNotMatchTaskCard(claimID: claim.id, taskCardID: card.id)
        }
        guard let acceptedClaim = board.acceptedClaim(for: card.id) else {
            throw Error.taskCardUnclaimed(card.id)
        }
        guard acceptedClaim.id == claim.id else {
            throw Error.claimNotAccepted(claimID: claim.id, acceptedClaimID: acceptedClaim.id)
        }
        guard acceptedClaim.providerReference == providerReference else {
            throw Error.providerIsNotCurrentOwner(
                taskCardID: card.id,
                expected: acceptedClaim.providerReference,
                actual: providerReference
            )
        }
    }
}
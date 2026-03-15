import Foundation
import SwiftData

@MainActor
final class SessionTaskStateStore {
    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator = .shared
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
    }

    func taskState(for sessionId: String) throws -> SessionTaskState? {
        if let existing = try fetchTaskState(for: sessionId) {
            return existing
        }
        guard let session = try? fetchSession(for: sessionId) else {
            return nil
        }
        guard !session.planJson.isEmpty else {
            return nil
        }

        let state = SessionTaskState(sessionId: sessionId, planJson: session.planJson)
        modelContext.insert(state)
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "任务状态迁移未成功保存",
            metadata: ["sessionId": sessionId]
        )
        return state
    }

    func savePlan(_ plan: ExecutionPlan, for sessionId: String) throws {
        let planJson = try encode(plan)
        let state = try upsertTaskState(for: sessionId)
        state.planJson = planJson
        state.updatedAt = Date()

        if let session = try? fetchSession(for: sessionId) {
            session.planJson = planJson
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "执行计划未成功保存",
            metadata: ["sessionId": sessionId]
        )
    }

    func saveTodoItems(_ items: [TodoItem], for sessionId: String) throws {
        let state = try upsertTaskState(for: sessionId)
        state.todoJson = try encode(items)
        state.updatedAt = Date()
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "任务列表未成功保存",
            metadata: ["sessionId": sessionId]
        )
    }

    func saveVerification(_ verification: CompletionVerification, for sessionId: String) throws {
        let state = try upsertTaskState(for: sessionId)
        state.verificationJson = try encode(verification)
        state.updatedAt = Date()
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "完成验证未成功保存",
            metadata: ["sessionId": sessionId]
        )
    }

    func saveRMSState(_ rmsState: RMSState, for sessionId: String) throws {
        let state = try upsertTaskState(for: sessionId)
        state.rmsStateJson = try encode(rmsState.stableSnapshot())
        state.updatedAt = Date()
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "RMS 状态未成功保存",
            metadata: ["sessionId": sessionId]
        )
    }

    func updateVerificationAssessment(
        _ update: VerificationAssessmentUpdate,
        for sessionId: String
    ) throws {
        let state = try upsertTaskState(for: sessionId)
        var verification = state.verification ?? CompletionVerification(verified: [], notVerified: [])
        verification.applyAssessment(update)
        verification.recordedAt = Date()
        state.verificationJson = try encode(verification)
        state.updatedAt = Date()
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "验证评估未成功保存",
            metadata: ["sessionId": sessionId]
        )
    }

    func todoItems(for sessionId: String) -> [TodoItem] {
        (try? taskState(for: sessionId)?.todoItems) ?? []
    }

    func verification(for sessionId: String) -> CompletionVerification? {
        try? taskState(for: sessionId)?.verification
    }

    func rmsState(for sessionId: String) -> RMSState? {
        try? taskState(for: sessionId)?.rmsState
    }

    private func upsertTaskState(for sessionId: String) throws -> SessionTaskState {
        if let existing = try fetchTaskState(for: sessionId) {
            return existing
        }

        let migratedPlanJson = (try? fetchSession(for: sessionId)?.planJson) ?? ""
        let state = SessionTaskState(sessionId: sessionId, planJson: migratedPlanJson)
        modelContext.insert(state)
        return state
    }

    private func fetchTaskState(for sessionId: String) throws -> SessionTaskState? {
        let descriptor = FetchDescriptor<SessionTaskState>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSession(for sessionId: String) throws -> Session? {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
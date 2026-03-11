import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class ReliabilityCenterViewModel {
    private let persistenceCoordinator: PersistenceCoordinator
    private let dataIntegrityChecker: DataIntegrityChecker
    private let backupArchiveService: BackupArchiveService

    private(set) var integrityIssues: [IntegrityIssue] = []
    private(set) var recoverySnapshots: [RecoverySnapshot] = []
    private(set) var persistenceFailures: [PersistenceFailureRecord] = []
    private(set) var lastBackupStatus: String?

    init() {
        self.persistenceCoordinator = .shared
        self.dataIntegrityChecker = DataIntegrityChecker()
        self.backupArchiveService = BackupArchiveService()
    }

    var issueCount: Int {
        integrityIssues.count + recoverySnapshots.count + persistenceFailures.count
    }

    func refresh(using modelContext: ModelContext) {
        _ = try? dataIntegrityChecker.runLightweightChecks(in: modelContext)
        integrityIssues = (try? modelContext.fetch(FetchDescriptor<IntegrityIssue>()))?
            .sorted { $0.createdAt > $1.createdAt } ?? []
        recoverySnapshots = ((try? modelContext.fetch(FetchDescriptor<RecoverySnapshot>())) ?? [])
            .filter { $0.handlingState.isVisible }
            .sorted { $0.updatedAt > $1.updatedAt }
        persistenceFailures = persistenceCoordinator.recentFailures
    }

    func exportAllBackup(using modelContext: ModelContext) {
        do {
            let url = try backupArchiveService.exportAll(from: modelContext)
            lastBackupStatus = "已导出到 \(url.path)"
        } catch {
            lastBackupStatus = "导出失败：\(error.localizedDescription)"
        }
    }
}
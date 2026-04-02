import SwiftData

@MainActor
protocol ACPRemoteSessionConfigurationControlling: AnyObject {
    func remoteSessionConfiguration(localSessionID: String) -> ACPExternalAgentSessionConfigurationSnapshot?
    func updateSessionMode(session: Session, modelContext: ModelContext, modeID: String) async throws
    func updateSessionConfigOption(session: Session, modelContext: ModelContext, configID: String, value: String) async throws
    /// 清理 warmup probe session 产生的所有临时状态（运行时、binding 记录、session state）。
    func discardWarmupState(localSessionID: String, modelContext: ModelContext) async
}
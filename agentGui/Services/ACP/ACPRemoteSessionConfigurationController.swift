import SwiftData

@MainActor
protocol ACPRemoteSessionConfigurationControlling: AnyObject {
    func remoteSessionConfiguration(localSessionID: String) -> ACPExternalAgentSessionConfigurationSnapshot?
    func updateSessionMode(session: Session, modelContext: ModelContext, modeID: String) async throws
    func updateSessionConfigOption(session: Session, modelContext: ModelContext, configID: String, value: String) async throws
}
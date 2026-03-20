import Foundation
import SwiftData

@Model
final class ACPExternalSessionBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var localSessionID: String
    var providerIDRaw: String
    var remoteSessionID: String
    var agentVersion: String
    var negotiatedCapabilitiesJSON: String
    var lastSelectedModel: String
    var lastSelectedAgentName: String
    var lastHandshakeAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        localSessionID: String,
        providerIDRaw: String,
        remoteSessionID: String,
        agentVersion: String = "",
        negotiatedCapabilitiesJSON: String = "",
        lastSelectedModel: String = "",
        lastSelectedAgentName: String = "",
        lastHandshakeAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.localSessionID = localSessionID
        self.providerIDRaw = providerIDRaw
        self.remoteSessionID = remoteSessionID
        self.agentVersion = agentVersion
        self.negotiatedCapabilitiesJSON = negotiatedCapabilitiesJSON
        self.lastSelectedModel = lastSelectedModel
        self.lastSelectedAgentName = lastSelectedAgentName
        self.lastHandshakeAt = lastHandshakeAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ACPExternalSessionBinding {
    var providerID: ConversationExecutionProviderID? {
        ConversationExecutionProviderID(rawValue: providerIDRaw)
    }

    var negotiatedCapabilities: ACPExternalAgentCapabilitySnapshot? {
        get {
            guard let data = negotiatedCapabilitiesJSON.data(using: .utf8),
                  let capabilities = try? JSONDecoder().decode(ACPExternalAgentCapabilitySnapshot.self, from: data) else {
                return nil
            }
            return capabilities
        }
        set {
            negotiatedCapabilitiesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? ""
        }
    }
}
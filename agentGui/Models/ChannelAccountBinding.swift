import Foundation
import SwiftData

@Model
final class ChannelAccountBinding {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var configurationKey: String
    var displayName: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        configurationKey: String,
        displayName: String = "",
        isEnabled: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.configurationKey = configurationKey
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
import Foundation
import SwiftData

@Model
final class ChannelAccountBinding {
    private struct SettingsPayload: Codable {
        var values: [String: String]

        init(values: [String: String] = [:]) {
            self.values = values
        }
    }

    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    var id: UUID
    var channelKind: IMChannelKind
    var configurationKey: String
    var displayName: String
    var isEnabled: Bool
    var settingsJSON: String="{}"  
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        channelKind: IMChannelKind,
        configurationKey: String,
        displayName: String = "",
        isEnabled: Bool = false,
        settingsJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.channelKind = channelKind
        self.configurationKey = configurationKey
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.settingsJSON = settingsJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func stringSetting(forKey key: String) -> String? {
        decodedSettings().values[key]
    }

    func setStringSetting(_ value: String?, forKey key: String) {
        var settings = decodedSettings()
        if let value {
            settings.values[key] = value
        } else {
            settings.values.removeValue(forKey: key)
        }
        settingsJSON = Self.encodeSettings(settings)
    }

    private func decodedSettings() -> SettingsPayload {
        guard let data = settingsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SettingsPayload.self, from: data) else {
            return SettingsPayload()
        }
        return decoded
    }

    private static func encodeSettings(_ settings: SettingsPayload) -> String {
        guard let data = try? JSONEncoder().encode(settings),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
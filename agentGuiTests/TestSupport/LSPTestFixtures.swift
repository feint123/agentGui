import Foundation
@testable import agentGui

extension AppSettings {
    static func lspFixture(installedProviderIDs: [String]) -> AppSettings {
        let catalog = LSPProviderCatalog.builtInCatalog()
        let definitions = installedProviderIDs.compactMap { providerID in
            catalog.provider(id: providerID)?.defaultServerTemplate
        }

        let settings = AppSettings.testFixture(installedDefinitions: definitions)
        settings.lspInstalledProviders = definitions.map {
            LSPInstalledProviderRecord(providerID: $0.providerID, executablePath: $0.launchCommand)
        }
        return settings
    }
}
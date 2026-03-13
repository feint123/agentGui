import Testing
@testable import agentGui

struct LSPSettingsTests {
    @Test func appSettingsExposeLSPDefaults() {
        let settings = AppSettings()

        #expect(settings.enableLSPTools == false)
        #expect(settings.autoStartLSPServers == true)
        #expect(settings.lspDefaultRoutingMode == "automatic")
        #expect(settings.lspCustomServerProfilesJSON == "[]")
        #expect(settings.isLSPAutoStartEffective == false)
    }

    @Test func customProfilesRoundTripThroughTypedAccessor() throws {
        let settings = AppSettings()
        let profiles = [
            LSPServerDefinition(
                id: "custom-rust-analyzer",
                displayName: "Rust Analyzer",
                launchCommand: "rust-analyzer",
                launchArguments: [],
                supportedLanguageIDs: ["rust"],
                defaultFileGlobs: ["**/*.rs"],
                rootMarkers: ["Cargo.toml"],
                adapterKind: .generic
            )
        ]

        settings.lspCustomServerProfiles = profiles

        #expect(settings.lspCustomServerProfiles == profiles)
        #expect(settings.lspCustomServerProfilesJSON.contains("custom-rust-analyzer"))
        #expect(settings.lspCustomServerProfilesValidationError == nil)
    }

    @Test func invalidCustomProfileJSONReportsValidationError() {
        let settings = AppSettings()
        settings.lspCustomServerProfilesJSON = "{not-json}"

        #expect(settings.lspCustomServerProfiles.isEmpty)
        #expect(settings.lspCustomServerProfilesValidationError != nil)
    }

    @Test func disablingLSPToolsMakesAutoStartIneffective() {
        let settings = AppSettings()
        settings.enableLSPTools = true
        settings.autoStartLSPServers = true
        #expect(settings.isLSPAutoStartEffective == true)

        settings.enableLSPTools = false

        #expect(settings.isLSPAutoStartEffective == false)
    }
}
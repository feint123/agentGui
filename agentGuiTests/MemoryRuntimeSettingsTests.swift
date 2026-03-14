import Testing
@testable import agentGui

struct MemoryRuntimeSettingsTests {
    @Test func appSettingsExposeRMSFlags() async throws {
        let settings = AppSettings()

        #expect(settings.enableEpistemicExtraction == false)
        #expect(settings.enableRMSRetrieval == false)
        #expect(settings.enableRMSDistillation == false)
    }

    @Test func appSettingsExposeUnifiedMemoryRuntimeDefaults() async throws {
        let settings = AppSettings()

        #expect(settings.enableUnifiedMemoryRuntime == false)
        #expect(settings.unifiedMemoryContextBudget == 8)
        #expect(settings.enableMemoryGovernance == true)
        #expect(settings.enableUnifiedMemoryWritePath == true)
        #expect(settings.enableBackgroundMemoryConsolidation == true)
        #expect(settings.memoryConfirmationThreshold == 0.6)
        #expect(settings.enableMemoryTTLSweep == true)
        #expect(settings.memoryBackgroundSchedulerIntervalSeconds == 30)
        #expect(settings.memoryTTLSweepIntervalSeconds == 300)
    }
}
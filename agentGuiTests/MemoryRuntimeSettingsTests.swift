import Testing
@testable import agentGui

struct MemoryRuntimeSettingsTests {
    @Test func appSettingsExposeSimplifiedMemoryFlags() async throws {
        let settings = AppSettings()

        #expect(settings.memoryEnabled == true)
        #expect(settings.memoryContextBudget == 8)
    }
}
import Testing
@testable import agentGui

struct AuthorizedRuntimeSettingsFactoryTests {
    @Test func runtimeSettingsReflectAuthorizedToolSnapshot() {
        let base = AppSettings.testFixture(apiKey: "test")
        base.enableTextEditorTool = true
        base.enableBashTool = true
        base.enableWebSearchTool = true
        base.enableWebFetchTool = true
        base.memoryEnabled = true

        let snapshot = EffectiveToolAuthorizationSnapshot(
            context: .backgroundTask,
            allowedToolIDs: ["str_replace_based_edit_tool", "bash", "web_search"],
            deniedToolReasons: [:],
            capabilityLevels: [
                .fileSystem: .mutate,
                .shell: .execute,
                .network: .observe,
                .memory: .disabled
            ]
        )

        let runtime = AuthorizedRuntimeSettingsFactory().makeRuntimeSettings(
            base: base,
            snapshot: snapshot,
            workingDirectory: "/tmp/workspace",
            enabledSkillNames: []
        )

        #expect(runtime.enableTextEditorTool == true)
        #expect(runtime.enableBashTool == true)
        #expect(runtime.enableWebSearchTool == true)
        #expect(runtime.enableWebFetchTool == false)
        #expect(runtime.memoryEnabled == false)
        #expect(runtime.workingDirectory == "/tmp/workspace")
        #expect(runtime.enabledSkillNames.isEmpty)
    }
}
import Testing
@testable import agentGui

struct ToolAuthorizationResolverTests {
    @Test func resolverAllowsEditorAndShellForActLimitedBackgroundPolicy() {
        let registry = DefaultToolRegistry()
        let resolver = ToolAuthorizationResolver(registry: registry)
        let settings = AppSettings.testFixture(apiKey: "test")
        settings.enableTextEditorTool = true
        settings.enableBashTool = true
        settings.enableWebSearchTool = true
        settings.enableWebFetchTool = true

        let snapshot = resolver.resolve(
            ToolAuthorizationRequest(
                context: .backgroundTask,
                settings: settings,
                subjectPolicy: ToolAuthorizationPolicy(preset: .actLimited)
            )
        )

        #expect(snapshot.allowedToolIDs.contains("str_replace_based_edit_tool"))
        #expect(snapshot.allowedToolIDs.contains("bash"))
        #expect(snapshot.allowedToolIDs.contains("web_search"))
        #expect(snapshot.allowedToolIDs.contains("web_fetch"))
    }

    @Test func resolverRejectsEditorWhenGlobalSwitchIsOff() {
        let resolver = ToolAuthorizationResolver(registry: DefaultToolRegistry())
        let settings = AppSettings.testFixture(apiKey: "test")
        settings.enableTextEditorTool = false

        let snapshot = resolver.resolve(
            ToolAuthorizationRequest(
                context: .backgroundTask,
                settings: settings,
                subjectPolicy: ToolAuthorizationPolicy(preset: .actLimited)
            )
        )

        #expect(snapshot.allowedToolIDs.contains("str_replace_based_edit_tool") == false)
        #expect(snapshot.deniedToolReasons["str_replace_based_edit_tool"] == .globallyDisabled)
    }
}

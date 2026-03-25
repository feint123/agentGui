import Foundation
import Testing
@testable import agentGui

struct ACPProtocolConformanceTests {
    @Test func agentMethodCatalogContainsOnlyOfficialStandardMethods() {
        let methods = [
            ACPMethodCatalog.Agent.authenticate,
            ACPMethodCatalog.Agent.initialize,
            ACPMethodCatalog.Agent.sessionCancel,
            ACPMethodCatalog.Agent.sessionList,
            ACPMethodCatalog.Agent.sessionLoad,
            ACPMethodCatalog.Agent.sessionNew,
            ACPMethodCatalog.Agent.sessionPrompt,
            ACPMethodCatalog.Agent.sessionSetConfigOption,
            ACPMethodCatalog.Agent.sessionSetMode
        ]

        #expect(Set(methods).count == 9)
        #expect(Set(methods) == Set([
            "authenticate",
            "initialize",
            "session/cancel",
            "session/list",
            "session/load",
            "session/new",
            "session/prompt",
            "session/set_config_option",
            "session/set_mode"
        ]))
    }

    @Test func extensionMethodsMustStartWithUnderscore() {
        let method = ACPProviderExtensionMethod("_opencode/session/set_model")

        #expect(method.method == "_opencode/session/set_model")
    }
}
import Testing
@testable import agentGui

@MainActor
struct LSPServerCapabilitiesTests {

    // MARK: - Field defaults

    @Test func readOnlySemanticDefaultsMissingNewFields() {
        let h = LSPServerCapabilityHints.readOnlySemanticDefaults
        #expect(h.supportsCompletion == false)
        #expect(h.completionTriggerCharacters == [])
        #expect(h.supportsSignatureHelp == false)
        #expect(h.signatureHelpTriggerCharacters == [])
        #expect(h.signatureHelpRetriggerCharacters == [])
        #expect(h.supportsCodeActions == false)
        #expect(h.supportsDocumentFormatting == false)
        #expect(h.supportsRangeFormatting == false)
        #expect(h.supportsOnTypeFormatting == false)
        #expect(h.onTypeFormattingTriggerCharacters == [])
        #expect(h.supportsRename == false)
        #expect(h.supportsPrepareRename == false)
        #expect(h.supportsDocumentHighlights == false)
        #expect(h.supportsDeclaration == false)
        #expect(h.supportsTypeDefinition == false)
        #expect(h.supportsImplementation == false)
        #expect(h.supportsFoldingRange == false)
        #expect(h.supportsSemanticTokens == false)
        #expect(h.supportsInlayHints == false)
    }

    // MARK: - negotiatedCapabilities parsing

    @Test func parsesCompletionProviderAsObject() {
        let raw: [String: Any] = [
            "capabilities": [
                "completionProvider": [
                    "triggerCharacters": [".", "(", ","],
                    "resolveProvider": true
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == true)
        #expect(result.completionTriggerCharacters == [".", "(", ","])
    }

    @Test func parsesCompletionProviderAsBoolTrue() {
        let raw: [String: Any] = ["capabilities": ["completionProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == true)
        #expect(result.completionTriggerCharacters == [])
    }

    @Test func parsesCompletionProviderAsBoolFalse() {
        let raw: [String: Any] = ["capabilities": ["completionProvider": false]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == false)
    }

    @Test func parsesSignatureHelpProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "signatureHelpProvider": [
                    "triggerCharacters": ["(", ","],
                    "retriggerCharacters": [")"]
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsSignatureHelp == true)
        #expect(result.signatureHelpTriggerCharacters == ["(", ","])
        #expect(result.signatureHelpRetriggerCharacters == [")"])
    }

    @Test func parsesCodeActionProviderAsBool() {
        let raw: [String: Any] = ["capabilities": ["codeActionProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCodeActions == true)
    }

    @Test func parsesCodeActionProviderAsObject() {
        let raw: [String: Any] = [
            "capabilities": ["codeActionProvider": ["codeActionKinds": ["quickfix", "refactor"]]]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCodeActions == true)
    }

    @Test func parsesDocumentFormattingProvider() {
        let raw: [String: Any] = ["capabilities": ["documentFormattingProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDocumentFormatting == true)
    }

    @Test func parsesDocumentRangeFormattingProvider() {
        let raw: [String: Any] = ["capabilities": ["documentRangeFormattingProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRangeFormatting == true)
    }

    @Test func parsesOnTypeFormattingProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "documentOnTypeFormattingProvider": [
                    "firstTriggerCharacter": ":",
                    "moreTriggerCharacter": ["{", "}"]
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsOnTypeFormatting == true)
        #expect(result.onTypeFormattingTriggerCharacters.contains(":"))
        #expect(result.onTypeFormattingTriggerCharacters.contains("{"))
    }

    @Test func parsesRenameProviderAsBool() {
        let raw: [String: Any] = ["capabilities": ["renameProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRename == true)
        #expect(result.supportsPrepareRename == false)
    }

    @Test func parsesRenameProviderWithPrepareRename() {
        let raw: [String: Any] = [
            "capabilities": ["renameProvider": ["prepareProvider": true]]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRename == true)
        #expect(result.supportsPrepareRename == true)
    }

    @Test func parsesDocumentHighlightProvider() {
        let raw: [String: Any] = ["capabilities": ["documentHighlightProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDocumentHighlights == true)
    }

    @Test func parsesTypeDefinitionAndImplementationProviders() {
        let raw: [String: Any] = [
            "capabilities": [
                "typeDefinitionProvider": true,
                "implementationProvider": ["id": "impl"]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsTypeDefinition == true)
        #expect(result.supportsImplementation == true)
    }

    @Test func parsesDeclarationProvider() {
        let raw: [String: Any] = ["capabilities": ["declarationProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDeclaration == true)
    }

    @Test func parsesFoldingRangeProvider() {
        let raw: [String: Any] = ["capabilities": ["foldingRangeProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsFoldingRange == true)
    }

    @Test func parsesSemanticTokensProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "semanticTokensProvider": [
                    "legend": ["tokenTypes": ["namespace"], "tokenModifiers": []],
                    "full": true
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsSemanticTokens == true)
    }

    @Test func parsesInlayHintProvider() {
        let raw: [String: Any] = ["capabilities": ["inlayHintProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsInlayHints == true)
    }

    @Test func missingCapabilitiesKeepFallback() {
        let raw: [String: Any] = [
            "capabilities": ["hoverProvider": true]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == false)
    }

    @Test func malformedCapabilitiesObjectFallsBackCompletely() {
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: nil, fallback: .allDisabled)
        #expect(result.supportsHover == false)
        #expect(result.supportsCompletion == false)
    }

    // MARK: - diagnosticProvider parsing

    @Test func parsesDiagnosticProviderAsObject() {
        let raw: [String: Any] = [
            "capabilities": [
                "diagnosticProvider": [
                    "identifier": "pylsp",
                    "interFileDependencies": false,
                    "workspaceDiagnostics": false
                ]
            ]
        ]
        let fallback = LSPServerCapabilityHints.allDisabled
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: fallback)
        #expect(result.supportsDiagnostics == true)
    }

    @Test func diagnosticsDefaultFallbackWhenProviderAbsent() {
        let raw: [String: Any] = ["capabilities": ["hoverProvider": true]]
        var fallback = LSPServerCapabilityHints.allDisabled
        fallback.supportsDiagnostics = true
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: fallback)
        #expect(result.supportsDiagnostics == true)
    }
}

@MainActor
struct LSPClientCapabilitiesParamsTests {

    @Test func initializeParamsContainsTextDocumentCapabilities() throws {
        let client = LSPClient(
            transport: LSPJSONRPCTransport(),
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        let params = client.initializeParamsForTesting(workspaceRoot: "/tmp/test")
        let caps = try #require(params["capabilities"] as? [String: Any])
        let textDoc = try #require(caps["textDocument"] as? [String: Any])
        let workspace = try #require(caps["workspace"] as? [String: Any])

        #expect(textDoc["hover"] != nil)
        #expect(textDoc["completion"] != nil)
        #expect(textDoc["signatureHelp"] != nil)
        #expect(textDoc["codeAction"] != nil)
        #expect(textDoc["rename"] != nil)
        #expect(textDoc["formatting"] != nil)

        let applyEdit = try #require(workspace["applyEdit"] as? Bool)
        #expect(applyEdit == true)
    }
}

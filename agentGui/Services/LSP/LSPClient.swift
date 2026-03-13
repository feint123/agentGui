import Foundation

struct LSPSymbolLocation: Equatable, Sendable {
    let uri: String
    let line: Int
    let character: Int
}

final class LSPClient {
    private let transport: LSPJSONRPCTransport
    private let documentStore: LSPDocumentStore
    private let diagnosticsStore: LSPDiagnosticsStore
    private let adapter: any LSPServerAdapter

    private(set) var capabilities: LSPServerCapabilityHints?

    init(
        transport: LSPJSONRPCTransport,
        documentStore: LSPDocumentStore,
        diagnosticsStore: LSPDiagnosticsStore,
        adapter: any LSPServerAdapter
    ) {
        self.transport = transport
        self.documentStore = documentStore
        self.diagnosticsStore = diagnosticsStore
        self.adapter = adapter
    }

    func attach(process: any LSPManagedProcess) {
        if transport.outgoingDataHandler == nil {
            transport.outgoingDataHandler = { data in
                try? process.send(data)
            }
        }
        let previousOutputHandler = process.standardOutputHandler
        process.standardOutputHandler = { [weak transport] data in
            previousOutputHandler?(data)
            _ = try? transport?.receive(data)
        }
        let previousErrorHandler = process.standardErrorHandler
        process.standardErrorHandler = { data in
            previousErrorHandler?(data)
        }
    }

    func initializeSession(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        let hintedCapabilities = try await adapter.initialize(server: server, workspaceRoot: workspaceRoot)
        let result = try await transport.sendRequest(
            method: "initialize",
            params: initializeParams(workspaceRoot: workspaceRoot)
        )
        try transport.sendNotification(method: "initialized", params: [:])

        let capabilities = negotiatedCapabilities(from: result, fallback: hintedCapabilities)
        self.capabilities = capabilities
        return capabilities
    }

    @discardableResult
    func openDocument(uri: String, languageID: String, text: String) -> LSPDocumentSnapshot {
        documentStore.openDocument(uri: uri, languageID: languageID, text: text)
    }

    @discardableResult
    func updateDocument(uri: String, text: String) -> LSPDocumentSnapshot? {
        documentStore.updateDocument(uri: uri, text: text)
    }

    func closeDocument(uri: String) {
        documentStore.closeDocument(uri: uri)
    }

    func definition(uri: String, line: Int, character: Int) async throws -> LSPSymbolLocation? {
        let result = try await transport.sendRequest(
            method: "textDocument/definition",
            params: documentPositionParams(uri: uri, line: line, character: character)
        )
        return parseFirstLocation(from: result)
    }

    func references(uri: String, line: Int, character: Int) async throws -> [LSPSymbolLocation] {
        let params = documentPositionParams(uri: uri, line: line, character: character).merging(
            ["context": ["includeDeclaration": true]],
            uniquingKeysWith: { _, new in new }
        )
        let result = try await transport.sendRequest(method: "textDocument/references", params: params)
        return parseLocations(from: result)
    }

    func hover(uri: String, line: Int, character: Int) async throws -> String? {
        let result = try await transport.sendRequest(
            method: "textDocument/hover",
            params: documentPositionParams(uri: uri, line: line, character: character)
        )
        return parseHoverText(from: result)
    }

    func documentSymbols(uri: String) -> [String] { [] }

    func workspaceSymbols(query: String) -> [String] { [] }

    func publishDiagnostics(workspaceRoot: String, uri: String, diagnostics: [LSPDiagnostic]) {
        diagnosticsStore.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: workspaceRoot,
                uri: uri,
                diagnostics: diagnostics
            )
        )
    }

    func diagnosticsSnapshot(workspaceRoot: String, uri: String) -> LSPDiagnosticsSnapshot? {
        diagnosticsStore.snapshot(for: workspaceRoot, uri: uri)
    }

    private func documentPositionParams(uri: String, line: Int, character: Int) -> [String: Any] {
        [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character]
        ]
    }

    private func initializeParams(workspaceRoot: String) -> [String: Any] {
        let rootURL = URL(fileURLWithPath: workspaceRoot)
        return [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "rootUri": rootURL.absoluteString,
            "workspaceFolders": [
                [
                    "uri": rootURL.absoluteString,
                    "name": rootURL.lastPathComponent.isEmpty ? workspaceRoot : rootURL.lastPathComponent
                ]
            ],
            "clientInfo": [
                "name": "agentGui",
                "version": "1"
            ],
            "capabilities": [
                "workspace": [:],
                "textDocument": [:]
            ]
        ]
    }

    private func negotiatedCapabilities(from rawResult: Any?, fallback: LSPServerCapabilityHints) -> LSPServerCapabilityHints {
        guard let object = rawResult as? [String: Any],
              let capabilities = object["capabilities"] as? [String: Any] else {
            return fallback
        }

        return LSPServerCapabilityHints(
            supportsHover: boolCapability(capabilities["hoverProvider"], fallback: fallback.supportsHover),
            supportsDefinition: boolCapability(capabilities["definitionProvider"], fallback: fallback.supportsDefinition),
            supportsReferences: boolCapability(capabilities["referencesProvider"], fallback: fallback.supportsReferences),
            supportsDocumentSymbols: boolCapability(capabilities["documentSymbolProvider"], fallback: fallback.supportsDocumentSymbols),
            supportsWorkspaceSymbols: boolCapability(
                capabilities["workspaceSymbolProvider"] ?? (capabilities["workspace"] as? [String: Any])?["symbolProvider"],
                fallback: fallback.supportsWorkspaceSymbols
            ),
            supportsDiagnostics: fallback.supportsDiagnostics
        )
    }

    private func boolCapability(_ value: Any?, fallback: Bool) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if value is [String: Any] {
            return true
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return fallback
    }

    private func parseFirstLocation(from rawResult: Any?) -> LSPSymbolLocation? {
        parseLocations(from: rawResult).first
    }

    private func parseLocations(from rawResult: Any?) -> [LSPSymbolLocation] {
        if let array = rawResult as? [[String: Any]] {
            return array.compactMap(parseLocation(from:))
        }
        if let object = rawResult as? [String: Any],
           let location = parseLocation(from: object) {
            return [location]
        }
        return []
    }

    private func parseLocation(from object: [String: Any]) -> LSPSymbolLocation? {
        if let targetURI = object["targetUri"] as? String,
           let targetSelectionRange = object["targetSelectionRange"] as? [String: Any],
           let start = targetSelectionRange["start"] as? [String: Any],
           let line = number(from: start["line"]),
           let character = number(from: start["character"]) {
            return LSPSymbolLocation(uri: targetURI, line: line, character: character)
        }

        guard let uri = object["uri"] as? String,
              let range = object["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let line = number(from: start["line"]),
              let character = number(from: start["character"]) else {
            return nil
        }

        return LSPSymbolLocation(uri: uri, line: line, character: character)
    }

    private func parseHoverText(from rawResult: Any?) -> String? {
        guard let object = rawResult as? [String: Any],
              let contents = object["contents"] else {
            return nil
        }

        if let string = contents as? String {
            return string
        }
        if let markup = contents as? [String: Any],
           let value = markup["value"] as? String {
            return value
        }
        if let markedStrings = contents as? [[String: Any]] {
            return markedStrings.compactMap { $0["value"] as? String }.joined(separator: "\n\n")
        }
        if let strings = contents as? [String] {
            return strings.joined(separator: "\n\n")
        }

        return nil
    }

    private func number(from value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
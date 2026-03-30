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
    private var notificationWorkspaceRoot: String?

    private(set) var capabilities: LSPServerCapabilityHints?
    var onDocumentLifecycleEvent: ((String, LSPDocumentSnapshot?) -> Void)?

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
        configureNotificationHandling(workspaceRoot: workspaceRoot)
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
        let snapshot = documentStore.openDocument(uri: uri, languageID: languageID, text: text)
        try? transport.sendNotification(
            method: "textDocument/didOpen",
            params: [
                "textDocument": [
                    "uri": uri,
                    "languageId": languageID,
                    "version": snapshot.version,
                    "text": text
                ]
            ]
        )
        onDocumentLifecycleEvent?("open:\(uri)", snapshot)
        return snapshot
    }

    @discardableResult
    func updateDocument(uri: String, text: String) -> LSPDocumentSnapshot? {
        guard let snapshot = documentStore.updateDocument(uri: uri, text: text) else { return nil }
        try? transport.sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": [
                    "uri": uri,
                    "version": snapshot.version
                ],
                "contentChanges": [
                    ["text": text]
                ]
            ]
        )
        onDocumentLifecycleEvent?("change:\(uri)", snapshot)
        return snapshot
    }

    func closeDocument(uri: String) {
        try? transport.sendNotification(
            method: "textDocument/didClose",
            params: [
                "textDocument": [
                    "uri": uri
                ]
            ]
        )
        documentStore.closeDocument(uri: uri)
        onDocumentLifecycleEvent?("close:\(uri)", nil)
    }

    func configureNotificationHandling(workspaceRoot: String) {
        notificationWorkspaceRoot = workspaceRoot
        transport.notificationPayloadHandler = { [weak self] method, params in
            Task { @MainActor in
                self?.handleNotification(method: method, params: params)
            }
        }
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

    func documentSymbols(uri: String) async throws -> [LSPDocumentSymbol] {
        let result = try await transport.sendRequest(
            method: "textDocument/documentSymbol",
            params: [
                "textDocument": [
                    "uri": uri
                ]
            ]
        )
        return parseDocumentSymbols(from: result)
    }

    func workspaceSymbols(query: String) -> [String] { [] }

    func publishDiagnostics(
        workspaceRoot: String,
        uri: String,
        diagnostics: [LSPDiagnostic],
        documentVersion: Int? = nil
    ) {
        diagnosticsStore.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: workspaceRoot,
                uri: uri,
                diagnostics: diagnostics,
                documentVersion: documentVersion
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

    private func parseDocumentSymbols(from rawResult: Any?) -> [LSPDocumentSymbol] {
        guard let array = rawResult as? [[String: Any]] else {
            return []
        }

        let documentSymbols = array.compactMap { parseDocumentSymbol(from: $0) }
        if !documentSymbols.isEmpty {
            return documentSymbols
        }

        return array.compactMap { parseSymbolInformation(from: $0) }
    }

    private func parseDocumentSymbol(from object: [String: Any]) -> LSPDocumentSymbol? {
        guard let name = object["name"] as? String,
              let kind = number(from: object["kind"]),
              let selectionRange = object["selectionRange"] as? [String: Any],
              let start = selectionRange["start"] as? [String: Any],
              let line = number(from: start["line"]),
              let character = number(from: start["character"]) else {
            return nil
        }

        let end = (selectionRange["end"] as? [String: Any])
        let children = (object["children"] as? [[String: Any]] ?? []).compactMap { parseDocumentSymbol(from: $0) }

        return LSPDocumentSymbol(
            name: name,
            detail: object["detail"] as? String,
            kind: kind,
            line: line,
            character: character,
            endLine: number(from: end?["line"]),
            endCharacter: number(from: end?["character"]),
            children: children
        )
    }

    private func parseSymbolInformation(from object: [String: Any]) -> LSPDocumentSymbol? {
        guard let name = object["name"] as? String,
              let kind = number(from: object["kind"]),
              let location = object["location"] as? [String: Any],
              let range = location["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let line = number(from: start["line"]),
              let character = number(from: start["character"]) else {
            return nil
        }

        let end = range["end"] as? [String: Any]
        return LSPDocumentSymbol(
            name: name,
            detail: object["containerName"] as? String,
            kind: kind,
            line: line,
            character: character,
            endLine: number(from: end?["line"]),
            endCharacter: number(from: end?["character"])
        )
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

    private func handleNotification(method: String, params: [String: Any]?) {
        guard method == "textDocument/publishDiagnostics",
              let workspaceRoot = notificationWorkspaceRoot,
              let params,
              let uri = params["uri"] as? String else {
            return
        }

        let diagnostics = (params["diagnostics"] as? [[String: Any]] ?? []).compactMap(parseDiagnostic(from:))
        publishDiagnostics(
            workspaceRoot: workspaceRoot,
            uri: uri,
            diagnostics: diagnostics,
            documentVersion: number(from: params["version"])
        )
    }

    private func parseDiagnostic(from object: [String: Any]) -> LSPDiagnostic? {
        guard let message = object["message"] as? String else {
            return nil
        }

        let severity: LSPDiagnosticSeverity
        switch number(from: object["severity"]) {
        case 1:
            severity = .error
        case 2:
            severity = .warning
        case 3:
            severity = .information
        case 4:
            severity = .hint
        default:
            severity = .information
        }

        let source = object["source"] as? String
        let range = object["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]

        return LSPDiagnostic(
            message: message,
            severity: severity,
            source: source,
            line: number(from: start?["line"]),
            character: number(from: start?["character"])
        )
    }
}
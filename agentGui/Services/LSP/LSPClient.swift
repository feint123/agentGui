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

    /// Sends a `textDocument/didChange` notification.
    ///
    /// If `capabilities.syncKind == .incremental` and the LSP range can be computed,
    /// sends a ranged content-change event. Otherwise falls back to full-text sync.
    @discardableResult
    func updateDocument(
        uri: String,
        replacing nsRange: NSRange,
        insertedText: String,
        newText: String
    ) -> LSPDocumentSnapshot? {
        let useIncremental = capabilities?.syncKind == .incremental
        if useIncremental, let range = documentStore.lspRange(for: nsRange, uri: uri) {
            guard let snapshot = documentStore.updateDocument(uri: uri, text: newText) else { return nil }
            try? transport.sendNotification(
                method: "textDocument/didChange",
                params: [
                    "textDocument": [
                        "uri": uri,
                        "version": snapshot.version
                    ],
                    "contentChanges": [
                        ["range": range, "text": insertedText]
                    ]
                ]
            )
            onDocumentLifecycleEvent?("change:\(uri)", snapshot)
            return snapshot
        } else {
            return updateDocument(uri: uri, text: newText)
        }
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

    // MARK: - Cancellable Request Variants

    /// Hover 可取消变体：调用方预分配 ID，持有 handle，可随时 cancel。
    func cancellableHover(uri: String, line: Int, character: Int) -> LSPCancellableRequest<String?> {
        let requestID = transport.allocateRequestID()
        let params = documentPositionParams(uri: uri, line: line, character: character)
        let task = Task<String?, Error> { [transport] in
            let result = try await transport.sendCancellableRequest(
                id: requestID,
                method: "textDocument/hover",
                params: params
            )
            return self.parseHoverText(from: result)
        }
        return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
    }

    /// Definition 可取消变体。
    func cancellableDefinition(uri: String, line: Int, character: Int) -> LSPCancellableRequest<LSPSymbolLocation?> {
        let requestID = transport.allocateRequestID()
        let params = documentPositionParams(uri: uri, line: line, character: character)
        let task = Task<LSPSymbolLocation?, Error> { [transport] in
            let result = try await transport.sendCancellableRequest(
                id: requestID,
                method: "textDocument/definition",
                params: params
            )
            return self.parseFirstLocation(from: result)
        }
        return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
    }

    /// References 可取消变体。
    func cancellableReferences(uri: String, line: Int, character: Int) -> LSPCancellableRequest<[LSPSymbolLocation]> {
        let requestID = transport.allocateRequestID()
        var params = documentPositionParams(uri: uri, line: line, character: character)
        params["context"] = ["includeDeclaration": true]
        let task = Task<[LSPSymbolLocation], Error> { [transport] in
            let result = try await transport.sendCancellableRequest(
                id: requestID,
                method: "textDocument/references",
                params: params
            )
            return self.parseLocations(from: result)
        }
        return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
    }

    /// 发送 textDocument/completion 请求并解析返回的补全项列表。
    /// - Returns: 解析后的补全项数组；网络或解析失败时返回空数组（不 throw）。
    func completion(
        uri: String,
        line: Int,
        character: Int,
        triggerKind: LSPCompletionTriggerKind,
        triggerCharacter: String?
    ) async -> [CodeEditorCompletionItem] {
        var context: [String: Any] = ["triggerKind": triggerKind.rawValue]
        if let tc = triggerCharacter {
            context["triggerCharacter"] = tc
        }
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "position": ["line": line, "character": character],
            "context": context
        ]
        guard let result = try? await transport.sendRequest(
            method: "textDocument/completion",
            params: params
        ) else { return [] }
        return parseCompletionItems(from: result)
    }

    /// Convenience overload: resolves LSP position from a UTF-16 code-unit offset.
    func completion(
        uri: String,
        utf16Offset: Int,
        triggerKind: LSPCompletionTriggerKind,
        triggerCharacter: String?
    ) async -> [CodeEditorCompletionItem] {
        let position = documentStore.lspPosition(forUTF16Offset: utf16Offset, uri: uri)
        return await completion(
            uri: uri,
            line: position.line,
            character: position.character,
            triggerKind: triggerKind,
            triggerCharacter: triggerCharacter
        )
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

    // MARK: - Inlay Hints

    /// 请求 textDocument/inlayHint（LSP §3.17.12）。
    ///
    /// - Parameters:
    ///   - uri: 文档 URI。
    ///   - startLine/startCharacter: 请求范围起点（0-based）。
    ///   - endLine/endCharacter: 请求范围终点（0-based）。
    /// - Returns: 解析后的 hints 数组；失败或服务端无能力时返回空数组。
    func inlayHints(
        uri: String,
        startLine: Int,
        startCharacter: Int,
        endLine: Int,
        endCharacter: Int
    ) async -> [CodeEditorInlayHint] {
        let params: [String: Any] = [
            "textDocument": ["uri": uri],
            "range": [
                "start": ["line": startLine, "character": startCharacter],
                "end":   ["line": endLine,   "character": endCharacter]
            ]
        ]
        guard let result = try? await transport.sendRequest(
            method: "textDocument/inlayHint",
            params: params
        ) else { return [] }
        return parseInlayHints(from: result)
    }

    /// 按 UTF-16 行号边界发起请求（1-based → 0-based 转换由此方法负责）。
    func inlayHints(
        uri: String,
        startLine1Based: Int,
        endLine1Based: Int
    ) async -> [CodeEditorInlayHint] {
        return await inlayHints(
            uri: uri,
            startLine: max(0, startLine1Based - 1),
            startCharacter: 0,
            endLine: max(0, endLine1Based - 1),
            endCharacter: Int.max
        )
    }

    /// 解析 `textDocument/inlayHint` 响应 → `[CodeEditorInlayHint]`。
    ///
    /// 响应格式（LSP Spec）：
    /// ```
    /// InlayHint {
    ///   position: Position    // { line: number, character: number }（0-based）
    ///   label: string | InlayHintLabelPart[]
    ///   kind?: InlayHintKind  // 1=Type, 2=Parameter
    ///   paddingLeft?: boolean
    ///   paddingRight?: boolean
    /// }
    /// ```
    func parseInlayHints(from result: Any?) -> [CodeEditorInlayHint] {
        guard let array = result as? [[String: Any]] else { return [] }
        let maxLabelLength = 40

        var hints: [CodeEditorInlayHint] = []
        for item in array {
            guard let position = item["position"] as? [String: Any],
                  let line0     = (position["line"]      as? Int) ?? (position["line"]      as? NSNumber).map(\.intValue),
                  let char0     = (position["character"] as? Int) ?? (position["character"] as? NSNumber).map(\.intValue)
            else { continue }

            // label: string | InlayHintLabelPart[]
            let rawLabel: String
            if let str = item["label"] as? String {
                rawLabel = str
            } else if let parts = item["label"] as? [[String: Any]] {
                rawLabel = parts.compactMap { $0["value"] as? String }.joined()
            } else { continue }

            // 截断超长 label
            let label: String
            if rawLabel.count > maxLabelLength {
                label = String(rawLabel.prefix(maxLabelLength)) + "…"
            } else {
                label = rawLabel
            }

            let kindRaw = (item["kind"] as? Int) ?? (item["kind"] as? NSNumber).map(\.intValue) ?? 0
            let paddingLeft  = item["paddingLeft"]  as? Bool ?? false
            let paddingRight = item["paddingRight"] as? Bool ?? false

            hints.append(CodeEditorInlayHint(
                line: line0 + 1,           // 0-based → 1-based
                character: char0 + 1,      // 0-based → 1-based
                label: label,
                kind: CodeEditorInlayHintKind(rawValue: kindRaw),
                paddingLeft: paddingLeft,
                paddingRight: paddingRight
            ))
        }
        return hints
    }

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
                "workspace": [
                    "applyEdit": true,
                    "workspaceEdit": [
                        "documentChanges": true
                    ],
                    "symbol": [
                        "symbolKind": [
                            "valueSet": Array(1...26)
                        ]
                    ]
                ],
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": false,
                        "willSave": false,
                        "didSave": true
                    ],
                    "hover": [
                        "contentFormat": ["markdown", "plaintext"]
                    ],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": false,
                            "documentationFormat": ["markdown", "plaintext"],
                            "insertReplaceSupport": true
                        ],
                        "contextSupport": true
                    ],
                    "signatureHelp": [
                        "signatureInformation": [
                            "documentationFormat": ["markdown", "plaintext"],
                            "parameterInformation": ["labelOffsetSupport": true]
                        ],
                        "contextSupport": true
                    ],
                    "definition": ["linkSupport": false],
                    "declaration": ["linkSupport": false],
                    "typeDefinition": ["linkSupport": false],
                    "implementation": ["linkSupport": false],
                    "references": [:] as [String: Any],
                    "documentHighlight": [:] as [String: Any],
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true,
                        "symbolKind": ["valueSet": Array(1...26)]
                    ],
                    "codeAction": [
                        "codeActionLiteralSupport": [
                            "codeActionKind": [
                                "valueSet": ["", "quickfix", "refactor", "refactor.extract",
                                             "refactor.inline", "refactor.rewrite",
                                             "source", "source.organizeImports"]
                            ]
                        ],
                        "resolveSupport": ["properties": ["edit"]]
                    ],
                    "rename": [
                        "prepareSupport": true
                    ],
                    "formatting": [:] as [String: Any],
                    "rangeFormatting": [:] as [String: Any],
                    "onTypeFormatting": [:] as [String: Any],
                    "foldingRange": [
                        "rangeLimit": 5000,
                        "lineFoldingOnly": true
                    ],
                    "semanticTokens": [
                        "requests": ["full": true, "range": false],
                        "tokenTypes": [String](),
                        "tokenModifiers": [String](),
                        "formats": ["relative"],
                        "multilineTokenSupport": false
                    ],
                    "inlayHint": [
                        "resolveSupport": ["properties": ["tooltip", "textEdits", "label.tooltip"]]
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": true,
                        "versionSupport": true,
                        "tagSupport": ["valueSet": [1, 2]]
                    ]
                ]
            ]
        ]
    }

    private func negotiatedCapabilities(from rawResult: Any?, fallback: LSPServerCapabilityHints) -> LSPServerCapabilityHints {
        guard let object = rawResult as? [String: Any],
              let capabilities = object["capabilities"] as? [String: Any] else {
            return fallback
        }

        // Helper: extract trigger character array from an options dict
        func triggerChars(_ key: String, in opts: [String: Any]) -> [String] {
            (opts[key] as? [String]) ?? []
        }

        // textDocumentSync: Int | { change: Int }
        let syncKind: TextDocumentSyncKind
        if let rawSync = capabilities["textDocumentSync"] {
            if let syncInt = (rawSync as? Int) ?? (rawSync as? NSNumber).map({ $0.intValue }),
               let kind = TextDocumentSyncKind(rawValue: syncInt) {
                syncKind = kind
            } else if let syncObj = rawSync as? [String: Any],
                      let changeRaw = syncObj["change"],
                      let changeInt = (changeRaw as? Int) ?? (changeRaw as? NSNumber).map({ $0.intValue }),
                      let kind = TextDocumentSyncKind(rawValue: changeInt) {
                syncKind = kind
            } else {
                syncKind = fallback.syncKind
            }
        } else {
            syncKind = fallback.syncKind
        }

        // completion
        let completionOpts = capabilities["completionProvider"] as? [String: Any]
        let supportsCompletion: Bool = completionOpts != nil
            || (capabilities["completionProvider"] as? Bool ?? false)
        let completionTriggers: [String] = completionOpts.map { triggerChars("triggerCharacters", in: $0) } ?? []

        // signatureHelp
        let sigOpts = capabilities["signatureHelpProvider"] as? [String: Any]
        let supportsSignatureHelp = sigOpts != nil || (capabilities["signatureHelpProvider"] as? Bool ?? false)
        let sigTriggers: [String] = sigOpts.map { triggerChars("triggerCharacters", in: $0) } ?? []
        let sigRetriggers: [String] = sigOpts.map { triggerChars("retriggerCharacters", in: $0) } ?? []

        // onTypeFormatting — firstTriggerCharacter + moreTriggerCharacter
        var onTypeTriggers: [String] = []
        var supportsOnTypeFormatting = false
        if let onTypeOpts = capabilities["documentOnTypeFormattingProvider"] as? [String: Any] {
            supportsOnTypeFormatting = true
            if let first = onTypeOpts["firstTriggerCharacter"] as? String {
                onTypeTriggers.append(first)
            }
            if let more = onTypeOpts["moreTriggerCharacter"] as? [String] {
                onTypeTriggers.append(contentsOf: more)
            }
        }

        // rename — bool | { prepareProvider: bool }
        let renameRaw = capabilities["renameProvider"]
        let supportsRename: Bool = (renameRaw as? Bool) ?? (renameRaw is [String: Any])
        let supportsPrepareRename: Bool = (renameRaw as? [String: Any])?["prepareProvider"] as? Bool ?? false

        return LSPServerCapabilityHints(
            supportsHover: boolCapability(capabilities["hoverProvider"], fallback: fallback.supportsHover),
            supportsDefinition: boolCapability(capabilities["definitionProvider"], fallback: fallback.supportsDefinition),
            supportsReferences: boolCapability(capabilities["referencesProvider"], fallback: fallback.supportsReferences),
            supportsDocumentSymbols: boolCapability(capabilities["documentSymbolProvider"], fallback: fallback.supportsDocumentSymbols),
            supportsWorkspaceSymbols: boolCapability(
                capabilities["workspaceSymbolProvider"] ?? (capabilities["workspace"] as? [String: Any])?["symbolProvider"],
                fallback: fallback.supportsWorkspaceSymbols
            ),
            supportsDiagnostics: boolCapability(
                capabilities["diagnosticProvider"],
                fallback: fallback.supportsDiagnostics
            ),
            supportsCompletion: supportsCompletion,
            completionTriggerCharacters: completionTriggers,
            supportsSignatureHelp: supportsSignatureHelp,
            signatureHelpTriggerCharacters: sigTriggers,
            signatureHelpRetriggerCharacters: sigRetriggers,
            supportsCodeActions: boolCapability(capabilities["codeActionProvider"], fallback: fallback.supportsCodeActions),
            supportsDocumentFormatting: boolCapability(capabilities["documentFormattingProvider"], fallback: fallback.supportsDocumentFormatting),
            supportsRangeFormatting: boolCapability(capabilities["documentRangeFormattingProvider"], fallback: fallback.supportsRangeFormatting),
            supportsOnTypeFormatting: supportsOnTypeFormatting,
            onTypeFormattingTriggerCharacters: onTypeTriggers,
            supportsRename: supportsRename,
            supportsPrepareRename: supportsPrepareRename,
            supportsDocumentHighlights: boolCapability(capabilities["documentHighlightProvider"], fallback: fallback.supportsDocumentHighlights),
            supportsDeclaration: boolCapability(capabilities["declarationProvider"], fallback: fallback.supportsDeclaration),
            supportsTypeDefinition: boolCapability(capabilities["typeDefinitionProvider"], fallback: fallback.supportsTypeDefinition),
            supportsImplementation: boolCapability(capabilities["implementationProvider"], fallback: fallback.supportsImplementation),
            supportsFoldingRange: boolCapability(capabilities["foldingRangeProvider"], fallback: fallback.supportsFoldingRange),
            supportsSemanticTokens: (capabilities["semanticTokensProvider"] as? [String: Any]) != nil,
            supportsInlayHints: boolCapability(capabilities["inlayHintProvider"], fallback: fallback.supportsInlayHints),
            syncKind: syncKind
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
        let end = range?["end"] as? [String: Any]

        return LSPDiagnostic(
            message: message,
            severity: severity,
            source: source,
            line: number(from: start?["line"]),
            character: number(from: start?["character"]),
            endLine: number(from: end?["line"]),
            endCharacter: number(from: end?["character"])
        )
    }

    private func parseCompletionItems(from result: Any?) -> [CodeEditorCompletionItem] {
        // LSP 返回 CompletionList | CompletionItem[] | null
        let rawItems: [[String: Any]]
        if let list = result as? [String: Any],
           let items = list["items"] as? [[String: Any]] {
            rawItems = items               // CompletionList
        } else if let items = result as? [[String: Any]] {
            rawItems = items               // CompletionItem[]
        } else {
            return []
        }

        return rawItems.compactMap { item -> CodeEditorCompletionItem? in
            guard let label = item["label"] as? String else { return nil }
            let detail = item["detail"] as? String
            let insertText = item["insertText"] as? String
            let filterText = item["filterText"] as? String
            let kindRaw = item["kind"] as? Int
            let formatRaw = (item["insertTextFormat"] as? Int) ?? 1
            let documentationRaw = item["documentation"]
            let documentation: String?
            if let s = documentationRaw as? String {
                documentation = s
            } else if let d = documentationRaw as? [String: Any],
                      let value = d["value"] as? String {
                documentation = value
            } else {
                documentation = nil
            }
            return CodeEditorCompletionItem(
                label: label,
                detail: detail,
                documentation: documentation,
                kind: kindRaw.flatMap { LSPCompletionItemKind(rawValue: $0) },
                insertText: insertText,
                insertTextFormat: LSPInsertTextFormat(rawValue: formatRaw) ?? .plainText,
                filterText: filterText
            )
        }
    }
}

// MARK: - Testing Hooks

final class _NoOpLSPAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .allDisabled
    }
}

extension LSPClient {
    @MainActor
    static func negotiatedCapabilitiesForTesting(
        from rawResult: Any?,
        fallback: LSPServerCapabilityHints
    ) -> LSPServerCapabilityHints {
        let dummy = LSPClient(
            transport: LSPJSONRPCTransport(),
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        return dummy.negotiatedCapabilities(from: rawResult, fallback: fallback)
    }

    /// テスト専用：データパースのみを検証するための最小クライアントを生成する。
    static func makeTestInstance() -> LSPClient {
        LSPClient(
            transport: LSPJSONRPCTransport(),
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
    }

    @MainActor
    func initializeParamsForTesting(workspaceRoot: String) -> [String: Any] {
        initializeParams(workspaceRoot: workspaceRoot)
    }

    /// For testing only: directly sets the negotiated capabilities.
    func setCapabilitiesForTesting(_ hints: LSPServerCapabilityHints) {
        capabilities = hints
    }
}

// MARK: - LSPCancellableRequest

/// LSP 可取消请求句柄。调用方持有此句柄，可在需要时通过 `cancel()` 向服务器发送
/// `$/cancelRequest` 并中止本地 await。
final class LSPCancellableRequest<T: Sendable>: Sendable {
    let requestID: String
    private let transport: LSPJSONRPCTransport
    private let task: Task<T, Error>

    init(transport: LSPJSONRPCTransport, task: Task<T, Error>, requestID: String) {
        self.transport = transport
        self.task = task
        self.requestID = requestID
    }

    /// 等待请求完成并返回结果。若已取消则 throw `CancellationError`。
    func result() async throws -> T {
        try await task.value
    }

    /// 向服务器发送 `$/cancelRequest` 通知，并取消本地 task。
    func cancel() {
        try? transport.cancelRequest(id: requestID)
        task.cancel()
    }
}
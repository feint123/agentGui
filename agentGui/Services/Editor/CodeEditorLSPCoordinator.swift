import Foundation

struct CodeEditorLSPDocumentBinding: Equatable, Sendable {
    let workspaceRoot: String
    let serverID: String
    let uri: String
    let languageID: String
}

@MainActor
final class CodeEditorLSPCoordinator {
    private let manager: LSPServerManager
    private let binding: CodeEditorLSPDocumentBinding
    private let debounceNanoseconds: UInt64

    private var isOpen = false
    private var latestLocalVersion = 0
    private var latestSentVersion = 0
    private var pendingText: String?
    private var pendingVersion: Int?
    private var pendingChangeTask: Task<Void, Never>?
    private var pendingChangeSet: EditorChangeSet?
    private var pendingChangeSetIsAmbiguous = false
    private var latestHoverGeneration = 0
    private var pendingHoverTask: Task<Void, Never>?
    private var completionGeneration = 0
    private var pendingCompletionTask: Task<Void, Never>?

    init(
        manager: LSPServerManager,
        binding: CodeEditorLSPDocumentBinding,
        debounceNanoseconds: UInt64 = 120_000_000
    ) {
        self.manager = manager
        self.binding = binding
        self.debounceNanoseconds = debounceNanoseconds
    }

    deinit {
        pendingChangeTask?.cancel()
        pendingHoverTask?.cancel()
        pendingCompletionTask?.cancel()
    }

    func activate(initialText: String, version: Int) {
        latestLocalVersion = max(latestLocalVersion, version)

        guard !isOpen else {
            return
        }

        manager.syncDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri,
            languageID: binding.languageID,
            text: initialText
        )
        isOpen = true
        latestSentVersion = max(latestSentVersion, version)
    }

    func handleTextChange(text: String, change: EditorChangeSet) {
        switch change.origin {
        case .userEdit:
            latestLocalVersion = max(latestLocalVersion, change.version)
            // Track change accumulation.
            // If there's already a pending change we haven't flushed, mark as ambiguous
            // so the flush falls back to full sync.
            if pendingText != nil {
                pendingChangeSetIsAmbiguous = true
            } else {
                pendingChangeSet = change
                pendingChangeSetIsAmbiguous = false
            }
            pendingText = text
            pendingVersion = change.version
            schedulePendingChange(expectedVersion: change.version)

        case .externalReload:
            handleProgrammaticReload(text: text, version: change.version)
        }
    }

    func handleProgrammaticReload(text: String, version: Int) {
        latestLocalVersion = max(latestLocalVersion, version)
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        pendingText = nil
        pendingVersion = nil
        pendingChangeSet = nil
        pendingChangeSetIsAmbiguous = false
        cancelHover()

        if !isOpen {
            activate(initialText: text, version: version)
            return
        }

        manager.syncDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri,
            languageID: binding.languageID,
            text: text
        )
        latestSentVersion = max(latestSentVersion, version)
    }

    func deactivate() {
        pendingChangeTask?.cancel()
        pendingChangeTask = nil
        pendingText = nil
        pendingVersion = nil
        pendingChangeSet = nil
        pendingChangeSetIsAmbiguous = false
        cancelHover()

        guard isOpen else {
            return
        }

        manager.closeDocument(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri
        )
        isOpen = false
    }

    func acceptsDiagnostics(_ snapshot: LSPDiagnosticsSnapshot?) -> Bool {
        guard isOpen,
              let snapshot,
              snapshot.workspaceRoot == binding.workspaceRoot,
              snapshot.uri == binding.uri else {
            return false
        }

        guard let documentVersion = snapshot.documentVersion else {
            return true
        }

        guard documentVersion >= latestSentVersion else {
            return false
        }

        guard documentVersion <= latestLocalVersion else {
            return false
        }

        return true
    }

    func requestDefinition(at position: CodeEditorSemanticPosition) async -> CodeEditorRevealRequest? {
        guard canServeSemanticRequest(
            supports: \LSPServerCapabilityHints.supportsDefinition,
            requestVersion: position.version
        ) else {
            return nil
        }

        do {
            guard let location = try await manager.definition(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                line: max(position.line - 1, 0),
                character: max(position.column - 1, 0)
            ) else {
                return nil
            }

            guard position.version == latestLocalVersion,
                  let fileURL = localFileURL(for: location.uri) else {
                return nil
            }

            return CodeEditorRevealRequest(
                fileURL: fileURL,
                line: location.line + 1,
                column: location.character + 1,
                reason: .definition
            )
        } catch {
            return nil
        }
    }

    func requestReferences(at position: CodeEditorSemanticPosition) async -> CodeEditorReferencePresentation? {
        guard canServeSemanticRequest(
            supports: \LSPServerCapabilityHints.supportsReferences,
            requestVersion: position.version
        ) else {
            return nil
        }

        do {
            let locations = try await manager.references(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                line: max(position.line - 1, 0),
                character: max(position.column - 1, 0)
            )

            guard position.version == latestLocalVersion else {
                return nil
            }

            let items = locations.compactMap { location -> CodeEditorReferencePresentation.Item? in
                guard let fileURL = localFileURL(for: location.uri) else {
                    return nil
                }

                let line = location.line + 1
                let column = location.character + 1
                return CodeEditorReferencePresentation.Item(
                    fileURL: fileURL,
                    line: line,
                    column: column,
                    title: fileURL.lastPathComponent,
                    subtitle: "Ln \(line), Col \(column)"
                )
            }

            guard !items.isEmpty else {
                return nil
            }

            return CodeEditorReferencePresentation(queryPosition: position, items: items)
        } catch {
            return nil
        }
    }

    func requestDocumentSymbols(documentVersion: Int) async -> [LSPDocumentSymbol] {
        guard canServeSemanticRequest(
            supports: \LSPServerCapabilityHints.supportsDocumentSymbols,
            requestVersion: documentVersion
        ) else {
            return []
        }

        do {
            let symbols = try await manager.documentSymbols(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri
            )
            guard documentVersion == latestLocalVersion, isOpen else {
                return []
            }
            return symbols
        } catch {
            return []
        }
    }

    func scheduleHover(
        at position: CodeEditorSemanticPosition,
        debounceNanoseconds: UInt64,
        deliver: @escaping @MainActor (CodeEditorHoverPresentation?) -> Void
    ) {
        guard canServeSemanticRequest(
            supports: \LSPServerCapabilityHints.supportsHover,
            requestVersion: position.version
        ) else {
            deliver(nil)
            return
        }

        latestHoverGeneration += 1
        let generation = latestHoverGeneration
        pendingHoverTask?.cancel()
        pendingHoverTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }

            let hoverText: String?
            do {
                hoverText = try await self.manager.hover(
                    workspaceRoot: self.binding.workspaceRoot,
                    serverID: self.binding.serverID,
                    uri: self.binding.uri,
                    line: max(position.line - 1, 0),
                    character: max(position.column - 1, 0)
                )
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.latestHoverGeneration == generation,
                          self.isOpen else {
                        return
                    }

                    self.pendingHoverTask = nil
                    deliver(nil)
                }
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.latestHoverGeneration == generation,
                      self.isOpen,
                      position.version == self.latestLocalVersion,
                      let hoverText,
                      hoverText.isEmpty == false else {
                    deliver(nil)
                    return
                }

                self.pendingHoverTask = nil
                deliver(CodeEditorHoverPresentation(position: position, markdown: hoverText))
            }
        }
    }

    func cancelHover() {
        latestHoverGeneration += 1
        pendingHoverTask?.cancel()
        pendingHoverTask = nil
    }

    /// 当前服务端协商能力（用于检查 supportsCompletion 等）。
    var capabilities: LSPServerCapabilityHints? {
        manager.capabilities(for: binding.workspaceRoot, serverID: binding.serverID)
    }

    /// 请求 LSP 代码补全（含代际取消）。
    /// - Parameters:
    ///   - context: 触发上下文
    ///   - onResult: 主线程回调。items 为 nil 表示被取消。
    func requestCompletion(
        context: CompletionTriggerContext,
        onResult: @MainActor @escaping ([CodeEditorCompletionItem]?) -> Void
    ) {
        guard isOpen else { return }
        completionGeneration &+= 1
        let generation = completionGeneration
        pendingCompletionTask?.cancel()
        pendingCompletionTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.manager.completion(
                workspaceRoot: self.binding.workspaceRoot,
                serverID: self.binding.serverID,
                uri: self.binding.uri,
                utf16Offset: context.cursorOffset,
                triggerKind: context.triggerKind,
                triggerCharacter: context.triggerCharacter
            )
            guard !Task.isCancelled, self.completionGeneration == generation else {
                await onResult(nil)
                return
            }
            await onResult(items)
        }
    }

    func cancelCompletion() {
        pendingCompletionTask?.cancel()
        pendingCompletionTask = nil
    }

    private func schedulePendingChange(expectedVersion: Int) {
        pendingChangeTask?.cancel()
        pendingChangeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingChange(expectedVersion: expectedVersion)
        }
    }

    private func flushPendingChange(expectedVersion: Int) {
        guard let pendingText,
              let pendingVersion,
              pendingVersion == expectedVersion else {
            return
        }

        // Only forward EditorChangeSet when exactly one change accumulated (unambiguous),
        // enabling the incremental sync path. Multiple accumulated changes fall back to full.
        let changeSetToSend: EditorChangeSet? = pendingChangeSetIsAmbiguous ? nil : pendingChangeSet

        if !isOpen {
            activate(initialText: pendingText, version: pendingVersion)
        } else {
            manager.syncDocument(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                languageID: binding.languageID,
                text: pendingText,
                editorChange: changeSetToSend
            )
        }

        latestSentVersion = max(latestSentVersion, pendingVersion)
        self.pendingText = nil
        self.pendingVersion = nil
        self.pendingChangeSet = nil
        self.pendingChangeSetIsAmbiguous = false
        pendingChangeTask = nil
    }

    private func canServeSemanticRequest(
        supports capability: KeyPath<LSPServerCapabilityHints, Bool>,
        requestVersion: Int
    ) -> Bool {
        guard isOpen,
              requestVersion == latestLocalVersion,
              let capabilities = manager.capabilities(for: binding.workspaceRoot, serverID: binding.serverID) else {
            return false
        }

        return capabilities[keyPath: capability]
    }

    private func localFileURL(for uri: String) -> URL? {
        guard let url = URL(string: uri), url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL
    }
}
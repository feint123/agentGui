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

    private func schedulePendingChange(expectedVersion: Int) {
        pendingChangeTask?.cancel()
        pendingChangeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.flushPendingChange(expectedVersion: expectedVersion)
        }
    }

    private func flushPendingChange(expectedVersion: Int) {
        guard let pendingText,
              let pendingVersion,
              pendingVersion == expectedVersion else {
            return
        }

        if !isOpen {
            activate(initialText: pendingText, version: pendingVersion)
        } else {
            manager.syncDocument(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                languageID: binding.languageID,
                text: pendingText
            )
        }

        latestSentVersion = max(latestSentVersion, pendingVersion)
        self.pendingText = nil
        self.pendingVersion = nil
        pendingChangeTask = nil
    }
}
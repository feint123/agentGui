import Foundation

struct LSPToolFacade {
    let registry: LSPServerRegistry
    let serverManager: LSPServerManager?

    func listServers() -> String {
        registry.allDefinitions()
            .map { "\($0.id): \($0.displayName)" }
            .joined(separator: "\n")
    }

    func serverStatus(workspaceRoot: String, serverID: String) -> String {
        guard let definition = registry.definition(for: serverID) else {
            return "Error: unknown LSP server '\(serverID)'"
        }

        guard let state = serverManager?.state(for: workspaceRoot, serverID: serverID) else {
            return "\(definition.id): inactive"
        }

        var lines = ["\(definition.id): \(state.summaryText)"]
        let recentLogs = serverManager?.recentLogs(for: workspaceRoot, serverID: serverID) ?? []
        if !recentLogs.isEmpty {
            lines.append("Recent logs:")
            lines.append(contentsOf: recentLogs.suffix(8).map { "- [\($0.level.rawValue)] \($0.message)" })
        }
        return lines.joined(separator: "\n")
    }

    func diagnostics(workspaceRoot: String, uri: String) -> String {
        guard let snapshot = serverManager?.diagnosticsStore.snapshot(for: workspaceRoot, uri: uri) else {
            return "No diagnostics for \(uri)"
        }

        let lines = snapshot.diagnostics.map { "[\($0.severity.rawValue)] \($0.message)" }
        return lines.joined(separator: "\n")
    }

    func definition(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        guard let location = try await serverManager?.definition(
            workspaceRoot: workspaceRoot,
            serverID: serverID,
            uri: uri,
            line: line,
            character: character
        ) else {
            return "No definition found for \(uri):\(line):\(character)"
        }

        return "\(location.uri) @ \(location.line):\(location.character)"
    }

    func references(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        let locations = try await serverManager?.references(
            workspaceRoot: workspaceRoot,
            serverID: serverID,
            uri: uri,
            line: line,
            character: character
        ) ?? []
        guard !locations.isEmpty else {
            return "No references found for \(uri):\(line):\(character)"
        }

        return locations
            .map { "\($0.uri) @ \($0.line):\($0.character)" }
            .joined(separator: "\n")
    }

    func hover(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        return try await serverManager?.hover(
            workspaceRoot: workspaceRoot,
            serverID: serverID,
            uri: uri,
            line: line,
            character: character
        ) ?? "No hover found for \(uri):\(line):\(character)"
    }

    func documentSymbols(workspaceRoot: String, serverID: String, uri: String) -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        return "Document symbols are not implemented yet for \(uri)"
    }

    func workspaceSymbols(workspaceRoot: String, serverID: String, query: String) -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        return "Workspace symbol search is not implemented yet for '\(query)'"
    }
}

extension LSPProcessState {
    var summaryText: String {
        switch self {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .running(let processIdentifier):
            return "running (pid: \(processIdentifier))"
        case .failedToLaunch(let reason):
            return "failedToLaunch (\(reason))"
        case .crashed(let reason, let restartCount):
            return "crashed (\(reason), restartCount: \(restartCount))"
        case .stopped:
            return "stopped"
        }
    }
}
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

    func documentSymbols(workspaceRoot: String, serverID: String, uri: String) async throws -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        let symbols = try await serverManager?.documentSymbols(
            workspaceRoot: workspaceRoot,
            serverID: serverID,
            uri: uri
        ) ?? []

        guard !symbols.isEmpty else {
            return "No document symbols found for \(uri)"
        }

        return formatDocumentSymbols(symbols)
    }

    func workspaceSymbols(workspaceRoot: String, serverID: String, query: String) -> String {
        guard serverManager?.state(for: workspaceRoot, serverID: serverID) != nil else {
            return "Error: no active LSP session for \(serverID) in \(workspaceRoot)"
        }

        return "Workspace symbol search is not implemented yet for '\(query)'"
    }
}

private extension LSPToolFacade {
    func formatDocumentSymbols(_ symbols: [LSPDocumentSymbol], depth: Int = 0) -> String {
        symbols
            .flatMap { symbol -> [String] in
                let indent = String(repeating: "  ", count: depth)
                let location = "@ \(symbol.line + 1):\(symbol.character + 1)"
                let detail = symbol.detail.flatMap { $0.isEmpty ? nil : $0 }
                let line = ["\(indent)\(symbol.name)", detail, location]
                    .compactMap { $0 }
                    .joined(separator: " ")
                let childLines = formatDocumentSymbols(symbol.children, depth: depth + 1)
                if childLines.isEmpty {
                    return [line]
                }
                return [line, childLines]
            }
            .joined(separator: "\n")
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
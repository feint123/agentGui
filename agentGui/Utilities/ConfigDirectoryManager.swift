//
//  ConfigDirectoryManager.swift
//  agentGui
//
//  Manages the app's file-system configuration directory at ~/.agentgui/.
//  A compatibility memory.md file is still created for migration-safe startup.
//

import Foundation


// MARK: - ConfigDirectoryManager

final class ConfigDirectoryManager {

    static let shared = ConfigDirectoryManager()
    private init() {}

    // MARK: - Paths

    /// `~/.agentgui/`
    let agentGuiDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".agentgui", isDirectory: true)
    }()

    /// `~/.agentgui/memory.md`
    var memoryFileURL: URL {
        agentGuiDir.appendingPathComponent("memory.md")
    }

    /// `~/.agentgui/lsp-server/`
    var lspServerDirectoryURL: URL {
        agentGuiDir.appendingPathComponent("lsp-server", isDirectory: true)
    }

    // MARK: - Setup

    /// Creates `~/.agentgui/` and an empty legacy `memory.md` if they do not yet exist.
    /// Call once at app launch.
    func setup() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: agentGuiDir, withIntermediateDirectories: true)
        } catch {
            print("[ConfigDirectoryManager] Failed to create config directory: \(error)")
            return
        }

        if !fm.fileExists(atPath: memoryFileURL.path) {
            let placeholder = """
            # Long-term Memory
            <!-- Legacy compatibility file retained for migration-safe startup. -->
            """
            try? placeholder.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        }

        do {
            try fm.createDirectory(at: lspServerDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[ConfigDirectoryManager] Failed to create LSP server directory: \(error)")
        }
    }

}

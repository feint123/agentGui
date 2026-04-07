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

    /// `~/.agentgui/lsp-server/`
    var lspServerDirectoryURL: URL {
        agentGuiDir.appendingPathComponent("lsp-server", isDirectory: true)
    }

    /// `~/.agentgui/memory/`
    var memoryDir: URL {
        agentGuiDir.appendingPathComponent("memory", isDirectory: true)
    }

    /// `~/.agentgui/memory/MEMORY.md`
    var memoryIndexURL: URL {
        memoryDir.appendingPathComponent("MEMORY.md")
    }

    /// `~/.agentgui/sessions/{sessionId}/session-memory/`
    func sessionMemoryDir(sessionId: String) -> URL {
        agentGuiDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("session-memory", isDirectory: true)
    }

    /// `~/.agentgui/sessions/{sessionId}/session-memory/summary.md`
    func sessionMemorySummaryURL(sessionId: String) -> URL {
        sessionMemoryDir(sessionId: sessionId)
            .appendingPathComponent("summary.md")
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

        do {
            try fm.createDirectory(at: lspServerDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[ConfigDirectoryManager] Failed to create LSP server directory: \(error)")
        }

        do {
            try fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        } catch {
            print("[ConfigDirectoryManager] Failed to create memory directory: \(error)")
        }
    }

}

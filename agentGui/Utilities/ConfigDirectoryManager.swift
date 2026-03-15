//
//  ConfigDirectoryManager.swift
//  agentGui
//
//  Manages the app's file-system configuration directory at ~/.agentgui/.
//  Currently stores:
//   - memory.md  — legacy local memory file retained for compatibility/migration,
//                  no longer injected directly into system prompts
//

import Foundation

// MARK: - Write Mode

enum MemoryWriteMode {
    case overwrite
    case append
}

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
            <!-- Claude will update this file via the memory_write tool. -->
            <!-- You can also edit it directly in the Settings panel.    -->
            """
            try? placeholder.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        }

        do {
            try fm.createDirectory(at: lspServerDirectoryURL, withIntermediateDirectories: true)
        } catch {
            print("[ConfigDirectoryManager] Failed to create LSP server directory: \(error)")
        }
    }

    // MARK: - Read

    /// Returns the current contents of the legacy `memory.md`, or `""` on failure.
    func readMemory() -> String {
        (try? String(contentsOf: memoryFileURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Write

    /// Writes `content` to the legacy `memory.md` compatibility file.
    /// - `.overwrite`: replaces the entire file.
    /// - `.append`: adds a newline separator then `content` at the end.
    @discardableResult
    func writeMemory(content: String, mode: MemoryWriteMode) -> Result<Void, Error> {
        do {
            switch mode {
            case .overwrite:
                try content.write(to: memoryFileURL, atomically: true, encoding: .utf8)
            case .append:
                let existing = readMemory()
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                let combined = existing + separator + content
                try combined.write(to: memoryFileURL, atomically: true, encoding: .utf8)
            }
            return .success(())
        } catch {
            print("[ConfigDirectoryManager] Failed to write memory.md: \(error)")
            return .failure(error)
        }
    }
}

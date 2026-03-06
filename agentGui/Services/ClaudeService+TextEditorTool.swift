//
//  ClaudeService+TextEditorTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Text Editor Tool

extension ClaudeService {

    /// Dispatches text editor commands. Runs all blocking file I/O off the MainActor
    /// via Task.detached to prevent freezing the UI.
    func executeTextEditorTool(input: MessageResponse.Content.Input) async -> String {
        // Extract input values on MainActor before hopping off
        let command   = input["command"]?.stringValue
        let path      = input["path"]?.stringValue
        let oldStr    = input["old_str"]?.stringValue
        let newStr    = input["new_str"]?.stringValue
        let fileText  = input["file_text"]?.stringValue
        let insertLine = input["insert_line"]?.intValue
        let viewRange  = input["view_range"]?.arrayValue?.compactMap { $0.intValue }

        return await Task.detached(priority: .userInitiated) {
            guard let command else { return "Error: missing 'command' parameter" }
            guard let path    else { return "Error: missing 'path' parameter" }

            switch command {
            case "view", "read", "open":
                return Self.textEditorView(path: path, viewRange: viewRange)
            case "str_replace":
                guard let oldStr else { return "Error: missing 'old_str'" }
                return Self.textEditorStrReplace(path: path, oldStr: oldStr, newStr: newStr ?? "")
            case "create":
                guard let fileText else { return "Error: missing 'file_text'" }
                return Self.textEditorWrite(path: path, fileText: fileText)
            case "write":
                return Self.textEditorWrite(path: path, fileText: newStr ?? fileText ?? "")
            case "insert":
                guard let insertLine, let newStr else { return "Error: missing parameters" }
                return Self.textEditorInsert(path: path, insertLine: insertLine, newStr: newStr)
            default:
                return "Error: unknown command '\(command)'"
            }
        }.value
    }

    // MARK: - File Operations (nonisolated static — no actor isolation needed)

    nonisolated private static func textEditorView(path: String, viewRange: [Int]?) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            let start: Int
            let end: Int
            if let r = viewRange, r.count >= 2 {
                start = max(1, r[0])
                end = min(lines.count, r[1])
            } else {
                start = 1
                end = lines.count
            }
            return lines[(start - 1)..<end]
                .enumerated()
                .map { "\(start + $0.offset)\t\($0.element)" }
                .joined(separator: "\n")
        } catch {
            return "Error reading '\(path)': \(error.localizedDescription)"
        }
    }

    nonisolated private static func textEditorStrReplace(path: String, oldStr: String, newStr: String) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let count = content.components(separatedBy: oldStr).count - 1
            if count == 0 { return "Error: old_str not found in '\(path)'" }
            if count > 1 { return "Error: old_str appears \(count) times (ambiguous). Add more context." }
            let updated = content.replacingOccurrences(of: oldStr, with: newStr, options: .literal)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            return "Replaced text in '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    nonisolated private static func textEditorWrite(path: String, fileText: String) -> String {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try fileText.write(toFile: path, atomically: true, encoding: .utf8)
            return "Written '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    nonisolated private static func textEditorInsert(path: String, insertLine: Int, newStr: String) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            let idx = max(0, min(insertLine, lines.count))
            lines.insert(contentsOf: newStr.components(separatedBy: "\n"), at: idx)
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return "Inserted text after line \(insertLine) in '\(path)'."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}


//
//  ClaudeService+TextEditorTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Text Editor Tool

extension ClaudeService {

    func executeTextEditorTool(input: MessageResponse.Content.Input) -> String {
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        guard let path = input["path"]?.stringValue else {
            return "Error: missing 'path' parameter"
        }

        switch command {
        case "view":
            let range = input["view_range"]?.arrayValue?.compactMap { $0.intValue }
            return textEditorView(path: path, viewRange: range)
        case "str_replace":
            guard let oldStr = input["old_str"]?.stringValue else { return "Error: missing 'old_str'" }
            let newStr = input["new_str"]?.stringValue ?? ""
            return textEditorStrReplace(path: path, oldStr: oldStr, newStr: newStr)
        case "create":
            guard let fileText = input["file_text"]?.stringValue else { return "Error: missing 'file_text'" }
            return textEditorWrite(path: path, fileText: fileText)
        case "write":
            // Claude 4 uses 'write' to overwrite entire file content
            let fileText = input["new_str"]?.stringValue ?? input["file_text"]?.stringValue ?? ""
            return textEditorWrite(path: path, fileText: fileText)
        case "insert":
            guard let line = input["insert_line"]?.intValue,
                  let newStr = input["new_str"]?.stringValue else { return "Error: missing parameters" }
            return textEditorInsert(path: path, insertLine: line, newStr: newStr)
        default:
            return "Error: unknown command '\(command)'"
        }
    }

    // MARK: - File Operations

    private func textEditorView(path: String, viewRange: [Int]?) -> String {
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

    private func textEditorStrReplace(path: String, oldStr: String, newStr: String) -> String {
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

    private func textEditorWrite(path: String, fileText: String) -> String {
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

    private func textEditorInsert(path: String, insertLine: Int, newStr: String) -> String {
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

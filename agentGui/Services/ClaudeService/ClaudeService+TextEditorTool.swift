//
//  ClaudeService+TextEditorTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

// MARK: - Text Editor Tool

extension ClaudeService {

    /// Dispatches text editor commands. Runs all blocking file I/O off the MainActor
    /// via Task.detached to prevent freezing the UI.
    func executeTextEditorTool(
        input: MessageResponse.Content.Input,
        sessionID: String,
        baseWorkspaceRoot: String?,
        modelContext: ModelContext
    ) async -> ToolExecutionResult {
        // Extract input values on MainActor before hopping off
        let command   = input["command"]?.stringValue
        let path      = input["path"]?.stringValue
        let oldStr    = input["old_str"]?.stringValue
        let newStr    = input["new_str"]?.stringValue
        let fileText  = input["file_text"]?.stringValue
        let insertLine = input["insert_line"]?.intValue
        let viewRange  = input["view_range"]?.arrayValue?.compactMap { $0.intValue }

        guard let command else { return .missingParameter("command") }
        guard let path else { return .missingParameter("path") }

        switch command {
        case "view", "read", "open":
            return await Task.detached(priority: .userInitiated) {
                .success(Self.textEditorView(path: path, viewRange: viewRange))
            }.value
        case "str_replace":
            guard let oldStr else { return .missingParameter("old_str") }
            return await stageTextEditorDraft(
                sessionID: sessionID,
                baseWorkspaceRoot: baseWorkspaceRoot,
                modelContext: modelContext
            ) {
                try DirectIntentDraft.strReplace(path: path, oldStr: oldStr, newStr: newStr ?? "")
            }
        case "create":
            guard let fileText else { return .missingParameter("file_text") }
            return await stageTextEditorDraft(
                sessionID: sessionID,
                baseWorkspaceRoot: baseWorkspaceRoot,
                modelContext: modelContext
            ) {
                try DirectIntentDraft.write(path: path, fileText: fileText)
            }
        case "write":
            return await stageTextEditorDraft(
                sessionID: sessionID,
                baseWorkspaceRoot: baseWorkspaceRoot,
                modelContext: modelContext
            ) {
                try DirectIntentDraft.write(path: path, fileText: newStr ?? fileText ?? "")
            }
        case "insert":
            guard let insertLine, let newStr else {
                return .failure("Error: missing parameters")
            }
            return await stageTextEditorDraft(
                sessionID: sessionID,
                baseWorkspaceRoot: baseWorkspaceRoot,
                modelContext: modelContext
            ) {
                try DirectIntentDraft.insert(path: path, insertLine: insertLine, newStr: newStr)
            }
        default:
            return .unknownTool(command)
        }
    }

    private func stageTextEditorDraft(
        sessionID: String,
        baseWorkspaceRoot: String?,
        modelContext: ModelContext,
        makeDraft: @escaping @Sendable () throws -> DirectIntentDraft
    ) async -> ToolExecutionResult {
        let draftResult = await Task.detached(priority: .userInitiated) {
            Result { try makeDraft() }
        }.value

        switch draftResult {
        case .failure(let error):
            return ToolExecutionResult.detect(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                toolName: "str_replace_based_edit_tool"
            )
        case .success(let draft):
            let backend = DirectIntentBackend(
                modelContext: modelContext,
                projectionStore: changeReviewProjectionStore
            )

            do {
                let snapshot = try await backend.stageDraft(
                    draft,
                    sessionID: sessionID,
                    baseWorkspaceRoot: baseWorkspaceRoot
                )
                let fileCount = snapshot.fileChanges.count
                let summary = "已创建待审查变更提案（\(fileCount) 个文件）。在 Apply 前不会修改真实工作区。"
                return ToolExecutionResult(
                    summary,
                    status: .success,
                    rawOutputText: summary,
                    changeProposalID: snapshot.proposal.id,
                    changeProposalState: snapshot.proposal.state,
                    changeProposalSnapshot: snapshot,
                    changeProposalDiffContent: snapshot.fileChanges.first?.unifiedDiff
                )
            } catch {
                return ToolExecutionResult.detect(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    toolName: "str_replace_based_edit_tool"
                )
            }
        }
    }

    // MARK: - File Operations (nonisolated static — no actor isolation needed)

    nonisolated private static func textEditorView(path: String, viewRange: [Int]?) -> String {
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            return renderTextEditorView(content: content, viewRange: viewRange)
        } catch {
            return "Error reading '\(path)': \(error.localizedDescription)"
        }
    }

    nonisolated static func renderTextEditorViewForTests(content: String, viewRange: [Int]?) -> String {
        renderTextEditorView(content: content, viewRange: viewRange)
    }

    nonisolated private static func renderTextEditorView(content: String, viewRange: [Int]?) -> String {
        let lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }

        let bounds = normalizedViewBounds(totalLines: lines.count, viewRange: viewRange)
        return lines[(bounds.start - 1)..<bounds.end]
            .enumerated()
            .map { "\(bounds.start + $0.offset)\t\($0.element)" }
            .joined(separator: "\n")
    }

    nonisolated private static func normalizedViewBounds(totalLines: Int, viewRange: [Int]?) -> (start: Int, end: Int) {
        let safeTotal = max(1, totalLines)
        guard let viewRange, viewRange.count >= 2 else {
            return (1, safeTotal)
        }

        let requestedStart = max(1, viewRange[0])
        let requestedEnd = max(1, viewRange[1])
        let clampedStart = min(requestedStart, safeTotal)
        let clampedEnd = min(requestedEnd, safeTotal)

        if clampedStart > clampedEnd {
            return (clampedStart, clampedStart)
        }

        return (clampedStart, clampedEnd)
    }

}


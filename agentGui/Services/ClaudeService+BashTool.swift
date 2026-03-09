//
//  ClaudeService+BashTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

extension ClaudeService {

    // MARK: - Bash Tool

    func executeBashTool(
        input: MessageResponse.Content.Input,
        session: BashSession,
        workingDirectory: String?,
        settings: AppSettings
    ) async -> String {
        let environmentOverrides = settings.proxyConfiguration.bashEnvironmentOverrides
        if input["restart"]?.boolValue == true {
            await session.restart(
                workingDirectory: workingDirectory,
                environmentOverrides: environmentOverrides
            )
            return "Bash session restarted."
        }
        let hasFollowUpInput = input["input"]?.stringValue != nil
        let isInteractive = input["interactive"]?.boolValue == true || hasFollowUpInput
        let timeout: TimeInterval
        if let t = input["timeout"]?.intValue {
            timeout = TimeInterval(max(1, t))
        } else {
            timeout = isInteractive ? 2 : 300
        }
        if input["interrupt"]?.boolValue == true {
            return await session.interrupt(timeout: timeout)
        }
        if let followUpInput = input["input"]?.stringValue {
            return await session.sendInput(followUpInput, timeout: timeout)
        }
        guard let command = input["command"]?.stringValue else {
            return "Error: missing 'command' parameter"
        }
        let background = input["background"]?.boolValue ?? false
        let interactive = background
            ? false
            : (input["interactive"]?.boolValue ?? shouldAutoEnableInteractiveMode(for: command))
        return await session.execute(command, timeout: timeout, background: background, interactive: interactive)
    }

    // MARK: - Interactive Mode Detection

    private static let interactiveCommandRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(^|\s)read\s+"#,
            #"(^|\s)select\s+"#,
            #"(^|\s)(sudo|su|passwd)(\s|$)"#,
            #"(^|\s)(ssh|sftp|ftp)\s"#,
            #"(^|\s)(mysql|psql|sqlite3)(\s|$)"#,
            #"(^|\s)git\s+add\s+-p(\s|$)"#,
            #"(^|\s)git\s+rebase\s+-i(\s|$)"#,
            #"(^|\s)git\s+commit(\s|$)"#,
            #"(^|\s)(npm|pnpm|yarn)\s+(init|login)(\s|$)"#,
            #"(^|\s)(pnpm|yarn|npm|bunx|npx)\s+(create|dlx)\s"#,
            #"(^|\s)(rails\s+console|python(3)?|node|irb)(\s|$)"#
        ]

        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private static let nonInteractiveGitCommitRegex = try? NSRegularExpression(
        pattern: #"(^|\s)git\s+commit\s+.*(--message|-m|--amend\s+--no-edit|--no-edit)(\s|$)"#,
        options: [.caseInsensitive]
    )

    private func shouldAutoEnableInteractiveMode(for command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if let regex = Self.nonInteractiveGitCommitRegex,
           regex.firstMatch(in: trimmed, options: [], range: range) != nil {
            return false
        }

        return Self.interactiveCommandRegexes.contains { regex in
            regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }
    }
}

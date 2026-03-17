import Foundation

struct TerminalSurfaceProjector {
    func project(_ snapshot: TerminalScreenSnapshot, rawANSISnippet: String = "") -> TerminalSurfaceSnapshot {
        let normalizedLines = snapshot.plainTextLines.map { $0.replacingOccurrences(of: "\r", with: "") }
        let plainText = normalizedLines.joined(separator: "\n")
        let options = extractVisibleOptions(from: normalizedLines)
        let inputHint = inferInputHint(
            from: normalizedLines,
            plainText: plainText,
            options: options,
            isAlternateScreen: snapshot.activeBuffer == .alternate
        )
        let selectionMode = inferSelectionMode(from: plainText, options: options, inputHint: inputHint)
        let focusedIndex = options.firstIndex(where: \.isFocused)

        return TerminalSurfaceSnapshot(
            plainTextFrame: plainText,
            rawANSISnippet: rawANSISnippet,
            visibleOptions: options,
            focusedOptionIndex: focusedIndex,
            selectionMode: selectionMode,
            isAlternateScreen: snapshot.activeBuffer == .alternate,
            cursorRow: snapshot.cursor.row,
            cursorColumn: snapshot.cursor.column,
            inputHint: inputHint
        )
    }

    private func extractVisibleOptions(from lines: [String]) -> [TerminalVisibleOption] {
        var options: [TerminalVisibleOption] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let radioOptions = extractInlineRadioOptions(from: trimmed), !radioOptions.isEmpty {
                options.append(contentsOf: radioOptions)
                continue
            }

            let multiPatterns: [(token: String, selected: Bool)] = [
                ("◻", false),
                ("◼", true),
                ("☐", false),
                ("☑", true),
                ("□", false),
                ("■", true)
            ]

            if let pattern = multiPatterns.first(where: { trimmed.contains($0.token) }) {
                let label = trimmed.replacingOccurrences(of: pattern.token, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "│┆•·- ").union(.whitespaces))
                if !label.isEmpty {
                    options.append(TerminalVisibleOption(label: label, isSelected: pattern.selected, isFocused: true))
                }
                continue
            }

            let singlePatterns = ["◇", "◆", ">", "❯"]
            if let token = singlePatterns.first(where: { trimmed.hasPrefix($0) }) {
                let label = trimmed.replacingOccurrences(of: token, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "│ ").union(.whitespaces))
                if !label.isEmpty, !isPromptLine(label), !isLikelyShellCommandEcho(label) {
                    options.append(TerminalVisibleOption(label: label, isSelected: token == "◆", isFocused: true))
                }
            }
        }

        return options
    }

    private func extractInlineRadioOptions(from line: String) -> [TerminalVisibleOption]? {
        guard line.contains("○") || line.contains("●") else { return nil }

        let pattern = #"([○●])\s*([^/]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex.matches(in: line, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        return matches.compactMap { match in
            guard let tokenRange = Range(match.range(at: 1), in: line),
                  let labelRange = Range(match.range(at: 2), in: line) else {
                return nil
            }

            let token = String(line[tokenRange])
            let label = String(line[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            return TerminalVisibleOption(label: label, isSelected: token == "●", isFocused: token == "●")
        }
    }

    private func inferSelectionMode(from plainText: String, options: [TerminalVisibleOption], inputHint: String?) -> TerminalSelectionMode {
        guard !options.isEmpty else {
            if plainText.contains("输入") {
                return .textInput
            }
            return inputHint == nil ? .none : .unknown
        }

        if plainText.contains("空格选择") || options.contains(where: { $0.label.contains("JSX") || $0.label.contains("Pinia") || $0.label.contains("Vitest") }) {
            return .multiSelect
        }

        if options.count < 2 {
            return .unknown
        }

        let normalizedLabels = options.map { $0.label.lowercased() }
        if options.count == 2 && normalizedLabels.contains("yes") && normalizedLabels.contains("no") {
            return .singleSelect
        }

        return .singleSelect
    }

    private func inferInputHint(
        from lines: [String],
        plainText: String,
        options: [TerminalVisibleOption],
        isAlternateScreen: Bool
    ) -> String? {
        guard options.isEmpty else { return nil }

        let normalized = plainText.lowercased()
        let hasViewerHint = normalized.contains("terminal is not fully functional")
            || normalized.contains("(end)")
            || normalized.contains("press return to continue")
            || normalized.contains("press enter to continue")
            || normalized.contains("q to quit")

        let hasStructuredDocument = lines.contains { line in
            line.contains("diff --git")
                || line.contains("@@")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
        }

        guard isAlternateScreen || hasViewerHint else { return nil }
        return (hasViewerHint && hasStructuredDocument) ? "viewer_navigation" : nil
    }

    private func isLikelyShellCommandEcho(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        let pattern = #"^[a-z0-9._/@-]+(\s+[a-z0-9._/@-]+)*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, options: [], range: range) != nil
    }

    private func isPromptLine(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.contains("?")
            || candidate.contains("？")
            || candidate.contains("请选择")
            || candidate.contains("切换")
            || candidate.contains("回车确认")
            || candidate.contains("Target directory")
            || candidate.contains("continue")
    }
}
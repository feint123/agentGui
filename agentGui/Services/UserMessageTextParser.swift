import Foundation

struct ParsedUserMessageText: Equatable {
    let bodyText: String
    let directiveAuditItems: [ParsedDirectiveAuditItem]
    let inlineSegments: [UserMessageInlineSegment]
    let images: [String]
    let pdfs: [String]
    let others: [String]
}

struct ParsedDirectiveAuditItem: Equatable {
    let kind: String
    let rawValue: String
    let displayName: String
}

enum UserMessageInlineSegment: Equatable {
    case text(String)
    case mention(ParsedMention)
}

struct ParsedMention: Equatable {
    let fullPath: String
    let displayName: String
    let secondaryPath: String?
    let lineRange: FileLineRange?

    var matchedText: String {
        guard let lineRange else { return fullPath }
        return "\(fullPath):\(lineRange.displayText)"
    }
}

extension ParsedUserMessageText {
    /// 用结构化附件覆盖文件列表，保留 bodyText 和 inlineSegments。
    func replacingAttachments(with entries: [AttachmentSnapshotEntry]) -> ParsedUserMessageText {
        var imgs: [String] = []
        var pdfs: [String] = []
        var others: [String] = []
        for e in entries {
            switch AttachmentKind(rawValue: e.fileKindRaw) ?? .other {
            case .image:                          imgs.append(e.filePath)
            case .pdf:                            pdfs.append(e.filePath)
            case .sourceCode, .directory, .other: others.append(e.filePath)
            }
        }
        return ParsedUserMessageText(
            bodyText: bodyText,
            directiveAuditItems: directiveAuditItems,
            inlineSegments: inlineSegments,
            images: imgs,
            pdfs: pdfs,
            others: others
        )
    }
}

enum UserMessageTextParser {
    private static let directiveMarker = "\n\n[Active directives] "
    private static let fileSectionMarker = "\n\nReferenced files:\n"

    static func parse(text: String, workspaceRoot: String) -> ParsedUserMessageText {
        let normalizedRoot = normalizeWorkspaceRoot(workspaceRoot)
        let textWithoutAudit = stripDirectiveAudit(from: text)
        let bodyAndAttachments = splitReferencedFiles(in: textWithoutAudit.remainingText)
        let displayBody = normalizeContextDisplayText(from: stripSelectionExcerpt(from: bodyAndAttachments.body))
        let trimmedBody = displayBody.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedUserMessageText(
            bodyText: trimmedBody,
            directiveAuditItems: textWithoutAudit.items,
            inlineSegments: tokenizeMentions(in: trimmedBody, workspaceRoot: normalizedRoot),
            images: bodyAndAttachments.images,
            pdfs: bodyAndAttachments.pdfs,
            others: bodyAndAttachments.others
        )
    }

    private static func stripDirectiveAudit(from text: String) -> (remainingText: String, items: [ParsedDirectiveAuditItem]) {
        guard let range = text.range(of: directiveMarker, options: .backwards) else {
            return (text, [])
        }

        let auditStart = range.upperBound
        let trailingText = text[auditStart...]
        let auditEnd = trailingText.range(of: "\n\n")?.lowerBound ?? text.endIndex
        let auditText = String(text[auditStart..<auditEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let items = auditText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(parseDirectiveItem)

        guard !items.isEmpty else {
            return (text, [])
        }

        let prefix = String(text[..<range.lowerBound])
        let suffix = auditEnd < text.endIndex ? String(text[auditEnd...]) : ""
        return (prefix + suffix, items)
    }

    private static func parseDirectiveItem(_ raw: String) -> ParsedDirectiveAuditItem? {
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let kind = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !value.isEmpty else { return nil }

        return ParsedDirectiveAuditItem(kind: kind, rawValue: raw, displayName: value)
    }

    private static func splitReferencedFiles(in text: String) -> (body: String, images: [String], pdfs: [String], others: [String]) {
        guard let range = text.range(of: fileSectionMarker, options: .backwards) else {
            return (text, [], [], [])
        }

        let body = String(text[..<range.lowerBound])
        let filesSection = String(text[range.upperBound...])
        let paths = filesSection
            .split(separator: "\n")
            .map { line -> String in
                let raw = String(line)
                return raw.hasPrefix("- ") ? String(raw.dropFirst(2)) : raw
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var images: [String] = []
        var pdfs: [String] = []
        var others: [String] = []

        for path in paths {
            if AttachedFile.pathIsImage(path) {
                images.append(path)
            } else if AttachedFile.pathIsPDF(path) {
                pdfs.append(path)
            } else {
                others.append(path)
            }
        }

        return (body, images, pdfs, others)
    }

    private static func tokenizeMentions(in text: String, workspaceRoot: String) -> [UserMessageInlineSegment] {
        guard !text.isEmpty else { return [] }

        guard !workspaceRoot.isEmpty else {
            return [.text(text)]
        }

        let escapedRoot = NSRegularExpression.escapedPattern(for: workspaceRoot)
        let pattern = escapedRoot + #"(?:/[^\s\]\[\)\(\{\}\<\>\"\',;:!?]+)+(?:\:\d+(?:-\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)

        var segments: [UserMessageInlineSegment] = []
        var currentIndex = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let rawCandidate = String(text[range])
            guard let mention = makeMention(from: rawCandidate, workspaceRoot: workspaceRoot) else { continue }
            guard let mentionRange = text.range(of: mention.matchedText, range: range.lowerBound..<range.upperBound) else { continue }

            if currentIndex < mentionRange.lowerBound {
                segments.append(.text(String(text[currentIndex..<mentionRange.lowerBound])))
            }
            segments.append(.mention(mention))
            currentIndex = mentionRange.upperBound
        }

        if currentIndex < text.endIndex {
            segments.append(.text(String(text[currentIndex...])))
        }

        return segments.isEmpty ? [.text(text)] : coalesceTextSegments(in: segments)
    }

    private static func makeMention(from rawCandidate: String, workspaceRoot: String) -> ParsedMention? {
        var candidate = rawCandidate

        while !candidate.isEmpty, candidate.count >= workspaceRoot.count {
            let split = splitLineRangeSuffix(from: candidate)
            let pathCandidate = split.path
            let url = URL(fileURLWithPath: pathCandidate)
            if FileManager.default.fileExists(atPath: pathCandidate), pathCandidate.hasPrefix(workspaceRoot + "/") || pathCandidate == workspaceRoot {
                let relativePath: String?
                if pathCandidate.hasPrefix(workspaceRoot + "/") {
                    relativePath = String(pathCandidate.dropFirst(workspaceRoot.count + 1))
                } else {
                    relativePath = nil
                }

                return ParsedMention(
                    fullPath: pathCandidate,
                    displayName: url.lastPathComponent,
                    secondaryPath: relativePath,
                    lineRange: split.lineRange
                )
            }

            candidate.removeLast()
        }

        return nil
    }

    private static func coalesceTextSegments(in segments: [UserMessageInlineSegment]) -> [UserMessageInlineSegment] {
        var result: [UserMessageInlineSegment] = []

        for segment in segments {
            switch segment {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if case .text(let existing)? = result.last {
                    result[result.count - 1] = .text(existing + text)
                } else {
                    result.append(.text(text))
                }
            case .mention:
                result.append(segment)
            }
        }

        return result
    }

    private static func normalizeWorkspaceRoot(_ workspaceRoot: String) -> String {
        let trimmed = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return trimmed }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func stripSelectionExcerpt(from text: String) -> String {
        let marker = "\n选区内容:\n"
        guard let selectionMarkerRange = text.range(of: marker) else {
            if text.hasPrefix("选区内容:\n"), let endOfBlock = text.range(of: "\n\n") {
                return String(text[endOfBlock.upperBound...])
            }
            return text
        }

        let prefix = String(text[..<selectionMarkerRange.lowerBound])
        let selectionContentStart = selectionMarkerRange.upperBound
        let remaining = text[selectionContentStart...]
        guard let endOfBlock = remaining.range(of: "\n\n") else {
            return prefix
        }

        let suffix = String(remaining[endOfBlock.lowerBound...]).trimmingCharacters(in: .newlines)
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return suffix
        }
        if suffix.isEmpty {
            return prefix
        }
        return prefix + "\n\n" + suffix
    }

    private static func normalizeContextDisplayText(from text: String) -> String {
        var normalized = text

        if normalized.hasPrefix("当前文件: ") || normalized.hasPrefix("当前选区: ") {
            let lines = normalized.components(separatedBy: .newlines)
            if let firstLine = lines.first {
                let inlinePrefix: String
                if firstLine.hasPrefix("当前文件: ") {
                    inlinePrefix = String(firstLine.dropFirst("当前文件: ".count))
                } else if firstLine.hasPrefix("当前选区: ") {
                    inlinePrefix = String(firstLine.dropFirst("当前选区: ".count))
                } else {
                    inlinePrefix = firstLine
                }

                let remainingLines = Array(lines.dropFirst())
                let remainingText = remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

                if remainingText.isEmpty {
                    normalized = inlinePrefix
                } else if inlinePrefix.isEmpty {
                    normalized = remainingText
                } else {
                    normalized = inlinePrefix + " " + remainingText
                }
            }
        }

        let normalizedLines = normalized
            .components(separatedBy: .newlines)
            .map { line -> String in
                if line.hasPrefix("当前文件: ") {
                    return String(line.dropFirst("当前文件: ".count))
                }
                if line.hasPrefix("当前选区: ") {
                    return String(line.dropFirst("当前选区: ".count))
                }
                return line
            }

        return normalizedLines.joined(separator: "\n")
    }

    private static func splitLineRangeSuffix(from text: String) -> (path: String, lineRange: FileLineRange?) {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?$"#) else {
            return (text, nil)
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange), match.range.location != NSNotFound,
              let suffixRange = Range(match.range, in: text),
              let startRange = Range(match.range(at: 1), in: text) else {
            return (text, nil)
        }

        let startLine = Int(text[startRange]) ?? 1
        let endLine: Int
        if let endRange = Range(match.range(at: 2), in: text) {
            endLine = Int(text[endRange]) ?? startLine
        } else {
            endLine = startLine
        }

        return (String(text[..<suffixRange.lowerBound]), FileLineRange(startLine: startLine, endLine: endLine))
    }
}
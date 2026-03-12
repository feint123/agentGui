import Foundation

actor ToolPayloadStore {
    private let baseDirectory: URL
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        baseDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory ?? fileManager.temporaryDirectory
            .appending(path: "agentgui-tool-payloads", directoryHint: .isDirectory)
        self.now = now
        self.fileManager = fileManager
    }

    func createPayload(
        text: String,
        sourceKind: LargeTextPayload.SourceKind,
        sourceDescriptor: String,
        ttl: TimeInterval = 3600
    ) throws -> LargeTextPayload {
        try ensureBaseDirectory()
        let payloadID = "payload_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let contentURL = baseDirectory.appending(path: "\(payloadID).txt")
        let metadataURL = baseDirectory.appending(path: "\(payloadID).json")
        let createdAt = now()
        let payload = LargeTextPayload(
            payloadID: payloadID,
            sourceKind: sourceKind,
            sourceDescriptor: sourceDescriptor,
            fileURL: contentURL,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ttl),
            rawCharCount: text.count,
            lineCount: text.components(separatedBy: "\n").count
        )

        do {
            try text.write(to: contentURL, atomically: true, encoding: .utf8)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: metadataURL, options: .atomic)
            return payload
        } catch {
            throw ToolPayloadStoreError.payloadStorageFailed(error.localizedDescription)
        }
    }

    func payload(for payloadID: String) throws -> LargeTextPayload {
        let payload = try loadPayload(payloadID: payloadID)
        guard payload.expiresAt >= now() else {
            throw ToolPayloadStoreError.payloadExpired(payloadID)
        }
        return payload
    }

    func readChars(payloadID: String, start: Int, end: Int) throws -> String {
        guard start > 0, end >= start else {
            throw ToolPayloadStoreError.invalidRange("chars \(start)-\(end)")
        }
        let text = try loadText(payloadID: payloadID)
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }

        let lowerBound = start - 1
        let upperBound = min(end, characters.count)
        guard lowerBound < upperBound else {
            throw ToolPayloadStoreError.invalidRange("chars \(start)-\(end)")
        }
        return String(characters[lowerBound..<upperBound])
    }

    func readLines(payloadID: String, start: Int, end: Int) throws -> String {
        guard start > 0, end >= start else {
            throw ToolPayloadStoreError.invalidRange("lines \(start)-\(end)")
        }
        let text = try loadText(payloadID: payloadID)
        let lines = text.components(separatedBy: "\n")
        let upperBound = min(end, lines.count)
        guard start <= upperBound else {
            throw ToolPayloadStoreError.invalidRange("lines \(start)-\(end)")
        }
        return lines[(start - 1)..<upperBound]
            .enumerated()
            .map { "\(start + $0.offset)\t\($0.element)" }
            .joined(separator: "\n")
    }

    func readChunk(payloadID: String, cursor: String?, maxChars: Int = 4000) throws -> ToolPayloadReadWindow {
        let payload = try self.payload(for: payloadID)
        let text = try loadText(payloadID: payloadID)
        let safeMaxChars = max(1, maxChars)
        let chunkCount = max(1, Int(ceil(Double(max(text.count, 1)) / Double(safeMaxChars))))

        let chunkIndex: Int
        if let cursor, !cursor.isEmpty {
            guard cursor.hasPrefix("chunk:"),
                  let parsed = Int(cursor.replacingOccurrences(of: "chunk:", with: "")),
                  parsed >= 1,
                  parsed <= chunkCount else {
                throw ToolPayloadStoreError.cursorInvalid(cursor)
            }
            chunkIndex = parsed
        } else {
            chunkIndex = 1
        }

        let startOffset = (chunkIndex - 1) * safeMaxChars
        let endOffset = min(startOffset + safeMaxChars, text.count)
        let windowText = try readChars(payloadID: payloadID, start: startOffset + 1, end: endOffset)
        let hasMore = chunkIndex < chunkCount

        return ToolPayloadReadWindow(
            content: windowText,
            cursor: "chunk:\(chunkIndex)",
            nextCursor: hasMore ? "chunk:\(chunkIndex + 1)" : nil,
            hasMore: hasMore,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            rangeSummary: "chars \(startOffset + 1)-\(endOffset) of \(payload.rawCharCount)"
        )
    }

    func readWindow(
        payloadID: String,
        readMode: ToolPayloadReadMode,
        start: Int?,
        end: Int?,
        cursor: String?,
        maxChars: Int?
    ) throws -> ToolPayloadReadWindow {
        switch readMode {
        case .lines:
            let payload = try self.payload(for: payloadID)
            let lines = try loadText(payloadID: payloadID).components(separatedBy: "\n")
            let lineStart = max(1, start ?? 1)
            let lineEnd = max(lineStart, end ?? min(lineStart + 2, lines.count))
            let content = try readLines(payloadID: payloadID, start: lineStart, end: lineEnd)
            let windowSize = max(1, lineEnd - lineStart + 1)
            let nextStart = lineEnd + 1
            let nextEnd = min(lines.count, nextStart + windowSize - 1)
            let hasMore = nextStart <= lines.count
            return ToolPayloadReadWindow(
                content: content,
                cursor: "lines:\(lineStart)-\(lineEnd)",
                nextCursor: hasMore ? "lines:\(nextStart)-\(nextEnd)" : nil,
                hasMore: hasMore,
                chunkIndex: Int(ceil(Double(lineEnd) / Double(windowSize))),
                chunkCount: max(1, Int(ceil(Double(lines.count) / Double(windowSize)))),
                rangeSummary: "lines \(lineStart)-\(lineEnd) of \(payload.lineCount ?? lines.count)"
            )
        case .chars:
            let payload = try self.payload(for: payloadID)
            let charStart = max(1, start ?? 1)
            let charEnd = max(charStart, end ?? min(payload.rawCharCount, charStart + (maxChars ?? 4000) - 1))
            let content = try readChars(payloadID: payloadID, start: charStart, end: charEnd)
            let hasMore = charEnd < payload.rawCharCount
            let windowSize = max(1, charEnd - charStart + 1)
            let nextStart = charEnd + 1
            let nextEnd = min(payload.rawCharCount, nextStart + windowSize - 1)
            return ToolPayloadReadWindow(
                content: content,
                cursor: "chars:\(charStart)-\(charEnd)",
                nextCursor: hasMore ? "chars:\(nextStart)-\(nextEnd)" : nil,
                hasMore: hasMore,
                chunkIndex: Int(ceil(Double(charEnd) / Double(windowSize))),
                chunkCount: max(1, Int(ceil(Double(payload.rawCharCount) / Double(windowSize)))),
                rangeSummary: "chars \(charStart)-\(charEnd) of \(payload.rawCharCount)"
            )
        case .chunk:
            return try readChunk(payloadID: payloadID, cursor: cursor, maxChars: maxChars ?? 4000)
        case .head:
            return try readWindow(payloadID: payloadID, readMode: .chars, start: 1, end: min(maxChars ?? 4000, try self.payload(for: payloadID).rawCharCount), cursor: nil, maxChars: maxChars)
        case .tail:
            let payload = try self.payload(for: payloadID)
            let size = max(1, maxChars ?? 4000)
            let charStart = max(1, payload.rawCharCount - size + 1)
            return try readWindow(payloadID: payloadID, readMode: .chars, start: charStart, end: payload.rawCharCount, cursor: nil, maxChars: size)
        case .summary:
            let payload = try self.payload(for: payloadID)
            let text = try loadText(payloadID: payloadID)
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "(empty)"
            return ToolPayloadReadWindow(
                content: firstLine,
                cursor: nil,
                nextCursor: nil,
                hasMore: payload.rawCharCount > firstLine.count,
                chunkIndex: 1,
                chunkCount: 1,
                rangeSummary: "summary of \(payload.rawCharCount) chars"
            )
        case .preview:
            let payload = try self.payload(for: payloadID)
            let previewLength = min(maxChars ?? 800, payload.rawCharCount)
            return try readWindow(payloadID: payloadID, readMode: .chars, start: 1, end: previewLength, cursor: nil, maxChars: previewLength)
        }
    }

    func deleteExpiredPayloads() throws {
        guard fileManager.fileExists(atPath: baseDirectory.path()) else { return }
        let metadataFiles = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        for metadataURL in metadataFiles {
            let data = try Data(contentsOf: metadataURL)
            let payload = try JSONDecoder().decode(LargeTextPayload.self, from: data)
            if payload.expiresAt < now() {
                try? fileManager.removeItem(at: metadataURL)
                try? fileManager.removeItem(at: payload.fileURL)
            }
        }
    }

    private func ensureBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path()) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    private func loadPayload(payloadID: String) throws -> LargeTextPayload {
        let metadataURL = baseDirectory.appending(path: "\(payloadID).json")
        guard fileManager.fileExists(atPath: metadataURL.path()) else {
            throw ToolPayloadStoreError.payloadNotFound(payloadID)
        }
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode(LargeTextPayload.self, from: data)
    }

    private func loadText(payloadID: String) throws -> String {
        let payload = try self.payload(for: payloadID)
        guard fileManager.fileExists(atPath: payload.fileURL.path()) else {
            throw ToolPayloadStoreError.payloadNotFound(payloadID)
        }
        return try String(contentsOf: payload.fileURL, encoding: .utf8)
    }
}
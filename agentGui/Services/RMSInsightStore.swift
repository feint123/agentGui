import Foundation

protocol RMSInsightStoring {
    func load(scope: MemoryScope) throws -> [RMSInsight]
    func load(scopes: [MemoryScope]) throws -> [RMSInsight]
    func upsert(_ insight: RMSInsight) throws
    func remove(id: String) throws
}

struct RMSInsightStore: RMSInsightStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = RMSInsightStore.defaultBaseDirectory(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = baseDirectory.appending(path: "rms-insights.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private static func defaultBaseDirectory() -> URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appending(path: "agentgui-rms-insights-tests-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return ConfigDirectoryManager.shared.agentGuiDir
    }

    func load(scope: MemoryScope) throws -> [RMSInsight] {
        try load(scopes: [scope])
    }

    func load(scopes: [MemoryScope]) throws -> [RMSInsight] {
        let namespaces = Set(scopes.map(\.namespace))
        return try loadAll().filter { insight in
            guard let scope = insight.scope else { return true }
            return namespaces.contains(scope.namespace)
        }
    }

    func upsert(_ insight: RMSInsight) throws {
        var insights = try loadAll()
        let normalized = normalizedInsight(insight)

        if let index = insights.firstIndex(where: { $0.id == normalized.id }) {
            insights[index] = normalized
        } else {
            insights.append(normalized)
        }

        try save(insights)
    }

    func remove(id: String) throws {
        let insights = try loadAll().filter { $0.id != id }
        try save(insights)
    }

    private func loadAll() throws -> [RMSInsight] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([RMSInsight].self, from: data)
    }

    private func save(_ insights: [RMSInsight]) throws {
        try ensureBaseDirectoryExists()
        let sorted = insights.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            return lhs.id < rhs.id
        }
        let data = try encoder.encode(sorted)
        try data.write(to: fileURL, options: .atomic)
    }

    private func ensureBaseDirectoryExists() throws {
        let baseDirectory = fileURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: baseDirectory.path) else { return }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func normalizedInsight(_ insight: RMSInsight) -> RMSInsight {
        let trim: (String) -> String = { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var normalized = insight
        normalized.summary = trim(normalized.summary)
        normalized.appliesWhen = trim(normalized.appliesWhen)
        normalized.changesDecision = trim(normalized.changesDecision)
        normalized.replacementAction = normalized.replacementAction.map(trim)
        normalized.evidenceRefs = normalized.evidenceRefs.map(trim).filter { !$0.isEmpty }
        normalized.rawContentFilePath = normalized.rawContentFilePath.map(trim)
        normalized.updatedAt = normalized.updatedAt ?? Date()
        return normalized
    }
}
import Foundation

struct AgentDefinitionLoader {
    private static let builtInSortOrder = ["explore", "worker", "verifier"]
    private let requiredFields: Set<String> = [
        "name",
        "display-name",
        "description",
        "argument-hint",
        "tools",
        "max-turns",
        "user-invocable",
        "subagent-invocable",
        "output-contract"
    ]
    private let optionalFields: Set<String> = [
        "model-preference",
        "effort",
        "background",
        "omit-main-context",
        "initial-prompt",
        "critical-reminder",
        "color",
        "disallowed-tools",
        "tags",
        "examples",
        "notes"
    ]

    func loadBuiltInDocuments(from bundle: Bundle) throws -> [AgentDefinitionDocument] {
        let directory = try builtInAgentsDirectoryURL(from: bundle)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasSuffix(".agent.md") }

        guard !urls.isEmpty else {
            throw AgentValidationError.missingBuiltInAgentFiles
        }

        var seenNames: Set<String> = []
        var documents: [AgentDefinitionDocument] = []

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let document = try parseDocument(named: url.lastPathComponent, raw: raw)
            if !seenNames.insert(document.name).inserted {
                throw AgentValidationError.duplicateAgentName(document.name)
            }
            documents.append(document)
        }

        return documents.sorted { lhs, rhs in
            sortIndex(for: lhs.name) < sortIndex(for: rhs.name)
        }
    }

    func loadBuiltInRuntimeDefinitions(from bundle: Bundle) throws -> [AgentRuntimeDefinition] {
        try loadBuiltInDocuments(from: bundle).map(AgentRuntimeDefinition.make(from:))
    }

    func parseDocument(named: String, raw: String) throws -> AgentDefinitionDocument {
        let parsed = try parseFrontmatter(raw)
        let unsupported = Set(parsed.fields.keys).subtracting(requiredFields).subtracting(optionalFields)
        if !unsupported.isEmpty {
            throw AgentValidationError.unsupportedFields(Array(unsupported))
        }

        for field in requiredFields where parsed.fields[field] == nil {
            throw AgentValidationError.missingRequiredField(field)
        }

        guard let name = parsed.fields["name"], !name.isEmpty else {
            throw AgentValidationError.missingRequiredField("name")
        }
        guard let displayName = parsed.fields["display-name"] else {
            throw AgentValidationError.missingRequiredField("display-name")
        }
        guard let description = parsed.fields["description"] else {
            throw AgentValidationError.missingRequiredField("description")
        }
        guard let argumentHint = parsed.fields["argument-hint"] else {
            throw AgentValidationError.missingRequiredField("argument-hint")
        }
        guard let toolsText = parsed.fields["tools"] else {
            throw AgentValidationError.missingRequiredField("tools")
        }
        let tools = try parseArray(toolsText)
        guard let maxTurnsText = parsed.fields["max-turns"],
              let maxTurns = Int(maxTurnsText), maxTurns > 0 else {
            throw AgentValidationError.invalidIntegerField("max-turns")
        }
        guard let userInvocableText = parsed.fields["user-invocable"],
              let userInvocable = parseBool(userInvocableText) else {
            throw AgentValidationError.invalidBooleanField("user-invocable")
        }
        guard let subagentInvocableText = parsed.fields["subagent-invocable"],
              let subagentInvocable = parseBool(subagentInvocableText) else {
            throw AgentValidationError.invalidBooleanField("subagent-invocable")
        }
        if !userInvocable && !subagentInvocable {
            throw AgentValidationError.invalidVisibilityCombination
        }
        guard let outputContract = parsed.fields["output-contract"],
              !outputContract.isEmpty else {
            throw AgentValidationError.missingRequiredField("output-contract")
        }
        guard !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentValidationError.emptyBody
        }

        // MARK: Optional execution-trait fields (S-A1)
        let modelPreference = parsed.fields["model-preference"]
            .flatMap(SubagentModelPreference.init(rawValue:)) ?? .inherit

        let effort = parsed.fields["effort"]
            .flatMap(SubagentEffort.init(rawValue:))

        let background = parseBool(parsed.fields["background"] ?? "false") ?? false

        let omitMainContext = parseBool(parsed.fields["omit-main-context"] ?? "false") ?? false

        let initialPrompt = parsed.fields["initial-prompt"].flatMap { $0.isEmpty ? nil : $0 }

        let criticalReminder = parsed.fields["critical-reminder"].flatMap { $0.isEmpty ? nil : $0 }

        let color = parsed.fields["color"].flatMap { $0.isEmpty ? nil : $0 }

        let disallowedToolNames: [String]
        if let rawDisallowed = parsed.fields["disallowed-tools"] {
            disallowedToolNames = try parseArray(rawDisallowed)
        } else {
            disallowedToolNames = []
        }

        return AgentDefinitionDocument(
            name: name,
            displayName: displayName,
            description: description,
            argumentHint: argumentHint,
            toolGroupNames: tools,
            maxTurns: maxTurns,
            userInvocable: userInvocable,
            subagentInvocable: subagentInvocable,
            outputContract: outputContract,
            body: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            modelPreference: modelPreference,
            effort: effort,
            background: background,
            omitMainContext: omitMainContext,
            initialPrompt: initialPrompt,
            criticalReminder: criticalReminder,
            color: color,
            disallowedToolNames: disallowedToolNames
        )
    }

    private func sortIndex(for name: String) -> Int {
        Self.builtInSortOrder.firstIndex(of: name) ?? .max
    }

    private func builtInAgentsDirectoryURL(from bundle: Bundle) throws -> URL {
        if let bundleResourceURL = bundle.resourceURL?.appendingPathComponent("Resources/Agents"),
           FileManager.default.fileExists(atPath: bundleResourceURL.path) {
            return bundleResourceURL
        }

        if let bundleAgentURL = bundle.resourceURL?.appendingPathComponent("Agents"),
           FileManager.default.fileExists(atPath: bundleAgentURL.path) {
            return bundleAgentURL
        }

        let sourceFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Agents", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceFallback.path) {
            return sourceFallback
        }

        throw AgentValidationError.missingBuiltInAgentDirectory
    }

    private func parseFrontmatter(_ raw: String) throws -> (fields: [String: String], body: String) {
        let lines = raw.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw AgentValidationError.malformedFrontmatter("missing opening delimiter")
        }

        var fields: [String: String] = [:]
        var frontmatterEndIndex: Int?

        for index in 1..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                frontmatterEndIndex = index
                break
            }

            guard let separatorIndex = line.firstIndex(of: ":") else {
                throw AgentValidationError.malformedFrontmatter("invalid field line: \(line)")
            }

            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separatorIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            fields[key] = trimQuotes(value)
        }

        guard let endIndex = frontmatterEndIndex else {
            throw AgentValidationError.malformedFrontmatter("missing closing delimiter")
        }

        let body = lines[(endIndex + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    private func parseArray(_ text: String) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw AgentValidationError.malformedFrontmatter("expected inline array, got: \(text)")
        }

        let inner = String(trimmed.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        return inner
            .split(separator: ",")
            .map { trimQuotes($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private func trimQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
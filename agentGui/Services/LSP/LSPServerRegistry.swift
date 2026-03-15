import Foundation

struct LSPServerRegistry {
    enum RegistryError: Error, Equatable {
        case duplicateDefinitionID(String)
        case invalidCustomProfiles
    }

    private let definitionsByID: [String: LSPServerDefinition]

    init(settings: AppSettings) throws {
        let builtIns = Self.builtInDefinitions()
        let installedDefinitions = settings.lspInstalledServerDefinitions
        let customProfiles = try Self.decodeCustomProfiles(from: settings.lspCustomServerProfilesJSON)
        var merged: [String: LSPServerDefinition] = [:]

        for definition in builtIns {
            merged[definition.id] = definition
        }

        for definition in installedDefinitions {
            merged[definition.id] = definition
        }

        for definition in customProfiles {
            if merged[definition.id] != nil {
                throw RegistryError.duplicateDefinitionID(definition.id)
            }
            merged[definition.id] = definition
        }

        self.definitionsByID = merged
    }

    func definition(for id: String) -> LSPServerDefinition? {
        definitionsByID[id]
    }

    func allDefinitions() -> [LSPServerDefinition] {
        definitionsByID.values.sorted { $0.id < $1.id }
    }

    private static func decodeCustomProfiles(from json: String) throws -> [LSPServerDefinition] {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        do {
            return try JSONDecoder().decode([LSPServerDefinition].self, from: Data(json.utf8))
        } catch {
            throw RegistryError.invalidCustomProfiles
        }
    }

    private static func builtInDefinitions() -> [LSPServerDefinition] {
        [
            LSPServerDefinition(
                id: "python-lsp",
                displayName: "Python LSP",
                launchCommand: "pylsp",
                launchArguments: [],
                supportedLanguageIDs: ["python"],
                defaultFileGlobs: ["**/*.py"],
                rootMarkers: ["pyproject.toml", "requirements.txt", ".venv"],
                adapterKind: .generic,
                providerID: "python-lsp",
                sourceKind: .builtIn
            )
        ]
    }
}

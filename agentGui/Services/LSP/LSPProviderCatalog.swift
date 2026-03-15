import Foundation

struct LSPProviderCatalog {
    private let providersByID: [String: LSPProviderDefinition]

    init(providers: [LSPProviderDefinition]) {
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    static func builtInCatalog() -> LSPProviderCatalog {
        LSPProviderCatalog(providers: [
            .python,
            .typescript,
            .clangd,
            .gopls
        ])
    }

    func allProviders() -> [LSPProviderDefinition] {
        providersByID.values.sorted { $0.id < $1.id }
    }

    func provider(id: String) -> LSPProviderDefinition? {
        providersByID[id]
    }

    func providerID(forLegacyServerID legacyServerID: String) -> String? {
        if providersByID[legacyServerID] != nil {
            return legacyServerID
        }

        return providersByID.values.first { $0.legacyServerIDs.contains(legacyServerID) }?.id
    }

    func migrateLegacyBuiltInServerDefinitions(in settings: AppSettings) -> [LSPMigrationRecord] {
        settings.lspInstalledServerDefinitions.compactMap { definition in
            guard let providerID = providerID(forLegacyServerID: definition.id) else {
                return nil
            }
            return LSPMigrationRecord(legacyServerID: definition.id, providerID: providerID)
        }
    }

    func providerForFilePath(_ filePath: String) -> LSPProviderDefinition? {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }

        return allProviders().first { provider in
            let supportedExtensions = Self.fileExtensions(from: provider.defaultServerTemplate.defaultFileGlobs)
            return supportedExtensions.contains(ext)
        }
    }

    private static func fileExtensions(from globs: [String]) -> Set<String> {
        var result: Set<String> = []
        for glob in globs {
            if let rangeStart = glob.range(of: "{"),
               let rangeEnd = glob.range(of: "}"),
               rangeStart.upperBound <= rangeEnd.lowerBound {
                let list = glob[rangeStart.upperBound..<rangeEnd.lowerBound]
                for item in list.split(separator: ",") {
                    result.insert(item.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }

            if let extRange = glob.range(of: ".", options: .backwards) {
                result.insert(String(glob[extRange.upperBound...]))
            }
        }
        return result
    }
}

private extension LSPProviderDefinition {
    static let python = LSPProviderDefinition(
        id: "python-lsp",
        displayName: "Python LSP",
        supportedLanguageIDs: ["python"],
        recommendedInstallMethod: .builtIn,
        installPackageIdentifiers: ["pylsp"],
        isBuiltIn: true,
        defaultServerTemplate: LSPServerDefinition(
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
    )

    static let typescript = LSPProviderDefinition(
        id: "typescript-language-server",
        displayName: "TypeScript Language Server",
        supportedLanguageIDs: ["typescript", "typescriptreact", "javascript", "javascriptreact"],
        recommendedInstallMethod: .npmGlobal,
        installPackageIdentifiers: ["typescript-language-server", "typescript"],
        isBuiltIn: false,
        defaultServerTemplate: LSPServerDefinition(
            id: "typescript-language-server",
            displayName: "TypeScript Language Server",
            launchCommand: "typescript-language-server",
            launchArguments: ["--stdio"],
            supportedLanguageIDs: ["typescript", "typescriptreact", "javascript", "javascriptreact"],
            defaultFileGlobs: ["**/*.{ts,tsx,js,jsx}"],
            rootMarkers: ["package.json", "tsconfig.json", "jsconfig.json"],
            adapterKind: .generic,
            providerID: "typescript-language-server",
            sourceKind: .installed
        )
    )

    static let clangd = LSPProviderDefinition(
        id: "clangd",
        displayName: "Clangd",
        supportedLanguageIDs: ["c", "cpp", "objective-c", "objective-cpp"],
        recommendedInstallMethod: .homebrew,
        installPackageIdentifiers: ["llvm"],
        isBuiltIn: false,
        defaultServerTemplate: LSPServerDefinition(
            id: "clangd",
            displayName: "Clangd",
            launchCommand: "clangd",
            launchArguments: [],
            supportedLanguageIDs: ["c", "cpp", "objective-c", "objective-cpp"],
            defaultFileGlobs: ["**/*.{c,cc,cpp,cxx,h,hpp,hxx,m,mm}"],
            rootMarkers: ["compile_commands.json", "compile_flags.txt", ".clangd"],
            adapterKind: .generic,
            providerID: "clangd",
            sourceKind: .installed
        )
    )

    static let gopls = LSPProviderDefinition(
        id: "gopls",
        displayName: "Go Language Server",
        supportedLanguageIDs: ["go"],
        recommendedInstallMethod: .goTool,
        installPackageIdentifiers: ["golang.org/x/tools/gopls@latest"],
        isBuiltIn: false,
        defaultServerTemplate: LSPServerDefinition(
            id: "gopls",
            displayName: "Go Language Server",
            launchCommand: "gopls",
            launchArguments: [],
            supportedLanguageIDs: ["go"],
            defaultFileGlobs: ["**/*.go"],
            rootMarkers: ["go.mod", "go.work"],
            adapterKind: .generic,
            providerID: "gopls",
            sourceKind: .installed
        )
    )

}
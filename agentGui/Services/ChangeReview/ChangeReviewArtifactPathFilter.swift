import Foundation

struct ChangeReviewArtifactPathFilter: Sendable {
    private static let excludedDirectoryNames: Set<String> = [
        ".build",
        ".cache",
        ".gradle",
        ".next",
        ".nuxt",
        ".pytest_cache",
        ".ruff_cache",
        ".svelte-kit",
        ".tox",
        ".turbo",
        ".venv",
        "__pycache__",
        "__pypackages__",
        "build",
        "carthage",
        "deriveddata",
        "dist",
        "dist-packages",
        "env",
        "node_modules",
        "out",
        "pods",
        "site-packages",
        "target",
        "venv"
    ]

    func includes(relativePath: String) -> Bool {
        let normalizedPath = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !normalizedPath.isEmpty else {
            return true
        }

        let pathComponents = normalizedPath
            .split(separator: "/")
            .map { $0.lowercased() }

        return pathComponents.allSatisfy { component in
            !Self.excludedDirectoryNames.contains(component)
        }
    }
}
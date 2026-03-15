import Foundation

enum LSPFileLanguageMapper {
    static func languageID(for filePath: String) -> String? {
        languageID(forExtension: URL(fileURLWithPath: filePath).pathExtension.lowercased())
    }

    static func languageID(forExtension fileExtension: String) -> String? {
        switch fileExtension {
        case "ts":
            return "typescript"
        case "tsx":
            return "typescriptreact"
        case "js":
            return "javascript"
        case "jsx":
            return "javascriptreact"
        case "py":
            return "python"
        case "go":
            return "go"
        case "c":
            return "c"
        case "cc", "cpp", "cxx", "h", "hpp", "hxx":
            return "cpp"
        case "m":
            return "objective-c"
        case "mm":
            return "objective-cpp"
        default:
            return nil
        }
    }
}
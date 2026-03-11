import Foundation

enum FileIconSymbolResolver {
    static func symbol(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return "swift"
        case "md", "markdown":
            return "doc.richtext"
        case "json":
            return "curlybraces"
        case "py", "js", "ts":
            return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp":
            return "photo"
        case "pdf":
            return "doc.fill"
        case "sh", "zsh", "bash":
            return "terminal"
        default:
            return "doc"
        }
    }
}
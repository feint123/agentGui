import SwiftData
import Foundation

// MARK: - Enums (Codable for SwiftData persistence)

enum AttachmentKind: String, Codable {
    /// Swift / Objective-C / TypeScript 等源代码文件
    case sourceCode
    /// PNG / JPEG / WEBP / HEIC / GIF / TIFF / BMP
    case image
    /// PDF 文档
    case pdf
    /// 目录/文件夹
    case directory
    /// 其他（Markdown、JSON、文本等）
    case other
}

enum AttachmentStatus: String, Codable {
    /// 文件存在且未修改（相对于消息发送时刻）
    case valid
    /// 文件发送后被删除或移动
    case missing
    /// 文件发送后内容已变更
    case modified
}

// MARK: - Model

@Model
final class MessageAttachment {
    var id: UUID
    var filePath: String
    var displayName: String
    var fileKindRaw: String        // 存 AttachmentKind.rawValue
    var statusRaw: String          // 存 AttachmentStatus.rawValue
    var lineStart: Int?
    var lineEnd: Int?

    // MARK: - CV-FA2: Origin + selected text (聚焦文件专用)

    /// 附件来源。新增字段，旧数据库行默认 NULL 映射为 `.external`。
    var originRaw: String = AttachmentOrigin.external.rawValue

    /// 聚焦文件的选区文本（仅 origin == .focused 时非 nil）。
    var selectedText: String?

    var origin: AttachmentOrigin {
        get { AttachmentOrigin(rawValue: originRaw) ?? .external }
        set { originRaw = newValue.rawValue }
    }

    /// 反向关系（由 Message.attachments 拥有）
    var message: Message?

    var fileKind: AttachmentKind {
        get { AttachmentKind(rawValue: fileKindRaw) ?? .other }
        set { fileKindRaw = newValue.rawValue }
    }

    var status: AttachmentStatus {
        get { AttachmentStatus(rawValue: statusRaw) ?? .valid }
        set { statusRaw = newValue.rawValue }
    }

    init(
        filePath: String,
        displayName: String,
        fileKind: AttachmentKind,
        lineStart: Int? = nil,
        lineEnd: Int? = nil,
        origin: AttachmentOrigin = .external,
        selectedText: String? = nil
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.displayName = displayName
        self.fileKindRaw = fileKind.rawValue
        self.statusRaw = AttachmentStatus.valid.rawValue
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.originRaw = origin.rawValue
        self.selectedText = selectedText
    }
}

// MARK: - Convenience factory from AttachedFile

extension MessageAttachment {
    static func from(_ file: AttachedFile) -> MessageAttachment {
        MessageAttachment(
            filePath: file.path,
            displayName: file.name,
            fileKind: resolveKind(for: file),
            lineStart: file.lineStart,
            lineEnd: file.lineEnd,
            origin: file.origin,
            selectedText: file.selectedText
        )
    }

    private static func resolveKind(for file: AttachedFile) -> AttachmentKind {
        if file.isImage { return .image }
        if file.isPDF   { return .pdf }
        let ext = (file.path as NSString).pathExtension.lowercased()
        let sourceExts: Set<String> = [
            "swift", "m", "mm", "h", "cpp", "c", "ts", "tsx", "js", "jsx",
            "py", "rb", "go", "rs", "kt", "java", "cs", "php"
        ]
        if sourceExts.contains(ext) { return .sourceCode }
        return .other
    }
}

import Foundation

struct UserMessagePresentation: Equatable {
    let directiveChips: [DirectiveChipPresentation]
    let inlineItems: [InlineItem]
    let images: [String]
    let pdfs: [String]
    let others: [AttachmentSnapshotEntry]   // 升级为结构化条目

    var hasStructuredInlineContent: Bool {
        !directiveChips.isEmpty || inlineItems.contains { item in
            if case .mention = item { return true }
            return false
        }
    }

    /// CV-FA3: 所有附件的统一条目列表（含图片/PDF 合成 entry）。
    var allEntries: [AttachmentSnapshotEntry] {
        let imageEntries = images.map { path in
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                fileKindRaw: AttachmentKind.image.rawValue,
                statusRaw: AttachmentStatus.valid.rawValue
            )
        }
        let pdfEntries = pdfs.map { path in
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent,
                fileKindRaw: AttachmentKind.pdf.rawValue,
                statusRaw: AttachmentStatus.valid.rawValue
            )
        }
        return imageEntries + pdfEntries + others
    }

    static func make(from parsed: ParsedUserMessageText) -> UserMessagePresentation {
        let directiveChips: [DirectiveChipPresentation] = parsed.directiveAuditItems.map { item in
            DirectiveChipPresentation(item: item)
        }
        let inlineItems: [InlineItem] = parsed.inlineSegments.map { segment in
            InlineItem(segment: segment)
        }

        return UserMessagePresentation(
            directiveChips: directiveChips,
            inlineItems: inlineItems,
            images: parsed.images,
            pdfs: parsed.pdfs,
            others: parsed.others
        )
    }
}

struct DirectiveChipPresentation: Equatable, Identifiable {
    let id: String
    let title: String
    let helpText: String

    init(item: ParsedDirectiveAuditItem) {
        self.id = item.rawValue
        switch item.kind {
        case "skill":
            self.title = "Skill: \(item.displayName)"
        default:
            self.title = item.rawValue
        }
        self.helpText = item.rawValue
    }
}

struct TextRunPresentation: Equatable, Identifiable {
    let id: String
    let text: String

    init(text: String) {
        self.text = text
        self.id = text
    }
}

struct MentionTokenPresentation: Equatable, Identifiable {
    let id: String
    let iconName: String
    let title: String
    let subtitle: String?
    let fullPath: String

    init(mention: ParsedMention) {
        self.id = mention.fullPath
        self.iconName = FileIconSymbolResolver.symbol(forFileName: mention.displayName)
        if let lineRange = mention.lineRange {
            self.title = "\(mention.displayName):\(lineRange.displayText)"
        } else {
            self.title = mention.displayName
        }
        self.subtitle = mention.secondaryPath
        self.fullPath = mention.fullPath
    }

    init(iconName: String, title: String, subtitle: String?, fullPath: String) {
        self.id = fullPath
        self.iconName = iconName
        self.title = title
        self.subtitle = subtitle
        self.fullPath = fullPath
    }
}

enum InlineItem: Equatable, Identifiable {
    case text(TextRunPresentation)
    case mention(MentionTokenPresentation)

    var id: String {
        switch self {
        case .text(let value):
            return "text:\(value.id)"
        case .mention(let value):
            return "mention:\(value.id)"
        }
    }

    init(segment: UserMessageInlineSegment) {
        switch segment {
        case .text(let value):
            self = .text(TextRunPresentation(text: value))
        case .mention(let value):
            self = .mention(MentionTokenPresentation(mention: value))
        }
    }
}
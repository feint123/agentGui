import SwiftUI

enum GitDiffRowBackgroundRole: Equatable {
    case neutral
    case addition
    case deletion
    case metadata
}

struct GitDiffRowStyle: Equatable {
    let gutterBackgroundOpacity: Double
    let contentBackgroundRole: GitDiffRowBackgroundRole

    static func make(for row: GitDiffPresentation.Row) -> GitDiffRowStyle {
        switch row {
        case .addition:
            return .init(gutterBackgroundOpacity: 0.045, contentBackgroundRole: .addition)
        case .deletion:
            return .init(gutterBackgroundOpacity: 0.045, contentBackgroundRole: .deletion)
        case .metadata:
            return .init(gutterBackgroundOpacity: 0.045, contentBackgroundRole: .metadata)
        case .context:
            return .init(gutterBackgroundOpacity: 0.045, contentBackgroundRole: .neutral)
        }
    }
}

struct GitDiffPresentation: Equatable {
    struct ChangeSummary: Equatable {
        let additions: Int
        let deletions: Int
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let header: String
        let rows: [Row]
    }

    enum Row: Equatable, Identifiable {
        case context(oldLineNumber: Int?, newLineNumber: Int?, text: String)
        case addition(oldLineNumber: Int?, newLineNumber: Int?, text: String)
        case deletion(oldLineNumber: Int?, newLineNumber: Int?, text: String)
        case metadata(text: String)

        var id: String {
            switch self {
            case .context(let old, let new, let text):
                return "context:\(old ?? -1):\(new ?? -1):\(text)"
            case .addition(let old, let new, let text):
                return "addition:\(old ?? -1):\(new ?? -1):\(text)"
            case .deletion(let old, let new, let text):
                return "deletion:\(old ?? -1):\(new ?? -1):\(text)"
            case .metadata(let text):
                return "metadata:\(text)"
            }
        }

        var oldLineNumber: Int? {
            switch self {
            case .context(let old, _, _), .addition(let old, _, _), .deletion(let old, _, _):
                return old
            case .metadata:
                return nil
            }
        }

        var newLineNumber: Int? {
            switch self {
            case .context(_, let new, _), .addition(_, let new, _), .deletion(_, let new, _):
                return new
            case .metadata:
                return nil
            }
        }

        var text: String {
            switch self {
            case .context(_, _, let text), .addition(_, _, let text), .deletion(_, _, let text):
                return text
            case .metadata(let text):
                return text
            }
        }

        var prefix: String {
            switch self {
            case .context:
                return " "
            case .addition:
                return "+"
            case .deletion:
                return "-"
            case .metadata:
                return ""
            }
        }
    }

    let filePath: String
    let changeSummary: ChangeSummary
    let sections: [Section]

    static func build(title: String, diffText: String) -> GitDiffPresentation {
        let lines = diffText.split(whereSeparator: \ .isNewline).map(String.init)
        guard !lines.isEmpty else {
            return GitDiffPresentation(filePath: title, changeSummary: .init(additions: 0, deletions: 0), sections: [])
        }

        var sections: [Section] = []
        var currentRows: [Row] = []
        var currentHeader: String?
        var currentOldLine: Int?
        var currentNewLine: Int?
        var additions = 0
        var deletions = 0

        func flushSection() {
            guard let currentHeader else { return }
            sections.append(.init(id: currentHeader + ":\(sections.count)", header: currentHeader, rows: currentRows))
            currentRows = []
        }

        for line in lines {
            if line.hasPrefix("@@") {
                flushSection()
                currentHeader = line
                let span = parseHunkHeader(line)
                currentOldLine = span.oldStart
                currentNewLine = span.newStart
                continue
            }

            guard currentHeader != nil else { continue }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                additions += 1
                currentRows.append(.addition(oldLineNumber: nil, newLineNumber: currentNewLine, text: String(line.dropFirst())))
                currentNewLine = increment(currentNewLine)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                deletions += 1
                currentRows.append(.deletion(oldLineNumber: currentOldLine, newLineNumber: nil, text: String(line.dropFirst())))
                currentOldLine = increment(currentOldLine)
            } else if line.hasPrefix("\\") {
                currentRows.append(.metadata(text: line))
            } else {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                currentRows.append(.context(oldLineNumber: currentOldLine, newLineNumber: currentNewLine, text: content))
                currentOldLine = increment(currentOldLine)
                currentNewLine = increment(currentNewLine)
            }
        }

        flushSection()

        return GitDiffPresentation(
            filePath: title,
            changeSummary: .init(additions: additions, deletions: deletions),
            sections: sections
        )
    }

    private static func increment(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return value + 1
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int?, newStart: Int?) {
        let pattern = #"@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, nil) }
        let range = NSRange(header.startIndex..., in: header)
        guard let match = regex.firstMatch(in: header, range: range),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header) else {
            return (nil, nil)
        }
        return (Int(header[oldRange]), Int(header[newRange]))
    }
}

enum FileEditorDisplayMode: Equatable {
    case empty
    case file(URL)
    case gitDiff(title: String, diffText: String)

    @MainActor
    static func resolve(from workspaceState: WorkspaceState) -> FileEditorDisplayMode {
        if let title = workspaceState.selectedGitDiffTitle,
           let diffText = workspaceState.selectedGitDiffText,
           !diffText.isEmpty {
            return .gitDiff(title: title, diffText: diffText)
        }
        if let fileURL = workspaceState.selectedFile {
            return .file(fileURL)
        }
        return .empty
    }
}

struct GitDiffView: View {
    @Environment(WorkspaceState.self) private var workspaceState

    let title: String
    let diffText: String

    private var presentation: GitDiffPresentation {
        GitDiffPresentation.build(title: title, diffText: diffText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if presentation.sections.isEmpty {
                emptyState
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard
                        ForEach(presentation.sections) { section in
                            hunkSection(section)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    workspaceState.clearGitDiffSelection()
                } label: {
                    Label("返回文件", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Divider()
                    .frame(height: 14)

                Image(systemName: "doc.append")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.filePath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Patch Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                summaryBadge(title: "+\(presentation.changeSummary.additions)", tint: .green)
                summaryBadge(title: "-\(presentation.changeSummary.deletions)", tint: .red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lastPathComponent)
                    .font(.headline)
                Text(presentation.filePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            diffMetric(title: "新增", value: presentation.changeSummary.additions, tint: .green)
            diffMetric(title: "删除", value: presentation.changeSummary.deletions, tint: .red)
            diffMetric(title: "Hunks", value: presentation.sections.count, tint: .secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func hunkSection(_ section: GitDiffPresentation.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))

            LazyVStack(spacing: 0) {
                ForEach(section.rows) { row in
                    diffRow(row)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func diffRow(_ row: GitDiffPresentation.Row) -> some View {
        let style = GitDiffRowStyle.make(for: row)

        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                lineNumberCell(row.oldLineNumber)
                lineNumberCell(row.newLineNumber)

                Text(row.prefix)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(prefixColor(for: row))
                    .frame(width: 18)
            }
            .background(Color.black.opacity(style.gutterBackgroundOpacity))

            Text(verbatim: row.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.trailing, 10)
        }
        .background(rowBackground(for: style.contentBackgroundRole))
    }

    private func lineNumberCell(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
    }

    private func rowBackground(for role: GitDiffRowBackgroundRole) -> some View {
        switch role {
        case .addition:
            return Color.green.opacity(0.13)
        case .deletion:
            return Color.red.opacity(0.12)
        case .metadata:
            return Color.orange.opacity(0.08)
        case .neutral:
            return Color.clear
        }
    }

    private func prefixColor(for row: GitDiffPresentation.Row) -> Color {
        switch row {
        case .addition:
            return .green
        case .deletion:
            return .red
        case .metadata:
            return .orange
        case .context:
            return .secondary
        }
    }

    private func summaryBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private func diffMetric(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(minWidth: 48, alignment: .leading)
    }

    private var lastPathComponent: String {
        URL(fileURLWithPath: presentation.filePath).lastPathComponent
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("无可显示的 Diff", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("这个文件当前没有可渲染的 patch，或者 diff 内容为空。")
        }
    }
}
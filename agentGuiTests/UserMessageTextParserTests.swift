import Foundation
import Testing
@testable import agentGui

@MainActor
@Suite(.serialized)
struct UserMessageTextParserTests {

    @Test func parserLeavesPlainMessageUntouched() async throws {
        let parsed = UserMessageTextParser.parse(
            text: "普通消息正文",
            workspaceRoot: "/tmp/nonexistent"
        )

        #expect(parsed.bodyText == "普通消息正文")
        #expect(parsed.directiveAuditItems.isEmpty)
        #expect(parsed.inlineSegments == [.text("普通消息正文")])
        #expect(parsed.images.isEmpty)
        #expect(parsed.pdfs.isEmpty)
        #expect(parsed.others.isEmpty)
    }

    @Test func parserExtractsDirectiveAuditAndLeavesBodyClean() async throws {
        let parsed = UserMessageTextParser.parse(
            text: "请按这个技能处理。\n\n[Active directives] skill=brainstorming",
            workspaceRoot: "/tmp/nonexistent"
        )

        #expect(parsed.bodyText == "请按这个技能处理。")
        #expect(parsed.directiveAuditItems.count == 1)
        #expect(parsed.directiveAuditItems.first?.kind == "skill")
        #expect(parsed.directiveAuditItems.first?.rawValue == "skill=brainstorming")
        #expect(parsed.inlineSegments == [.text("请按这个技能处理。")])
    }

    @Test func parserSeparatesDirectiveAuditBeforeReferencedFilesSection() async throws {
        let parsed = UserMessageTextParser.parse(
            text: "请查看附加内容\n\n[Active directives] skill=brainstorming\n\nReferenced files:\n- /tmp/a.png\n- /tmp/b.pdf\n- /tmp/c.txt",
            workspaceRoot: "/tmp/nonexistent"
        )

        #expect(parsed.bodyText == "请查看附加内容")
        #expect(parsed.directiveAuditItems.count == 1)
        #expect(parsed.images == ["/tmp/a.png"])
        #expect(parsed.pdfs == ["/tmp/b.pdf"])
        #expect(parsed.others == ["/tmp/c.txt"])
    }

    @Test func parserSeparatesReferencedFilesWhenDirectiveAuditIsAppendedLast() async throws {
        let parsed = UserMessageTextParser.parse(
            text: "请查看附加内容\n\nReferenced files:\n- /tmp/a.png\n- /tmp/b.pdf\n- /tmp/c.txt\n\n[Active directives] skill=brainstorming",
            workspaceRoot: "/tmp/nonexistent"
        )

        #expect(parsed.bodyText == "请查看附加内容")
        #expect(parsed.directiveAuditItems.map(\.rawValue) == ["skill=brainstorming"])
        #expect(parsed.images == ["/tmp/a.png"])
        #expect(parsed.pdfs == ["/tmp/b.pdf"])
        #expect(parsed.others == ["/tmp/c.txt"])
    }

    @Test func parserPromotesWorkspaceFilePathIntoMentionSegment() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let filePath = workspaceRoot.appending(path: "agentGui/Views/MessageBubbleView.swift").path

        let parsed = UserMessageTextParser.parse(
            text: "请检查 \(filePath) 里的布局",
            workspaceRoot: workspaceRoot.path
        )

        #expect(parsed.inlineSegments.count == 3)
        #expect(parsed.inlineSegments[0] == .text("请检查 "))

        let mention = try #require({ () -> ParsedMention? in
            guard case .mention(let value) = parsed.inlineSegments[1] else { return nil }
            return value
        }())

        #expect(mention.fullPath == filePath)
        #expect(mention.displayName == "MessageBubbleView.swift")
        #expect(mention.secondaryPath == "agentGui/Views/MessageBubbleView.swift")
        #expect(parsed.inlineSegments[2] == .text(" 里的布局"))
    }

    @Test func parserKeepsExternalAbsolutePathAsPlainText() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let parsed = UserMessageTextParser.parse(
            text: "系统日志路径 /usr/bin/swift 不应变成 token",
            workspaceRoot: workspaceRoot.path
        )

        #expect(parsed.inlineSegments == [.text("系统日志路径 /usr/bin/swift 不应变成 token")])
    }

    @Test func parserCapturesWorkspaceMentionLineRangeSuffix() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let filePath = workspaceRoot.appending(path: "agentGui/Views/MessageBubbleView.swift").path

        let parsed = UserMessageTextParser.parse(
            text: "请检查当前选区 \(filePath):12-18",
            workspaceRoot: workspaceRoot.path
        )

        let mention = try #require({ () -> ParsedMention? in
            guard parsed.inlineSegments.count >= 2,
                  case .mention(let value) = parsed.inlineSegments[1] else { return nil }
            return value
        }())

        #expect(mention.fullPath == filePath)
        #expect(mention.lineRange == FileLineRange(startLine: 12, endLine: 18))
    }

    @Test func parserHidesSelectionExcerptFromDisplayedBody() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let filePath = workspaceRoot.appending(path: "agentGui/Views/MessageBubbleView.swift").path

        let parsed = UserMessageTextParser.parse(
            text: "当前文件: \(filePath):12-18\n选区内容:\nlet example = true\nprint(example)\n\n帮我解释这个逻辑",
            workspaceRoot: workspaceRoot.path
        )

        #expect(parsed.bodyText.contains("选区内容") == false)
        #expect(parsed.bodyText.contains("let example = true") == false)
        #expect(parsed.bodyText.contains("帮我解释这个逻辑"))

        let mention = try #require({ () -> ParsedMention? in
            for segment in parsed.inlineSegments {
                if case .mention(let value) = segment {
                    return value
                }
            }
            return nil
        }())

        #expect(mention.fullPath == filePath)
        #expect(mention.lineRange == FileLineRange(startLine: 12, endLine: 18))
    }

    @Test func parserHidesCurrentFileLabelFromDisplayedBody() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let filePath = workspaceRoot.appending(path: "agentGui/Views/MessageBubbleView.swift").path

        let parsed = UserMessageTextParser.parse(
            text: "当前文件: \(filePath):12-18\n\n帮我检查这段布局",
            workspaceRoot: workspaceRoot.path
        )

        #expect(parsed.bodyText.contains("当前文件:") == false)
        let flattenedText = parsed.inlineSegments.reduce(into: "") { partialResult, segment in
            if case .text(let value) = segment {
                partialResult += value
            }
        }
        #expect(flattenedText.contains("当前文件:") == false)
        let mention = try #require({ () -> ParsedMention? in
            for segment in parsed.inlineSegments {
                if case .mention(let value) = segment {
                    return value
                }
            }
            return nil
        }())
        #expect(mention.fullPath == filePath)
        #expect(mention.lineRange == FileLineRange(startLine: 12, endLine: 18))

        let trailingText = try #require({ () -> String? in
            guard let last = parsed.inlineSegments.last,
                  case .text(let value) = last else { return nil }
            return value
        }())
        #expect(trailingText.hasPrefix(" "))
        #expect(trailingText.contains("帮我检查这段布局"))
    }

    @Test func parserSplitsMultipleWorkspaceMentionsInOrder() async throws {
        let workspaceRoot = URL(fileURLWithPath: "/Volumes/T7/文稿/Projects/agentGui", isDirectory: true)
        let first = workspaceRoot.appending(path: "agentGui/Views/MessageBubbleView.swift").path
        let second = workspaceRoot.appending(path: "agentGui/Views/ChatView+InputArea.swift").path

        let parsed = UserMessageTextParser.parse(
            text: "对比 \(first) 和 \(second) 的展示差异",
            workspaceRoot: workspaceRoot.path
        )

        #expect(parsed.inlineSegments.count == 5)
        let firstMention = try #require({ () -> ParsedMention? in
            guard case .mention(let value) = parsed.inlineSegments[1] else { return nil }
            return value
        }())
        let secondMention = try #require({ () -> ParsedMention? in
            guard case .mention(let value) = parsed.inlineSegments[3] else { return nil }
            return value
        }())

        #expect(firstMention.fullPath == first)
        #expect(secondMention.fullPath == second)
    }
}
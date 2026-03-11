import Foundation
import Testing
@testable import agentGui

@MainActor
struct UserMessagePresentationTests {

    @Test func presentationBuildsDirectiveAndMentionDisplayModels() async throws {
        let parsed = ParsedUserMessageText(
            bodyText: "请查看路径",
            directiveAuditItems: [
                ParsedDirectiveAuditItem(kind: "skill", rawValue: "skill=brainstorming", displayName: "brainstorming")
            ],
            inlineSegments: [
                .text("请查看 "),
                .mention(
                    ParsedMention(
                        fullPath: "/tmp/ws/agentGui/Views/MessageBubbleView.swift",
                        displayName: "MessageBubbleView.swift",
                        secondaryPath: "agentGui/Views/MessageBubbleView.swift",
                        lineRange: nil
                    )
                )
            ],
            images: [],
            pdfs: [],
            others: []
        )

        let presentation = UserMessagePresentation.make(from: parsed)

        #expect(presentation.directiveChips.count == 1)
        #expect(presentation.directiveChips.first?.title == "Skill: brainstorming")
        #expect(presentation.inlineItems.count == 2)
        #expect(presentation.inlineItems[0] == .text(TextRunPresentation(text: "请查看 ")))
        #expect(presentation.inlineItems[1] == .mention(
            MentionTokenPresentation(
                iconName: "swift",
                title: "MessageBubbleView.swift",
                subtitle: "agentGui/Views/MessageBubbleView.swift",
                fullPath: "/tmp/ws/agentGui/Views/MessageBubbleView.swift"
            )
        ))
    }

    @Test func presentationMarksStructuredContentAvailability() async throws {
        let parsed = ParsedUserMessageText(
            bodyText: "普通正文",
            directiveAuditItems: [],
            inlineSegments: [.text("普通正文")],
            images: [],
            pdfs: [],
            others: []
        )

        let presentation = UserMessagePresentation.make(from: parsed)

        #expect(presentation.hasStructuredInlineContent == false)
        #expect(presentation.inlineItems == [.text(TextRunPresentation(text: "普通正文"))])
    }

    @Test func presentationCarriesAttachmentGroupsThrough() async throws {
        let parsed = ParsedUserMessageText(
            bodyText: "请看附件",
            directiveAuditItems: [],
            inlineSegments: [.text("请看附件")],
            images: ["/tmp/a.png"],
            pdfs: ["/tmp/b.pdf"],
            others: ["/tmp/c.txt"]
        )

        let presentation = UserMessagePresentation.make(from: parsed)

        #expect(presentation.images == ["/tmp/a.png"])
        #expect(presentation.pdfs == ["/tmp/b.pdf"])
        #expect(presentation.others == ["/tmp/c.txt"])
    }

    @Test func fileIconResolverUsesStableSymbolsForKnownExtensions() async throws {
        #expect(FileIconSymbolResolver.symbol(forFileName: "MessageBubbleView.swift") == "swift")
        #expect(FileIconSymbolResolver.symbol(forFileName: "README.md") == "doc.richtext")
        #expect(FileIconSymbolResolver.symbol(forFileName: "diagram.png") == "photo")
        #expect(FileIconSymbolResolver.symbol(forFileName: "report.pdf") == "doc.fill")
    }

    @Test func presentationAppendsLineRangeToMentionTitle() async throws {
        let parsed = ParsedUserMessageText(
            bodyText: "检查当前选区",
            directiveAuditItems: [],
            inlineSegments: [
                .mention(
                    ParsedMention(
                        fullPath: "/tmp/ws/agentGui/Views/MessageBubbleView.swift",
                        displayName: "MessageBubbleView.swift",
                        secondaryPath: "agentGui/Views/MessageBubbleView.swift",
                        lineRange: FileLineRange(startLine: 12, endLine: 18)
                    )
                )
            ],
            images: [],
            pdfs: [],
            others: []
        )

        let presentation = UserMessagePresentation.make(from: parsed)
        let token = try #require({ () -> MentionTokenPresentation? in
            guard case .mention(let value) = presentation.inlineItems.first else { return nil }
            return value
        }())

        #expect(token.title == "MessageBubbleView.swift:12-18")
    }
}
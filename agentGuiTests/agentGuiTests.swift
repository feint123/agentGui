//
//  agentGuiTests.swift
//  agentGuiTests
//
//  Created by feint on 2026/2/10.
//

import Foundation
import Testing
@testable import agentGui

@Suite(.serialized)
struct agentGuiTests {

    private func signature(_ document: BlockDocument) -> [BlockSignature] {
        document.blocks.map {
            BlockSignature(kind: $0.kind, text: $0.text, metadata: $0.metadata)
        }
    }

    @Test func markdownRoundTripPreservesDocumentStructure() async throws {
        let input = """
        # 文档标题

        - 第一项
          延续描述
        - [x] 已完成任务
          更多说明

        > 第一行引用
        > 第二行引用

        > [!NOTE] 注意
        > 这里是提示块正文

        <details><summary>更多信息</summary>

        折叠块正文

        </details>

        ```swift
        print(\"hello\")
        ```

        ::url[GitHub](https://github.com)
        ::file[说明.pdf](/tmp/readme.pdf)
        ![封面](/tmp/cover.png)
        """

        let url = URL(fileURLWithPath: "/tmp/test.md")
        let parsed = BlockMarkdownCodec.parse(input, fileURL: url)
        let serialized = BlockMarkdownCodec.serialize(parsed, fileURL: url)
        let reparsed = BlockMarkdownCodec.parse(serialized, fileURL: url)

        #expect(signature(parsed) == signature(reparsed))
        #expect(reparsed.blocks.contains { $0.kind == DocumentBlockKind.toggle })
        #expect(reparsed.blocks.contains { $0.kind == DocumentBlockKind.callout })
        #expect(reparsed.blocks.contains { $0.kind == DocumentBlockKind.code && $0.metadata.language == "swift" })
    }

    @Test func nonMarkdownFilesStayInSourceMode() async throws {
        let input = """
        struct Demo {
            let value = 1
        }
        """

        let url = URL(fileURLWithPath: "/tmp/demo.swift")
        let parsed = BlockMarkdownCodec.parse(input, fileURL: url)
        let serialized = BlockMarkdownCodec.serialize(parsed, fileURL: url)

        #expect(parsed.blocks.count == 1)
        #expect(parsed.blocks.first?.kind == DocumentBlockKind.source)
        #expect(parsed.blocks.first?.metadata.language == "swift")
        #expect(serialized == input)
    }

    @Test func multilineListAndQuoteSerializationIsStable() async throws {
        let url = URL(fileURLWithPath: "/tmp/stable.md")
        let document = BlockDocument(blocks: [
            {
                var block = DocumentBlock(kind: .bulletedList, text: "第一项\n延续行")
                block.metadata.indentLevel = 1
                return block
            }(),
            {
                var block = DocumentBlock(kind: .todo, text: "待办\n补充说明")
                block.metadata.checked = true
                block.metadata.indentLevel = 2
                return block
            }(),
            {
                var block = DocumentBlock(kind: .quote, text: "引用第一行\n引用第二行")
                block.metadata.indentLevel = 1
                return block
            }()
        ])

        let serialized = BlockMarkdownCodec.serialize(document, fileURL: url)
        let reparsed = BlockMarkdownCodec.parse(serialized, fileURL: url)

        #expect(serialized.contains("  - 第一项\n    延续行"))
        #expect(serialized.contains("    - [x] 待办\n      补充说明"))
        #expect(serialized.contains(">> 引用第一行\n>> 引用第二行"))
        #expect(signature(reparsed) == signature(document))
    }

    @Test func tableSerializationProducesEditableGridShape() async throws {
        let rows = [
            ["姓名", "角色"],
            ["Claude", "Assistant"],
            ["Copilot", "Editor"]
        ]

        let markdown = BlockMarkdownCodec.serializeTableContent(rows)
        let reparsed = BlockMarkdownCodec.parseTableContent(markdown)

        #expect(markdown.contains("| 姓名 | 角色 |"))
        #expect(markdown.contains("| --- | --- |"))
        #expect(reparsed == rows)
    }

    @Test func toggleOpenStateSurvivesRoundTrip() async throws {
        let input = """
        <details open><summary>更多</summary>

        展开内容

        </details>
        """

        let url = URL(fileURLWithPath: "/tmp/toggle.md")
        let parsed = BlockMarkdownCodec.parse(input, fileURL: url)
        let serialized = BlockMarkdownCodec.serialize(parsed, fileURL: url)
        let reparsed = BlockMarkdownCodec.parse(serialized, fileURL: url)

        #expect(parsed.blocks.first?.kind == .toggle)
        #expect(parsed.blocks.first?.metadata.isCollapsed == false)
        #expect(serialized.contains("<details open>"))
        #expect(reparsed.blocks.first?.metadata.isCollapsed == false)
    }

}

private struct BlockSignature: Equatable {
    let kind: DocumentBlockKind
    let text: String
    let checked: Bool
    let language: String
    let resource: String
    let secondaryText: String
    let tone: String
    let isCollapsed: Bool
    let indentLevel: Int

    init(kind: DocumentBlockKind, text: String, metadata: DocumentBlockMetadata) {
        self.kind = kind
        self.text = text
        checked = metadata.checked
        language = metadata.language
        resource = metadata.resource
        secondaryText = metadata.secondaryText
        tone = metadata.tone
        isCollapsed = metadata.isCollapsed
        indentLevel = metadata.indentLevel
    }
}

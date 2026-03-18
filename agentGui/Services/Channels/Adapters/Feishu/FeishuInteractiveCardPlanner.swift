import Foundation

struct FeishuInteractiveCardPlanner {
    func makePlan(text: String, title: String?) -> FeishuInteractiveCardPlan {
        let document = BlockMarkdownCodec.parse(text, fileURL: nil)
        var sections: [FeishuInteractiveSection] = []
        var bufferedBlocks: [DocumentBlock] = []

        func serialize(_ blocks: [DocumentBlock]) -> String {
            BlockMarkdownCodec.serialize(
                BlockDocument(blocks: blocks),
                fileURL: nil
            )
        }

        func flushBufferedBlocks() {
            guard !bufferedBlocks.isEmpty else { return }
            let markdown = serialize(bufferedBlocks)
            bufferedBlocks.removeAll(keepingCapacity: true)
            guard !markdown.isEmpty else { return }
            sections.append(.markdown(markdown))
        }

        for block in document.blocks {
            if let section = dedicatedSection(for: block, serialize: serialize) {
                flushBufferedBlocks()
                sections.append(section)
            } else {
                bufferedBlocks.append(block)
            }
        }

        flushBufferedBlocks()

        return FeishuInteractiveCardPlan(title: title, sections: sections)
    }

    private func dedicatedSection(
        for block: DocumentBlock,
        serialize: ([DocumentBlock]) -> String
    ) -> FeishuInteractiveSection? {
        switch block.kind {
        case .table:
            return .table(markdown: block.text)
        case .code:
            return .codeBlock(markdown: serialize([block]))
        case .callout:
            return .callout(markdown: serialize([block]))
        case .divider:
            return .divider(markdown: serialize([block]))
        default:
            return nil
        }
    }
}
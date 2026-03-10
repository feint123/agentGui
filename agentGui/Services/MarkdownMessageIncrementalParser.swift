import Foundation

@MainActor
struct MarkdownIncrementalSnapshot: Equatable {
    let sourceText: String
    let blocks: [MarkdownMessageRenderBlock]
}

@MainActor
struct MarkdownMessageIncrementalParser {
    func fullParse(_ text: String) -> [MarkdownMessageRenderBlock] {
        MarkdownMessageBlockPresentation.makeBlocks(from: text)
    }

    func reconcile(
        oldText: String,
        newText: String,
        previous: MarkdownIncrementalSnapshot? = nil
    ) -> MarkdownIncrementalSnapshot {
        guard newText != oldText else {
            return previous ?? MarkdownIncrementalSnapshot(sourceText: newText, blocks: fullParse(newText))
        }

        guard let previous, !oldText.isEmpty, newText.hasPrefix(oldText) else {
            return MarkdownIncrementalSnapshot(sourceText: newText, blocks: fullParse(newText))
        }

        let parsed = fullParse(newText)
        let merged = reuseStablePrefixIDs(from: previous.blocks, into: parsed)
        return MarkdownIncrementalSnapshot(sourceText: newText, blocks: merged)
    }

    private func reuseStablePrefixIDs(
        from previous: [MarkdownMessageRenderBlock],
        into current: [MarkdownMessageRenderBlock]
    ) -> [MarkdownMessageRenderBlock] {
        guard !previous.isEmpty, !current.isEmpty else {
            return current
        }

        var result: [MarkdownMessageRenderBlock] = []
        result.reserveCapacity(current.count)

        var prefixIndex = 0
        while prefixIndex < previous.count && prefixIndex < current.count {
            guard previous[prefixIndex].matchesContent(of: current[prefixIndex]) else {
                break
            }
            result.append(current[prefixIndex].withID(previous[prefixIndex].id))
            prefixIndex += 1
        }

        if prefixIndex < current.count {
            result.append(contentsOf: current[prefixIndex...])
        }

        return result
    }
}

private extension MarkdownMessageRenderBlock {
    func matchesContent(of other: MarkdownMessageRenderBlock) -> Bool {
        kind == other.kind && text == other.text && metadata == other.metadata
    }

    func withID(_ id: String) -> MarkdownMessageRenderBlock {
        MarkdownMessageRenderBlock(id: id, kind: kind, text: text, metadata: metadata)
    }
}
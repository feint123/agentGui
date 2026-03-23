import Foundation
import SwiftUI

struct BlockInlineMarkdownRenderedContent {
    let sourceText: String
    let attributedString: AttributedString?
    let projection: BlockInlineMarkdownProjection

    var displayPlainText: String {
        projection.visibleText
    }
}

struct BlockInlineMarkdownRenderCacheStats: Equatable {
    let hitCount: Int
    let missCount: Int
    let entryCount: Int
}

final class BlockInlineMarkdownRenderCache {
    static let shared = BlockInlineMarkdownRenderCache()

    private let lock = NSLock()
    private let entryLimit: Int
    private var entries: [String: BlockInlineMarkdownRenderedContent] = [:]
    private var usageOrder: [String] = []
    private var hitCount = 0
    private var missCount = 0

    init(entryLimit: Int = 256) {
        self.entryLimit = max(16, entryLimit)
    }

    func renderedContent(for text: String) -> BlockInlineMarkdownRenderedContent {
        lock.lock()
        if let cached = entries[text] {
            hitCount += 1
            promote(text)
            lock.unlock()
            return cached
        }

        let renderedContent = Self.makeRenderedContent(for: text)
        missCount += 1
        entries[text] = renderedContent
        promote(text)
        trimIfNeeded()
        lock.unlock()
        return renderedContent
    }

    func reset() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        usageOrder.removeAll(keepingCapacity: false)
        hitCount = 0
        missCount = 0
        lock.unlock()
    }

    func stats() -> BlockInlineMarkdownRenderCacheStats {
        lock.lock()
        let stats = BlockInlineMarkdownRenderCacheStats(
            hitCount: hitCount,
            missCount: missCount,
            entryCount: entries.count
        )
        lock.unlock()
        return stats
    }

    private func promote(_ key: String) {
        if usageOrder.first == key {
            return
        }
        usageOrder.removeAll { $0 == key }
        usageOrder.insert(key, at: 0)
    }

    private func trimIfNeeded() {
        guard usageOrder.count > entryLimit else { return }
        let overflowCount = usageOrder.count - entryLimit
        let evictedKeys = usageOrder.suffix(overflowCount)
        for key in evictedKeys {
            entries.removeValue(forKey: key)
        }
        usageOrder.removeLast(overflowCount)
    }

    private static func makeRenderedContent(for text: String) -> BlockInlineMarkdownRenderedContent {
        let projection = BlockInlineMarkdownProjection(sourceText: text)
        let attributedString: AttributedString?

        if text.isEmpty {
            attributedString = AttributedString("")
        } else {
            attributedString = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }

        return BlockInlineMarkdownRenderedContent(
            sourceText: text,
            attributedString: attributedString,
            projection: projection
        )
    }
}

enum BlockInlineMarkdownRendering {
    private static let cache = BlockInlineMarkdownRenderCache.shared

    static func renderedContent(for text: String) -> BlockInlineMarkdownRenderedContent {
        cache.renderedContent(for: text)
    }

    static func attributedString(for text: String) -> AttributedString? {
        renderedContent(for: text).attributedString
    }

    static func displayPlainText(for text: String) -> String {
        renderedContent(for: text).displayPlainText
    }

    static func projection(for text: String) -> BlockInlineMarkdownProjection {
        renderedContent(for: text).projection
    }

    static func resetCacheForTesting() {
        cache.reset()
    }

    static func cacheStatsForTesting() -> BlockInlineMarkdownRenderCacheStats {
        cache.stats()
    }
}

struct InlineMarkdownText: View {
    let renderedContent: BlockInlineMarkdownRenderedContent
    var font: Font? = nil
    var color: Color? = nil
    var strikethrough: Bool = false

    init(text: String, font: Font? = nil, color: Color? = nil, strikethrough: Bool = false) {
        self.init(
            renderedContent: BlockInlineMarkdownRendering.renderedContent(for: text),
            font: font,
            color: color,
            strikethrough: strikethrough
        )
    }

    init(renderedContent: BlockInlineMarkdownRenderedContent, font: Font? = nil, color: Color? = nil, strikethrough: Bool = false) {
        self.renderedContent = renderedContent
        self.font = font
        self.color = color
        self.strikethrough = strikethrough
    }

    var body: some View {
        Group {
            if let attributed = renderedContent.attributedString {
                Text(attributed)
            } else {
                Text(renderedContent.sourceText)
            }
        }
        .font(font)
        .foregroundStyle(color ?? .primary)
        .strikethrough(strikethrough)
    }
}
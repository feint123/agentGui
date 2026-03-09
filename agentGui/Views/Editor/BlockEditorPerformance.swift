//
//  BlockEditorPerformance.swift
//  agentGui
//

import Foundation
import OSLog

/// Block 编辑器性能监控
///
/// 使用统一的 PerformanceMonitor 进行日志记录
enum BlockEditorPerformance {
    private static var parseCache: [String: BlockDocument] = [:]
    private static var tableCache: [String: [[String]]] = [:]
    private static let cacheLimit = 20

    // 使用统一性能监控工具
    private static let perf = PerformanceMonitor.self

    static func cachedDocument(for key: String) -> BlockDocument? {
        parseCache[key]
    }

    static func storeDocument(_ document: BlockDocument, for key: String) {
        parseCache[key] = document
        trim(&parseCache)
    }

    static func cachedTable(for key: String) -> [[String]]? {
        tableCache[key]
    }

    static func storeTable(_ table: [[String]], for key: String) {
        tableCache[key] = table
        trim(&tableCache)
    }

    @discardableResult
    static func measureValue<T>(_ phase: String, thresholdMS: Double = 3, _ block: () -> T) -> T {
        #if DEBUG
        let span = perf.startSpan("BlockEditor.\(phase)", category: "Editor", level: .verbose)
        let result = block()
        span.end()
        return result
        #else
        let span = perf.startSpan("BlockEditor.\(phase)", category: "Editor", level: .normal)
        let result = block()
        span.end()
        return result
        #endif
    }

    static func measure(_ phase: String, thresholdMS: Double = 3, _ block: () -> Void) {
        _ = measureValue(phase, thresholdMS: thresholdMS, block)
    }

    // MARK: - 专用的编辑操作监控

    /// 监控 parse 操作
    static func measureParse<T>(_ fileExtension: String?, _ block: () -> T) -> T {
        let span = perf.startSpan("BlockMarkdownCodec.parse", category: "Editor", level: .normal)
        defer {
            if let ext = fileExtension {
                span.addMetadata("extension", value: ext)
            }
            span.end()
        }
        return block()
    }

    /// 监控 serialize 操作
    static func measureSerialize<T>(_ blockCount: Int, _ block: () -> T) -> T {
        let span = perf.startSpan("BlockMarkdownCodec.serialize", category: "Editor", level: .normal)
        defer {
            span.addMetadata("blocks", value: blockCount)
            span.end()
        }
        return block()
    }

    /// 监控 syncText 操作
    static func measureSyncText<T>(_ textLength: Int, _ block: () -> T) -> T {
        let span = perf.startSpan("BlockDocumentEditor.syncText", category: "Editor", level: .verbose)
        defer {
            span.addMetadata("length", value: textLength)
            span.end()
        }
        return block()
    }

    /// 监控编辑操作（split, merge, insert, delete 等）
    static func measureEditOperation<T>(_ operation: String, blockCount: Int, _ block: () -> T) -> T {
        let span = perf.startSpan("BlockEditor.\(operation)", category: "Editor", level: .normal)
        defer {
            span.addMetadata("blocks", value: blockCount)
            span.end()
        }
        return block()
    }

    /// 监控 BlockRowView 渲染
    ///
    /// ⚠️ 警告：不要在视图的 body 中调用此方法！
    /// 它会在每次渲染时执行，包括滚动时的高频更新。
    /// 只适合在特定事件（如 onAppear）或一次性操作中使用。
    static func measureBlockRender<T>(_ kind: DocumentBlockKind, _ block: () -> T) -> T {
        let span = perf.startSpan("BlockRowView.render", category: "Editor", level: .verbose)
        defer {
            span.addMetadata("kind", value: String(describing: kind))
            span.end()
        }
        return block()
    }

    private static func trim<T>(_ cache: inout [String: T]) {
        guard cache.count > cacheLimit else { return }
        for key in cache.keys.prefix(cache.count - cacheLimit) {
            cache.removeValue(forKey: key)
        }
    }
}

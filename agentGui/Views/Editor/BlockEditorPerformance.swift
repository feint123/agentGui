//
//  BlockEditorPerformance.swift
//  agentGui
//

import Foundation

enum BlockEditorPerformance {
    private static var parseCache: [String: BlockDocument] = [:]
    private static var tableCache: [String: [[String]]] = [:]
    private static let cacheLimit = 20

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
        let start = CFAbsoluteTimeGetCurrent()
        let result = block()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if elapsed >= thresholdMS {
            print("[MarkdownPerf] \(phase) \(String(format: "%.2f", elapsed))ms")
        }
        return result
        #else
        return block()
        #endif
    }

    static func measure(_ phase: String, thresholdMS: Double = 3, _ block: () -> Void) {
        _ = measureValue(phase, thresholdMS: thresholdMS, block)
    }

    private static func trim<T>(_ cache: inout [String: T]) {
        guard cache.count > cacheLimit else { return }
        for key in cache.keys.prefix(cache.count - cacheLimit) {
            cache.removeValue(forKey: key)
        }
    }
}

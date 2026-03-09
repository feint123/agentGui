//
//  PerformanceMonitor.swift
//  agentGui
//
//  性能监控工具 - 用于定位性能瓶颈
//

import Foundation
import OSLog

/// 性能监控工具
///
/// 使用方式：
/// ```swift
/// let span = PerformanceMonitor.startSpan("operation_name")
/// // ... 执行操作 ...
/// span.end()
/// ```
///
/// 或者使用 measure 函数：
/// ```swift
/// PerformanceMonitor.measure("operation_name") {
///     // ... 执行操作 ...
/// }
/// ```
final class PerformanceMonitor {

    private static let logger = Logger(subsystem: "com.agentgui", category: "Performance")

    /// 性能日志级别
    enum LogLevel {
        case verbose   // 所有日志
        case normal    // 重要日志（>10ms）
        case quiet     // 只记录慢操作（>100ms）
    }

    /// 当前日志级别
    static var logLevel: LogLevel = {
        #if DEBUG
        return .verbose
        #else
        return .normal
        #endif
    }()

    /// 阈值配置
    struct Thresholds {
        static var warning: TimeInterval = 0.050   // 50ms
        static var slow: TimeInterval = 0.100      // 100ms
        static var verySlow: TimeInterval = 0.500  // 500ms
    }

    // MARK: - Span API

    /// 开始一个新的性能测量 span
    static func startSpan(
        _ name: String,
        category: String = "default",
        level: LogLevel = .normal
    ) -> Span {
        Span(name: name, category: category, level: level)
    }

    /// 测量一个同步操作的执行时间
    static func measure<T>(
        _ name: String,
        category: String = "default",
        level: LogLevel = .normal,
        _ block: () throws -> T
    ) rethrows -> T {
        let span = startSpan(name, category: category, level: level)
        let result = try block()
        span.end()
        return result
    }

    /// 测量一个异步操作的执行时间
    static func measure<T>(
        _ name: String,
        category: String = "default",
        level: LogLevel = .normal,
        _ block: () async throws -> T
    ) async rethrows -> T {
        let span = startSpan(name, category: category, level: level)
        let result = try await block()
        span.end()
        return result
    }

    // MARK: - Span

    final class Span {
        private let name: String
        private let category: String
        private let level: LogLevel
        private let startTime: Date
        private var endTime: Date?
        private var metadata: [String: Any] = [:]

        private var elapsed: TimeInterval {
            endTime?.timeIntervalSince(startTime) ?? Date().timeIntervalSince(startTime)
        }

        init(name: String, category: String, level: LogLevel) {
            self.name = name
            self.category = category
            self.level = level
            self.startTime = Date()
        }

        /// 添加元数据
        func addMetadata(_ key: String, value: Any) {
            metadata[key] = value
        }

        /// 结束测量并记录日志
        func end() {
            guard endTime == nil else { return }
            endTime = Date()

            let duration = endTime!.timeIntervalSince(startTime)
            log(duration: duration)
        }

        /// 结束测量并添加额外的元数据
        func end(metadata: [String: Any]) {
            self.metadata.merge(metadata) { _, new in new }
            end()
        }

        private func log(duration: TimeInterval) {
            // 根据日志级别决定是否输出
            let shouldLog: Bool
            switch level {
            case .verbose:
                shouldLog = true
            case .normal:
                shouldLog = duration > 0.010 || duration > Thresholds.warning
            case .quiet:
                shouldLog = duration > Thresholds.slow
            }

            guard shouldLog else { return }

            // 构建日志字符串
            var parts = ["[\(category)]", name]

            // 添加持续时间
            let durationStr = formatDuration(duration)
            parts.append(durationStr)

            // 添加元数据
            if !metadata.isEmpty {
                let metadataStr = metadata.map { "\($0)=\($1)" }.joined(separator: ", ")
                parts.append("(\(metadataStr))")
            }

            let message = parts.joined(separator: " ")

            // 根据耗时选择日志级别
            if duration > Thresholds.verySlow {
                logger.error("\(message) ⚠️ VERY SLOW")
            } else if duration > Thresholds.slow {
                logger.warning("\(message) ⚠️ SLOW")
            } else if duration > Thresholds.warning {
                logger.info("\(message)")
            } else {
                logger.debug("\(message)")
            }

            // 打印到控制台（便于开发时查看）
            if PerformanceMonitor.logLevel == .verbose || duration > Thresholds.warning {
                let prefix = duration > Thresholds.slow ? "⚠️" : "📊"
                print("\(prefix) \(message)")
            }
        }

        private func formatDuration(_ duration: TimeInterval) -> String {
            if duration < 0.001 {
                return String(format: "%.0fµs", duration * 1_000_000)
            } else if duration < 1 {
                return String(format: "%.1fms", duration * 1000)
            } else {
                return String(format: "%.2fs", duration)
            }
        }
    }

    // MARK: - 特定场景的监控

    /// 监控 UI 更新性能
    static func measureUIUpdate<T>(_ name: String, _ block: () -> T) -> T {
        measure(name, category: "UI", level: .normal, block)
    }

    /// 监控 Markdown 解析性能
    static func measureMarkdownParsing<T>(_ name: String, _ block: () -> T) -> T {
        measure(name, category: "Markdown", level: .normal, block)
    }

    /// 监控 API 调用性能
    static func measureAPICall<T>(_ name: String, _ block: () async throws -> T) async throws -> T {
        try await measure(name, category: "API", level: .normal, block)
    }

    /// 监控数据库操作性能
    static func measureDatabase<T>(_ name: String, _ block: () -> T) -> T {
        measure(name, category: "Database", level: .normal, block)
    }

    /// 监控工具执行性能
    static func measureToolExecution<T>(_ name: String, _ block: () async throws -> T) async throws -> T {
        try await measure(name, category: "Tool", level: .normal, block)
    }

    // MARK: - 流式输出监控

    /// 流式输出累积统计
    static var streamStats = StreamStats()

    final class StreamStats {
        private var lastLogTime = Date()
        private var logInterval: TimeInterval = 1.0 // 每秒最多输出一次
        private var deltaCount: Int = 0
        private var totalBytes: Int = 0

        func recordDelta(_ bytes: Int, round: Int) {
            deltaCount += 1
            totalBytes += bytes

            let now = Date()
            let elapsed = now.timeIntervalSince(lastLogTime)

            if elapsed >= logInterval {
                let bytesPerSec = Double(totalBytes) / elapsed
                print("📡 Stream[round=\(round)]: \(deltaCount) deltas, \(totalBytes) bytes, \(String(format: "%.0f", bytesPerSec)) bytes/sec")
                lastLogTime = now
                deltaCount = 0
                totalBytes = 0
            }
        }

        func reset() {
            lastLogTime = Date()
            deltaCount = 0
            totalBytes = 0
        }
    }
}

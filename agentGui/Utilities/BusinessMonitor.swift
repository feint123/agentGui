import Foundation
import OSLog

enum BusinessLogLevel: String, Equatable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct BusinessLogContext: Equatable, Sendable {
    var runID: String?
    var sessionID: String?
    var workflowID: String?
    var roundIndex: Int?
    var toolName: String?
    var phase: String?

    init(
        runID: String? = nil,
        sessionID: String? = nil,
        workflowID: String? = nil,
        roundIndex: Int? = nil,
        toolName: String? = nil,
        phase: String? = nil
    ) {
        self.runID = runID
        self.sessionID = sessionID
        self.workflowID = workflowID
        self.roundIndex = roundIndex
        self.toolName = toolName
        self.phase = phase
    }

    var metadata: [String: Any] {
        var values: [String: Any] = [:]
        if let runID { values["runID"] = runID }
        if let sessionID { values["sessionID"] = sessionID }
        if let workflowID { values["workflowID"] = workflowID }
        if let roundIndex { values["roundIndex"] = roundIndex }
        if let toolName { values["toolName"] = toolName }
        if let phase { values["phase"] = phase }
        return values
    }
}

struct BusinessLogEntry: Sendable {
    let event: AgentBusinessEvent
    let category: String
    let level: BusinessLogLevel
    let metadata: [String: Any]
    let message: String
    let timestamp: Date
}

protocol BusinessLogSink: AnyObject {
    func write(_ entry: BusinessLogEntry)
}

final class InMemoryBusinessLogSink: BusinessLogSink {
    private(set) var events: [BusinessLogEntry] = []

    func write(_ entry: BusinessLogEntry) {
        events.append(entry)
    }
}

final class BusinessMonitor {
    static let category = "AgentBusiness"

    private static let logger = Logger(subsystem: "com.agentgui", category: category)
    private static let maxStringLength = 160

    static func makeEntry(
        _ event: AgentBusinessEvent,
        context: BusinessLogContext = .init(),
        metadata: [String: Any] = [:],
        timestamp: Date = Date()
    ) -> BusinessLogEntry {
        let merged = merge(context: context, metadata: metadata)
        return BusinessLogEntry(
            event: event,
            category: category,
            level: level(for: event),
            metadata: merged,
            message: makeMessage(event: event, metadata: merged),
            timestamp: timestamp
        )
    }

    static func emit(
        _ event: AgentBusinessEvent,
        context: BusinessLogContext = .init(),
        metadata: [String: Any] = [:],
        sink: BusinessLogSink? = nil
    ) {
        let entry = makeEntry(event, context: context, metadata: metadata)
        sink?.write(entry)
        writeToUnifiedLog(entry)
    }

    private static func level(for event: AgentBusinessEvent) -> BusinessLogLevel {
        switch event {
        case .loopFailed:
            return .error
        case .verificationSkipped, .workflowContractViolation:
            return .warning
        default:
            return .info
        }
    }

    private static func merge(
        context: BusinessLogContext,
        metadata: [String: Any]
    ) -> [String: Any] {
        var merged = context.metadata
        for (key, value) in metadata {
            merged[key] = sanitize(value)
        }
        return merged
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return String(string.prefix(maxStringLength))
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        default:
            return String(String(describing: value).prefix(maxStringLength))
        }
    }

    private static func makeMessage(
        event: AgentBusinessEvent,
        metadata: [String: Any]
    ) -> String {
        guard !metadata.isEmpty else { return event.rawValue }
        let details = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "\(event.rawValue) (\(details))"
    }

    private static func writeToUnifiedLog(_ entry: BusinessLogEntry) {
        switch entry.level {
        case .debug:
            logger.debug("\(entry.message)")
        case .info:
            logger.info("\(entry.message)")
        case .warning:
            logger.warning("\(entry.message)")
        case .error:
            logger.error("\(entry.message)")
        }
    }
}

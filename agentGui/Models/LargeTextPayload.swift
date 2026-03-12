import Foundation

struct LargeTextPayload: Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case file = "file"
        case bash = "bash"
        case webFetch = "web_fetch"
        case webSearch = "web_search"
        case other = "other"
    }

    let payloadID: String
    let sourceKind: SourceKind
    let sourceDescriptor: String
    let fileURL: URL
    let createdAt: Date
    let expiresAt: Date
    let rawCharCount: Int
    let lineCount: Int?
}

struct ToolPayloadReadWindow: Equatable, Sendable {
    let content: String
    let cursor: String?
    let nextCursor: String?
    let hasMore: Bool
    let chunkIndex: Int
    let chunkCount: Int
    let rangeSummary: String
}

enum ToolPayloadReadMode: String, Sendable {
    case summary
    case preview
    case chars
    case lines
    case chunk
    case head
    case tail
}

enum ToolPayloadStoreError: Error, Equatable, LocalizedError {
    case payloadNotFound(String)
    case payloadExpired(String)
    case invalidRange(String)
    case cursorInvalid(String)
    case payloadStorageFailed(String)

    var errorDescription: String? {
        switch self {
        case .payloadNotFound(let payloadID):
            return "Error: payload_not_found \(payloadID)"
        case .payloadExpired(let payloadID):
            return "Error: payload_expired \(payloadID)"
        case .invalidRange(let summary):
            return "Error: invalid_range \(summary)"
        case .cursorInvalid(let cursor):
            return "Error: cursor_invalid \(cursor)"
        case .payloadStorageFailed(let reason):
            return "Error: payload_storage_failed \(reason)"
        }
    }
}
import Foundation

final class LSPJSONRPCTransport {
    enum IncomingMessage: Equatable {
        case notification(method: String)
        case response(id: String)
    }

    enum TransportError: Error {
        case invalidHeader
        case invalidBodyEncoding
        case invalidJSONObject
        case missingOutgoingDataHandler
        case requestFailed(String)
    }

    var notificationHandler: ((String) -> Void)?
    var notificationPayloadHandler: ((String, [String: Any]?) -> Void)?
    var outgoingDataHandler: ((Data) -> Void)?

    private var bufferedData = Data()
    private var pendingRequestIDs: Set<String> = []
    private var pendingContinuations: [String: CheckedContinuation<Any?, Error>] = [:]

    func registerPendingRequest(id: String) {
        pendingRequestIDs.insert(id)
    }

    func hasPendingRequest(id: String) -> Bool {
        pendingRequestIDs.contains(id)
    }

    /// 测试辅助：返回当前第一个 pending 请求 ID（用于取消测试）。
    var firstPendingRequestID: String? {
        pendingRequestIDs.first
    }

    /// 预分配一个请求 ID，供 `sendCancellableRequest(id:method:params:)` 使用。
    func allocateRequestID() -> String {
        UUID().uuidString
    }

    /// 发送 LSP 请求（使用调用方预分配的 `id`），返回响应 result。
    /// 允许调用者在请求发出后通过 `cancelRequest(id:)` 取消。
    func sendCancellableRequest(id: String, method: String, params: [String: Any]) async throws -> Any? {
        guard let outgoingDataHandler else {
            throw TransportError.missingOutgoingDataHandler
        }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let framed = try makeOutgoingData(jsonObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
            registerPendingRequest(id: id)
            outgoingDataHandler(framed)
        }
    }

    /// 向服务器发送 `$/cancelRequest` 通知，并以 `CancellationError` 恢复对应的
    /// pending continuation（如果仍存在）。
    ///
    /// 如果指定 ID 没有 pending 请求，则静默忽略（幂等）。
    func cancelRequest(id: String) throws {
        guard pendingRequestIDs.contains(id) else { return }

        // 1. 发送 $/cancelRequest notification
        try sendNotification(method: "$/cancelRequest", params: ["id": id])

        // 2. 本地清理：移除 pending 状态，以 CancellationError 恢复 continuation
        pendingRequestIDs.remove(id)
        if let continuation = pendingContinuations.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }

    func sendRequest(method: String, params: [String: Any]) async throws -> Any? {
        guard let outgoingDataHandler else {
            throw TransportError.missingOutgoingDataHandler
        }

        let id = UUID().uuidString
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let framed = try makeOutgoingData(jsonObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
            registerPendingRequest(id: id)
            outgoingDataHandler(framed)
        }
    }

    func sendNotification(method: String, params: [String: Any]) throws {
        guard let outgoingDataHandler else {
            throw TransportError.missingOutgoingDataHandler
        }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        let framed = try makeOutgoingData(jsonObject: message)
        outgoingDataHandler(framed)
    }

    func makeOutgoingData(jsonObject: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        var framed = Data()
        let header = "Content-Length: \(body.count)\r\n\r\n"
        framed.append(Data(header.utf8))
        framed.append(body)
        return framed
    }

    func receive<S: DataProtocol>(_ data: S) throws -> [IncomingMessage] {
        bufferedData.append(contentsOf: data)
        var messages: [IncomingMessage] = []

        while let range = bufferedData.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = bufferedData.subdata(in: 0..<range.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8),
                  let lengthLine = headerText
                    .split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let contentLength = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) else {
                throw TransportError.invalidHeader
            }

            let bodyStart = range.upperBound
            let availableBodyBytes = bufferedData.count - bodyStart
            guard availableBodyBytes >= contentLength else {
                break
            }

            let bodyData = bufferedData.subdata(in: bodyStart..<(bodyStart + contentLength))
            let remaining = bufferedData.suffix(from: bodyStart + contentLength)
            bufferedData = Data(remaining)

            guard let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                throw TransportError.invalidJSONObject
            }

            if let method = object["method"] as? String {
                let params = object["params"] as? [String: Any]
                notificationHandler?(method)
                notificationPayloadHandler?(method, params)
                messages.append(.notification(method: method))
                continue
            }

            if let id = object["id"] as? String {
                pendingRequestIDs.remove(id)
                if let continuation = pendingContinuations.removeValue(forKey: id) {
                    if let errorObject = object["error"] as? [String: Any],
                       let message = errorObject["message"] as? String {
                        let code = errorObject["code"] as? Int
                        if code == -32800 {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: TransportError.requestFailed(message))
                        }
                    } else {
                        continuation.resume(returning: object["result"])
                    }
                }
                messages.append(.response(id: id))
            } else if let idNumber = object["id"] as? NSNumber {
                let id = idNumber.stringValue
                pendingRequestIDs.remove(id)
                if let continuation = pendingContinuations.removeValue(forKey: id) {
                    if let errorObject = object["error"] as? [String: Any],
                       let message = errorObject["message"] as? String {
                        let code = errorObject["code"] as? Int
                        if code == -32800 {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: TransportError.requestFailed(message))
                        }
                    } else {
                        continuation.resume(returning: object["result"])
                    }
                }
                messages.append(.response(id: id))
            }
        }

        return messages
    }
}
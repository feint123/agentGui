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
                notificationHandler?(method)
                messages.append(.notification(method: method))
                continue
            }

            if let id = object["id"] as? String {
                pendingRequestIDs.remove(id)
                if let continuation = pendingContinuations.removeValue(forKey: id) {
                    if let errorObject = object["error"] as? [String: Any],
                       let message = errorObject["message"] as? String {
                        continuation.resume(throwing: TransportError.requestFailed(message))
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
                        continuation.resume(throwing: TransportError.requestFailed(message))
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
import Foundation

nonisolated enum ACPRequestID: Codable, Equatable, Hashable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported request id")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

nonisolated struct ACPErrorObject: Codable, Equatable, Sendable {
    let code: Int
    let message: String
    let data: ACPJSONValue?
}

nonisolated struct ACPRequestMessage: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: ACPRequestID
    let method: String
    let params: ACPJSONValue?

    nonisolated
    init(id: ACPRequestID, method: String, params: ACPJSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

nonisolated struct ACPNotificationMessage: Codable, Equatable, Sendable {
    let jsonrpc: String
    let method: String
    let params: ACPJSONValue?

    nonisolated
    init(method: String, params: ACPJSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

nonisolated struct ACPResponseMessage: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: ACPRequestID
    let result: ACPJSONValue?
    let error: ACPErrorObject?

    nonisolated
    init(id: ACPRequestID, result: ACPJSONValue? = nil, error: ACPErrorObject? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

nonisolated enum ACPWireMessage: Equatable, Sendable {
    case request(ACPRequestMessage)
    case notification(ACPNotificationMessage)
    case response(ACPResponseMessage)
}

extension ACPWireMessage {
    func encodedLine(encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        let payload: Data
        switch self {
        case .request(let message):
            payload = try encoder.encode(message)
        case .notification(let message):
            payload = try encoder.encode(message)
        case .response(let message):
            payload = try encoder.encode(message)
        }

        var framed = payload
        framed.append(0x0A)
        return framed
    }

    static func decode(lineData: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ACPWireMessage {
        let trimmed: Data
        if lineData.last == 0x0A {
            trimmed = lineData.dropLast()
        } else {
            trimmed = lineData
        }

        let envelope = try decoder.decode(ACPMessageEnvelope.self, from: trimmed)
        guard envelope.jsonrpc == "2.0" else {
            throw ACPTransportError.invalidMessageShape
        }

        if let method = envelope.method {
            guard envelope.result == nil, envelope.error == nil else {
                throw ACPTransportError.invalidMessageShape
            }
            if let id = envelope.id {
                return .request(ACPRequestMessage(id: id, method: method, params: envelope.params))
            }
            return .notification(ACPNotificationMessage(method: method, params: envelope.params))
        }

        if let id = envelope.id {
            let hasResult = envelope.result != nil
            let hasError = envelope.error != nil
            guard hasResult != hasError else {
                throw ACPTransportError.invalidMessageShape
            }
            return .response(ACPResponseMessage(id: id, result: envelope.result, error: envelope.error))
        }

        throw ACPTransportError.invalidMessageShape
    }
}

private nonisolated struct ACPMessageEnvelope: Codable {
    let jsonrpc: String?
    let id: ACPRequestID?
    let method: String?
    let params: ACPJSONValue?
    let result: ACPJSONValue?
    let error: ACPErrorObject?
}
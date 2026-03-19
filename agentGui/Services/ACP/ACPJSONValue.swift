import Foundation

enum ACPJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ACPJSONValue])
    case array([ACPJSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ACPJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ACPJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension ACPJSONValue {
    nonisolated var objectValue: [String: ACPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    nonisolated var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    nonisolated static func fromEncodable<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> ACPJSONValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(ACPJSONValue.self, from: data)
    }

    nonisolated func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(type, from: data)
    }
}
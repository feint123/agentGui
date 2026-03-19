import Foundation

struct ACPRequestError: Error, Equatable, Sendable {
    let code: Int
    let message: String
    let data: ACPJSONValue?

    init(code: Int, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    init(_ errorObject: ACPErrorObject) {
        self.init(code: errorObject.code, message: errorObject.message, data: errorObject.data)
    }

    static func parseError(data: ACPJSONValue? = nil) -> ACPRequestError {
        ACPRequestError(code: -32700, message: "Parse error", data: data)
    }

    static func invalidRequest(data: ACPJSONValue? = nil) -> ACPRequestError {
        ACPRequestError(code: -32600, message: "Invalid request", data: data)
    }

    static func methodNotFound(_ method: String) -> ACPRequestError {
        ACPRequestError(code: -32601, message: "Method not found", data: .object(["method": .string(method)]))
    }

    static func invalidParams(data: ACPJSONValue? = nil) -> ACPRequestError {
        ACPRequestError(code: -32602, message: "Invalid params", data: data)
    }

    static func internalError(data: ACPJSONValue? = nil) -> ACPRequestError {
        ACPRequestError(code: -32603, message: "Internal error", data: data)
    }

    static func authRequired(data: ACPJSONValue? = nil) -> ACPRequestError {
        ACPRequestError(code: -32000, message: "Authentication required", data: data)
    }

    static func resourceNotFound(uri: String? = nil) -> ACPRequestError {
        if let uri {
            return ACPRequestError(code: -32002, message: "Resource not found", data: .object(["uri": .string(uri)]))
        }
        return ACPRequestError(code: -32002, message: "Resource not found", data: nil)
    }

    func asErrorObject() -> ACPErrorObject {
        ACPErrorObject(code: code, message: message, data: data)
    }
}

extension ACPRequestError: LocalizedError {
    var errorDescription: String? {
        message
    }
}
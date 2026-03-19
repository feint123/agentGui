import Foundation

final class ACPMessageRouter {
    typealias RequestHandler = (ACPJSONValue?) async throws -> ACPJSONValue?
    typealias NotificationHandler = (ACPJSONValue?) async throws -> Void
    typealias ExtensionRequestHandler = (String, [String: ACPJSONValue]) async throws -> ACPJSONValue?
    typealias ExtensionNotificationHandler = (String, [String: ACPJSONValue]) async throws -> Void

    private var requestHandlers: [String: RequestHandler] = [:]
    private var notificationHandlers: [String: NotificationHandler] = [:]

    var extensionRequestHandler: ExtensionRequestHandler?
    var extensionNotificationHandler: ExtensionNotificationHandler?

    func onRequest(_ method: String, handler: @escaping RequestHandler) {
        requestHandlers[method] = handler
    }

    func onNotification(_ method: String, handler: @escaping NotificationHandler) {
        notificationHandlers[method] = handler
    }

    func handle(method: String, params: ACPJSONValue?, isNotification: Bool) async throws -> ACPJSONValue? {
        if method.hasPrefix("_") {
            let payload = params?.objectValue ?? [:]
            if isNotification {
                try await extensionNotificationHandler?(String(method.dropFirst()), payload)
                return nil
            }
            guard let extensionRequestHandler else {
                throw ACPRequestError.methodNotFound(method)
            }
            return try await extensionRequestHandler(String(method.dropFirst()), payload)
        }

        if isNotification {
            guard let handler = notificationHandlers[method] else {
                throw ACPRequestError.methodNotFound(method)
            }
            try await handler(params)
            return nil
        }

        guard let handler = requestHandlers[method] else {
            throw ACPRequestError.methodNotFound(method)
        }
        return try await handler(params)
    }
}
import Foundation

nonisolated protocol ACPClientHandler: AnyObject {
    func handleSessionUpdate(_ notification: ACPSessionNotification) async
    func handleRequestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse?
    func handleReadTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse?
    func handleWriteTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse?
    func handleCreateTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse?
    func handleTerminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse?
    func handleWaitForTerminalExit(_ request: ACPWaitForTerminalExitRequest) async throws -> ACPWaitForTerminalExitResponse?
    func handleKillTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse?
    func handleReleaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse?
    func handleExtensionRequest(name: String, params: [String: ACPJSONValue]) async throws -> ACPJSONValue?
    func handleExtensionNotification(name: String, params: [String: ACPJSONValue]) async
}

extension ACPClientHandler {
    func handleSessionUpdate(_ notification: ACPSessionNotification) async {}
    func handleRequestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse? { nil }
    func handleReadTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse? { nil }
    func handleWriteTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse? { nil }
    func handleCreateTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse? { nil }
    func handleTerminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse? { nil }
    func handleWaitForTerminalExit(_ request: ACPWaitForTerminalExitRequest) async throws -> ACPWaitForTerminalExitResponse? { nil }
    func handleKillTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse? { nil }
    func handleReleaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse? { nil }
    func handleExtensionRequest(name: String, params: [String: ACPJSONValue]) async throws -> ACPJSONValue? { nil }
    func handleExtensionNotification(name: String, params: [String: ACPJSONValue]) async {}
}

extension ACPMessageRouter {
    static func clientRouter(handler: any ACPClientHandler) -> ACPMessageRouter {
        let router = ACPMessageRouter()
        router.onNotification(ACPMethodCatalog.Client.sessionUpdate) { params in
            let notification = try ACPMessageRouter.decodeRequired(params, as: ACPSessionNotification.self)
            await handler.handleSessionUpdate(notification)
        }
        router.onRequest(ACPMethodCatalog.Client.sessionRequestPermission) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPRequestPermissionRequest.self)
            let response = try await handler.handleRequestPermission(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.filesystemReadTextFile) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPReadTextFileRequest.self)
            let response = try await handler.handleReadTextFile(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.filesystemWriteTextFile) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPWriteTextFileRequest.self)
            let response = try await handler.handleWriteTextFile(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.terminalCreate) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPCreateTerminalRequest.self)
            let response = try await handler.handleCreateTerminal(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.terminalOutput) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPTerminalOutputRequest.self)
            let response = try await handler.handleTerminalOutput(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.terminalWaitForExit) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPWaitForTerminalExitRequest.self)
            let response = try await handler.handleWaitForTerminalExit(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.terminalKill) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPKillTerminalRequest.self)
            let response = try await handler.handleKillTerminal(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.onRequest(ACPMethodCatalog.Client.terminalRelease) { params in
            let request = try ACPMessageRouter.decodeRequired(params, as: ACPReleaseTerminalRequest.self)
            let response = try await handler.handleReleaseTerminal(request)
            return try ACPMessageRouter.encodeOptional(response)
        }
        router.extensionRequestHandler = { name, params in
            try await handler.handleExtensionRequest(name: name, params: params)
        }
        router.extensionNotificationHandler = { name, params in
            try await handler.handleExtensionNotification(name: name, params: params)
        }
        return router
    }

    private static func decodeRequired<T: Decodable>(_ params: ACPJSONValue?, as type: T.Type) throws -> T {
        guard let params else {
            throw ACPRequestError.invalidParams(data: .object(["reason": .string("Missing params")]))
        }

        do {
            return try params.decode(T.self)
        } catch {
            throw ACPRequestError.invalidParams(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }

    private static func encodeOptional<T: Encodable>(_ value: T?) throws -> ACPJSONValue? {
        guard let value else { return nil }
        return try ACPJSONValue.fromEncodable(value)
    }
}
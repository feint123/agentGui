import Foundation

actor ACPClientRuntime {
    enum State: Equatable {
        case idle
        case connected
        case closed
    }

    private let connection: ACPConnection
    private(set) var state: State = .idle

    init(connection: ACPConnection) {
        self.connection = connection
    }

    func connect() async {
        guard state == .idle else { return }
        await connection.start()
        state = .connected
    }

    func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.initialize,
            params: request,
            responseType: ACPInitializeResponse.self
        )
    }

    func newSession(_ request: ACPNewSessionRequest) async throws -> ACPNewSessionResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionNew,
            params: request,
            responseType: ACPNewSessionResponse.self
        )
    }

    func loadSession(_ request: ACPLoadSessionRequest) async throws -> ACPLoadSessionResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionLoad,
            params: request,
            responseType: ACPLoadSessionResponse.self
        )
    }

    func listSessions(_ request: ACPListSessionsRequest = ACPListSessionsRequest()) async throws -> ACPListSessionsResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionList,
            params: request,
            responseType: ACPListSessionsResponse.self
        )
    }

    func prompt(_ request: ACPPromptRequest) async throws -> ACPPromptResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionPrompt,
            params: request,
            responseType: ACPPromptResponse.self
        )
    }

    func setSessionMode(_ request: ACPSetSessionModeRequest) async throws -> ACPSetSessionModeResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionSetMode,
            params: request,
            responseType: ACPSetSessionModeResponse.self
        )
    }

    func setSessionConfigOption(_ request: ACPSetSessionConfigOptionRequest) async throws -> ACPSetSessionConfigOptionResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.sessionSetConfigOption,
            params: request,
            responseType: ACPSetSessionConfigOptionResponse.self
        )
    }

    func authenticate(_ request: ACPAuthenticateRequest) async throws -> ACPAuthenticateResponse {
        await connect()
        return try await performRequest(
            method: ACPMethodCatalog.Agent.authenticate,
            params: request,
            responseType: ACPAuthenticateResponse.self
        )
    }

    func cancel(_ notification: ACPCancelNotification) async throws {
        await connect()
        let params = try ACPJSONValue.fromEncodable(notification)
        try await connection.sendNotification(method: ACPMethodCatalog.Agent.sessionCancel, params: params)
    }

    func sendExtensionRequest(name: String, params: [String: ACPJSONValue]) async throws -> ACPJSONValue? {
        await connect()
        return try await connection.sendRequest(method: "_\(name)", params: .object(params))
    }

    func sendExtensionNotification(name: String, params: [String: ACPJSONValue]) async throws {
        await connect()
        try await connection.sendNotification(method: "_\(name)", params: .object(params))
    }

    func close() async {
        guard state != .closed else { return }
        state = .closed
        await connection.close()
    }

    private func performRequest<Request: Encodable, Response: Decodable>(
        method: String,
        params: Request,
        responseType: Response.Type
    ) async throws -> Response {
        let encodedParams = try ACPJSONValue.fromEncodable(params)
        let response = try await connection.sendRequest(method: method, params: encodedParams)

        guard let response else {
            throw ACPRequestError.internalError(data: .object(["reason": .string("Missing response payload")]))
        }

        do {
            return try response.decode(Response.self)
        } catch {
            throw ACPRequestError.invalidParams(data: .object(["reason": .string(error.localizedDescription)]))
        }
    }
}
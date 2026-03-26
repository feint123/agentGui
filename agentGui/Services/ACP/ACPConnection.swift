import Foundation

actor ACPConnection {
    typealias StreamObserver = @Sendable (ACPStreamEvent) async -> Void
    typealias ErrorObserver = @Sendable (Error) async -> Void

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<ACPJSONValue?, Error>
    }

    private let transport: ACPTransport
    private let router: ACPMessageRouter
    private var nextRequestID = 0
    private var pendingRequests: [ACPRequestID: PendingRequest] = [:]
    private var receiveTask: Task<Void, Never>?
    private var observers: [StreamObserver] = []
    private var errorObservers: [ErrorObserver] = []
    private var isClosed = false

    init(
        transport: ACPTransport,
        router: ACPMessageRouter = ACPMessageRouter(),
        observers: [StreamObserver] = [],
        errorObservers: [ErrorObserver] = []
    ) {
        self.transport = transport
        self.router = router
        self.observers = observers
        self.errorObservers = errorObservers
    }

    deinit {
        receiveTask?.cancel()
    }

    func start() {
        guard receiveTask == nil, !isClosed else { return }
        let stream = transport.messages()
        receiveTask = Task {
            do {
                for try await message in stream {
                    await self.dispatchObservers(direction: .incoming, message: message)
                    await self.process(message)
                }
                await self.failAllPending(with: ACPTransportError.closed)
            } catch {
                await self.dispatchErrorObservers(error)
                await self.failAllPending(with: error)
            }
        }
    }

    func addObserver(_ observer: @escaping StreamObserver) {
        observers.append(observer)
    }

    func addErrorObserver(_ observer: @escaping ErrorObserver) {
        errorObservers.append(observer)
    }

    func sendRequest(method: String, params: ACPJSONValue? = nil) async throws -> ACPJSONValue? {
        guard !isClosed else { throw ACPTransportError.closed }
        start()

        let requestID = ACPRequestID.int(nextRequestID)
        nextRequestID += 1
        let message = ACPWireMessage.request(ACPRequestMessage(id: requestID, method: method, params: params))

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = PendingRequest(method: method, continuation: continuation)

            Task {
                do {
                    try await self.transport.send(message)
                    await self.dispatchObservers(direction: .outgoing, message: message)
                } catch {
                    await self.failPending(requestID: requestID, error: error)
                }
            }
        }
    }

    func sendNotification(method: String, params: ACPJSONValue? = nil) async throws {
        guard !isClosed else { throw ACPTransportError.closed }
        start()
        let message = ACPWireMessage.notification(ACPNotificationMessage(method: method, params: params))
        try await transport.send(message)
        await dispatchObservers(direction: .outgoing, message: message)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        await failAllPending(with: ACPTransportError.closed)
    }

    private func process(_ message: ACPWireMessage) async {
        switch message {
        case .response(let response):
            handleResponse(response)
        case .notification(let notification):
            let router = self.router
            Task.detached {
                do {
                    _ = try await router.handle(method: notification.method, params: notification.params, isNotification: true)
                } catch {
                    await self.dispatchErrorObservers(error)
                }
            }
        case .request(let request):
            Task.detached {
                await self.handleIncomingRequest(request)
            }
        }
    }

    private func handleResponse(_ response: ACPResponseMessage) {
        guard let pending = pendingRequests.removeValue(forKey: response.id) else { return }
        if let error = response.error {
            pending.continuation.resume(throwing: ACPRequestError(error))
        } else {
            pending.continuation.resume(returning: response.result)
        }
    }

    private func handleIncomingRequest(_ request: ACPRequestMessage) async {
        let response: ACPResponseMessage
        do {
            let result = try await router.handle(method: request.method, params: request.params, isNotification: false)
            response = ACPResponseMessage(id: request.id, result: result)
        } catch let error as ACPRequestError {
            response = ACPResponseMessage(id: request.id, error: error.asErrorObject())
        } catch {
            response = ACPResponseMessage(
                id: request.id,
                error: ACPRequestError.internalError(data: .object(["details": .string(error.localizedDescription)])).asErrorObject()
            )
        }

        let wireMessage = ACPWireMessage.response(response)
        do {
            try await transport.send(wireMessage)
            await dispatchObservers(direction: .outgoing, message: wireMessage)
        } catch {
            await dispatchErrorObservers(error)
            await close()
        }
    }

    private func failPending(requestID: ACPRequestID, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for entry in pending {
            entry.continuation.resume(throwing: error)
        }
    }

    private func dispatchObservers(direction: ACPStreamEvent.Direction, message: ACPWireMessage) {
        guard !observers.isEmpty else { return }
        let event = ACPStreamEvent(direction: direction, message: message)
        let currentObservers = observers
        Task.detached {
            for observer in currentObservers {
                await observer(event)
            }
        }
    }

    private func dispatchErrorObservers(_ error: Error) {
        guard !errorObservers.isEmpty else { return }
        let currentErrorObservers = errorObservers
        Task.detached {
            for observer in currentErrorObservers {
                await observer(error)
            }
        }
    }
}
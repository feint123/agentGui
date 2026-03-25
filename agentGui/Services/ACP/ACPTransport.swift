import Foundation

enum ACPTransportError: Error, Equatable {
    case invalidMessageShape
    case closed
}

struct ACPStreamEvent: Sendable {
    enum Direction: String, Sendable {
        case incoming
        case outgoing
    }

    let direction: Direction
    let message: ACPWireMessage
}

actor ACPLineWriter {
    private let handle: FileHandle
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard !isClosed else { throw ACPTransportError.closed }
        try handle.write(contentsOf: data)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}

final class ACPTransport {
    private let reader: FileHandle
    private let writer: ACPLineWriter
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var receiveTask: Task<Void, Never>?
    private let stream: AsyncThrowingStream<ACPWireMessage, Error>
    private let continuation: AsyncThrowingStream<ACPWireMessage, Error>.Continuation

    init(
        reader: FileHandle,
        writer: FileHandle,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.reader = reader
        self.writer = ACPLineWriter(handle: writer)
        self.decoder = decoder
        self.encoder = encoder
        var capturedContinuation: AsyncThrowingStream<ACPWireMessage, Error>.Continuation?
        self.stream = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
        self.receiveTask = Task { [reader, continuation, decoder] in
            do {
                var buffer = Data()

                for try await byte in reader.bytes {
                    buffer.append(byte)
                    if byte == 0x0A {
                        try Self.yieldBufferedMessages(from: &buffer, atEOF: false, decoder: decoder, continuation: continuation)
                    }
                }

                try Self.yieldBufferedMessages(from: &buffer, atEOF: true, decoder: decoder, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func messages() -> AsyncThrowingStream<ACPWireMessage, Error> {
        stream
    }

    func send(_ message: ACPWireMessage) async throws {
        let line = try message.encodedLine(encoder: encoder)
        try await writer.write(line)
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        continuation.finish()
        await writer.close()
        try? reader.close()
    }

    private static func yieldBufferedMessages(
        from buffer: inout Data,
        atEOF: Bool,
        decoder: JSONDecoder,
        continuation: AsyncThrowingStream<ACPWireMessage, Error>.Continuation
    ) throws {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)

            let normalized = normalizeFrame(frame)
            guard !normalized.isEmpty else { continue }

            let message = try ACPWireMessage.decode(lineData: normalized, decoder: decoder)
            continuation.yield(message)
        }

        guard atEOF else { return }

        let trailing = normalizeFrame(buffer)
        buffer.removeAll(keepingCapacity: false)
        guard !trailing.isEmpty else { return }

        let message = try ACPWireMessage.decode(lineData: trailing, decoder: decoder)
        continuation.yield(message)
    }

    private static func normalizeFrame(_ frame: Data) -> Data {
        if frame.last == 0x0D {
            return frame.dropLast()
        }
        return frame
    }
}
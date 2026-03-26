import Foundation
import Testing
@testable import agentGui

struct SpeechCaptureSessionTests {
    @Test
    func unavailableLocaleThrowsHelpfulError() async throws {
        let session = SpeechCaptureSession(
            transcriberFactory: .alwaysUnsupported,
            microphoneAuthorizer: .authorized,
            audioEngineFactory: .noop
        )

        await #expect(throws: SpeechCaptureSession.Error.unsupportedLocale) {
            _ = try await session.start(locale: Locale(identifier: "zz-ZZ"))
        }
    }

    @Test
    func startPublishesPartialAndFinalEventsFromStream() async throws {
        let session = SpeechCaptureSession.fixtureStreaming([
            .partial("alpha"),
            .final("alpha beta")
        ])

        let stream = try await session.start(locale: Locale(identifier: "zh-CN"))
        var received: [SpeechCaptureSession.Event.Kind] = []

        for try await event in stream {
            received.append(event.kind)
        }

        #expect(received == [.partial("alpha"), .final("alpha beta")])
    }

    @Test
    func stopFinalizesWithoutCancellingActiveStream() async throws {
        let harness = SpeechCaptureSessionHarness()
        let session = harness.makeSession()

        _ = try await session.start(locale: Locale(identifier: "zh-CN"))
        try await session.stop()

        #expect(await harness.didFinalize)
        #expect(await harness.didCancel == false)
    }
}

actor SpeechCaptureSessionHarness {
    private(set) var didFinalize = false
    private(set) var didCancel = false

    func makeSession() -> SpeechCaptureSession {
        SpeechCaptureSession(
            transcriberFactory: .init { _ in
                SpeechCaptureSession.RunningSession(
                    stream: AsyncThrowingStream { continuation in
                        continuation.yield(.init(kind: .partial("alpha")))
                    },
                    stop: { [weak self] in
                        await self?.markFinalize()
                    },
                    cancel: { [weak self] in
                        await self?.markCancel()
                    }
                )
            },
            microphoneAuthorizer: .authorized,
            audioEngineFactory: .noop
        )
    }

    private func markFinalize() {
        didFinalize = true
    }

    private func markCancel() {
        didCancel = true
    }
}
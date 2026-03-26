import Foundation
import Testing
@testable import agentGui

@MainActor
struct VoiceInputControllerTests {
    @Test
    func partialTranscriptAppendsToEmptyComposer() async throws {
        let controller = VoiceInputController()

        controller.beginSessionForTesting(currentText: "")
        controller.consumeEvent(.partial("hello world"))

        #expect(controller.displayedText == "hello world")
        #expect(controller.liveTranscript == "hello world")
        #expect(controller.phase == .recording)
    }

    @Test
    func partialTranscriptUsesNewlineSeparatorForNonEmptyComposer() async throws {
        let controller = VoiceInputController()

        controller.beginSessionForTesting(currentText: "已有文本")
        controller.consumeEvent(.partial("继续口述"))

        #expect(controller.displayedText == "已有文本\n继续口述")
    }

    @Test
    func finalTranscriptCommitsIntoDisplayedText() async throws {
        let controller = VoiceInputController()

        controller.beginSessionForTesting(currentText: "")
        controller.consumeEvent(.partial("第一段"))
        controller.consumeEvent(.final("第一段 完成"))

        #expect(controller.displayedText == "第一段 完成")
        #expect(controller.liveTranscript == "第一段 完成")
        #expect(controller.phase == .idle)
    }

    @Test
    func editingBaseTextDuringRecordingStopsSessionAndKeepsVisibleText() async throws {
        let controller = VoiceInputController()

        controller.beginSessionForTesting(currentText: "原始")
        controller.consumeEvent(.partial("语音"))
        await controller.handleManualTextMutation("手动改写原始")

        #expect(controller.phase == .idle)
        #expect(controller.displayedText == "手动改写原始\n语音")
    }

    @Test
    func startRecordingTransitionsThroughPreparingIntoRecording() async throws {
        let session = FakeSpeechCaptureSession(events: [.partial("开始")])
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")
        await Task.yield()

        #expect(controller.phase == .recording)
        #expect(controller.displayedText == "开始")
    }

    @Test
    func permissionFailurePublishesFailedPhase() async throws {
        let session = FakeSpeechCaptureSession(startError: .microphonePermissionDenied)
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")

        #expect(controller.phase == .failed("需要麦克风权限"))
    }

    @Test
    func stopRecordingFinalizesAndReturnsToIdle() async throws {
        let session = FakeSpeechCaptureSession(events: [.partial("甲"), .final("甲乙")])
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")
        await Task.yield()
        await controller.stopRecording()
        await Task.yield()

        #expect(controller.phase == .idle)
        #expect(controller.displayedText == "甲乙")
    }
}

actor FakeSpeechCaptureSession: SpeechCaptureSessionProtocol {
    private let events: [SpeechCaptureSession.Event.Kind]
    private let startError: SpeechCaptureSession.Error?

    init(
        events: [SpeechCaptureSession.Event.Kind] = [],
        startError: SpeechCaptureSession.Error? = nil
    ) {
        self.events = events
        self.startError = startError
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error> {
        _ = locale

        if let startError {
            throw startError
        }

        return AsyncThrowingStream { continuation in
            for kind in events {
                continuation.yield(.init(kind: kind))
            }
            continuation.finish()
        }
    }

    func stop() async throws {}

    func cancel() async {}
}
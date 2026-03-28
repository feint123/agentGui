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
        let session = FakeSpeechCaptureSession(events: [.preparing, .ready, .partial("开始")])
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")
        for _ in 0..<20 {
            if controller.phase == .recording, controller.displayedText == "开始" {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .recording)
        #expect(controller.displayedText == "开始")
    }

    @Test
    func startRecordingBecomesActiveAfterCaptureSessionSignalsReady() async throws {
        let session = FakeSpeechCaptureSession(
            events: [.preparing, .ready],
            finishesAfterEvents: false
        )
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "已有文本")
        for _ in 0..<10 {
            if controller.phase == .recording {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .recording)
        #expect(controller.displayedText == "已有文本")

        await controller.cancelRecording()
    }

    @Test
    func startRecordingLeavesPermissionPhaseWhenSessionStartsWithoutImmediateEvents() async throws {
        let session = FakeSpeechCaptureSession(finishesAfterEvents: false)
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "已有文本")

        #expect(controller.phase == .preparing)
        #expect(controller.displayedText == "已有文本")

        await controller.cancelRecording()
    }

    @Test
    func startRecordingStaysRequestingPermissionUntilSessionStartReturns() async throws {
        let session = FakeSpeechCaptureSession(
            startDelayInNanoseconds: 80_000_000,
            finishesAfterEvents: false
        )
        let controller = VoiceInputController(captureSession: session)

        let task = Task {
            await controller.startRecording(currentText: "")
        }

        for _ in 0..<10 {
            if controller.phase == .requestingPermission {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .requestingPermission)

        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.phase == .preparing)

        task.cancel()
        await controller.cancelRecording()
    }

    @Test
    func cancellingDuringPermissionRequestPreventsLateSessionActivation() async throws {
        let session = FakeSpeechCaptureSession(
            events: [.ready],
            startDelayInNanoseconds: 80_000_000,
            finishesAfterEvents: false
        )
        let controller = VoiceInputController(captureSession: session)

        let task = Task {
            await controller.startRecording(currentText: "")
        }

        for _ in 0..<10 {
            if controller.phase == .requestingPermission {
                break
            }
            await Task.yield()
        }

        await controller.cancelRecording()
        try? await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.phase == .idle)

        task.cancel()
    }

    @Test
    func permissionFailurePublishesFailedPhase() async throws {
        let session = FakeSpeechCaptureSession(startError: .microphonePermissionDenied)
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")

        #expect(controller.phase == .failed("需要麦克风权限"))
    }

    @Test
    func assetInstallationProgressPublishesInstallingPhase() async throws {
        let session = FakeSpeechCaptureSession(events: [
            .installingModel(progress: 0.42, message: "正在下载语音模型"),
            .partial("开始")
        ], interEventDelayInNanoseconds: 20_000_000)
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")
        for _ in 0..<50 {
            if controller.phase == .installingModel(progress: 0.42, message: "正在下载语音模型") {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .installingModel(progress: 0.42, message: "正在下载语音模型"))
        #expect(controller.displayedText.isEmpty)
    }

    @Test
    func installingOnlyStreamReturnsToIdleWhenFinished() async throws {
        let session = FakeSpeechCaptureSession(events: [
            .installingModel(progress: 0.42, message: "正在下载语音模型")
        ])
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "原始文本")

        for _ in 0..<10 {
            if controller.phase == .idle {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .idle)
        #expect(controller.displayedText == "原始文本")
    }

    @Test
    func stopRecordingFinalizesAndReturnsToIdle() async throws {
        let session = FakeSpeechCaptureSession(events: [.preparing, .ready, .partial("甲"), .final("甲乙")])
        let controller = VoiceInputController(captureSession: session)

        await controller.startRecording(currentText: "")
        for _ in 0..<20 {
            if controller.displayedText == "甲" {
                break
            }
            await Task.yield()
        }
        await controller.stopRecording()
        for _ in 0..<20 {
            if controller.phase == .idle, controller.displayedText == "甲乙" {
                break
            }
            await Task.yield()
        }

        #expect(controller.phase == .idle)
        #expect(controller.displayedText == "甲乙")
    }
}

actor FakeSpeechCaptureSession: SpeechCaptureSessionProtocol {
    private let events: [SpeechCaptureSession.Event.Kind]
    private let startError: SpeechCaptureSession.Error?
    private let interEventDelayInNanoseconds: UInt64
    private let startDelayInNanoseconds: UInt64
    private let finishesAfterEvents: Bool

    init(
        events: [SpeechCaptureSession.Event.Kind] = [],
        startError: SpeechCaptureSession.Error? = nil,
        interEventDelayInNanoseconds: UInt64 = 0,
        startDelayInNanoseconds: UInt64 = 0,
        finishesAfterEvents: Bool = true
    ) {
        self.events = events
        self.startError = startError
        self.interEventDelayInNanoseconds = interEventDelayInNanoseconds
        self.startDelayInNanoseconds = startDelayInNanoseconds
        self.finishesAfterEvents = finishesAfterEvents
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error> {
        _ = locale

        if startDelayInNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayInNanoseconds)
        }

        if let startError {
            throw startError
        }

        return AsyncThrowingStream { continuation in
            Task {
                for kind in events {
                    continuation.yield(.init(kind: kind))
                    if interEventDelayInNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: interEventDelayInNanoseconds)
                    }
                    await Task.yield()
                }
                if finishesAfterEvents {
                    continuation.finish()
                }
            }
        }
    }

    func stop() async throws {}

    func cancel() async {}
}
import Foundation
import Observation

@MainActor
@Observable
final class VoiceInputController {
    var phase: VoiceInputPhase = .idle
    var liveTranscript: String = ""
    var displayedText: String = ""
    var startedAt: Date?

    private let captureSession: any SpeechCaptureSessionProtocol
    private var baseInputText: String = ""
    private var listeningTask: Task<Void, Never>?

    init() {
        self.captureSession = SpeechCaptureSession()
    }

    init(captureSession: any SpeechCaptureSessionProtocol) {
        self.captureSession = captureSession
    }

    func beginSessionForTesting(currentText: String) {
        baseInputText = currentText
        displayedText = currentText
        liveTranscript = ""
        startedAt = Date()
        phase = .recording
    }

    func consumeEvent(_ event: VoiceInputTestEvent) {
        switch event {
        case let .partial(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
            phase = .recording
        case let .final(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
            phase = .idle
        }
    }

    func handleManualTextMutation(_ text: String) async {
        listeningTask?.cancel()
        listeningTask = nil
        await captureSession.cancel()
        baseInputText = text
        displayedText = Self.merge(base: text, transcript: liveTranscript)
        phase = .idle
    }

    func startRecording(currentText: String) async {
        guard phase == .idle else { return }
        baseInputText = currentText
        displayedText = currentText
        liveTranscript = ""
        startedAt = Date()
        phase = .preparing

        do {
            let stream = try await captureSession.start(locale: .current)
            phase = .recording
            listeningTask?.cancel()
            listeningTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in stream {
                        await self.consume(event)
                    }
                } catch {
                    await self.handleCaptureFailure(error)
                }
            }
        } catch {
            await handleCaptureFailure(error)
        }
    }

    func stopRecording() async {
        guard phase == .recording || phase == .preparing else { return }
        phase = .finalizing

        do {
            try await captureSession.stop()
        } catch {
            await handleCaptureFailure(error)
        }
    }

    func cancelRecording() async {
        listeningTask?.cancel()
        listeningTask = nil
        await captureSession.cancel()
        liveTranscript = ""
        displayedText = baseInputText
        phase = .idle
    }

    private func consume(_ event: SpeechCaptureSession.Event) async {
        switch event.kind {
        case let .partial(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
            phase = .recording
        case let .final(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
            phase = .idle
            listeningTask = nil
        case let .unavailable(message):
            phase = .failed(message)
            listeningTask = nil
        }
    }

    private func handleCaptureFailure(_ error: Swift.Error) async {
        listeningTask = nil

        if let speechError = error as? SpeechCaptureSession.Error {
            switch speechError {
            case .unsupportedLocale:
                phase = .failed("当前语言暂不支持语音输入")
            case .microphonePermissionDenied:
                phase = .failed("需要麦克风权限")
            case let .initializationFailed(message):
                phase = .failed(message)
            }
            return
        }

        phase = .failed("语音输入启动失败")
    }

    static func merge(base: String, transcript: String) -> String {
        guard transcript.isEmpty == false else { return base }
        guard base.isEmpty == false else { return transcript }
        return base + "\n" + transcript
    }
}

enum VoiceInputTestEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}
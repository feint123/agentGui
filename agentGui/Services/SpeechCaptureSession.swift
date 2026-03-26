import Foundation
import AVFAudio
import AVFoundation
import CoreMedia
import Speech

protocol SpeechCaptureSessionProtocol: Sendable {
    func start(locale: Locale) async throws -> AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>
    func stop() async throws
    func cancel() async
}

actor SpeechCaptureSession: SpeechCaptureSessionProtocol {
    struct Event: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case partial(String)
            case final(String)
            case unavailable(String)
        }

        let kind: Kind
    }

    enum Error: Swift.Error, Equatable {
        case unsupportedLocale
        case microphonePermissionDenied
        case initializationFailed(String)
    }

    struct RunningSession: Sendable {
        let stream: AsyncThrowingStream<Event, Swift.Error>
        let stop: @Sendable () async throws -> Void
        let cancel: @Sendable () async -> Void
    }

    struct TranscriberFactory: Sendable {
        let startSession: @Sendable (Locale) async throws -> RunningSession

        static let alwaysUnsupported = TranscriberFactory { _ in
            throw Error.unsupportedLocale
        }

        static let live = TranscriberFactory { locale in
            let runtime = try await LiveSpeechCaptureRuntime(locale: locale)
            return await runtime.makeRunningSession()
        }
    }

    struct MicrophoneAuthorizer: Sendable {
        let requestAccess: @Sendable () async -> Bool

        static let live = MicrophoneAuthorizer {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        }

        static let authorized = MicrophoneAuthorizer {
            true
        }

        static let denied = MicrophoneAuthorizer {
            false
        }
    }

    struct AudioEngineFactory: Sendable {
        let finalize: @Sendable () async -> Void
        let cancel: @Sendable () async -> Void

        static let noop = AudioEngineFactory(
            finalize: {},
            cancel: {}
        )
    }

    private let transcriberFactory: TranscriberFactory
    private let microphoneAuthorizer: MicrophoneAuthorizer
    private let audioEngineFactory: AudioEngineFactory

    private var activeSession: RunningSession?

    init(
        transcriberFactory: TranscriberFactory = .live,
        microphoneAuthorizer: MicrophoneAuthorizer = .live,
        audioEngineFactory: AudioEngineFactory = .noop
    ) {
        self.transcriberFactory = transcriberFactory
        self.microphoneAuthorizer = microphoneAuthorizer
        self.audioEngineFactory = audioEngineFactory
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<Event, Swift.Error> {
        guard await microphoneAuthorizer.requestAccess() else {
            throw Error.microphonePermissionDenied
        }

        let runningSession = try await transcriberFactory.startSession(locale)
        activeSession = runningSession
        return runningSession.stream
    }

    func stop() async throws {
        guard let activeSession else { return }
        try await activeSession.stop()
        await audioEngineFactory.finalize()
        self.activeSession = nil
    }

    func cancel() async {
        if let activeSession {
            await activeSession.cancel()
        }
        await audioEngineFactory.cancel()
        activeSession = nil
    }
}

extension SpeechCaptureSession {
    static func fixtureStreaming(_ events: [Event.Kind]) -> SpeechCaptureSession {
        SpeechCaptureSession(
            transcriberFactory: .init { _ in
                RunningSession(
                    stream: AsyncThrowingStream { continuation in
                        for kind in events {
                            continuation.yield(Event(kind: kind))
                        }
                        continuation.finish()
                    },
                    stop: {},
                    cancel: {}
                )
            },
            microphoneAuthorizer: .authorized,
            audioEngineFactory: .noop
        )
    }
}

private actor LiveSpeechCaptureRuntime {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let engine: AVAudioEngine
    private let analysisInputStream: AsyncThrowingStream<AnalyzerInput, Swift.Error>
    private let analysisInputContinuation: AsyncThrowingStream<AnalyzerInput, Swift.Error>.Continuation
    private let eventStream: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>
    private let eventContinuation: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>.Continuation

    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var latestTranscript = ""
    private var hasFinished = false

    init(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechCaptureSession.Error.initializationFailed("当前设备暂不支持语音输入")
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechCaptureSession.Error.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        switch assetStatus {
        case .unsupported:
            throw SpeechCaptureSession.Error.unsupportedLocale
        case .supported, .downloading:
            throw SpeechCaptureSession.Error.initializationFailed("语音模型尚未安装完成")
        case .installed:
            break
        @unknown default:
            throw SpeechCaptureSession.Error.initializationFailed("语音模型状态未知")
        }

        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.engine = AVAudioEngine()

        let analysisParts = AsyncThrowingStream.makeStream(of: AnalyzerInput.self)
        self.analysisInputStream = analysisParts.stream
        self.analysisInputContinuation = analysisParts.continuation

        let eventParts = AsyncThrowingStream.makeStream(of: SpeechCaptureSession.Event.self)
        self.eventStream = eventParts.stream
        self.eventContinuation = eventParts.continuation

        try await prepareAndStartEngine()
        startAnalyzerLoop()
        startResultLoop()
    }

    func makeRunningSession() -> SpeechCaptureSession.RunningSession {
        SpeechCaptureSession.RunningSession(
            stream: eventStream,
            stop: { [weak self] in
                guard let self else { return }
                try await self.stop()
            },
            cancel: { [weak self] in
                guard let self else { return }
                await self.cancel()
            }
        )
    }

    func stop() async throws {
        guard hasFinished == false else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analysisInputContinuation.finish()

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            eventContinuation.finish(throwing: error)
            hasFinished = true
            return
        }

        _ = await analyzerTask?.result
        _ = await resultTask?.result

        if latestTranscript.isEmpty == false {
            eventContinuation.yield(.init(kind: .final(latestTranscript)))
        }
        eventContinuation.finish()
        hasFinished = true
    }

    func cancel() async {
        guard hasFinished == false else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analysisInputContinuation.finish()
        await analyzer.cancelAndFinishNow()
        analyzerTask?.cancel()
        resultTask?.cancel()
        eventContinuation.finish()
        hasFinished = true
    }

    private func prepareAndStartEngine() async throws {
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat
        ) ?? naturalFormat

        try await analyzer.prepareToAnalyze(in: format)

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            Task {
                await self?.yield(buffer: buffer)
            }
        }

        do {
            try engine.start()
        } catch {
            throw SpeechCaptureSession.Error.initializationFailed("麦克风输入启动失败")
        }
    }

    private func startAnalyzerLoop() {
        analyzerTask = Task { [analysisInputStream, analyzer, eventContinuation] in
            do {
                try await analyzer.start(inputSequence: analysisInputStream)
            } catch is CancellationError {
                return
            } catch {
                eventContinuation.finish(throwing: error)
            }
        }
    }

    private func startResultLoop() {
        resultTask = Task { [transcriber, eventContinuation] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard text.isEmpty == false else { continue }
                    await self.setLatestTranscript(text)
                    eventContinuation.yield(.init(kind: .partial(text)))
                }
            } catch is CancellationError {
                return
            } catch {
                eventContinuation.finish(throwing: error)
            }
        }
    }

    private func yield(buffer: AVAudioPCMBuffer) {
        guard hasFinished == false else { return }
        analysisInputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    private func setLatestTranscript(_ text: String) {
        latestTranscript = text
    }
}
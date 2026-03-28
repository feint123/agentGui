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
            case preparing
            case installingModel(progress: Double?, message: String)
            case ready
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
            try await LiveSpeechCaptureCoordinator.makeRunningSession(locale: locale)
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

private actor LiveSpeechCaptureCoordinator {
    private let transcriber: SpeechTranscriber
    private let eventStream: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>
    private let eventContinuation: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>.Continuation

    private var bootstrapTask: Task<Void, Never>?
    private var runtime: LiveSpeechCaptureRuntime?
    private var hasFinished = false

    static func makeRunningSession(locale: Locale) async throws -> SpeechCaptureSession.RunningSession {
        let coordinator = try await LiveSpeechCaptureCoordinator(locale: locale)
        return await coordinator.runningSession()
    }

    init(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechCaptureSession.Error.initializationFailed("当前设备暂不支持语音输入")
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechCaptureSession.Error.unsupportedLocale
        }

        self.transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)

        let eventParts = AsyncThrowingStream.makeStream(of: SpeechCaptureSession.Event.self)
        self.eventStream = eventParts.stream
        self.eventContinuation = eventParts.continuation

        bootstrapTask = Task { [weak self] in
            await self?.bootstrapRuntime()
        }
    }

    func runningSession() -> SpeechCaptureSession.RunningSession {
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

        if let runtime {
            try await runtime.stop()
            hasFinished = true
            return
        }

        await cancel()
    }

    func cancel() async {
        guard hasFinished == false else { return }
        hasFinished = true
        bootstrapTask?.cancel()
        if let runtime {
            await runtime.cancel()
        } else {
            eventContinuation.finish()
        }
    }

    private func bootstrapRuntime() async {
        do {
            emitPreparing()
            try await installAssetsIfNeeded()
            guard Task.isCancelled == false else {
                eventContinuation.finish()
                hasFinished = true
                return
            }

            let runtime = try await LiveSpeechCaptureRuntime(
                transcriber: transcriber,
                eventContinuation: eventContinuation
            )
            self.runtime = runtime
        } catch is CancellationError {
            eventContinuation.finish()
            hasFinished = true
        } catch {
            eventContinuation.finish(throwing: error)
            hasFinished = true
        }
    }

    private func installAssetsIfNeeded() async throws {
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        switch assetStatus {
        case .unsupported:
            throw SpeechCaptureSession.Error.unsupportedLocale
        case .installed:
            return
        case .supported, .downloading:
            try await installAssets()
        @unknown default:
            throw SpeechCaptureSession.Error.initializationFailed("语音模型状态未知")
        }
    }

    private func installAssets() async throws {
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        if let request {
            let progressTask = Task { [weak self] in
                await self?.publishInstallationProgress(for: request.progress)
            }
            defer { progressTask.cancel() }

            emitInstallationProgress(
                progress: normalizedProgressFraction(for: request.progress),
                message: installationMessage(for: normalizedProgressFraction(for: request.progress))
            )
            try await request.downloadAndInstall()
            emitInstallationProgress(progress: 1, message: installationMessage(for: 1))
            return
        }

        try await waitForExistingInstallation()
    }

    private func publishInstallationProgress(for progress: Progress) async {
        while Task.isCancelled == false && progress.isFinished == false {
            let fraction = normalizedProgressFraction(for: progress)
            emitInstallationProgress(
                progress: fraction,
                message: installationMessage(for: fraction)
            )

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
    }

    private func waitForExistingInstallation() async throws {
        while Task.isCancelled == false {
            let status = await AssetInventory.status(forModules: [transcriber])
            switch status {
            case .installed:
                emitInstallationProgress(progress: 1, message: installationMessage(for: 1))
                return
            case .unsupported:
                throw SpeechCaptureSession.Error.unsupportedLocale
            case .supported, .downloading:
                emitInstallationProgress(progress: nil, message: "等待系统完成语音模型安装")
            @unknown default:
                throw SpeechCaptureSession.Error.initializationFailed("语音模型状态未知")
            }

            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func emitInstallationProgress(progress: Double?, message: String) {
        guard hasFinished == false else { return }
        eventContinuation.yield(.init(kind: .installingModel(progress: progress, message: message)))
    }

    private func emitPreparing() {
        guard hasFinished == false else { return }
        eventContinuation.yield(.init(kind: .preparing))
    }

    private func normalizedProgressFraction(for progress: Progress) -> Double? {
        guard progress.totalUnitCount > 0 else { return nil }
        return min(max(progress.fractionCompleted, 0), 1)
    }

    private func installationMessage(for progress: Double?) -> String {
        guard let progress else {
            return "正在下载语音模型"
        }

        return "正在下载语音模型 \(Int((progress * 100).rounded()))%"
    }
}

private actor LiveSpeechCaptureRuntime {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let engine: AVAudioEngine
    private let analysisInputStream: AsyncThrowingStream<AnalyzerInput, Swift.Error>
    private let analysisInputContinuation: AsyncThrowingStream<AnalyzerInput, Swift.Error>.Continuation
    private let eventContinuation: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>.Continuation

    private var analyzerTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var latestTranscript = ""
    private var hasFinished = false

    init(
        transcriber: SpeechTranscriber,
        eventContinuation: AsyncThrowingStream<SpeechCaptureSession.Event, Swift.Error>.Continuation
    ) async throws {
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.engine = AVAudioEngine()

        let analysisParts = AsyncThrowingStream.makeStream(of: AnalyzerInput.self)
        self.analysisInputStream = analysisParts.stream
        self.analysisInputContinuation = analysisParts.continuation
        self.eventContinuation = eventContinuation

        try await prepareAndStartEngine()
        startAnalyzerLoop()
        startResultLoop()
        eventContinuation.yield(.init(kind: .ready))
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
                    self.setLatestTranscript(text)
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
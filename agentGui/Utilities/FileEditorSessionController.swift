import AppKit
import Foundation
import Observation

enum FileEditorViewerType {
    case text
    case image
    case pdf
}

struct FileEditorDocumentState {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case conflicted
        case failed
    }

    var phase: Phase = .idle
    var fileURL: URL?
    var viewer: FileEditorViewerType = .text
    var textContent = ""
    var persistedText = ""
    var viewerImage: NSImage?
    var errorMessage: String?
    var isSaving = false
    var pendingConflict: FileEditorExternalConflict?

    var hasUnsavedChanges: Bool {
        guard fileURL != nil, viewer == .text else { return false }
        return textContent != persistedText
    }

    var isLoading: Bool {
        phase == .loading
    }
}

@Observable
@MainActor
final class FileEditorSessionController {
    private(set) var document = FileEditorDocumentState()

    private let textLoadingStrategy: FileEditorTextLoadingStrategy
    private let saveText: @Sendable (String, URL) async throws -> Void
    private let imageLoader: @Sendable (URL) async -> NSImage?

    private var requestTracker = FileEditorRequestTracker()
    private var openFileRefreshMonitor: OpenFileRefreshMonitor
    private var externalConflictCoordinator = FileEditorExternalConflictCoordinator()
    private var isActive = false

    init(
        textLoadingStrategy: FileEditorTextLoadingStrategy = .live,
        saveText: @escaping @Sendable (String, URL) async throws -> Void = FileEditorSessionController.defaultSaveText,
        imageLoader: @escaping @Sendable (URL) async -> NSImage? = FileEditorSessionController.defaultImageLoader,
        refreshMonitor: OpenFileRefreshMonitor? = nil
    ) {
        self.textLoadingStrategy = textLoadingStrategy
        self.saveText = saveText
        self.imageLoader = imageLoader
        self.openFileRefreshMonitor = refreshMonitor ?? OpenFileRefreshMonitor()
        self.openFileRefreshMonitor.onExternalChange = { [weak self] changedURL in
            Task { @MainActor [weak self] in
                await self?.handleExternalChange(for: changedURL)
            }
        }
    }

    func activate() {
        isActive = true
        openFileRefreshMonitor.watch(document.fileURL)
    }

    func deactivate() {
        isActive = false
        requestTracker.invalidate()
        openFileRefreshMonitor.watch(nil)
    }

    func open(_ url: URL?) async {
        externalConflictCoordinator.clear()
        syncConflictState()

        guard let url else {
            clearDocument()
            openFileRefreshMonitor.watch(nil)
            return
        }

        let standardizedURL = url.standardizedFileURL
        if isActive {
            openFileRefreshMonitor.watch(standardizedURL)
        }
        await loadFile(standardizedURL)
    }

    func updateText(_ text: String) {
        document.textContent = text
        if document.pendingConflict == nil, document.phase != .loading, document.phase != .failed {
            document.phase = document.fileURL == nil ? .idle : .ready
        }
    }

    func save() async {
        guard document.viewer == .text,
              let fileURL = document.fileURL,
              document.hasUnsavedChanges,
              !document.isSaving else {
            return
        }

        let standardizedURL = fileURL.standardizedFileURL
        let saveToken = requestTracker.snapshot(for: standardizedURL)
        let textToSave = document.textContent

        document.isSaving = true
        document.errorMessage = nil

        do {
            try await saveText(textToSave, standardizedURL)
            guard requestTracker.isCurrent(saveToken, for: document.fileURL) else { return }
            externalConflictCoordinator.handleSuccessfulSave(for: standardizedURL)
            document.persistedText = textToSave
            document.isSaving = false
            document.phase = .ready
            syncConflictState()
        } catch {
            guard requestTracker.isCurrent(saveToken, for: document.fileURL) else { return }
            document.isSaving = false
            document.phase = .failed
            document.errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func handleExternalChange(for changedURL: URL) async {
        let outcome = externalConflictCoordinator.handleExternalChange(
            changedURL: changedURL,
            loadedURL: document.fileURL,
            hasUnsavedChanges: document.hasUnsavedChanges
        )
        await applyExternalConflictOutcome(outcome)
    }

    func resolveConflict(_ decision: FileEditorExternalConflictDecision) async {
        let outcome = externalConflictCoordinator.resolve(decision)
        await applyExternalConflictOutcome(outcome)
    }

    func clearErrorMessage() {
        document.errorMessage = nil
        if document.phase == .failed {
            document.phase = document.fileURL == nil ? .idle : .ready
            syncConflictState()
        }
    }

    private func loadFile(_ url: URL) async {
        let requestToken = requestTracker.beginRequest(for: url)
        prepareForLoading(url: url)

        do {
            if AttachedFile.pathIsImage(url.path) {
                let image = await imageLoader(url)
                finishImageLoad(image, requestToken: requestToken, url: url)
                return
            }

            if AttachedFile.pathIsPDF(url.path) {
                finishPDFLoad(requestToken: requestToken, url: url)
                return
            }

            let normalizedText = try await textLoadingStrategy.loadNormalizedText(from: url)
            finishTextLoad(normalizedText, requestToken: requestToken, url: url)
        } catch is CancellationError {
            return
        } catch {
            finishLoadFailure(error, requestToken: requestToken, url: url)
        }
    }

    private func prepareForLoading(url: URL) {
        document.fileURL = url
        document.textContent = ""
        document.persistedText = ""
        document.viewerImage = nil
        document.errorMessage = nil
        document.isSaving = false
        document.pendingConflict = nil
        document.phase = .loading
        document.viewer = viewerType(for: url)
    }

    private func clearDocument() {
        requestTracker.invalidate()
        document = FileEditorDocumentState()
        externalConflictCoordinator.clear()
    }

    private func applyExternalConflictOutcome(_ outcome: FileEditorExternalConflictOutcome) async {
        switch outcome {
        case .none:
            syncConflictState()
            if document.fileURL != nil, document.phase != .loading, document.phase != .failed {
                document.phase = .ready
            }
        case .presentConflict:
            syncConflictState()
            document.phase = .conflicted
        case .reload(let url):
            syncConflictState()
            await loadFile(url)
        }
    }

    private func syncConflictState() {
        document.pendingConflict = externalConflictCoordinator.pendingConflict
    }

    private func finishImageLoad(_ image: NSImage?, requestToken: FileEditorRequestToken, url: URL) {
        guard requestTracker.isCurrent(requestToken, for: document.fileURL), document.fileURL == url else { return }
        document.viewerImage = image
        document.phase = .ready
    }

    private func finishPDFLoad(requestToken: FileEditorRequestToken, url: URL) {
        guard requestTracker.isCurrent(requestToken, for: document.fileURL), document.fileURL == url else { return }
        document.phase = .ready
    }

    private func finishTextLoad(_ normalizedText: String, requestToken: FileEditorRequestToken, url: URL) {
        guard requestTracker.isCurrent(requestToken, for: document.fileURL), document.fileURL == url else { return }
        document.persistedText = normalizedText
        document.textContent = normalizedText
        document.phase = .ready
    }

    private func finishLoadFailure(_ error: Error, requestToken: FileEditorRequestToken, url: URL) {
        guard requestTracker.isCurrent(requestToken, for: document.fileURL), document.fileURL == url else { return }
        document.textContent = ""
        document.persistedText = ""
        document.viewerImage = nil
        document.phase = .failed
        document.errorMessage = "无法读取文件：\(error.localizedDescription)"
        syncConflictState()
    }

    private func viewerType(for url: URL) -> FileEditorViewerType {
        if AttachedFile.pathIsImage(url.path) {
            return .image
        }
        if AttachedFile.pathIsPDF(url.path) {
            return .pdf
        }
        return .text
    }

    private static func defaultSaveText(_ text: String, _ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    private static func defaultImageLoader(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }
}
import Foundation
import CoreServices

protocol OpenFileObservationSession: AnyObject {
    func stop()
}

struct OpenFileObservationFactory {
    let makeObservation: (URL, @escaping (URL) -> Void) -> OpenFileObservationSession?

    init(_ makeObservation: @escaping (URL, @escaping (URL) -> Void) -> OpenFileObservationSession?) {
        self.makeObservation = makeObservation
    }

    func make(url: URL, onChange: @escaping (URL) -> Void) -> OpenFileObservationSession? {
        makeObservation(url.standardizedFileURL, onChange)
    }

    static let live = OpenFileObservationFactory { url, onChange in
        LiveOpenFileObservation(url: url, onChange: onChange)
    }
}

@MainActor
final class OpenFileRefreshMonitor {
    var onExternalChange: ((URL) -> Void)?

    private let observationFactory: OpenFileObservationFactory
    private var activeObservation: OpenFileObservationSession?

    init(observationFactory: OpenFileObservationFactory = .live) {
        self.observationFactory = observationFactory
    }

    deinit {
        activeObservation?.stop()
    }

    func watch(_ url: URL?) {
        activeObservation?.stop()
        activeObservation = nil

        guard let url else { return }
        let standardizedURL = url.standardizedFileURL
        activeObservation = observationFactory.make(url: standardizedURL) { [weak self] changedURL in
            Task { @MainActor [weak self] in
                self?.onExternalChange?(changedURL.standardizedFileURL)
            }
        }
    }
}

private struct OpenFileSnapshot: Equatable {
    let exists: Bool
    let contentModificationDate: Date?
    let fileSize: Int64?
    let fileResourceIdentifier: String?

    static func capture(for url: URL) -> OpenFileSnapshot {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey,
            .isRegularFileKey
        ]

        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else {
            return OpenFileSnapshot(
                exists: false,
                contentModificationDate: nil,
                fileSize: nil,
                fileResourceIdentifier: nil
            )
        }

        return OpenFileSnapshot(
            exists: true,
            contentModificationDate: values.contentModificationDate,
            fileSize: values.fileSize.map(Int64.init),
            fileResourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
    }
}

private final class LiveOpenFileObservation: OpenFileObservationSession, @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let targetURL: URL
    private let parentDirectoryURL: URL
    private var lastSnapshot: OpenFileSnapshot

    init?(url: URL, onChange: @escaping (URL) -> Void) {
        let standardizedURL = url.standardizedFileURL
        self.targetURL = standardizedURL
        self.parentDirectoryURL = standardizedURL.deletingLastPathComponent().standardizedFileURL
        self.lastSnapshot = OpenFileSnapshot.capture(for: standardizedURL)
        guard start(onChange: onChange) else { return nil }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    private func start(onChange: @escaping (URL) -> Void) -> Bool {
        final class CallbackBox {
            let fn: ([String]) -> Void

            init(_ fn: @escaping ([String]) -> Void) {
                self.fn = fn
            }
        }

        let callbackBox = Unmanaged.passRetained(CallbackBox { [weak self] changedPaths in
            self?.handleEvents(changedPaths, onChange: onChange)
        })

        var context = FSEventStreamContext(
            version: 0,
            info: callbackBox.toOpaque(),
            retain: nil,
            release: { pointer in
                Unmanaged<CallbackBox>.fromOpaque(pointer!).release()
            },
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn(paths)
            },
            &context,
            [parentDirectoryURL.path] as CFArray,
            FSEventStreamEventId.max,
            0.2,
            flags
        ) else {
            callbackBox.release()
            return false
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        streamRef = stream
        return true
    }

    private func handleEvents(_ changedPaths: [String], onChange: @escaping (URL) -> Void) {
        let parentPath = parentDirectoryURL.path
        let relevantChangeDetected = changedPaths.contains { changedPath in
            let standardizedPath = URL(fileURLWithPath: changedPath).standardizedFileURL.path
            return standardizedPath == parentPath || standardizedPath.hasPrefix(parentPath + "/")
        }

        guard relevantChangeDetected else { return }

        let currentSnapshot = OpenFileSnapshot.capture(for: targetURL)
        guard currentSnapshot != lastSnapshot else { return }
        lastSnapshot = currentSnapshot
        onChange(targetURL)
    }
}
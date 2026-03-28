import Foundation

#if canImport(Sparkle) && os(macOS)
import Sparkle
#endif

@MainActor
final class SparkleUpdateDelegate: NSObject {
    typealias UpdateChannelProvider = () -> SparkleUpdateChannel

    private let updateChannelProvider: UpdateChannelProvider
    private(set) var lastErrorDescription: String?

    init(updateChannelProvider: @escaping UpdateChannelProvider) {
        self.updateChannelProvider = updateChannelProvider
        super.init()
    }

    func allowedChannels() -> Set<String> {
        switch updateChannelProvider() {
        case .stable:
            return []
        case .beta:
            return [SparkleUpdateChannel.beta.rawValue]
        }
    }

    func record(error: Error) {
        lastErrorDescription = error.localizedDescription
    }
}

#if canImport(Sparkle) && os(macOS)
extension SparkleUpdateDelegate: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record(error: error)
    }
}
#endif
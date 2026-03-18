import Foundation

@MainActor
final class IMChannelRegistry {
    private var adapters: [IMChannelKind: any IMChannelAdapter] = [:]

    func register(_ adapter: any IMChannelAdapter) {
        adapters[adapter.kind] = adapter
    }

    func adapter(for kind: IMChannelKind) -> (any IMChannelAdapter)? {
        adapters[kind]
    }

    func start(kind: IMChannelKind, configuration: IMChannelConfiguration) async throws {
        try await adapters[kind]?.start(configuration: configuration)
    }

    func stop(kind: IMChannelKind) async {
        await adapters[kind]?.stop()
    }

    func stopAll() async {
        for adapter in adapters.values {
            await adapter.stop()
        }
    }
}
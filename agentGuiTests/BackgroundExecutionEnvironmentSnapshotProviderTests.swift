import Foundation
import Testing
@testable import agentGui

struct BackgroundExecutionEnvironmentSnapshotProviderTests {
    @Test func providerReturnsInjectedNetworkAndPowerSnapshot() {
        let provider = LiveBackgroundExecutionEnvironmentSnapshotProvider(
            networkAvailabilityReader: { true },
            externalPowerReader: { false }
        )

        let snapshot = provider.currentSnapshot()

        #expect(snapshot.networkAvailable == true)
        #expect(snapshot.externalPowerConnected == false)
    }

    @Test func providerPreservesUnknownSnapshotValues() {
        let provider = LiveBackgroundExecutionEnvironmentSnapshotProvider(
            networkAvailabilityReader: { nil },
            externalPowerReader: { nil }
        )

        let snapshot = provider.currentSnapshot()

        #expect(snapshot.networkAvailable == nil)
        #expect(snapshot.externalPowerConnected == nil)
    }
}
import Foundation
import Testing
@testable import agentGui

struct WorkbenchContextWindowConfiguratorTests {

    @Test func preferredHostPrefersKeyContextWindow() {
        let incoming = WorkbenchContextTabCandidate(
            windowNumber: 3,
            tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
            isKeyWindow: false,
            isVisible: true
        )
        let host = WorkbenchContextWindowConfigurator.preferredTabHost(
            for: incoming,
            candidates: [
                WorkbenchContextTabCandidate(
                    windowNumber: 1,
                    tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
                    isKeyWindow: false,
                    isVisible: true
                ),
                WorkbenchContextTabCandidate(
                    windowNumber: 2,
                    tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
                    isKeyWindow: true,
                    isVisible: true
                )
            ]
        )

        #expect(host?.windowNumber == 2)
    }

    @Test func preferredHostIgnoresNonContextWindowsAndSelf() {
        let incoming = WorkbenchContextTabCandidate(
            windowNumber: 7,
            tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
            isKeyWindow: false,
            isVisible: true
        )
        let host = WorkbenchContextWindowConfigurator.preferredTabHost(
            for: incoming,
            candidates: [
                WorkbenchContextTabCandidate(
                    windowNumber: 7,
                    tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
                    isKeyWindow: true,
                    isVisible: true
                ),
                WorkbenchContextTabCandidate(
                    windowNumber: 8,
                    tabbingIdentifier: "other-window-group",
                    isKeyWindow: true,
                    isVisible: true
                ),
                WorkbenchContextTabCandidate(
                    windowNumber: 9,
                    tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
                    isKeyWindow: false,
                    isVisible: true
                )
            ]
        )

        #expect(host?.windowNumber == 9)
    }

    @Test func preferredHostReturnsNilWhenNoVisibleContextWindowExists() {
        let incoming = WorkbenchContextTabCandidate(
            windowNumber: 5,
            tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
            isKeyWindow: false,
            isVisible: true
        )
        let host = WorkbenchContextWindowConfigurator.preferredTabHost(
            for: incoming,
            candidates: [
                WorkbenchContextTabCandidate(
                    windowNumber: 6,
                    tabbingIdentifier: WorkbenchContextWindowConfigurator.contextTabbingIdentifier,
                    isKeyWindow: false,
                    isVisible: false
                )
            ]
        )

        #expect(host == nil)
    }
}
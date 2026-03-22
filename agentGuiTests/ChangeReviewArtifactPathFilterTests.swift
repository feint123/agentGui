import Foundation
import Testing
@testable import agentGui

struct ChangeReviewArtifactPathFilterTests {

    @Test func excludesCommonGeneratedAndDependencyDirectories() {
        let filter = ChangeReviewArtifactPathFilter()

        #expect(filter.includes(relativePath: "node_modules/react/index.js") == false)
        #expect(filter.includes(relativePath: "venv/lib/python3.12/site.py") == false)
        #expect(filter.includes(relativePath: ".venv/bin/python") == false)
        #expect(filter.includes(relativePath: "build/debug/App.o") == false)
        #expect(filter.includes(relativePath: "DerivedData/Logs/Build/log.txt") == false)
    }

    @Test func keepsProjectSourcesAndConfigurationFiles() {
        let filter = ChangeReviewArtifactPathFilter()

        #expect(filter.includes(relativePath: "agentGui/Views/ChatView.swift"))
        #expect(filter.includes(relativePath: "docs/plans/workbench.md"))
        #expect(filter.includes(relativePath: ".swiftlint.yml"))
        #expect(filter.includes(relativePath: "Package.swift"))
    }
}
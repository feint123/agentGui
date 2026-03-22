import Foundation
import Testing
@testable import agentGui

@MainActor
struct SessionWorkspacePresentationFactoryTests {
    @Test func sessionOverrideWinsOverGlobalDirectory() {
        let session = Session.fixture(workingDirectory: "/tmp/RepoA")

        let presentation = SessionWorkspacePresentationFactory().build(
            session: session,
            globalWorkingDirectory: "/tmp/RepoB"
        )

        #expect(presentation.title == "RepoA")
        #expect(presentation.kindLabel == "会话级")
        #expect(presentation.representedURL?.path == "/tmp/RepoA")
    }

    @Test func globalDirectoryIsUsedWhenSessionHasNoOverride() {
        let session = Session.fixture(workingDirectory: "")

        let presentation = SessionWorkspacePresentationFactory().build(
            session: session,
            globalWorkingDirectory: "/tmp/RepoB"
        )

        #expect(presentation.title == "RepoB")
        #expect(presentation.kindLabel == "全局")
        #expect(!presentation.isMissing)
    }

    @Test func missingDirectoryProducesExplicitUnsetState() {
        let presentation = SessionWorkspacePresentationFactory().build(
            session: nil,
            globalWorkingDirectory: ""
        )

        #expect(presentation.title == "未设置工作区")
        #expect(presentation.kindLabel == "未设置")
        #expect(presentation.isMissing)
        #expect(presentation.representedURL == nil)
    }
}
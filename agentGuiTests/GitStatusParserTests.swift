import Foundation
import Testing
@testable import agentGui

@MainActor
struct GitStatusParserTests {

    @Test func parsesBranchCountersAndSections() throws {
        let output = """
        ## main...origin/main [ahead 2, behind 1]
         M agentGui/Views/FileEditorView.swift
        M  agentGui/Views/WorkspacePanelView.swift
        ?? docs/spec/2026-03-11-basic-git-ui-requirements.md
        """

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.repositoryName == "repo")
        #expect(snapshot.branchName == "main")
        #expect(snapshot.hasRemoteTrackingBranch)
        #expect(snapshot.aheadCount == 2)
        #expect(snapshot.behindCount == 1)
        #expect(snapshot.unstagedChanges.count == 1)
        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.untrackedChanges.count == 1)
        #expect(snapshot.unstagedChanges.first?.relativePath == "agentGui/Views/FileEditorView.swift")
        #expect(snapshot.stagedChanges.first?.status == .modified)
        #expect(snapshot.untrackedChanges.first?.status == .untracked)
    }

    @Test func parsesRenameAndDeleteLines() throws {
        let output = """
        ## feature/test
        R  old/path.swift -> new/path.swift
         D removed/file.txt
        """

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.stagedChanges.first?.status == .renamed)
        #expect(snapshot.stagedChanges.first?.relativePath == "new/path.swift")
        #expect(snapshot.unstagedChanges.count == 1)
        #expect(snapshot.unstagedChanges.first?.status == .deleted)
    }

    @Test func rejectsInvalidStatusOutput() {
        #expect(throws: GitStatusParser.ParseError.self) {
            try GitStatusParser.parseStatus(
                "fatal: not a git repository",
                repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
            )
        }
    }
}
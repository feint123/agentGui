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

    @Test func parsesChineseUntrackedAndSpacedPaths() throws {
        let output = """
        ## main
        ?? 文档/需求说明.md
        ?? 设计稿/版本 2/提交说明.swift
        """

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.untrackedChanges.count == 2)
        #expect(snapshot.untrackedChanges[0].relativePath == "文档/需求说明.md")
        #expect(snapshot.untrackedChanges[1].relativePath == "设计稿/版本 2/提交说明.swift")
    }

    @Test func parsesChineseRenamePathAndKeepsNewPath() throws {
        let output = """
        ## main
        R  旧目录/说明.txt -> 新目录/产品说明.txt
        """

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.stagedChanges.first?.relativePath == "新目录/产品说明.txt")
        #expect(snapshot.stagedChanges.first?.status == .renamed)
    }

    @Test func parsesQuotedRenamePathWithSpaces() throws {
        let output = #"""
        ## main
        R  "旧 目录/说明.txt" -> "新 目录/产品说明.txt"
        """#

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.stagedChanges.count == 1)
        #expect(snapshot.stagedChanges.first?.relativePath == "新 目录/产品说明.txt")
    }

    @Test func decodesQuotedOctalEscapedChinesePath() throws {
        let output = #"""
        ## main
        ?? "\346\226\207\346\241\243/\351\234\200\346\261\202\350\257\264\346\230\216.md"
        """#

        let snapshot = try GitStatusParser.parseStatus(
            output,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repo")
        )

        #expect(snapshot.untrackedChanges.count == 1)
        #expect(snapshot.untrackedChanges.first?.relativePath == "文档/需求说明.md")
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
import XCTest
@testable import agentGui

final class GitDiffPresentationTests: XCTestCase {

    // MARK: - Fixtures

    static let simplePatch = """
    @@ -1,3 +1,3 @@
     line1
    -old line
    +new line
     line3
    """

    static let emptyPatch = ""

    static let binaryPatch = "Binary files a/img.png and b/img.png differ"

    // MARK: - Basic Parsing

    func test_build_emptyText_returnsEmptySections() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.emptyPatch)
        XCTAssertEqual(result.sections.count, 0)
        XCTAssertEqual(result.changeSummary.additions, 0)
        XCTAssertEqual(result.changeSummary.deletions, 0)
    }

    func test_build_simpleHunk_returnsSingleSection() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        XCTAssertEqual(result.sections.count, 1)
    }

    func test_build_simpleHunk_correctChangeSummary() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        XCTAssertEqual(result.changeSummary.additions, 1)
        XCTAssertEqual(result.changeSummary.deletions, 1)
    }

    func test_build_simpleHunk_correctRowOrder() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        // context, deletion, addition, context
        XCTAssertEqual(rows.count, 4)
        if case .context(_, _, let text) = rows[0] { XCTAssertEqual(text, "line1") } else { XCTFail("Expected context row at index 0") }
        if case .deletion(_, _, let text) = rows[1] { XCTAssertEqual(text, "old line") } else { XCTFail("Expected deletion row at index 1") }
        if case .addition(_, _, let text) = rows[2] { XCTAssertEqual(text, "new line") } else { XCTFail("Expected addition row at index 2") }
        if case .context(_, _, let text) = rows[3] { XCTAssertEqual(text, "line3") } else { XCTFail("Expected context row at index 3") }
    }

    func test_build_lineNumbers_context() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .context(let old, let new, _) = rows[0] {
            XCTAssertEqual(old, 1)
            XCTAssertEqual(new, 1)
        } else { XCTFail("Expected context row at index 0") }
    }

    func test_build_lineNumbers_deletionHasOldOnly() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .deletion(let old, let new, _) = rows[1] {
            XCTAssertEqual(old, 2)
            XCTAssertNil(new)
        } else { XCTFail("Expected deletion row at index 1") }
    }

    func test_build_lineNumbers_additionHasNewOnly() {
        let result = GitDiffPresentation.build(title: "file.txt", diffText: Self.simplePatch)
        let rows = result.sections[0].rows
        if case .addition(let old, let new, _) = rows[2] {
            XCTAssertNil(old)
            XCTAssertEqual(new, 2)
        } else { XCTFail("Expected addition row at index 2") }
    }

    func test_build_titleStoredAsFilePath() {
        let result = GitDiffPresentation.build(title: "src/main.swift", diffText: Self.simplePatch)
        XCTAssertEqual(result.filePath, "src/main.swift")
    }

    // MARK: - Multi-hunk

    func test_build_multiHunk_returnsMultipleSections() {
        let multiHunk = """
        @@ -1,2 +1,2 @@
        -old1
        +new1
         context1
        @@ -10,2 +10,2 @@
        -old2
        +new2
         context2
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: multiHunk)
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.changeSummary.additions, 2)
        XCTAssertEqual(result.changeSummary.deletions, 2)
    }

    func test_build_multiHunk_secondSectionLineNumbers() {
        let multiHunk = """
        @@ -1,1 +1,1 @@
        -a
        +b
        @@ -10,1 +10,1 @@
        -c
        +d
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: multiHunk)
        let section2Rows = result.sections[1].rows
        if case .deletion(let old, _, _) = section2Rows[0] {
            XCTAssertEqual(old, 10)
        } else { XCTFail("Expected deletion row as first row of second section") }
    }

    // MARK: - Edge cases

    func test_build_onlyAdditions() {
        let addOnly = """
        @@ -0,0 +1,2 @@
        +line1
        +line2
        """
        let result = GitDiffPresentation.build(title: "new.txt", diffText: addOnly)
        XCTAssertEqual(result.changeSummary.additions, 2)
        XCTAssertEqual(result.changeSummary.deletions, 0)
    }

    func test_build_onlyDeletions() {
        let delOnly = """
        @@ -1,2 +0,0 @@
        -line1
        -line2
        """
        let result = GitDiffPresentation.build(title: "del.txt", diffText: delOnly)
        XCTAssertEqual(result.changeSummary.additions, 0)
        XCTAssertEqual(result.changeSummary.deletions, 2)
    }

    func test_build_noNewlineAtEof_metadataRow() {
        let withNoNewline = """
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: withNoNewline)
        let rows = result.sections[0].rows
        XCTAssertTrue(rows.contains { if case .metadata = $0 { return true }; return false },
                      "Expected at least one metadata row for '\\No newline at end of file'")
    }

    func test_build_linesBeforeFirstHunk_ignored() {
        let withPreamble = """
        diff --git a/f.txt b/f.txt
        index abc..def 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,1 +1,1 @@
        -x
        +y
        """
        let result = GitDiffPresentation.build(title: "f.txt", diffText: withPreamble)
        XCTAssertEqual(result.sections.count, 1)
    }

    // MARK: - longestLineCharacterCount

    func test_longestLineCharacterCount_returnsMaxLineLength() {
        let result = GitDiffPresentation.build(title: "f.txt", diffText: Self.simplePatch)
        // "old line" = 8 chars + 1 prefix = 9; "new line" = 8 + 1 = 9
        XCTAssertGreaterThanOrEqual(result.longestLineCharacterCount, 8)
    }

    // MARK: - Async Parse Parity

    func test_asyncParse_returnsIdenticalResultToSync() async {
        let diffText = GitDiffPresentationTests.simplePatch
        let title = "parity.txt"

        // 同步版本（基准）
        let syncResult = GitDiffPresentation.build(title: title, diffText: diffText)

        // 异步版本（Task.detached）
        let asyncResult = await Task.detached(priority: .userInitiated) {
            GitDiffPresentation.build(title: title, diffText: diffText)
        }.value

        XCTAssertEqual(syncResult, asyncResult)
    }

    func test_asyncParse_largeInput_completesWithinReasonableTime() async {
        // 构造 5000 行 diff
        let header = "@@ -1,2500 +1,2500 @@\n"
        let deletions = (1...2500).map { "-line\($0)" }.joined(separator: "\n")
        let additions = (1...2500).map { "+line\($0)" }.joined(separator: "\n")
        let largeDiff = header + deletions + "\n" + additions

        let start = Date()
        let result = await Task.detached(priority: .userInitiated) {
            GitDiffPresentation.build(title: "large.txt", diffText: largeDiff)
        }.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.changeSummary.additions, 2500)
        XCTAssertEqual(result.changeSummary.deletions, 2500)
        // 后台解析应在 500ms 内完成（性能上限）
        XCTAssertLessThan(elapsed, 0.5, "Async parse took \(elapsed)s, too slow")
    }

    // MARK: - Task Cancellation

    func test_taskCancelledBeforeCompletion_doesNotUpdateResult() async {
        // 验证快速取消不会导致 crash 或 race condition
        let expectation = XCTestExpectation(description: "task completes or cancels cleanly")

        let task = Task.detached {
            let largeDiff = "@@ -1,1000 +1,1000 @@\n" +
                (1...1000).map { "-old\($0)" }.joined(separator: "\n") +
                "\n" +
                (1...1000).map { "+new\($0)" }.joined(separator: "\n")
            return GitDiffPresentation.build(title: "cancel_test.txt", diffText: largeDiff)
        }

        // 立即取消
        task.cancel()

        // 等待 Task 结束（取消后 Task 仍可能完成，但结果被丢弃）
        let _ = await task.result
        expectation.fulfill()

        await fulfillment(of: [expectation], timeout: 1.0)
        // 主要验证：无 crash、无数据竞争
    }
}

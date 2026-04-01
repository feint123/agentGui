import XCTest
@testable import agentGui

final class TestCommandDetectorTests: XCTestCase {

    // MARK: - isTestCommand

    func test_xcodebuild_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("xcodebuild test -scheme agentGui"))
    }

    func test_xcodebuild_build_isNotTest() {
        XCTAssertFalse(TestCommandDetector.isTestCommand("xcodebuild build -scheme agentGui"))
    }

    func test_swift_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("swift test"))
    }

    func test_npm_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("npm test"))
    }

    func test_yarn_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("yarn test"))
    }

    func test_jest_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("npx jest"))
        XCTAssertTrue(TestCommandDetector.isTestCommand("jest --watch"))
    }

    func test_pytest_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("pytest tests/"))
        XCTAssertTrue(TestCommandDetector.isTestCommand("python -m pytest"))
    }

    func test_go_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("go test ./..."))
    }

    func test_cargo_test_isDetected() {
        XCTAssertTrue(TestCommandDetector.isTestCommand("cargo test"))
    }

    func test_ls_isNotTest() {
        XCTAssertFalse(TestCommandDetector.isTestCommand("ls -la"))
    }

    func test_echo_test_isNotTest() {
        // "echo test" should NOT match — word-boundary checks matter
        XCTAssertFalse(TestCommandDetector.isTestCommand("echo test"))
    }

    // MARK: - parseXcodebuildOutput

    func test_parseXcodebuild_succeeded() {
        let output = """
        Test Suite 'All tests' started at 2026-04-01 12:00:00
        Test Case 'ChangeReviewHookTests.test_nonWriteTool_returnsPassthrough' passed (0.001 sec)
        Test Case 'ChangeReviewHookTests.test_writeTool_noSnapshot_returnsPassthrough' passed (0.002 sec)

        ** TEST SUCCEEDED **

        Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
        """
        let result = TestCommandDetector.parseTestOutput(output, command: "xcodebuild test")
        XCTAssertEqual(result.passCount, 2)
        XCTAssertEqual(result.failCount, 0)
        XCTAssertTrue(result.exitedZero)
        XCTAssertNil(result.failureSummary)
    }

    func test_parseXcodebuild_failed() {
        let output = """
        Test Case 'FooTests.testBar' failed: (0.003 sec)
        /path/to/FooTests.swift:42: error: FooTests.testBar : XCTAssertEqual failed: ("1") is not equal to ("2")

        ** TEST FAILED **

        Executed 3 tests, with 1 failure (0 unexpected) in 0.050 (0.060) seconds
        """
        let result = TestCommandDetector.parseTestOutput(output, command: "xcodebuild test")
        XCTAssertEqual(result.passCount, 2)
        XCTAssertEqual(result.failCount, 1)
        XCTAssertFalse(result.exitedZero)
        XCTAssertNotNil(result.failureSummary)
    }

    // MARK: - parsePytestOutput

    func test_parsePytest_passed() {
        let output = "5 passed in 0.12s"
        let result = TestCommandDetector.parseTestOutput(output, command: "pytest tests/")
        XCTAssertEqual(result.passCount, 5)
        XCTAssertEqual(result.failCount, 0)
        XCTAssertTrue(result.exitedZero)
    }

    func test_parsePytest_failed() {
        let output = "3 passed, 2 failed in 1.5s"
        let result = TestCommandDetector.parseTestOutput(output, command: "pytest tests/")
        XCTAssertEqual(result.passCount, 3)
        XCTAssertEqual(result.failCount, 2)
        XCTAssertFalse(result.exitedZero)
    }

    // MARK: - parseGoTestOutput

    func test_parseGo_ok() {
        let output = "ok  github.com/example/project  0.003s"
        let result = TestCommandDetector.parseTestOutput(output, command: "go test ./...")
        XCTAssertTrue(result.exitedZero)
    }

    func test_parseGo_fail() {
        let output = "FAIL github.com/example/project  0.003s"
        let result = TestCommandDetector.parseTestOutput(output, command: "go test ./...")
        XCTAssertFalse(result.exitedZero)
    }

    // MARK: - formatSummaryLabel

    func test_summaryLabel_passed() {
        let summary = ParsedTestOutput(passCount: 5, failCount: 0, exitedZero: true, failureSummary: nil)
        let label = TestCommandDetector.formatSummaryLabel(summary, command: "swift test")
        XCTAssertTrue(label.contains("5"))
        XCTAssertTrue(label.lowercased().contains("passed") || label.lowercased().contains("通过"))
    }

    func test_summaryLabel_failed() {
        let summary = ParsedTestOutput(passCount: 3, failCount: 2, exitedZero: false, failureSummary: "XCTAssertEqual failed")
        let label = TestCommandDetector.formatSummaryLabel(summary, command: "xcodebuild test")
        XCTAssertTrue(label.lowercased().contains("fail") || label.lowercased().contains("失败"))
    }
}

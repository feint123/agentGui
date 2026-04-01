import Foundation

// MARK: - ParsedTestOutput

/// Parsed result of running `TestCommandDetector.parseTestOutput(_:command:)`.
struct ParsedTestOutput: Sendable, Equatable {
    let passCount: Int?
    let failCount: Int?
    let exitedZero: Bool
    /// Truncated first failure string extracted from output. nil when all passed.
    let failureSummary: String?
}

// MARK: - TestCommandDetector

/// Stateless utility for detecting test-run commands and parsing their output.
enum TestCommandDetector {

    // MARK: - Test Command Detection

    /// Returns true if `command` looks like a test-run invocation.
    ///
    /// Detection rules:
    /// - `xcodebuild` with the word `test` as a sub-command (not just in a flag)
    /// - `swift test`
    /// - `npm test` / `yarn test` / `pnpm test`
    /// - `npx jest` / bare `jest` binary
    /// - `pytest` / `python -m pytest`
    /// - `go test`
    /// - `cargo test`
    /// - `mvn test` / `gradle test`
    static func isTestCommand(_ command: String) -> Bool {
        let lower = command.trimmingCharacters(in: .whitespaces).lowercased()
        return testPatterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: lower,
                range: NSRange(lower.startIndex..., in: lower)
            ) != nil
        }
    }

    // Word-boundary aware regex patterns for each known test runner.
    // Patterns are anchored to avoid matching "echo test" or "notestfoo".
    private static let testPatterns: [String] = [
        #"^xcodebuild\b.*\btest\b"#,                  // xcodebuild test ...
        #"^swift\s+test\b"#,                           // swift test
        #"^(npm|yarn|pnpm)\s+test\b"#,                // npm/yarn/pnpm test
        #"(^|\s)(npx\s+)?jest\b"#,                    // jest / npx jest
        #"(^|\s)pytest\b"#,                           // pytest
        #"python\s+(-m\s+)?pytest\b"#,                // python -m pytest
        #"^go\s+test\b"#,                             // go test
        #"^cargo\s+test\b"#,                          // cargo test
        #"^(mvn|gradle)\s+test\b"#,                   // mvn/gradle test
    ]

    // MARK: - Output Parsing

    /// Parse a test run's stdout/stderr output into a `ParsedTestOutput`.
    /// Works heuristically across multiple test runners.
    static func parseTestOutput(_ text: String, command: String) -> ParsedTestOutput {
        // Try runner-specific parsers in priority order
        if let result = parseXcodebuildOutput(text) { return result }
        if let result = parsePytestOutput(text) { return result }
        if let result = parseGoTestOutput(text) { return result }
        if let result = parseJestOutput(text) { return result }
        if let result = parseSwiftTestOutput(text) { return result }
        // Fallback: infer from exit keywords
        return fallbackParse(text)
    }

    // MARK: Private parsers

    /// xcodebuild: "Executed N tests, with M failures"  +  "** TEST SUCCEEDED/FAILED **"
    private static func parseXcodebuildOutput(_ text: String) -> ParsedTestOutput? {
        // Pattern: "Executed 5 tests, with 2 failures"
        let executedPattern = #"Executed (\d+) tests?, with (\d+) failures?"#
        guard let match = firstMatch(pattern: executedPattern, in: text) else { return nil }
        let total = intCapture(match, group: 1, in: text) ?? 0
        let fail  = intCapture(match, group: 2, in: text) ?? 0
        let pass  = total - fail
        let exitedZero = text.contains("** TEST SUCCEEDED **")
        let failureSummary = fail > 0 ? extractFirstFailureLine(text) : nil
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: exitedZero, failureSummary: failureSummary)
    }

    /// pytest: "5 passed" / "3 passed, 2 failed"
    private static func parsePytestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains(" passed") || text.contains(" failed") else { return nil }
        let passPattern = #"(\d+) passed"#
        let failPattern = #"(\d+) failed"#
        guard let passMatch = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(passMatch, group: 1, in: text) ?? 0
        let failMatch = firstMatch(pattern: failPattern, in: text)
        let fail = failMatch.flatMap { intCapture($0, group: 1, in: text) } ?? 0
        let exitedZero = fail == 0
        let failureSummary = fail > 0 ? extractFirstFailureLine(text) : nil
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: exitedZero, failureSummary: failureSummary)
    }

    /// go test: "ok  pkg  0.003s" / "FAIL pkg  0.003s"
    private static func parseGoTestOutput(_ text: String) -> ParsedTestOutput? {
        let hasOk   = text.range(of: #"^ok\s+"#, options: [.regularExpression, .anchored]) != nil
                   || text.contains("\nok  ")
        let hasFail = text.range(of: #"^FAIL\s+"#, options: [.regularExpression, .anchored]) != nil
                   || text.contains("\nFAIL ")
        guard hasOk || hasFail else { return nil }
        let exitedZero = hasOk && !hasFail
        return ParsedTestOutput(passCount: nil, failCount: hasFail ? 1 : 0, exitedZero: exitedZero, failureSummary: nil)
    }

    /// jest: "Tests:  5 passed, 2 failed"
    private static func parseJestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains("Tests:") else { return nil }
        let passPattern = #"(\d+) passed"#
        let failPattern = #"(\d+) failed"#
        guard let passMatch = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(passMatch, group: 1, in: text) ?? 0
        let failMatch = firstMatch(pattern: failPattern, in: text)
        let fail = failMatch.flatMap { intCapture($0, group: 1, in: text) } ?? 0
        return ParsedTestOutput(passCount: pass, failCount: fail, exitedZero: fail == 0, failureSummary: nil)
    }

    /// swift test: "Test run started." ... "Test run with N test(s) passed"
    private static func parseSwiftTestOutput(_ text: String) -> ParsedTestOutput? {
        guard text.contains("Test run") else { return nil }
        let passPattern = #"(\d+) test.* passed"#
        guard let match = firstMatch(pattern: passPattern, in: text) else { return nil }
        let pass = intCapture(match, group: 1, in: text) ?? 0
        let exitedZero = !text.lowercased().contains("failed") && !text.lowercased().contains("error")
        return ParsedTestOutput(passCount: pass, failCount: exitedZero ? 0 : nil, exitedZero: exitedZero, failureSummary: nil)
    }

    /// Last-resort: look for positive/negative Tier-1 keywords.
    private static func fallbackParse(_ text: String) -> ParsedTestOutput {
        let lower = text.lowercased()
        let exitedZero = lower.contains("all tests passed")
                      || lower.contains("tests passed")
                      || (lower.contains("success") && !lower.contains("failure"))
        return ParsedTestOutput(passCount: nil, failCount: nil, exitedZero: exitedZero, failureSummary: nil)
    }

    // MARK: - Summary Label

    /// Build a short human-readable label (~40 chars) for the timeline attachment.
    static func formatSummaryLabel(_ output: ParsedTestOutput, command: String) -> String {
        let runner = inferRunner(from: command)
        if output.exitedZero {
            if let pass = output.passCount {
                return "\(runner): \(pass) 个测试通过"
            }
            return "\(runner): 测试通过"
        } else {
            if let fail = output.failCount, let pass = output.passCount {
                return "\(runner): \(pass) 通过 / \(fail) 失败"
            }
            if let fail = output.failCount {
                return "\(runner): \(fail) 个测试失败"
            }
            return "\(runner): 测试失败"
        }
    }

    private static func inferRunner(from command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("xcodebuild") { return "xcodebuild" }
        if lower.contains("swift test") { return "swift test" }
        if lower.contains("pytest")     { return "pytest" }
        if lower.contains("jest")       { return "jest" }
        if lower.contains("go test")    { return "go test" }
        if lower.contains("cargo")      { return "cargo test" }
        return "tests"
    }

    // MARK: - Regex helpers

    private static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func intCapture(_ match: NSTextCheckingResult, group: Int, in text: String) -> Int? {
        let range = match.range(at: group)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else { return nil }
        return Int(text[swiftRange])
    }

    private static func extractFirstFailureLine(_ text: String) -> String? {
        // Look for lines containing "failed" or "error:" that are not summary lines
        let lines = text.components(separatedBy: "\n")
        let failLine = lines.first { line in
            let lower = line.lowercased()
            return (lower.contains("failed:") || lower.contains("error:")) &&
                   !lower.contains("** test") &&
                   !lower.contains("executed") &&
                   !lower.contains("failures")
        }
        guard let line = failLine else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}

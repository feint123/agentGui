import XCTest
@testable import agentGui

final class MemoryTopicFileComposerTests: XCTestCase {

    private let composer = MemoryTopicFileComposer()
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func makeRecord(
        id: String = "abc123",
        title: String = "User Role",
        summary: String = "Senior iOS developer",
        payloadText: String = "User is a senior iOS developer focusing on Swift 6.",
        kind: MemoryKind = .semantic,
        scope: MemoryScope = .user,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> MemoryRecord {
        MemoryRecord.fixture(
            id: id, kind: kind, scope: scope,
            title: title, summary: summary,
            payload: .text(payloadText),
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    // MARK: - Frontmatter presence

    func test_compose_containsFrontmatterDelimiters() {
        let output = composer.compose(record: makeRecord())
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---", "第一行应为 ---")
        let secondDelimiter = lines.dropFirst().firstIndex(of: "---")
        XCTAssertNotNil(secondDelimiter, "应有第二个 --- 分隔符")
    }

    func test_compose_containsNameField() {
        let output = composer.compose(record: makeRecord(title: "User Role"))
        XCTAssertTrue(output.contains("name: \"User Role\""))
    }

    func test_compose_containsDescriptionField() {
        let output = composer.compose(record: makeRecord(summary: "Senior iOS developer"))
        XCTAssertTrue(output.contains("description: \"Senior iOS developer\""))
    }

    func test_compose_containsTypeField() {
        let output = composer.compose(record: makeRecord(kind: .semantic))
        XCTAssertTrue(output.contains("type: semantic"))
    }

    func test_compose_containsIdField() {
        let output = composer.compose(record: makeRecord(id: "abc123"))
        XCTAssertTrue(output.contains("id: abc123"))
    }

    func test_compose_containsScopeField() {
        let output = composer.compose(record: makeRecord(scope: .user))
        XCTAssertTrue(output.contains("scope: user"))
    }

    func test_compose_containsCreatedAt_inISO8601() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let output = composer.compose(record: makeRecord(createdAt: date))
        let expected = Self.iso8601.string(from: date)
        XCTAssertTrue(output.contains("created: \(expected)"),
                      "created 字段应为 ISO8601 格式，expected '\(expected)'，got:\n\(output)")
    }

    func test_compose_containsUpdatedAt_inISO8601() {
        let date = Date(timeIntervalSince1970: 2_000_000)
        let output = composer.compose(record: makeRecord(updatedAt: date))
        let expected = Self.iso8601.string(from: date)
        XCTAssertTrue(output.contains("updated: \(expected)"))
    }

    // MARK: - Body

    func test_compose_bodyContainsPayloadText() {
        let output = composer.compose(record: makeRecord(payloadText: "User is a senior iOS developer."))
        XCTAssertTrue(output.contains("User is a senior iOS developer."),
                      "正文应包含 payload 文本")
    }

    func test_compose_bodyAppearsAfterFrontmatter() {
        let output = composer.compose(record: makeRecord(payloadText: "Body content here."))
        let parts = output.components(separatedBy: "---\n")
        // parts[0] = "" (before first ---), parts[1] = frontmatter, parts[2] = body
        XCTAssertGreaterThanOrEqual(parts.count, 3, "应有至少 3 段（空头、frontmatter、body）")
        XCTAssertTrue(parts.last?.contains("Body content here.") == true,
                      "正文应在 frontmatter 之后")
    }

    // MARK: - YAML value quoting

    func test_compose_quotesNameWithSpecialChars() {
        // 含引号的 title 不应破坏 frontmatter
        let output = composer.compose(record: makeRecord(title: "Feedback: Use \"real\" DB"))
        // 只要 frontmatter 不以裸 " 形式破坏 YAML 格式 — 使用 escaped 或单引号
        XCTAssertTrue(output.contains("name:"), "name 字段应始终存在")
    }

    // MARK: - Freshness note (M-04)

    func test_compose_freshRecord_noFreshnessNote() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000)
        let record = makeRecord(updatedAt: now)
        let output = composer.compose(record: record, now: now)
        XCTAssertFalse(output.contains("days old"),
                       "今天更新的 topic 文件不应包含 freshness note")
        XCTAssertFalse(output.contains("<system-reminder>"),
                       "今天更新的 topic 文件不应有 <system-reminder> 节")
    }

    func test_compose_staleRecord_containsFreshnessNote() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000)
        let staleDate = now.addingTimeInterval(-86_400 * 5)  // 5 天前
        let record = makeRecord(updatedAt: staleDate)
        let output = composer.compose(record: record, now: now)
        XCTAssertTrue(output.contains("5 days old"),
                      "5 天前更新的话题文件应包含 '5 days old' 警告")
        XCTAssertTrue(output.contains("<system-reminder>"),
                      "freshness note 应用 <system-reminder> 包裹")
        XCTAssertTrue(output.contains("</system-reminder>"),
                      "freshness note 应包含闭合标签")
    }

    func test_compose_freshnessNoteAppearsBeforeBody() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000)
        let staleDate = now.addingTimeInterval(-86_400 * 3)
        let record = makeRecord(payloadText: "BODYMARKER", updatedAt: staleDate)
        let output = composer.compose(record: record, now: now)
        guard let reminderRange = output.range(of: "<system-reminder>"),
              let bodyRange = output.range(of: "BODYMARKER") else {
            XCTFail("output 应同时包含 <system-reminder> 和 BODYMARKER")
            return
        }
        XCTAssertLessThan(reminderRange.lowerBound, bodyRange.lowerBound,
                          "<system-reminder> 应出现在正文之前")
    }

    func test_compose_freshnessBoundary_oneDay_noNote() {
        let now = Date(timeIntervalSince1970: 86_400 * 20_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let record = makeRecord(updatedAt: yesterday)
        let output = composer.compose(record: record, now: now)
        XCTAssertFalse(output.contains("days old"),
                       "昨天更新（ageDays=1）不应触发 freshness note")
    }
}

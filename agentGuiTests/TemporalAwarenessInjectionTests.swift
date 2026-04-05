import XCTest
import SwiftAnthropic
@testable import agentGui

final class TemporalAwarenessInjectionTests: XCTestCase {

    // MARK: - Layer 1: SystemPromptRuntimeContext temporal reasoning instruction

    func test_promptSection_containsTemporalReasoningInstruction() {
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        let section = ctx.promptSection
        XCTAssertTrue(
            section.contains("knowledge cutoff") || section.contains("训练数据截止") || section.contains("training data"),
            "promptSection 应包含 knowledge cutoff 感知指令"
        )
    }

    func test_promptSection_containsRelativeTimeAnchorInstruction() {
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        let section = ctx.promptSection
        // 应包含"最近/近期"或"recent/latest"的相对时间锚定说明
        let hasRelativeTimeInstruction =
            section.contains("最近") || section.contains("recent") ||
            section.contains("latest") || section.contains("relative")
        XCTAssertTrue(hasRelativeTimeInstruction,
                      "promptSection 应包含相对时间表达的锚定指令")
    }

    func test_promptSection_currentDateIsPresent() {
        let dateText = "2026-04-05T14:30:00+08:00"
        let ctx = SystemPromptRuntimeContext(
            currentDateTimeText: dateText,
            timezoneIdentifier: "Asia/Shanghai",
            localeIdentifier: "zh_CN",
            operatingSystemText: "macOS 15.0",
            hostName: "test-host",
            workingDirectory: "/tmp",
            workingDirectorySource: "test",
            proxySummary: nil
        )
        XCTAssertTrue(ctx.promptSection.contains(dateText),
                      "promptSection 应包含注入的日期时间文本")
    }

    // MARK: - Layer 2: temporal context preamble message

    func test_makeTemporalContextPreamble_roleIsUser() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T14:30:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertEqual(preamble.role, "user",
                       "temporal preamble 应为 user role，以模拟 <system-reminder> 前置")
    }

    func test_makeTemporalContextPreamble_containsSystemReminderTag() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T00:00:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        switch preamble.content {
        case .text(let text):
            XCTAssertTrue(text.contains("<system-reminder>"),
                          "preamble 应包含 <system-reminder> 开始标签")
            XCTAssertTrue(text.contains("</system-reminder>"),
                          "preamble 应包含 </system-reminder> 结束标签")
        default:
            XCTFail("preamble content 应为 .text")
        }
    }

    func test_makeTemporalContextPreamble_containsDateText() {
        let dateText = "2026-04-05T14:30:00+08:00"
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: dateText,
            timezoneIdentifier: "Asia/Shanghai"
        )
        switch preamble.content {
        case .text(let text):
            XCTAssertTrue(text.contains(dateText),
                          "preamble 应包含注入的日期时间文本")
        default:
            XCTFail("preamble content 应为 .text")
        }
    }

    func test_makeTemporalContextPreamble_containsRelativeTimeKeywords() {
        let preamble = SystemPromptRuntimeContext.makeTemporalContextPreamble(
            currentDateTimeText: "2026-04-05T00:00:00+08:00",
            timezoneIdentifier: "Asia/Shanghai"
        )
        switch preamble.content {
        case .text(let text):
            let hasKeywords = text.contains("最近") || text.contains("recent") || text.contains("latest")
            XCTAssertTrue(hasKeywords,
                          "preamble 应包含相对时间表达关键词以强化模型时序感知")
        default:
            XCTFail("preamble content 应为 .text")
        }
    }
}

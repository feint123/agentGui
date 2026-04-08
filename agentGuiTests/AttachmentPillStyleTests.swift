import XCTest
import SwiftUI
@testable import agentGui

final class AttachmentPillStyleTests: XCTestCase {

    // MARK: - Origin tint

    func test_originTint_project_isAccent() {
        let tint = AttachmentPillStyle.originTint(for: .project)
        XCTAssertEqual(tint, .accentColor)
    }

    func test_originTint_focused_isOrange() {
        let tint = AttachmentPillStyle.originTint(for: .focused)
        XCTAssertEqual(tint, .orange)
    }

    func test_originTint_external_isSecondary() {
        let tint = AttachmentPillStyle.originTint(for: .external)
        XCTAssertEqual(tint, .secondary)
    }

    // MARK: - Status color

    func test_statusColor_valid_matchesOriginTint() {
        let color = AttachmentPillStyle.statusColor(origin: .project, status: .valid)
        XCTAssertEqual(color, .accentColor)
    }

    func test_statusColor_modified_isYellow() {
        let color = AttachmentPillStyle.statusColor(origin: .project, status: .modified)
        XCTAssertEqual(color, .yellow)
    }

    func test_statusColor_missing_isRed() {
        let color = AttachmentPillStyle.statusColor(origin: .external, status: .missing)
        XCTAssertEqual(color, .red)
    }
}

import XCTest
@testable import agentGui

final class GitChangeBadgeDisplayTests: XCTestCase {

    func test_statusBadgeText_modified() {
        XCTAssertEqual(GitChangeStatus.modified.statusBadgeText, "M")
    }

    func test_statusBadgeText_added() {
        XCTAssertEqual(GitChangeStatus.added.statusBadgeText, "A")
    }

    func test_statusBadgeText_deleted() {
        XCTAssertEqual(GitChangeStatus.deleted.statusBadgeText, "D")
    }

    func test_statusBadgeText_renamed() {
        XCTAssertEqual(GitChangeStatus.renamed.statusBadgeText, "R")
    }

    func test_statusBadgeText_untracked() {
        XCTAssertEqual(GitChangeStatus.untracked.statusBadgeText, "??")
    }

    func test_hoverActionSymbol_staged() {
        XCTAssertEqual(GitChangeSection.staged.hoverActionSymbol, "minus.circle")
    }

    func test_hoverActionSymbol_modified() {
        XCTAssertEqual(GitChangeSection.modified.hoverActionSymbol, "plus.circle")
    }

    func test_hoverActionSymbol_untracked() {
        XCTAssertEqual(GitChangeSection.untracked.hoverActionSymbol, "plus.circle")
    }
}

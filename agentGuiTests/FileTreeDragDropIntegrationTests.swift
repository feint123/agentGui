// agentGuiTests/FileTreeDragDropIntegrationTests.swift
import XCTest
@testable import agentGui

final class FileTreeDragDropIntegrationTests: XCTestCase {

    // MARK: - FileTreeDragState 行为测试

    func testDragState_cancelHoverExpand_preventsExecution() {
        let state = FileTreeDragState()

        var aExpanded = false
        let workA = DispatchWorkItem { aExpanded = true }
        state.hoverExpandWork = workA
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workA)

        // 立即取消（模拟移到另一行）
        state.cancelHoverExpand()
        XCTAssertNil(state.hoverExpandWork, "hoverExpandWork should be nil after cancel")

        // 等 100ms 确认 A 没有展开
        let exp = expectation(description: "notExpanded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(aExpanded, "work item should have been cancelled")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testDragState_cancelEdgeScroll_stopsLoop() {
        let state = FileTreeDragState()

        var scrollCount = 0
        let work = DispatchWorkItem { scrollCount += 1 }
        state.edgeScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)

        state.cancelEdgeScroll()
        XCTAssertNil(state.edgeScrollWork, "edgeScrollWork should be nil after cancel")

        let exp = expectation(description: "notScrolled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(scrollCount, 0, "scroll should not have executed after cancel")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testDragState_deinit_cancelsBothWorks() {
        var expandCalled = false
        var scrollCalled = false

        do {
            let state = FileTreeDragState()
            state.hoverExpandWork = DispatchWorkItem { expandCalled = true }
            state.edgeScrollWork = DispatchWorkItem { scrollCalled = true }
            // state deinits here, both work items should be cancelled
        }

        let exp = expectation(description: "neitherCalled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertFalse(expandCalled, "hover expand should not execute after deinit")
            XCTAssertFalse(scrollCalled, "edge scroll should not execute after deinit")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - FileTreeDropValidator + FileTreeDropPlan 联合测试

    func testDropPlan_isMove_default() {
        let plan = FileTreeDropPlan(
            draggedIDs: [EntryID(url: URL(fileURLWithPath: "/a/b.swift"))],
            destinationID: EntryID(url: URL(fileURLWithPath: "/a/c"))
        )
        XCTAssertTrue(plan.isMove)
        XCTAssertTrue(plan.externalURLs.isEmpty)
    }

    func testDropPlan_isCopy_whenOptionSet() {
        let snapshot = MockStoreSnapshot(
            entries: [
                id("src"):  FileEntry(id: id("src"),  name: "src",  isDirectory: true,  parentID: nil),
                id("main"): FileEntry(id: id("main"), name: "main", isDirectory: true,  parentID: id("src")),
                id("App"):  FileEntry(id: id("App"),  name: "App.swift", isDirectory: false, parentID: id("main")),
                id("tests"):FileEntry(id: id("tests"),name: "tests",isDirectory: true,  parentID: id("src")),
            ],
            childrenMap: [
                id("src"):   [id("main"), id("tests")],
                id("main"):  [id("App")],
                id("tests"): [],
            ]
        )
        // isCopy = true：即使源在当前父目录下（main/），也应允许 copy
        let plan = FileTreeDropValidator.validate(
            sourceIDs: [id("App")],
            destinationID: id("tests"),
            snapshot: snapshot,
            isCopy: true
        )
        XCTAssertNotNil(plan)
        XCTAssertFalse(plan!.isMove, "isCopy=true should result in isMove=false")
    }

    func testDropPlan_externalURLs_populated() {
        let url = URL(fileURLWithPath: "/tmp/ext.txt")
        let snapshot = MockStoreSnapshot(
            entries: [id("tests"): FileEntry(id: id("tests"), name: "tests", isDirectory: true, parentID: nil)],
            childrenMap: [id("tests"): []]
        )
        let plan = FileTreeDropValidator.validateExternalDrop(
            externalURLs: [url],
            destinationID: id("tests"),
            snapshot: snapshot
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.externalURLs, [url])
        XCTAssertFalse(plan!.isMove)
    }

    // MARK: - Helpers
    private func id(_ raw: String) -> EntryID {
        EntryID(url: URL(fileURLWithPath: "/root/\(raw)"))
    }
}

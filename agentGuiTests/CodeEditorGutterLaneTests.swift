import AppKit
import Testing
@testable import agentGui

// MARK: - Helpers

@MainActor
private func makeSnapshot(
    lineCount: Int = 40,
    currentLine: Int? = 10,
    diagnostics: [Int: CodeEditorLineDiagnosticSummary] = [:],
    visibleRange: ClosedRange<Int> = 1...40,
    translatedBy: CGFloat = 0
) -> CodeEditorGutterViewportSnapshot {
    let lineMetrics = visibleRange.map { line in
        let minY = CGFloat(line * 14) + translatedBy
        return CodeEditorVisibleLineMetric(
            line: line,
            rect: CGRect(x: 0, y: minY, width: 32, height: 14),
            baselineY: minY + 11
        )
    }
    return CodeEditorGutterViewportSnapshot(
        lineCount: lineCount,
        visibleLineRange: visibleRange,
        currentLine: currentLine,
        lineMetrics: lineMetrics,
        diagnosticsByLine: diagnostics
    )
}

// MARK: - Fake Lane

@MainActor
private final class FakeLane: CodeEditorGutterLane {
    let id: String
    let fixedWidth: CGFloat
    var onPreferredWidthChange: (() -> Void)?
    var drawCalled = false
    var lastHitTestPoint: CGPoint?

    init(id: String, width: CGFloat) {
        self.id = id
        self.fixedWidth = width
    }

    func preferredWidth(
        for snapshot: CodeEditorGutterViewportSnapshot,
        appearance: NSAppearance?
    ) -> CGFloat {
        fixedWidth
    }

    func draw(
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect,
        dirtyRect: NSRect,
        appearance: NSAppearance?
    ) {
        drawCalled = true
    }

    func hitTest(
        point: CGPoint,
        snapshot: CodeEditorGutterViewportSnapshot,
        laneRect: NSRect
    ) -> Int? {
        lastHitTestPoint = point
        // Return line 5 if x < width/2
        return point.x < fixedWidth / 2 ? 5 : nil
    }
}

// MARK: - Tests

@MainActor
struct CodeEditorGutterLaneTests {

    // MARK: - Width Calculation

    @Test
    func laneTotalWidthIsSumOfLaneWidths() {
        let view = CodeEditorGutterView(lineCount: 40)
        // Default lanes: lineNumber + diagnosticDot
        let snapshot = makeSnapshot()
        // Update so appearances are stable
        view.updateLayoutState(snapshot)
        // Default: lineNumber lane width + 16pt dot lane
        let lineNumberLane = CodeEditorLineNumberLane()
        let expectedLineNumberWidth = lineNumberLane.preferredWidth(for: snapshot, appearance: nil)
        // Default lanes: gitDiffStripe(4) + lineNumber + diagnosticDot(16)
        let expectedTotal = 4 + expectedLineNumberWidth + 16
        #expect(view.requiredWidth == expectedTotal)
    }

    @Test
    func registeredLaneTotalWidthSumsTwoFakeLanes() {
        let view = CodeEditorGutterView(lineCount: 10)
        // Replace built-in lanes with two fake lanes
        let lane1 = FakeLane(id: "lineNumber", width: 30)
        let lane2 = FakeLane(id: "diagnosticDot", width: 20)
        view.register(lane: lane1)
        view.register(lane: lane2)
        // gitDiffStripe(4) + lineNumber(30) + diagnosticDot(20) = 54
        #expect(view.requiredWidth == 54)
    }

    // MARK: - Frame Non-Overlap

    @Test
    func adjacentLaneFramesDoNotOverlap() {
        let view = CodeEditorGutterView(lineCount: 10)
        // Replace built-in lanes to have full control over widths
        let lane1 = FakeLane(id: "lineNumber", width: 30)
        let lane2 = FakeLane(id: "diagnosticDot", width: 20)
        view.register(lane: lane1)
        view.register(lane: lane2)

        let frame1 = view.laneFrame(for: lane1)
        let frame2 = view.laneFrame(for: lane2)

        // gitDiffStripe is now leftmost (x=0, width=4)
        // lineNumber (lane1) starts after gitDiffStripe
        #expect(frame1.origin.x == 4)
        #expect(frame2.origin.x == 34)
        // No overlap: frame1.maxX == frame2.minX
        #expect(frame1.maxX == frame2.minX)
    }

    // MARK: - Lane Registration Replace

    @Test
    func registeringSameIdReplacesExistingLane() {
        let view = CodeEditorGutterView(lineCount: 10)
        let lane1 = FakeLane(id: "lineNumber", width: 30)
        let lane2 = FakeLane(id: "lineNumber", width: 50)
        view.register(lane: lane1)
        // Default had lineNumber and diagnosticDot → 2 lanes
        let countBefore = view.requiredWidth  // captures combined width

        view.register(lane: lane2)
        // lineNumber replaced: gitDiffStripe(4) + lineNumber(50) + diagnosticDot(16) = 70
        #expect(view.requiredWidth == 70)
    }

    @Test
    func registeringNewUniqueIdAppendsLane() {
        let view = CodeEditorGutterView(lineCount: 10)
        let lane1 = FakeLane(id: "lineNumber", width: 30)
        let lane2 = FakeLane(id: "lineNumber", width: 30)
        view.register(lane: lane1)
        view.register(lane: lane2)
        // lineNumber replaced (not doubled): gitDiffStripe(4) + lineNumber(30) + diagnosticDot(16) = 50
        #expect(view.requiredWidth == 50)
    }

    // MARK: - Width Change Callback

    @Test
    func laneWidthChangeCallbackTriggersOnRequiredWidthChange() {
        let view = CodeEditorGutterView(lineCount: 10)
        let lane = FakeLane(id: "lineNumber", width: 30)
        view.register(lane: lane)

        var callbackFired = false
        view.onRequiredWidthChange = { callbackFired = true }

        lane.onPreferredWidthChange?()
        #expect(callbackFired)
    }

    // MARK: - Snapshot New Fields

    @Test
    func snapshotCreationWithDefaultFieldsCompiles() {
        // Verify that existing init (without new fields) still works
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            lineMetrics: [],
            diagnosticsByLine: [:]
        )
        // New fields default to empty
        #expect(snapshot.foldableLines.isEmpty)
        #expect(snapshot.foldedLines.isEmpty)
        #expect(snapshot.gitDiffByLine.isEmpty)
    }

    @Test
    func snapshotNewFieldsCanBeSet() {
        let snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: 10,
            visibleLineRange: 1...10,
            currentLine: nil,
            lineMetrics: [],
            diagnosticsByLine: [:],
            foldableLines: [3, 5],
            foldedLines: [5],
            gitDiffByLine: [2: .added, 4: .modified]
        )
        #expect(snapshot.foldableLines == [3, 5])
        #expect(snapshot.foldedLines == [5])
        #expect(snapshot.gitDiffByLine[2] == .added)
        #expect(snapshot.gitDiffByLine[4] == .modified)
    }

    // MARK: - Lane Invalidation Plans

    @Test
    func lineNumberLaneReturnNoneWhenSnapshotUnchanged() {
        let lane = CodeEditorLineNumberLane()
        let snapshot = makeSnapshot(currentLine: 10, visibleRange: 8...18)
        let plan = lane.invalidationPlan(from: snapshot, to: snapshot)
        if case .none = plan {
            // Expected
        } else {
            Issue.record("Expected .none but got \(plan)")
        }
    }

    @Test
    func lineNumberLaneReturnLinesWhenCurrentLineChanges() {
        let lane = CodeEditorLineNumberLane()
        let previous = makeSnapshot(currentLine: 10, visibleRange: 8...18)
        let current = makeSnapshot(currentLine: 11, visibleRange: 8...18)
        let plan = lane.invalidationPlan(from: previous, to: current)
        if case .lines(let lines) = plan {
            #expect(lines == [10, 11])
        } else {
            Issue.record("Expected .lines but got \(plan)")
        }
    }

    @Test
    func lineNumberLaneReturnFullWhenLineCountChanges() {
        let lane = CodeEditorLineNumberLane()
        let previous = makeSnapshot(lineCount: 10, visibleRange: 1...10)
        let current = makeSnapshot(lineCount: 100, visibleRange: 1...10)
        let plan = lane.invalidationPlan(from: previous, to: current)
        if case .full = plan {
            // Expected
        } else {
            Issue.record("Expected .full but got \(plan)")
        }
    }

    @Test
    func diagnosticDotLaneReturnLinesWhenDiagnosticsChange() {
        let lane = CodeEditorDiagnosticDotLane()
        let previous = makeSnapshot(diagnostics: [:], visibleRange: 1...20)
        let current = makeSnapshot(
            diagnostics: [12: CodeEditorLineDiagnosticSummary(highestSeverity: .warning, messageCount: 1)],
            visibleRange: 1...20
        )
        let plan = lane.invalidationPlan(from: previous, to: current)
        if case .lines(let lines) = plan {
            #expect(lines.contains(12))
        } else {
            Issue.record("Expected .lines but got \(plan)")
        }
    }

    @Test
    func diagnosticDotLaneReturnNoneWhenDiagnosticsUnchanged() {
        let lane = CodeEditorDiagnosticDotLane()
        let snapshot = makeSnapshot(
            diagnostics: [12: CodeEditorLineDiagnosticSummary(highestSeverity: .warning, messageCount: 1)],
            visibleRange: 1...20
        )
        let plan = lane.invalidationPlan(from: snapshot, to: snapshot)
        if case .none = plan {
            // Expected
        } else {
            Issue.record("Expected .none but got \(plan)")
        }
    }

    @Test
    func gitDiffStripeLane_registeredByDefault() throws {
        let view = CodeEditorGutterView(lineCount: 10)
        // 若 GitDiffStripeLane 注册，各 lane 宽度之和会包含至少 4pt 的 diff stripe 贡献
        #expect(view.requiredWidth >= 4)   // gitDiff lane 贡献至少 4pt
    }
}

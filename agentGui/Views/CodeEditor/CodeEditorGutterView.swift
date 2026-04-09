import AppKit

struct CodeEditorGutterInvalidationSummary: Equatable {
    let redrawnLines: [Int]
    let usedFullRedraw: Bool
}

final class CodeEditorGutterView: NSView {

    // MARK: - Lane Host State

    /// Ordered lane array (display order = array order, left → right)
    private var lanes: [any CodeEditorGutterLane] = []

    /// Each lane's x-offset in the current layout, keyed by lane.id
    private var laneOffsets: [String: CGFloat] = [:]

    // MARK: - Legacy Scroll Detection (removed)

    /// Retained only for redraw-plan detection.
    /// Scroll plans are no longer used; bounds-origin sync handles scrolling.
    private var renderer = CodeEditorGutterRenderer()

    // MARK: - Snapshot & Metrics

    private var snapshot: CodeEditorGutterViewportSnapshot
    private var lineMetricsByLine: [Int: CodeEditorVisibleLineMetric]

    // MARK: - Callbacks

    var onRequiredWidthChange: (() -> Void)?
    var onGutterLaneHit: ((CodeEditorGutterHitResult) -> Void)?

    // MARK: - Invalidation Summary (for tests)

    private(set) var lastInvalidationSummary: CodeEditorGutterInvalidationSummary?

    // MARK: - Computed Properties

    var lineCount: Int { snapshot.lineCount }
    var visibleLineRange: ClosedRange<Int> { snapshot.visibleLineRange }
    var currentLine: Int? { snapshot.currentLine }
    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] { snapshot.diagnosticsByLine }
    var lineMetrics: [CodeEditorVisibleLineMetric] { snapshot.lineMetrics }

    /// Total gutter width = sum of all lane preferred widths.
    var requiredWidth: CGFloat {
        lanes.reduce(0) { $0 + $1.preferredWidth(for: snapshot, appearance: effectiveAppearance) }
    }

    override var isFlipped: Bool { true }

    // MARK: - Init

    init(lineCount: Int) {
        let initialLineCount = max(lineCount, 1)
        self.snapshot = CodeEditorGutterViewportSnapshot(
            lineCount: initialLineCount,
            visibleLineRange: 1...initialLineCount,
            currentLine: nil,
            lineMetrics: [],
            diagnosticsByLine: [:]
        )
        self.lineMetricsByLine = [:]
        super.init(frame: .zero)

        // Register built-in lanes (left → right order)
        register(lane: GitDiffStripeLane())
        register(lane: AgentDiffStripeLane())
        register(lane: CodeEditorLineNumberLane())
        register(lane: CodeEditorDiagnosticDotLane())
        register(lane: ChangeReviewActionLane())
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lane Registration

    /// Register a lane (ordered by call sequence, left → right).
    /// Registering a lane with a duplicate id replaces the existing lane.
    func register(lane: any CodeEditorGutterLane) {
        lane.onPreferredWidthChange = { [weak self] in
            self?.handleLaneWidthChange()
        }
        if let idx = lanes.firstIndex(where: { $0.id == lane.id }) {
            lanes[idx] = lane
        } else {
            lanes.append(lane)
        }
        handleLaneWidthChange()
    }

    // MARK: - Lane Layout

    /// Returns the full-height frame for the given lane in gutter coordinates.
    /// With bounds-origin scroll sync, the visible region is
    /// [bounds.origin.y, bounds.origin.y + bounds.height).
    func laneFrame(for lane: any CodeEditorGutterLane) -> NSRect {
        let x = laneOffsets[lane.id, default: 0]
        let w = lane.preferredWidth(for: snapshot, appearance: effectiveAppearance)
        return NSRect(x: x, y: bounds.origin.y, width: w, height: bounds.height)
    }

    private func recalculateLaneLayout() {
        var x: CGFloat = 0
        for lane in lanes {
            laneOffsets[lane.id] = x
            x += lane.preferredWidth(for: snapshot, appearance: effectiveAppearance)
        }
    }

    private func handleLaneWidthChange() {
        recalculateLaneLayout()
        invalidateIntrinsicContentSize()
        onRequiredWidthChange?()
        setNeedsDisplay(bounds)
    }

    // MARK: - updateLayoutState

    func updateLayoutState(_ snapshot: CodeEditorGutterLineMetricsSnapshot) {
        if snapshot.lineMetrics.isEmpty, self.snapshot.lineMetrics.isEmpty == false {
            return
        }

        let previousSnapshot = self.snapshot
        let previousWidth = requiredWidth

        self.snapshot = snapshot
        self.lineMetricsByLine = Dictionary(uniqueKeysWithValues: snapshot.lineMetrics.map { ($0.line, $0) })

        recalculateLaneLayout()
        let nextWidth = requiredWidth

        if previousWidth != nextWidth {
            invalidateIntrinsicContentSize()
            onRequiredWidthChange?()
        }

        // Determine what changed between snapshots and invalidate accordingly.
        // With bounds-origin scroll sync, metrics use document coordinates,
        // so a pure scroll produces no metric changes for overlapping lines
        // and the renderer naturally emits a .redraw for new/removed lines.
        let hostPlan = renderer.invalidationPlan(from: previousSnapshot, to: snapshot)
        applyHostPlan(hostPlan, previousSnapshot: previousSnapshot)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        // Dispatch drawing to each lane
        for lane in lanes {
            let frame = laneFrame(for: lane)
            guard frame.intersects(dirtyRect) else { continue }
            lane.draw(snapshot: snapshot, laneRect: frame, dirtyRect: dirtyRect, appearance: effectiveAppearance)
        }
    }

    // MARK: - Hit Testing

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for lane in lanes {
            let frame = laneFrame(for: lane)
            guard frame.contains(point) else { continue }
            let localPoint = CGPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y)
            if let lineNumber = lane.hitTest(point: localPoint, snapshot: snapshot, laneRect: frame) {
                onGutterLaneHit?(CodeEditorGutterHitResult(lineNumber: lineNumber, laneID: lane.id))
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Public

    func clearLastInvalidationSummary() {
        lastInvalidationSummary = nil
    }

    // MARK: - Private

    private func applyHostPlan(
        _ plan: CodeEditorGutterInvalidationPlan,
        previousSnapshot: CodeEditorGutterViewportSnapshot
    ) {
        switch plan {
        case .full:
            needsDisplay = true
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: Array(visibleLineRange),
                usedFullRedraw: true
            ))

        case let .redraw(lines, _):
            // Use per-lane invalidation for precision
            applyLaneInvalidation(from: previousSnapshot)
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: lines.sorted(),
                usedFullRedraw: false
            ))

        case let .scroll(_, exposedLines, redrawLines, _):
            // With bounds-origin scroll sync, the gutter no longer needs
            // the legacy scrollRect:by: pixel-copy optimization (which is
            // broken on layer-backed views).  Simply redraw changed lines.
            let allLines = exposedLines.union(redrawLines)
            if allLines.isEmpty {
                needsDisplay = true
            } else {
                for line in allLines {
                    invalidateLine(line)
                }
            }
            recordInvalidationSummary(CodeEditorGutterInvalidationSummary(
                redrawnLines: allLines.sorted(),
                usedFullRedraw: allLines.isEmpty
            ))
        }
    }

    private func applyLaneInvalidation(from previousSnapshot: CodeEditorGutterViewportSnapshot) {
        for lane in lanes {
            switch lane.invalidationPlan(from: previousSnapshot, to: snapshot) {
            case .full:
                setNeedsDisplay(laneFrame(for: lane))
            case .lines(let lines):
                for line in lines {
                    guard let m = lineMetricsByLine[line] else { continue }
                    let frame = laneFrame(for: lane)
                    let lineInLane = NSRect(
                        x: frame.origin.x,
                        y: m.rect.minY,
                        width: frame.width,
                        height: m.rect.height
                    ).integral
                    setNeedsDisplay(lineInLane)
                }
            case .none:
                break
            }
        }
    }

    private func recordInvalidationSummary(_ summary: CodeEditorGutterInvalidationSummary) {
        guard let previous = lastInvalidationSummary else {
            lastInvalidationSummary = summary
            return
        }

        if summary.usedFullRedraw {
            lastInvalidationSummary = summary
            return
        }

        if summary.redrawnLines.isEmpty {
            return
        }

        let mergedLines = Array(Set(previous.redrawnLines).union(summary.redrawnLines)).sorted()
        lastInvalidationSummary = CodeEditorGutterInvalidationSummary(
            redrawnLines: mergedLines,
            usedFullRedraw: previous.usedFullRedraw || summary.usedFullRedraw
        )
    }

    private func invalidateLine(_ line: Int) {
        guard let metric = lineMetricsByLine[line] else { return }
        let rect = NSRect(x: 0, y: metric.rect.minY, width: requiredWidth, height: metric.rect.height).integral
        setNeedsDisplay(rect)
    }
}
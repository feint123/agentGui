import AppKit
import Foundation
import Testing
@testable import agentGui

struct CodeEditorHighlightPipelineTests {
    @Test
    func viewportRequestExpandsToRetainedWindowAndClampsToDocumentBounds() {
        let document = CodeEditorDocument(
            text: Array(repeating: "line", count: 20).joined(separator: "\n"),
            persistedText: ""
        )
        let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 3)

        let request = pipeline.makeViewportRequest(
            document: document,
            language: "swift",
            visibleLineRange: 5...8,
            dirtyLineRange: 7...7,
            appearance: .light,
            fontSize: 13
        )

        #expect(request.retainedLineRange == 2...11)
        #expect(request.dirtyLineRange == 7...7)
        #expect(request.version == document.version)
    }

    @MainActor
    @Test
    func highlightVisibleWindowReturnsLineFragmentsForRequestedLines() {
        let engine = RecordingHighlightEngine()
        let highlighter = CodeSyntaxHighlightingService(engine: engine)
        let document = CodeEditorDocument(
            text: "one\ntwo\nthree\nfour",
            persistedText: "one\ntwo\nthree\nfour"
        )
        let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 0)
        let request = pipeline.makeViewportRequest(
            document: document,
            language: "swift",
            visibleLineRange: 2...3,
            dirtyLineRange: 2...3,
            appearance: .light,
            fontSize: 13
        )

        let result = pipeline.highlight(request: request, document: document, highlighter: highlighter)

        #expect(result?.lineFragments.map(\.line) == [2, 3])
        #expect(result?.lineFragments.map(\.utf16Range) == [NSRange(location: 4, length: 4), NSRange(location: 8, length: 5)])
        #expect(result?.lineFragments.map(\.attributedString.string) == ["two\n", "three"])
        #expect(result?.lineFragments.allSatisfy { $0.fingerprint != 0 } == true)
    }

    @Test
    func schedulerOnlyPublishesNewestVersionResult() async {
        let scheduler = CodeEditorHighlightScheduler()
        let recorder = PublishedVersionsRecorder()

        await scheduler.schedule(
            .init(request: makeRequest(version: 1), textSnapshot: "old"),
            debounceNanoseconds: 50_000_000,
            execute: { work in
                try? await Task.sleep(nanoseconds: 80_000_000)
                return CodeEditorHighlightResult(
                    version: work.request.version,
                    lineRange: 1...1,
                    lineFragments: [
                        CodeEditorStyledLineFragment(
                            line: 1,
                            utf16Range: NSRange(location: 0, length: 3),
                            attributedString: NSAttributedString(string: work.textSnapshot),
                            fingerprint: 11
                        )
                    ]
                )
            },
            onResult: { result in
                await recorder.record(version: result.version)
            }
        )

        await scheduler.schedule(
            .init(request: makeRequest(version: 2), textSnapshot: "new"),
            debounceNanoseconds: 0,
            execute: { work in
                CodeEditorHighlightResult(
                    version: work.request.version,
                    lineRange: 1...1,
                    lineFragments: [
                        CodeEditorStyledLineFragment(
                            line: 1,
                            utf16Range: NSRange(location: 0, length: 3),
                            attributedString: NSAttributedString(string: work.textSnapshot),
                            fingerprint: 22
                        )
                    ]
                )
            },
            onResult: { result in
                await recorder.record(version: result.version)
            }
        )

        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(await recorder.versions() == [2])
    }

    @Test
    func pipelineSkipsHighlightWhenRequestedWindowExceedsLargeFileThreshold() {
        let pipeline = CodeEditorHighlightPipeline(retainedLinePadding: 120, realtimeHighlightLineLimit: 2000)
        let document = CodeEditorDocument(
            text: Array(repeating: "x", count: 5000).joined(separator: "\n"),
            persistedText: ""
        )

        let request = pipeline.makeViewportRequest(
            document: document,
            language: "swift",
            visibleLineRange: 2500...2600,
            dirtyLineRange: 2500...2600,
            appearance: .light,
            fontSize: 13
        )

        #expect(pipeline.shouldSkipRealtimeHighlight(for: request, document: document))
    }
}

private final class RecordingHighlightEngine: CodeSyntaxHighlightingEngine {
    func highlight(
        code: String,
        language: String?,
        theme: CodeHighlightTheme
    ) -> NSAttributedString? {
        NSAttributedString(string: code)
    }
}

private actor PublishedVersionsRecorder {
    private var publishedVersions: [Int] = []

    func record(version: Int) {
        publishedVersions.append(version)
    }

    func versions() -> [Int] {
        publishedVersions
    }
}

private func makeRequest(version: Int) -> CodeEditorHighlightRequest {
    CodeEditorHighlightRequest(
        version: version,
        language: "swift",
        visibleLineRange: 1...1,
        retainedLineRange: 1...1,
        dirtyLineRange: 1...1,
        priority: .viewportImmediate,
        appearance: .light,
        fontSize: 13
    )
}
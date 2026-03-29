import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct CodeEditorViewIntegrationTests {
    @Test
    func userEditForwardsTextChangeToHost() {
        let harness = CodeEditorViewHarness(initialText: "", persistedText: "")

        harness.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")

        #expect(harness.lastForwardedText == "hello")
        #expect(harness.lastChange?.insertedText == "hello")
        #expect(harness.changeSetCount == 1)
    }

    @Test
    func reloadFromDiskReplacesEditorContentWithoutEchoingUserChange() {
        let harness = CodeEditorViewHarness(initialText: "old", persistedText: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "fresh", persistedText: "fresh")

        #expect(harness.visibleText == "fresh")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChange == nil)
    }

    @Test
    func persistedTextCleanSyncDoesNotEmitUserChange() {
        let harness = CodeEditorViewHarness(initialText: "draft", persistedText: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "draft", persistedText: "draft")

        #expect(harness.visibleText == "draft")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChange == nil)
    }

    @Test
    func focusRequestMakesTextViewFirstResponder() {
        let harness = CodeEditorViewHarness(initialText: "hello", persistedText: "hello")

        harness.requestFocus()

        #expect(harness.window.firstResponder === harness.textView)
    }
}

@MainActor
private final class CodeEditorViewHarness {
    final class Recorder {
        var lastSelection: EditorSelectionSnapshot?
        var lastChange: EditorChangeSet?
        var lastForwardedText: String?
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var persistedText: String
        @Published var focusToken: UUID?

        init(text: String, persistedText: String) {
            self.text = text
            self.persistedText = persistedText
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    let window: NSWindow
    private let hostingView: NSHostingView<HostView>

    init(initialText: String, persistedText: String) {
        let storage = Storage(text: initialText, persistedText: persistedText)
        self.storage = storage
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            onSelectionChange: { snapshot in
                recorder.lastSelection = snapshot
            },
            onTextChange: { text, change in
                recorder.lastForwardedText = text
                recorder.lastChange = change
                recorder.changeSetCount += 1
            }
        )

        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)

        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pumpRunLoop()
    }

    deinit {
        Task { @MainActor [window] in
            window.orderOut(nil)
        }
    }

    var textView: NSTextView {
        guard let textView = findTextView(in: hostingView) else {
            fatalError("CodeEditorViewHarness could not find NSTextView")
        }
        return textView
    }

    var visibleText: String {
        textView.string
    }

    var lastSelection: EditorSelectionSnapshot? {
        recorder.lastSelection
    }

    var lastChange: EditorChangeSet? {
        recorder.lastChange
    }

    var lastForwardedText: String? {
        recorder.lastForwardedText
    }

    var changeSetCount: Int {
        recorder.changeSetCount
    }

    func updateFromHost(text: String, persistedText: String) {
        storage.text = text
        storage.persistedText = persistedText
        pumpRunLoop()
    }

    func replaceCharacters(in range: NSRange, with replacement: String) {
        let textView = textView
        guard let storage = textView.textStorage else {
            fatalError("CodeEditorViewHarness missing text storage")
        }

        let selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textView.setSelectedRange(range)
        _ = textView.shouldChangeText(in: range, replacementString: replacement)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
        textView.didChangeText()
        pumpRunLoop()
        pumpRunLoop()
    }

    func requestFocus() {
        storage.focusToken = UUID()
        pumpRunLoop()
    }

    func clearRecordedCallbacks() {
        recorder.lastSelection = nil
        recorder.lastChange = nil
        recorder.lastForwardedText = nil
        recorder.changeSetCount = 0
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }
}

private struct HostView: View {
    @ObservedObject var storage: CodeEditorViewHarness.Storage
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onTextChange: (String, EditorChangeSet) -> Void

    var body: some View {
        CodeEditorView(
            text: $storage.text,
            persistedText: storage.persistedText,
            fileURL: URL(fileURLWithPath: "/tmp/CodeEditorViewHarness.swift"),
            focusRequest: storage.focusToken,
            onSelectionChange: onSelectionChange,
            onTextChange: onTextChange
        )
        .frame(width: 480, height: 320)
    }
}
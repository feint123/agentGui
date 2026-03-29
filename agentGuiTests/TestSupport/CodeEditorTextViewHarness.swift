import AppKit
import Combine
import SwiftUI
@testable import agentGui

@MainActor
final class CodeEditorTextViewHarness {
    final class Recorder {
        var lastChangeSet: EditorChangeSet?
        var lastSelection: EditorSelectionSnapshot?
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var document: CodeEditorDocument

        init(text: String, persistedText: String) {
            self.text = text
            self.document = CodeEditorDocument(text: text, persistedText: persistedText)
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    private let window: NSWindow
    private let hostingView: NSHostingView<HostView>

    init(text: String, persistedText: String? = nil) {
        let persistedText = persistedText ?? text
        let storage = Storage(text: text, persistedText: persistedText)
        self.storage = storage
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            onSelectionChange: { snapshot in
                recorder.lastSelection = snapshot
            },
            onChangeSet: { change in
                recorder.lastChangeSet = change
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

    var boundText: String {
        storage.text
    }

    var lastChangeSet: EditorChangeSet? {
        recorder.lastChangeSet
    }

    var lastSelection: EditorSelectionSnapshot? {
        recorder.lastSelection
    }

    var changeSetCount: Int {
        recorder.changeSetCount
    }

    var document: CodeEditorDocument {
        storage.document
    }

    var textView: NSTextView {
        guard let textView = findTextView(in: hostingView) else {
            fatalError("CodeEditorTextViewHarness could not find NSTextView")
        }
        return textView
    }

    func replaceCharacters(in range: NSRange, with replacement: String) {
        let textView = textView
        guard let storage = textView.textStorage else {
            fatalError("CodeEditorTextViewHarness missing text storage")
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
    }

    func select(range: NSRange) {
        let textView = textView
        textView.setSelectedRange(range)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        waitUntil(timeoutSteps: 20) { recorder.lastSelection != nil }
    }

    func updateFromHost(text: String, persistedText: String? = nil) {
        storage.text = text
        storage.document = CodeEditorDocument(text: text, persistedText: persistedText ?? text, version: storage.document.version)
        pumpRunLoop()
    }

    func clearRecordedCallbacks() {
        recorder.lastChangeSet = nil
        recorder.lastSelection = nil
        recorder.changeSetCount = 0
    }

    func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func waitUntil(timeoutSteps: Int, condition: () -> Bool) {
        for _ in 0..<timeoutSteps {
            if condition() {
                return
            }
            pumpRunLoop()
        }
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
    @ObservedObject var storage: CodeEditorTextViewHarness.Storage
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onChangeSet: (EditorChangeSet) -> Void

    var body: some View {
        CodeEditorTextView(
            text: $storage.text,
            document: $storage.document,
            onSelectionChange: onSelectionChange,
            onChangeSet: onChangeSet
        )
        .frame(width: 480, height: 320)
    }
}
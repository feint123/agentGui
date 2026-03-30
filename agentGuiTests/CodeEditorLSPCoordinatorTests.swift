import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorLSPCoordinatorTests {
    @Test
    func activateSendsOpenDocumentOnce() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 30_000_000
        )

        coordinator.activate(initialText: "let value = 1", version: 0)
        coordinator.activate(initialText: "let value = 1", version: 0)

        #expect(harness.documentLifecycleEvents == ["open:file:///tmp/Sample.py"])
        #expect(harness.lastClientDocumentSnapshot?.text == "let value = 1")
        #expect(harness.lastClientDocumentSnapshot?.version == 1)
    }

    @Test
    func rapidTypingSendsOnlyLatestDocumentVersion() async {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try? await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 30_000_000
        )

        coordinator.activate(initialText: "let value = 1", version: 0)
        coordinator.handleTextChange(
            text: "let value = 2",
            change: EditorChangeSet(
                version: 1,
                replacedRange: NSRange(location: 12, length: 1),
                insertedText: "2",
                selectedRange: NSRange(location: 13, length: 0),
                origin: .userEdit
            )
        )
        coordinator.handleTextChange(
            text: "let value = 3",
            change: EditorChangeSet(
                version: 2,
                replacedRange: NSRange(location: 12, length: 1),
                insertedText: "3",
                selectedRange: NSRange(location: 13, length: 0),
                origin: .userEdit
            )
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(harness.documentLifecycleEvents.contains("open:file:///tmp/Sample.py"))
        #expect(harness.documentLifecycleEvents.last == "change:file:///tmp/Sample.py")
        #expect(harness.lastClientDocumentSnapshot?.text == "let value = 3")
        #expect(harness.lastClientDocumentSnapshot?.version == 2)
    }

    @Test
    func deactivateCancelsPendingChangeAndClosesDocument() async {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try? await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 200_000_000
        )

        coordinator.activate(initialText: "a", version: 0)
        coordinator.handleTextChange(
            text: "ab",
            change: EditorChangeSet(
                version: 1,
                replacedRange: NSRange(location: 1, length: 0),
                insertedText: "b",
                selectedRange: NSRange(location: 2, length: 0),
                origin: .userEdit
            )
        )
        coordinator.deactivate()

        try? await Task.sleep(nanoseconds: 260_000_000)

        let changeEvents = harness.documentLifecycleEvents.filter { $0 == "change:file:///tmp/Sample.py" }
        #expect(changeEvents.isEmpty)
        #expect(harness.documentLifecycleEvents.last == "close:file:///tmp/Sample.py")
    }

    @Test
    func unversionedDiagnosticsRemainVisibleForOpenDocument() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 30_000_000
        )

        coordinator.activate(initialText: "print('hi')", version: 0)

        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.py",
            diagnostics: [.init(message: "warning", severity: .warning, line: 0, character: 0)]
        )

        #expect(coordinator.acceptsDiagnostics(snapshot))
    }

    @Test
    func staleVersionedDiagnosticsAreRejectedAfterNewerSend() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 30_000_000
        )

        coordinator.activate(initialText: "a", version: 0)
        coordinator.handleTextChange(
            text: "ab",
            change: EditorChangeSet(
                version: 1,
                replacedRange: NSRange(location: 1, length: 0),
                insertedText: "b",
                selectedRange: NSRange(location: 2, length: 0),
                origin: .userEdit
            )
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        let stale = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.py",
            diagnostics: [.init(message: "old", severity: .warning, line: 0, character: 0)],
            documentVersion: 0
        )
        let current = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.py",
            diagnostics: [.init(message: "new", severity: .warning, line: 0, character: 0)],
            documentVersion: 1
        )

        #expect(coordinator.acceptsDiagnostics(stale) == false)
        #expect(coordinator.acceptsDiagnostics(current))
    }

    @Test
    func activateWithNonZeroVersionRejectsOlderDiagnostics() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 30_000_000
        )

        coordinator.activate(initialText: "abc", version: 3)

        let stale = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.py",
            diagnostics: [.init(message: "old", severity: .warning, line: 0, character: 0)],
            documentVersion: 2
        )
        let current = LSPDiagnosticsSnapshot(
            workspaceRoot: "/tmp",
            uri: "file:///tmp/Sample.py",
            diagnostics: [.init(message: "current", severity: .warning, line: 0, character: 0)],
            documentVersion: 3
        )

        #expect(coordinator.acceptsDiagnostics(stale) == false)
        #expect(coordinator.acceptsDiagnostics(current))
    }

    @Test
    func staleHoverResultIsDiscardedAfterNewerVersionArrives() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        var delivered: [CodeEditorHoverPresentation?] = []
        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) {
            delivered.append($0)
        }

        coordinator.handleTextChange(
            text: "value2",
            change: EditorChangeSet(
                version: 2,
                replacedRange: NSRange(location: 5, length: 0),
                insertedText: "2",
                selectedRange: NSRange(location: 6, length: 0),
                origin: .userEdit
            )
        )

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(delivered.allSatisfy { $0 == nil })
    }

    @Test
    func latestHoverRequestCancelsOlderPendingHoverTask() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        var delivered: [CodeEditorHoverPresentation?] = []
        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 200_000_000
        ) {
            delivered.append($0)
        }
        coordinator.scheduleHover(
            at: .init(line: 1, column: 2, utf16Offset: 1, version: 1),
            debounceNanoseconds: 5_000_000
        ) {
            delivered.append($0)
        }

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(delivered.count == 1)
        #expect(delivered.first??.markdown == "Demo hover")
        #expect(delivered.first??.position == .init(line: 1, column: 2, utf16Offset: 1, version: 1))
    }

    @Test
    func definitionRequestMapsLocalLocationToRevealRequest() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        let revealRequest = await coordinator.requestDefinition(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1)
        )

        #expect(revealRequest?.fileURL == URL(fileURLWithPath: "/tmp/Sample.py"))
        #expect(revealRequest?.line == 1)
        #expect(revealRequest?.column == 1)
        #expect(revealRequest?.reason == .definition)
    }

    @Test
    func referencesRequestMapsLocationsIntoPresentation() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        let presentation = await coordinator.requestReferences(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1)
        )

        #expect(presentation?.queryPosition == .init(line: 1, column: 1, utf16Offset: 0, version: 1))
        #expect(presentation?.items.count == 2)
        #expect(presentation?.items.first?.fileURL == URL(fileURLWithPath: "/tmp/Sample.py"))
        #expect(presentation?.items.last?.line == 5)
        #expect(presentation?.items.last?.column == 3)
    }

    @Test
    func documentSymbolsReturnEmptyAfterCoordinatorDeactivation() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)
        coordinator.deactivate()

        let symbols = await coordinator.requestDocumentSymbols(documentVersion: 1)

        #expect(symbols.isEmpty)
    }
}

private extension CodeEditorLSPDocumentBinding {
    static func fixtureSourceFile() -> CodeEditorLSPDocumentBinding {
        CodeEditorLSPDocumentBinding(
            workspaceRoot: "/tmp",
            serverID: "python-lsp",
            uri: "file:///tmp/Sample.py",
            languageID: "python"
        )
    }
}
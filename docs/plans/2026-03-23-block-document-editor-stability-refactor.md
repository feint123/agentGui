# BlockDocumentEditor Stability Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Eliminate the BlockDocumentEditor freeze caused by SwiftUI preference feedback loops by restructuring geometry collection, marquee selection orchestration, and editor interaction state so the editor remains responsive under drag selection and large documents.

**Architecture:** Replace the current view-driven feedback loop with a small set of pure coordination components: one for row-frame collection, one for marquee selection reduction, and one for editor interaction state transitions. Keep BlockDocumentEditor focused on composition, move high-frequency logic into testable pure types, and delete duplicated helpers that still live in the view layer after earlier runtime extraction.

**Tech Stack:** Swift 6, SwiftUI, AppKit bridge, Swift Testing

---

## Non-Goals

- Do not change block markdown semantics.
- Do not redesign block rendering styles.
- Do not add new editor features while fixing this regression.

## Success Criteria

- Drag-selecting blocks no longer emits repeated bound preference warnings during normal interaction.
- BlockDocumentEditor does not freeze when marquee selection crosses many blocks.
- Row frame collection happens only when selection hit-testing needs it.
- High-frequency interaction paths avoid redundant state writes.
- Duplicated helper logic is removed from BlockDocumentEditor when runtime-layer equivalents already exist.
- Unit tests cover the new geometry and marquee coordination logic.
- Existing undo and selection behavior remains intact.

## Files In Scope

**Modify:**
- `agentGui/Views/Editor/BlockDocumentEditor.swift`
- `agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift`
- `agentGui/Views/Editor/BlockRowView.swift`
- `agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift`
- `agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`

**Create:**
- `agentGui/Views/Editor/BlockEditorRowFrameSnapshot.swift`
- `agentGui/Views/Editor/BlockEditorMarqueeSelectionController.swift`
- `agentGuiTests/BlockEditorRowFrameSnapshotTests.swift`
- `agentGuiTests/BlockEditorMarqueeSelectionControllerTests.swift`

**Likely Cleanup Targets:**
- `agentGui/Views/Editor/BlockDocumentEditor.swift` unused helper section near the file tail
- `agentGui/Views/Editor/BlockEditorMutationDriver.swift` verify canonical helper ownership

**Verify Against Existing Tests:**
- `agentGuiTests/BlockDocumentEditorUndoTests.swift`
- `agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`

### Task 1: Freeze The Regression With Tests

**Files:**
- Modify: `agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`
- Create: `agentGuiTests/BlockEditorMarqueeSelectionControllerTests.swift`
- Create: `agentGuiTests/BlockEditorRowFrameSnapshotTests.swift`

**Step 1: Write failing tests for redundant marquee updates**

Add tests that prove the controller returns `nil` or an equivalent no-op result when:

- the marquee moves but selected block IDs do not change
- the primary block does not change
- the geometry snapshot is identical to the previous snapshot

Example test skeleton:

```swift
@Test func marqueeMoveThatDoesNotChangeHitSetProducesNoStateMutation() {
    let ids = [UUID(), UUID()]
    let snapshot = BlockEditorRowFrameSnapshot(frames: [
        ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
        ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40)
    ])
    let controller = BlockEditorMarqueeSelectionController()
    let base = BlockEditorBlockSelectionState.empty

    let first = controller.reduce(
        baseState: base,
        currentState: base,
        orderedBlockIDs: ids,
        rowFrames: snapshot,
        marquee: BlockEditorMarqueeSelection(
            startPoint: CGPoint(x: 0, y: 0),
            currentPoint: CGPoint(x: 80, y: 60),
            isAdditive: false
        )
    )

    let second = controller.reduce(
        baseState: base,
        currentState: first.state,
        orderedBlockIDs: ids,
        rowFrames: snapshot,
        marquee: BlockEditorMarqueeSelection(
            startPoint: CGPoint(x: 0, y: 0),
            currentPoint: CGPoint(x: 81, y: 61),
            isAdditive: false
        )
    )

    #expect(second.shouldMutateState == false)
}
```

**Step 2: Write failing tests for row-frame snapshot equality and pruning**

Cover these cases:

- same frames in different merge order compare equal
- removed block IDs are pruned
- tiny floating-point jitter below threshold does not count as a new snapshot
- materially changed geometry does count as a new snapshot

**Step 3: Run targeted tests to verify failure**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests -only-testing:agentGuiTests/BlockEditorMarqueeSelectionControllerTests -only-testing:agentGuiTests/BlockEditorRowFrameSnapshotTests
```

Expected: FAIL because the new controller and snapshot types do not exist yet.

**Step 4: Commit test scaffolding**

```bash
git add agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift agentGuiTests/BlockEditorMarqueeSelectionControllerTests.swift agentGuiTests/BlockEditorRowFrameSnapshotTests.swift
git commit -m "test: add block editor stability regression coverage"
```

### Task 2: Introduce A Dedicated Row-Frame Snapshot Model

**Files:**
- Create: `agentGui/Views/Editor/BlockEditorRowFrameSnapshot.swift`
- Modify: `agentGui/Views/Editor/BlockDocumentEditor.swift`
- Modify: `agentGui/Views/Editor/BlockRowView.swift`

**Step 1: Create a value type for frame snapshots**

Add a small model that owns:

- normalized frame storage
- equality with configurable tolerance
- pruning to current document IDs
- a factory for building snapshots from `[UUID: CGRect]`

Example API:

```swift
struct BlockEditorRowFrameSnapshot: Equatable {
    let frames: [UUID: CGRect]

    init(frames: [UUID: CGRect], tolerance: CGFloat = 0.5)
    func pruned(to validIDs: some Sequence<UUID>) -> BlockEditorRowFrameSnapshot
    func frame(for blockID: UUID) -> CGRect?
    var isEmpty: Bool { get }
}
```

**Step 2: Replace raw blockFrames state with the snapshot type**

Refactor `BlockDocumentEditor` to store:

```swift
@State private var rowFrameSnapshot = BlockEditorRowFrameSnapshot.empty
```

and stop assigning raw dictionaries directly.

**Step 3: Gate preference writes by semantic equality**

In the `onPreferenceChange` closure:

- build a new snapshot from preference data
- prune it to the current document block IDs
- only write state when the snapshot is materially different

This step is mandatory. A simple `blockFrames = frames` replacement is not sufficient.

**Step 4: Make row frame reporting opt-in**

Extend `BlockRowView` with a flag such as:

```swift
let reportsFrameForSelection: Bool
```

and only mount the `GeometryReader` preference publisher when marquee selection is active or about to begin.

**Step 5: Run the new row-frame snapshot tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -only-testing:agentGuiTests/BlockEditorRowFrameSnapshotTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorRowFrameSnapshot.swift agentGui/Views/Editor/BlockDocumentEditor.swift agentGui/Views/Editor/BlockRowView.swift agentGuiTests/BlockEditorRowFrameSnapshotTests.swift
git commit -m "refactor: normalize block editor row frame snapshots"
```

### Task 3: Extract Marquee Selection Into A Pure Controller

**Files:**
- Create: `agentGui/Views/Editor/BlockEditorMarqueeSelectionController.swift`
- Modify: `agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift`
- Modify: `agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift`
- Modify: `agentGuiTests/BlockEditorMarqueeSelectionControllerTests.swift`
- Modify: `agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift`

**Step 1: Create a dedicated marquee controller**

Move high-frequency drag-selection orchestration out of the view extension into a pure type.

Suggested API:

```swift
struct BlockEditorMarqueeSelectionResult: Equatable {
    let state: BlockEditorBlockSelectionState
    let shouldMutateState: Bool
    let shouldSyncRuntimeSelection: Bool
    let shouldUpdateActiveBlock: Bool
}

struct BlockEditorMarqueeSelectionController {
    func reduce(
        baseState: BlockEditorBlockSelectionState,
        currentState: BlockEditorBlockSelectionState,
        orderedBlockIDs: [UUID],
        rowFrames: BlockEditorRowFrameSnapshot,
        marquee: BlockEditorMarqueeSelection
    ) -> BlockEditorMarqueeSelectionResult
}
```

**Step 2: Keep hit-testing in the coordinator, move update policy to the controller**

`BlockEditorBlockSelectionCoordinator.selectionFromMarquee` should stay a pure mapping from geometry to selection. The new controller should decide whether the editor needs to mutate view state and runtime state.

**Step 3: Remove unconditional writes from the gesture hot path**

Update `BlockDocumentEditor+BlockSelection` so `onChanged` only mutates:

- `blockSelectionState`
- `runtimeState.blockSelection`
- `activeBlockID`
- `selectionState`
- `runtimeState.focus`
- `runtimeState.selection`

when the controller indicates a meaningful change.

The overlay rectangle may still move every drag event, but selection and runtime mirrors must not.

**Step 4: Run targeted marquee tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests -only-testing:agentGuiTests/BlockEditorMarqueeSelectionControllerTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockEditorMarqueeSelectionController.swift agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift agentGui/Views/Editor/BlockEditorBlockSelectionCoordinator.swift agentGuiTests/BlockEditorBlockSelectionCoordinatorTests.swift agentGuiTests/BlockEditorMarqueeSelectionControllerTests.swift
git commit -m "refactor: extract marquee selection controller"
```

### Task 4: Collapse Redundant Editor Interaction State

**Files:**
- Modify: `agentGui/Views/Editor/BlockDocumentEditor.swift`
- Modify: `agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift`
- Modify: `agentGuiTests/BlockDocumentEditorUndoTests.swift`

**Step 1: Audit duplicated state pairs**

Document every mirrored pair currently maintained across view state and runtime state, starting with:

- `activeBlockID` and `runtimeState.activeBlockID`
- `selectionState` and `runtimeState.selection`
- `blockSelectionState` and `runtimeState.blockSelection`

**Step 2: Introduce one internal synchronization boundary**

Do not keep ad hoc assignments spread across tap, focus, marquee, undo, and slash handlers. Replace them with a single internal helper or state applier with APIs such as:

```swift
private func applyBlockSelectionState(_ newState: BlockEditorBlockSelectionState, syncRuntime: Bool)
private func clearInlineSelection(syncRuntime: Bool)
private func setActiveBlock(_ blockID: UUID?)
```

This task is still refactoring, not architectural expansion. The goal is to delete repeated state write sequences.

**Step 3: Remove duplicate assignment blocks from interaction handlers**

Apply the new helper in:

- block tap handling
- marquee gesture handling
- context menu activation
- focus change paths
- selection clearing paths

**Step 4: Update undo-related tests if behavior contracts changed**

Only adjust tests when the observable contract changed. Do not rewrite passing coverage unnecessarily.

**Step 5: Run undo and selection tests**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -only-testing:agentGuiTests/BlockDocumentEditorUndoTests -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Views/Editor/BlockDocumentEditor.swift agentGui/Views/Editor/BlockDocumentEditor+BlockSelection.swift agentGuiTests/BlockDocumentEditorUndoTests.swift
git commit -m "refactor: consolidate block editor interaction state"
```

### Task 5: Delete View-Layer Redundancy That Obscures Ownership

**Files:**
- Modify: `agentGui/Views/Editor/BlockDocumentEditor.swift`
- Review: `agentGui/Views/Editor/BlockEditorMutationDriver.swift`

**Step 1: Identify helper methods in BlockDocumentEditor that duplicate runtime-layer logic**

Start with the known candidates:

- `makeResourceBlock`
- `makeTablePresetMarkdown`
- `followUpKind`
- `mergeSeparator`
- `supportsIndentation`

**Step 2: Verify each helper has a canonical owner**

If the runtime layer already owns the behavior, delete the view-layer copy. If ownership is still ambiguous, move the logic into the runtime layer and keep only one copy.

**Step 3: Remove dead code, not just unused call sites**

The target state is one source of truth per editor rule. Do not leave commented-out code, shadow helpers, or “temporary compatibility” methods behind.

**Step 4: Run the full editor unit subset**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -only-testing:agentGuiTests/BlockDocumentEditorUndoTests -only-testing:agentGuiTests/BlockEditorMutationDriverTests -only-testing:agentGuiTests/BlockEditorBlockSelectionCoordinatorTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/Editor/BlockDocumentEditor.swift agentGui/Views/Editor/BlockEditorMutationDriver.swift
git commit -m "refactor: remove redundant block editor view helpers"
```

### Task 6: Validate End-To-End Editor Stability

**Files:**
- No product code changes expected

**Step 1: Run the repository smoke task**

Run the existing workspace task:

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS.

**Step 2: Perform manual editor verification on macOS**

Verify all of the following in a real editor session:

- drag-select across 20+ blocks
- drag-select while hovering rows
- drag-select after text selection is cleared
- command-additive marquee selection
- drag-reorder after marquee selection
- inline toolbar still appears for text selection
- slash menu still positions correctly
- undo/redo after marquee selection and block deletion

**Step 3: Inspect runtime logs**

Confirm the previous warning no longer appears during normal marquee interaction:

- `Bound preference BlockEditorRowFramePreferenceKey tried to update multiple times per frame`

**Step 4: Commit verification note if additional docs changed**

```bash
git add docs/plans/2026-03-23-block-document-editor-stability-refactor.md
git commit -m "docs: record block editor stability refactor plan"
```

## Implementation Notes

- This fix must not stop at `if blockFrames != frames`. That only suppresses one symptom and keeps the layout feedback design intact.
- Keep `BlockEditorBlockSelectionCoordinator` pure. Do not reintroduce view state or AppKit state into it.
- The `GeometryReader` publisher in `BlockRowView` is the expensive edge. It should be mounted deliberately, not continuously.
- If a small helper grows beyond one responsibility, create a new file instead of extending the god view.
- Prefer deleting code over moving dead code to a new file.

## Final Verification Checklist

- [ ] No unconditional preference-to-state mirror remains in `BlockDocumentEditor`
- [ ] No marquee drag path performs redundant runtime mirror writes
- [ ] No duplicated helper logic remains between `BlockDocumentEditor` and mutation/runtime code
- [ ] New snapshot/controller types have direct unit tests
- [ ] Existing undo and selection tests still pass
- [ ] Quality smoke passes
- [ ] Manual drag-selection verification passes on macOS

## Risks To Watch

- Over-normalizing geometry with too large a tolerance can miss legitimate selection edge updates.
- Moving too much state at once can accidentally change undo snapshots.
- Gating frame collection too aggressively can break first-frame marquee hit-testing if snapshot warm-up is not handled.
- Refactoring selection sync helpers without test coverage can regress responder activation.

## Recommended Execution Order

1. Tests first.
2. Snapshot model.
3. Marquee controller.
4. State consolidation.
5. Redundant helper deletion.
6. Smoke and manual verification.
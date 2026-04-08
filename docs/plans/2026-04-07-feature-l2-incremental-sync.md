# Feature L-2: Incremental Document Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `textDocument/didChange` 从每次发送全量文档内容（Full Sync）升级为按变更区间发送（Incremental Sync），当服务器支持 `TextDocumentSyncKind.Incremental` 时，消息体积对于单字符修改可降低 ≥ 60%。

**Architecture:**
`EditorChangeSet`（来自 AppKit NSTextView delegate）已携带 `replacedRange: NSRange` 与 `insertedText`，是增量信息的原始来源。`LSPDocumentStore` 维护服务端视角的文档镜像（旧文本），借助 `CodeEditorLineIndex` 将 NSRange（UTF-16 字节偏移）转换为 LSP 0-based `(line, character)` 坐标。`LSPClient` 根据 `capabilities.syncKind` 决定发送 full 或 incremental payload。增量变更信息通过 `LSPServerManager.syncDocument` → `CodeEditorLSPCoordinator` 的调用链透传；Coordinator 在防抖窗口内若只累积了一次编辑，则传递增量信息；若多次编辑叠加（快速连打），退化为全量。

**Tech Stack:** Swift 6.0, Swift Testing framework (`@Test`, `#expect`), `@MainActor`, `LSPJSONRPCTransport`, `CodeEditorLineIndex`

---

## 修改文件总览

| 文件 | 操作 |
|------|------|
| `agentGui/Models/LSPServerCapabilities.swift` | 新增 `TextDocumentSyncKind` 枚举；`LSPServerCapabilityHints` 新增 `syncKind` 字段 |
| `agentGui/Services/LSP/LSPClient.swift` | `negotiatedCapabilities` 解析 `textDocumentSync`；新增增量重载 `updateDocument(uri:replacing:insertedText:newText:)` |
| `agentGui/Services/LSP/LSPDocumentStore.swift` | 新增 `lspRange(for:uri:) → [String:Any]?` 方法；内部维护每文档的 `CodeEditorLineIndex` |
| `agentGui/Services/LSP/LSPServerManager.swift` | `syncDocument` 添加可选 `editorChange: EditorChangeSet?` 参数 |
| `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift` | 存储 `pendingChangeSet` / `pendingChangeSetIsAmbiguous`；`flushPendingChange` 向 manager 透传 |
| `agentGuiTests/LSPServerCapabilitiesTests.swift` | 扩展：新增 4 个 `syncKind` 解析测试 |
| `agentGuiTests/LSPDocumentStoreTests.swift` | **新建**：`lspRange` 位置换算单元测试 |
| `agentGuiTests/LSPClientIncrementalSyncTests.swift` | **新建**：验证 `contentChanges` 含 `range` 字段的 JSON-RPC 消息 |
| `agentGuiTests/CodeEditorLSPCoordinatorTests.swift` | 扩展：增量透传 + 多编辑退化全量 |

---

## Task 1：`TextDocumentSyncKind` 枚举 + `syncKind` 字段

**目标：** 在 `LSPServerCapabilityHints` 中添加 `syncKind` 字段，默认 `.full`（保持向后兼容）。

### Files
- Modify: `agentGui/Models/LSPServerCapabilities.swift`

### Step 1：写失败测试

打开 `agentGuiTests/LSPServerCapabilitiesTests.swift`，在文件末尾 `}` 之前添加：

```swift
// MARK: - textDocumentSync / syncKind parsing

@Test func parsesTextDocumentSyncKindAsInteger() {
    let raw: [String: Any] = ["capabilities": ["textDocumentSync": 2]]
    let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
    #expect(result.syncKind == .incremental)
}

@Test func parsesTextDocumentSyncKindAsObject() {
    let raw: [String: Any] = [
        "capabilities": ["textDocumentSync": ["openClose": true, "change": 2]]
    ]
    let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
    #expect(result.syncKind == .incremental)
}

@Test func parsesTextDocumentSyncKindFull() {
    let raw: [String: Any] = ["capabilities": ["textDocumentSync": 1]]
    let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
    #expect(result.syncKind == .full)
}

@Test func missingTextDocumentSyncKindUsesFallback() {
    var fallback = LSPServerCapabilityHints.allDisabled
    fallback.syncKind = .incremental
    let raw: [String: Any] = ["capabilities": ["hoverProvider": true]]
    let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: fallback)
    #expect(result.syncKind == .incremental)
}
```

### Step 2：运行测试验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task1 \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败（`syncKind` 不存在）。

### Step 3：实现 `TextDocumentSyncKind` 枚举

在 `agentGui/Models/LSPServerCapabilities.swift` 顶部（`enum LSPAdapterKind` 之前）添加：

```swift
enum TextDocumentSyncKind: Int, Codable, Sendable {
    case none = 0
    case full = 1
    case incremental = 2
}
```

### Step 4：在 `LSPServerCapabilityHints` 中添加字段

在结构体的 `var supportsInlayHints: Bool = false` 行之后、`static let readOnlySemanticDefaults` 之前添加：

```swift
// — L-2 Incremental Sync —
var syncKind: TextDocumentSyncKind = .full
```

同时更新 `allDisabled` 静态属性（在 extension 中）——不需要显式设置，默认值 `.full` 即可。

### Step 5：在 `negotiatedCapabilities` 中解析 `textDocumentSync`

打开 `agentGui/Services/LSP/LSPClient.swift`，找到 `private func negotiatedCapabilities(from rawResult: Any?, fallback: LSPServerCapabilityHints)` 方法，在方法体内 `let completionOpts = ...` 之前添加如下代码：

```swift
// textDocumentSync: Int | { change: Int }
let syncKind: TextDocumentSyncKind
if let rawSync = capabilities["textDocumentSync"] {
    if let syncInt = (rawSync as? Int) ?? (rawSync as? NSNumber).map({ $0.intValue }),
       let kind = TextDocumentSyncKind(rawValue: syncInt) {
        syncKind = kind
    } else if let syncObj = rawSync as? [String: Any],
              let changeRaw = syncObj["change"],
              let changeInt = (changeRaw as? Int) ?? (changeRaw as? NSNumber).map({ $0.intValue }),
              let kind = TextDocumentSyncKind(rawValue: changeInt) {
        syncKind = kind
    } else {
        syncKind = fallback.syncKind
    }
} else {
    syncKind = fallback.syncKind
}
```

然后在 `return LSPServerCapabilityHints(` 的参数列表末尾添加 `syncKind` 参数（在 `supportsInlayHints:` 参数行之后，右括号之前）：

```swift
            supportsInlayHints: boolCapability(capabilities["inlayHintProvider"], fallback: fallback.supportsInlayHints),
            syncKind: syncKind
```

> **注意**：`LSPServerCapabilityHints` 的结构体初始化器是成员逐一初始化器（memberwise initializer）— 所有必须参数要有实参，新增字段有默认值所以不影响已有调用。但 `negotiatedCapabilities` 中是显式构造，需要补上新参数。

### Step 6：运行测试验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task1 \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：所有 `LSPServerCapabilitiesTests` 通过。

### Step 7：提交

```bash
git add agentGui/Models/LSPServerCapabilities.swift \
        agentGui/Services/LSP/LSPClient.swift \
        agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "feat(lsp-l2): add TextDocumentSyncKind and syncKind capability field"
```

---

## Task 2：`LSPDocumentStore` 维护行索引并暴露 LSP 坐标转换

**目标：** `LSPDocumentStore` 内部为每个打开文档维护一个 `CodeEditorLineIndex`，并提供方法将 `NSRange`（UTF-16 offset）转换为 LSP `range` dict（0-based `line`/`character`）。转换必须发生在文档更新**之前**（使用旧文本）。

### Files
- Modify: `agentGui/Services/LSP/LSPDocumentStore.swift`
- Create: `agentGuiTests/LSPDocumentStoreTests.swift`

### Step 1：写失败测试

创建 `agentGuiTests/LSPDocumentStoreTests.swift`：

```swift
import Testing
import Foundation
@testable import agentGui

struct LSPDocumentStoreTests {

    @Test func lspRangeConvertsSimpleSingleLineInsertion() {
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///a.py", languageID: "python", text: "hello world")
        // replace "world" (offset 6, length 5) → LSP range
        let range = store.lspRange(for: NSRange(location: 6, length: 5), uri: "file:///a.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 6)
        #expect(end?["line"] as? Int == 0)
        #expect(end?["character"] as? Int == 11)
    }

    @Test func lspRangeConvertsMultiLineRange() {
        // "abc\nxyz": line 0 = "abc\n" (4 UTF-16 units), line 1 = "xyz" (3 UTF-16 units)
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///b.py", languageID: "python", text: "abc\nxyz")
        // full range: offset 0 len 7
        let range = store.lspRange(for: NSRange(location: 0, length: 7), uri: "file:///b.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 0)
        #expect(end?["line"] as? Int == 1)
        #expect(end?["character"] as? Int == 3)
    }

    @Test func lspRangeConvertsEndOfFirstLine() {
        // "abc\nxyz" — range covering "c\n" (offset 2, length 2)
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///c.py", languageID: "python", text: "abc\nxyz")
        let range = store.lspRange(for: NSRange(location: 2, length: 2), uri: "file:///c.py")
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"] as? Int == 0)
        #expect(start?["character"] as? Int == 2)
        #expect(end?["line"] as? Int == 1)
        #expect(end?["character"] as? Int == 0)
    }

    @Test func lspRangeReturnsNilForUnknownURI() {
        let store = LSPDocumentStore()
        let range = store.lspRange(for: NSRange(location: 0, length: 1), uri: "file:///unknown.py")
        #expect(range == nil)
    }

    @Test func lspRangeUsesOldTextBeforeUpdate() {
        // verifies that range is computed before the snapshot text is replaced
        let store = LSPDocumentStore()
        store.openDocument(uri: "file:///d.py", languageID: "python", text: "hello world")
        // compute range on the OLD text
        let range = store.lspRange(for: NSRange(location: 6, length: 5), uri: "file:///d.py")
        // now update
        _ = store.updateDocument(uri: "file:///d.py", text: "hello Swift")
        // range should still be based on old text ("world" at 6..11)
        let end = range?["end"] as? [String: Any]
        #expect(end?["character"] as? Int == 11)
    }
}
```

### Step 2：运行验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task2 \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败（`lspRange` 不存在）。

### Step 3：实现

用以下内容**完整替换** `agentGui/Services/LSP/LSPDocumentStore.swift`：

```swift
import Foundation

final class LSPDocumentStore {
    private struct Entry {
        var snapshot: LSPDocumentSnapshot
        var lineIndex: CodeEditorLineIndex
    }

    private var entries: [String: Entry] = [:]

    // MARK: - Lifecycle

    @discardableResult
    func openDocument(uri: String, languageID: String, text: String) -> LSPDocumentSnapshot {
        let snapshot = LSPDocumentSnapshot(uri: uri, languageID: languageID, text: text, version: 1)
        entries[uri] = Entry(snapshot: snapshot, lineIndex: CodeEditorLineIndex(text: text))
        return snapshot
    }

    @discardableResult
    func updateDocument(uri: String, text: String) -> LSPDocumentSnapshot? {
        guard let current = entries[uri] else { return nil }
        let snapshot = LSPDocumentSnapshot(
            uri: current.snapshot.uri,
            languageID: current.snapshot.languageID,
            text: text,
            version: current.snapshot.version + 1
        )
        entries[uri] = Entry(snapshot: snapshot, lineIndex: CodeEditorLineIndex(text: text))
        return snapshot
    }

    func closeDocument(uri: String) {
        entries.removeValue(forKey: uri)
    }

    func snapshot(for uri: String) -> LSPDocumentSnapshot? {
        entries[uri]?.snapshot
    }

    // MARK: - Incremental range conversion

    /// Converts an NSRange (UTF-16 character offsets in the **current** document text)
    /// to an LSP `range` dictionary with 0-based `line`/`character` values.
    ///
    /// Returns `nil` if the URI is not currently open.
    /// Must be called **before** `updateDocument(uri:text:)` to use the old text for position calculation.
    func lspRange(for nsRange: NSRange, uri: String) -> [String: Any]? {
        guard let entry = entries[uri] else { return nil }
        let index = entry.lineIndex

        // CodeEditorLineIndex.location(ofUTF16Offset:) is 1-based → subtract 1 for LSP (0-based).
        let startLocation = index.location(ofUTF16Offset: nsRange.location)
        let endLocation   = index.location(ofUTF16Offset: nsRange.location + nsRange.length)

        return [
            "start": [
                "line":      startLocation.line - 1,
                "character": startLocation.column - 1
            ],
            "end": [
                "line":      endLocation.line - 1,
                "character": endLocation.column - 1
            ]
        ]
    }
}
```

### Step 4：运行验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task2 \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：5 个测试全部通过。

### Step 5：提交

```bash
git add agentGui/Services/LSP/LSPDocumentStore.swift \
        agentGuiTests/LSPDocumentStoreTests.swift
git commit -m "feat(lsp-l2): add line index and lspRange() to LSPDocumentStore"
```

---

## Task 3：`LSPClient` 增量更新重载 + 测试辅助扩展

**目标：** 在 `LSPClient` 中新增 `updateDocument(uri:replacing:insertedText:newText:)` 方法。当 `capabilities.syncKind == .incremental` 且 `lspRange` 计算成功时，发送含 `range` 的增量消息；否则退化为全量发送。

### Files
- Modify: `agentGui/Services/LSP/LSPClient.swift`
- Create: `agentGuiTests/LSPClientIncrementalSyncTests.swift`

### Step 1：添加测试辅助扩展（先于测试代码）

在 `agentGui/Services/LSP/LSPClient.swift` 末尾的 `extension LSPClient { ... }` 块中，在 `initializeParamsForTesting` 方法之后添加：

```swift
    /// For testing only: directly sets the negotiated capabilities.
    func setCapabilitiesForTesting(_ hints: LSPServerCapabilityHints) {
        capabilities = hints
    }
```

### Step 2：写失败测试

创建 `agentGuiTests/LSPClientIncrementalSyncTests.swift`：

```swift
import Testing
import Foundation
@testable import agentGui

@MainActor
struct LSPClientIncrementalSyncTests {

    // MARK: - Helpers

    /// Parses an LSP-framed message (Content-Length header + JSON body) into a dictionary.
    private func parseMessage(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let bodyData = data[headerEnd.upperBound...]
        return try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    }

    private func makeCapturingClient(syncKind: TextDocumentSyncKind) -> (LSPClient, captured: CapturedMessages) {
        let transport = LSPJSONRPCTransport()
        let captured = CapturedMessages()
        transport.outgoingDataHandler = { [weak captured] data in
            captured?.messages.append(data)
        }
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        var caps = LSPServerCapabilityHints.allDisabled
        caps.syncKind = syncKind
        client.setCapabilitiesForTesting(caps)
        return (client, captured)
    }

    // MARK: - Tests

    @Test func incrementalServerReceivesRangedContentChange() throws {
        let (client, captured) = makeCapturingClient(syncKind: .incremental)
        client.openDocument(uri: "file:///test.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///test.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        let first   = try #require(changes?.first)

        #expect(first["range"] != nil, "incremental change must include range")
        #expect(first["text"] as? String == "Swift")

        let range = first["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end   = range?["end"]   as? [String: Any]
        #expect(start?["line"]      as? Int == 0)
        #expect(start?["character"] as? Int == 6)
        #expect(end?["line"]        as? Int == 0)
        #expect(end?["character"]   as? Int == 11)
    }

    @Test func fullSyncServerReceivesTextOnlyContentChange() throws {
        let (client, captured) = makeCapturingClient(syncKind: .full)
        client.openDocument(uri: "file:///test.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///test.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        let first   = try #require(changes?.first)

        #expect(first["range"] == nil, "full sync must NOT include range")
        #expect(first["text"] as? String == "hello Swift")
    }

    @Test func incrementalUpdateIncreasesDocumentVersion() {
        let (client, _) = makeCapturingClient(syncKind: .incremental)
        client.openDocument(uri: "file:///v.py", languageID: "python", text: "initial")

        let snapshot = client.updateDocument(
            uri: "file:///v.py",
            replacing: NSRange(location: 0, length: 7),
            insertedText: "updated",
            newText: "updated"
        )
        #expect(snapshot?.version == 2)
    }

    @Test func nilCapabilitiesFallBackToFullSync() throws {
        let transport = LSPJSONRPCTransport()
        let captured = CapturedMessages()
        transport.outgoingDataHandler = { data in captured.messages.append(data) }
        // Do NOT set capabilities
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: _NoOpLSPAdapter()
        )
        client.openDocument(uri: "file:///nil.py", languageID: "python", text: "hello world")
        captured.messages.removeAll()

        client.updateDocument(
            uri: "file:///nil.py",
            replacing: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            newText: "hello Swift"
        )

        let msg = try #require(captured.messages.first.flatMap(parseMessage))
        let params  = msg["params"] as? [String: Any]
        let changes = params?["contentChanges"] as? [[String: Any]]
        #expect(changes?.first?["range"] == nil, "nil capabilities must use full sync")
    }
}

/// Helper to accumulate captured outgoing messages across async boundaries.
@MainActor
private final class CapturedMessages {
    var messages: [Data] = []
}
```

### Step 3：运行验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task3 \
  -only-testing:agentGuiTests/LSPClientIncrementalSyncTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败（`updateDocument(replacing:...)` 重载不存在；`setCapabilitiesForTesting` 不存在）。

### Step 4：实现 `updateDocument` 增量重载

在 `agentGui/Services/LSP/LSPClient.swift` 的 `func updateDocument(uri: String, text: String)` 方法**之后**（约 L96 之后）添加：

```swift
/// Sends a `textDocument/didChange` notification.
///
/// If `capabilities.syncKind == .incremental` and the LSP range can be computed,
/// sends a ranged content-change event. Otherwise falls back to full-text sync.
@discardableResult
func updateDocument(
    uri: String,
    replacing nsRange: NSRange,
    insertedText: String,
    newText: String
) -> LSPDocumentSnapshot? {
    let useIncremental = capabilities?.syncKind == .incremental
    if useIncremental, let range = documentStore.lspRange(for: nsRange, uri: uri) {
        guard let snapshot = documentStore.updateDocument(uri: uri, text: newText) else { return nil }
        try? transport.sendNotification(
            method: "textDocument/didChange",
            params: [
                "textDocument": [
                    "uri": uri,
                    "version": snapshot.version
                ],
                "contentChanges": [
                    ["range": range, "text": insertedText]
                ]
            ]
        )
        onDocumentLifecycleEvent?("change:\(uri)", snapshot)
        return snapshot
    } else {
        return updateDocument(uri: uri, text: newText)
    }
}
```

### Step 5：运行验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task3 \
  -only-testing:agentGuiTests/LSPClientIncrementalSyncTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：4 个测试全部通过。

### Step 6：提交

```bash
git add agentGui/Services/LSP/LSPClient.swift \
        agentGuiTests/LSPClientIncrementalSyncTests.swift
git commit -m "feat(lsp-l2): add incremental updateDocument overload to LSPClient"
```

---

## Task 4：`LSPServerManager` 透传 `EditorChangeSet`

**目标：** `syncDocument` 添加可选 `editorChange: EditorChangeSet?` 参数，当 `editorChange` 携带的是 `.userEdit` 时，调用增量重载；否则继续调用全量 `updateDocument`。

### Files
- Modify: `agentGui/Services/LSP/LSPServerManager.swift`

### Step 1：修改 `syncDocument` 方法签名

在 `agentGui/Services/LSP/LSPServerManager.swift` 中找到：

```swift
    func syncDocument(
        workspaceRoot: String,
        serverID: String,
        uri: String,
        languageID: String,
        text: String
    ) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }

        if session.client.updateDocument(uri: uri, text: text) == nil {
            _ = session.client.openDocument(uri: uri, languageID: languageID, text: text)
        }
        notifyPresentationStateDidChange()
    }
```

替换为：

```swift
    func syncDocument(
        workspaceRoot: String,
        serverID: String,
        uri: String,
        languageID: String,
        text: String,
        editorChange: EditorChangeSet? = nil
    ) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }

        let updated: LSPDocumentSnapshot?
        if let change = editorChange, change.origin == .userEdit {
            updated = session.client.updateDocument(
                uri: uri,
                replacing: change.replacedRange,
                insertedText: change.insertedText,
                newText: text
            )
        } else {
            updated = session.client.updateDocument(uri: uri, text: text)
        }

        if updated == nil {
            _ = session.client.openDocument(uri: uri, languageID: languageID, text: text)
        }
        notifyPresentationStateDidChange()
    }
```

> 函数签名仅添加了一个带默认值的参数，所有现有调用点自动兼容，无需修改。

### Step 2：验证编译（无测试需要为此单独写，在 Task 5 集成测试中覆盖）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-l2-task4-build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 3：提交

```bash
git add agentGui/Services/LSP/LSPServerManager.swift
git commit -m "feat(lsp-l2): thread EditorChangeSet through LSPServerManager.syncDocument"
```

---

## Task 5：`CodeEditorLSPCoordinator` 累积 `EditorChangeSet` 并透传

**目标：** 在防抖窗口内，若只有**一次**用户编辑累积待发送，则向 Manager 透传 `EditorChangeSet`，触发增量路径；若多次快速编辑导致防抖窗口内有超过一次累积，则标记为"歧义"，退化全量发送。

### Files
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Modify: `agentGuiTests/CodeEditorLSPCoordinatorTests.swift`

### Step 1：写失败测试

在 `agentGuiTests/CodeEditorLSPCoordinatorTests.swift` 末尾 `}` 之前追加：

```swift
// MARK: - Incremental change set forwarding

@Test
func singleEditForwardsEditorChangeSetToSyncDocument() async throws {
    // Setup: configure the harness with an adapter returning incremental syncKind
    let harness = IncrementalCapabilityHarness()
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSourceFile(),
        debounceNanoseconds: 30_000_000
    )

    coordinator.activate(initialText: "hello world", version: 1)

    coordinator.handleTextChange(
        text: "hello Swift",
        change: EditorChangeSet(
            version: 2,
            replacedRange: NSRange(location: 6, length: 5),
            insertedText: "Swift",
            selectedRange: NSRange(location: 11, length: 0),
            origin: .userEdit
        )
    )

    try await Task.sleep(nanoseconds: 80_000_000)

    // Verify: an incremental change was captured (range present in last didChange payload)
    #expect(harness.lastIncrementalChangeRange != nil,
            "single edit should be forwarded as incremental change with range")
}

@Test
func rapidEditsExceedingDebounceWindowFallBackToFullSync() async throws {
    let harness = IncrementalCapabilityHarness()
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSourceFile(),
        debounceNanoseconds: 60_000_000
    )

    coordinator.activate(initialText: "hello world", version: 1)

    // Two rapid edits before debounce fires → coordinator marks pending as ambiguous
    coordinator.handleTextChange(
        text: "hello Sw",
        change: EditorChangeSet(
            version: 2,
            replacedRange: NSRange(location: 6, length: 5),
            insertedText: "Sw",
            selectedRange: NSRange(location: 8, length: 0),
            origin: .userEdit
        )
    )
    coordinator.handleTextChange(
        text: "hello Swift",
        change: EditorChangeSet(
            version: 3,
            replacedRange: NSRange(location: 8, length: 0),
            insertedText: "ift",
            selectedRange: NSRange(location: 11, length: 0),
            origin: .userEdit
        )
    )

    try await Task.sleep(nanoseconds: 120_000_000)

    // Verify: incremental range NOT present (full text was sent)
    #expect(harness.lastIncrementalChangeRange == nil,
            "multiple rapid edits should fall back to full sync (no range in content change)")
    // But text WAS updated
    #expect(harness.lastClientDocumentSnapshot?.text == "hello Swift")
}
```

> 이 테스트에는 새로운 test harness `IncrementalCapabilityHarness`가 필요합니다.  
> 다음 Step에서 구현합니다.

### Step 2：新建 `IncrementalCapabilityHarness` 测试夹具

在 `agentGuiTests/TestSupport/` 目录下创建 `agentGuiTests/TestSupport/IncrementalCapabilityHarness.swift`：

```swift
import Foundation
@testable import agentGui

/// Test harness for Feature L-2 coordinator tests.
/// Returns capabilities with `syncKind == .incremental` and captures the last
/// `contentChanges[0]["range"]` value from outgoing didChange messages.
@MainActor
final class IncrementalCapabilityHarness {
    private(set) var documentLifecycleEvents: [String] = []
    private(set) var lastClientDocumentSnapshot: LSPDocumentSnapshot?
    /// Non-nil if the last didChange message included a `range` in contentChanges.
    private(set) var lastIncrementalChangeRange: [String: Any]?

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["python-lsp"])
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()
        let harness = self

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: {
                let transport = LSPJSONRPCTransport()
                let client = LSPClient(
                    transport: transport,
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: IncrementalHarnessAdapter()
                )
                // Capture outgoing JSON-RPC messages
                transport.outgoingDataHandler = { [weak harness] data in
                    harness?.handleOutgoing(data: data)
                }
                client.onDocumentLifecycleEvent = { [weak harness] event, snapshot in
                    harness?.documentLifecycleEvents.append(event)
                    harness?.lastClientDocumentSnapshot = snapshot
                }
                return client
            },
            makeSupervisor: {
                LSPProcessSupervisor(
                    processLauncher: IncrementalHarnessProcessLauncher()
                )
            }
        )
    }

    private func handleOutgoing(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return }
        let bodyData = data[headerEnd.upperBound...]
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let method = json["method"] as? String,
              method == "textDocument/didChange",
              let params = json["params"] as? [String: Any],
              let changes = params["contentChanges"] as? [[String: Any]],
              let first = changes.first else { return }

        lastIncrementalChangeRange = first["range"] as? [String: Any]
    }
}

private struct IncrementalHarnessAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        var hints = LSPServerCapabilityHints.readOnlySemanticDefaults
        hints.syncKind = .incremental
        return hints
    }
}

private final class IncrementalHarnessProcessLauncher: LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        IncrementalHarnessManagedProcess()
    }
}

private final class IncrementalHarnessManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 77
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?

    func start() throws {}
    func send(_ data: Data) throws {}
    func stop() {}
}
```

### Step 3：运行验证失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task5 \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：两个新测试失败（`lastIncrementalChangeRange` 始终为 nil，因为 Coordinator 还没透传）。

### Step 4：实现 Coordinator 侧变更

打开 `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`。

**4a. 在 private stored properties 区域**，在 `private var pendingChangeTask` 之后添加：

```swift
private var pendingChangeSet: EditorChangeSet?
private var pendingChangeSetIsAmbiguous = false
```

**4b. 修改 `handleTextChange` 中的 `.userEdit` 分支**：

找到：

```swift
        case .userEdit:
            latestLocalVersion = max(latestLocalVersion, change.version)
            pendingText = text
            pendingVersion = change.version
            schedulePendingChange(expectedVersion: change.version)
```

替换为：

```swift
        case .userEdit:
            latestLocalVersion = max(latestLocalVersion, change.version)
            // Track change accumulation.
            // If there's already a pending change we haven't flushed, mark as ambiguous
            // so the flush falls back to full sync.
            if pendingText != nil {
                pendingChangeSetIsAmbiguous = true
            } else {
                pendingChangeSet = change
                pendingChangeSetIsAmbiguous = false
            }
            pendingText = text
            pendingVersion = change.version
            schedulePendingChange(expectedVersion: change.version)
```

**4c. 修改 `handleProgrammaticReload`**，在已有的清零语句之后添加：

```swift
        pendingChangeSet = nil
        pendingChangeSetIsAmbiguous = false
```

（插入位置：`pendingText = nil` 和 `pendingVersion = nil` 之后，`cancelHover()` 调用之前。）

**4d. 修改 `deactivate`**，在 `pendingText = nil` 和 `pendingVersion = nil` 之后添加：

```swift
        pendingChangeSet = nil
        pendingChangeSetIsAmbiguous = false
```

**4e. 修改 `flushPendingChange`**：

找到：

```swift
    private func flushPendingChange(expectedVersion: Int) {
        guard let pendingText,
              let pendingVersion,
              pendingVersion == expectedVersion else {
            return
        }

        if !isOpen {
            activate(initialText: pendingText, version: pendingVersion)
        } else {
            manager.syncDocument(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                languageID: binding.languageID,
                text: pendingText
            )
        }

        latestSentVersion = max(latestSentVersion, pendingVersion)
        self.pendingText = nil
        self.pendingVersion = nil
        pendingChangeTask = nil
    }
```

替换为：

```swift
    private func flushPendingChange(expectedVersion: Int) {
        guard let pendingText,
              let pendingVersion,
              pendingVersion == expectedVersion else {
            return
        }

        // Only forward EditorChangeSet when exactly one change accumulated (unambiguous),
        // enabling the incremental sync path. Multiple accumulated changes fall back to full.
        let changeSetToSend: EditorChangeSet? = pendingChangeSetIsAmbiguous ? nil : pendingChangeSet

        if !isOpen {
            activate(initialText: pendingText, version: pendingVersion)
        } else {
            manager.syncDocument(
                workspaceRoot: binding.workspaceRoot,
                serverID: binding.serverID,
                uri: binding.uri,
                languageID: binding.languageID,
                text: pendingText,
                editorChange: changeSetToSend
            )
        }

        latestSentVersion = max(latestSentVersion, pendingVersion)
        self.pendingText = nil
        self.pendingVersion = nil
        self.pendingChangeSet = nil
        self.pendingChangeSetIsAmbiguous = false
        pendingChangeTask = nil
    }
```

### Step 5：运行全部相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-task5 \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  -only-testing:agentGuiTests/LSPClientIncrementalSyncTests \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -30
```

预期：所有测试通过。

### Step 6：提交

```bash
git add agentGui/Services/Editor/CodeEditorLSPCoordinator.swift \
        agentGuiTests/CodeEditorLSPCoordinatorTests.swift \
        agentGuiTests/TestSupport/IncrementalCapabilityHarness.swift
git commit -m "feat(lsp-l2): thread EditorChangeSet through coordinator for incremental sync"
```

---

## Task 6：全回归验证

验证没有引入编译错误和测试回归。

### Step 1：运行完整测试套件的烟雾测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l2-regression \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -only-testing:agentGuiTests/LSPDocumentStoreTests \
  -only-testing:agentGuiTests/LSPClientIncrementalSyncTests \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  -only-testing:agentGuiTests/LSPDiagnosticsParsingTests \
  -only-testing:agentGuiTests/CodeEditorSemanticQueryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed" | tail -20
```

预期：所有 6 个测试套件通过，0 失败。

### Step 2：确认向后兼容性

检查所有调用 `syncDocument(workspaceRoot:serverID:uri:languageID:text:)` 的地方（不传 `editorChange`），确认编译通过（默认值 `nil` 已覆盖）：

```bash
grep -rn "syncDocument(" agentGui/Services agentGui/Views --include="*.swift"
```

预期：只在 `CodeEditorLSPCoordinator.swift` 和 `LSPServerManager.swift`（定义处）找到。

### Step 3：最终提交（如有必要）

```bash
git add -A
git commit -m "feat(lsp-l2): incremental document sync - regression clean"
```

---

## 验收检查清单

| 验收项 | 对应 Task | 验证方式 |
|--------|-----------|---------|
| `textDocumentSync: 2` → `syncKind == .incremental` | Task 1 | `LSPServerCapabilitiesTests` |
| `textDocumentSync: { change: 2 }` → `syncKind == .incremental` | Task 1 | `LSPServerCapabilitiesTests` |
| `NSRange(6,5)` on `"hello world"` → `{line:0,char:6}` to `{line:0,char:11}` | Task 2 | `LSPDocumentStoreTests` |
| 多行范围转换正确 | Task 2 | `LSPDocumentStoreTests` |
| 增量服务器发送 `contentChanges[0].range` | Task 3 | `LSPClientIncrementalSyncTests` |
| 全量服务器不发送 `range` 字段 | Task 3 | `LSPClientIncrementalSyncTests` |
| `capabilities == nil` 退化为全量 | Task 3 | `LSPClientIncrementalSyncTests` |
| 单次用户编辑发送 incremental change event | Task 5 | `CodeEditorLSPCoordinatorTests` |
| 两次快速编辑退化为全量（无 range） | Task 5 | `CodeEditorLSPCoordinatorTests` |
| 所有现有 LSP 测试回归无失败 | Task 6 | 全套测试 |

---

## 关键设计决策记录

### 为什么防抖窗口内多次编辑退化为全量？
理想做法是将多个 `EditorChangeSet` 合并为单个覆盖区间，但区间合并在跨行/跨列场景下复杂度高且容易出错。当前实现选择"单次编辑走增量，多次走全量"策略：对于正常打字节奏（> 120ms 间隔），每次防抖只有一次编辑，命中增量路径；快速连打时虽然退化，但依然正确。未来若有性能需求，可升级为多变更合并（LSP 允许 `contentChanges` 数组包含多个条目）。

### 为什么 `lspRange` 在 `updateDocument` 之前计算？
LSP range 必须使用**旧文档坐标**。如果先更新快照再计算，行索引已经指向新文本，出现错误偏移。`lspRange(for:uri:)` 是独立的只读方法，调用顺序由 `LSPClient.updateDocument(replacing:...)` 保证：先调 `lspRange`，再调 `documentStore.updateDocument`。

### `editorChange.origin == .userEdit` 的守卫
`externalReload` 时 `replacedRange` 指向文档起始的整体替换，虽然可以编码，但这种场景下全文都变了，全量发送更语义清晰，也避免服务器收到大区间时的性能问题。

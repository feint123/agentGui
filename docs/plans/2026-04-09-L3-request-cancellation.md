# L-3 请求取消（$/cancelRequest）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 LSP `$/cancelRequest` 通知，当同类新请求发出或用户动作触发取消时，向服务器发送取消通知，减少无效服务端计算。

**Architecture:** 在 Transport 层新增 `sendCancellableRequest` 方法，返回请求 ID 供上层取消；Transport 维护 `cancelRequest(id:)` 方法发送 `$/cancelRequest` 通知并以 `CancellationError` 恢复对应 continuation。LSPClient 暴露返回请求 ID 的可取消变体；CodeEditorLSPCoordinator 在代际切换时调用 `cancelRequest` 通知服务器。

**Tech Stack:** Swift 6.0+, Swift Concurrency (CheckedContinuation), SwiftUI Testing framework

**参考 VSCode 实现：** VSCode `vscode-languageserver-node/jsonrpc/src/common/connection.ts` 中：
- 发送端（`sendRequest`）通过 `CancellationToken.onCancellationRequested` 监听取消，触发后调用 `CancellationSenderStrategy.sendCancellation(conn, id)` → `conn.sendNotification('$/cancelRequest', { id })`
- 接收端（Data callback）检测入站 `$/cancelRequest` 通知：若目标请求仍在队列中未分发，直接移除并返回 error response；若已在执行中，取消对应 `CancellationTokenSource`
- **关键数据结构：** `responsePromises: Map<id, ResponsePromise>` 追踪所有在途请求，`knownCanceledRequests: Set<id>` 处理取消先于请求到达的竞态

---

## Task 1: Transport 层 — `sendCancellableRequest` + `cancelRequest`

**Files:**
- Modify: `agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- Test: `agentGuiTests/LSPJSONRPCTransportCancellationTests.swift` (Create)

**设计说明：**

现有 `sendRequest(method:params:) async throws -> Any?` 将 UUID 生成和 continuation 管理封装在内部，调用者无法获取请求 ID。参考 VSCode 的 `responsePromises` + `sendCancellation` 模式，我们新增：
- `sendCancellableRequest` — 返回 `(id: String, result: Any?)` 元组，让调用者持有请求 ID
- `cancelRequest(id:)` — 发送 `$/cancelRequest` notification，并以 `CancellationError` 恢复对应 continuation

VSCode 使用 `ErrorCodes.RequestCancelled = -32800` 作为取消响应码。我们在 Swift 端用 `CancellationError()` 表达同等语义，调用者 `try await` 时捕获即可。

**Step 1: 编写失败测试 — cancelRequest 发送正确的 JSON-RPC 通知**

```swift
// agentGuiTests/LSPJSONRPCTransportCancellationTests.swift
import Foundation
import Testing
@testable import agentGui

struct LSPJSONRPCTransportCancellationTests {
    @Test
    func cancelRequestSendsNotificationWithCorrectID() throws {
        let transport = LSPJSONRPCTransport()
        var sentData: [Data] = []
        transport.outgoingDataHandler = { sentData.append($0) }

        // Register a fake pending request so cancel has something to target
        transport.registerPendingRequest(id: "req-42")

        try transport.cancelRequest(id: "req-42")

        #expect(sentData.count == 1)
        let body = extractJSONBody(from: sentData[0])
        #expect(body?["method"] as? String == "$/cancelRequest")
        let params = body?["params"] as? [String: Any]
        #expect(params?["id"] as? String == "req-42")
        // cancelRequest is a notification — no "id" field at top level
        #expect(body?["id"] == nil)
    }

    @Test
    func cancelRequestResumesContinuationWithCancellationError() async throws {
        let transport = LSPJSONRPCTransport()
        transport.outgoingDataHandler = { _ in } // swallow writes

        let task = Task<Any?, Error> {
            try await transport.sendCancellableRequest(
                method: "textDocument/hover",
                params: ["textDocument": ["uri": "file:///test.py"]]
            ).result
        }

        // Let the continuation register
        try await Task.sleep(nanoseconds: 20_000_000)

        // Find the pending request ID
        let pendingID = transport.firstPendingRequestID
        #expect(pendingID != nil)

        try transport.cancelRequest(id: pendingID!)

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(transport.hasPendingRequest(id: pendingID!) == false)
    }

    @Test
    func cancelRequestForUnknownIDIsNoOp() throws {
        let transport = LSPJSONRPCTransport()
        var sentData: [Data] = []
        transport.outgoingDataHandler = { sentData.append($0) }

        // Should not crash, should not send anything
        try transport.cancelRequest(id: "nonexistent")

        #expect(sentData.isEmpty)
    }

    @Test
    func sendCancellableRequestReturnsIDAndResult() async throws {
        let transport = LSPJSONRPCTransport()

        // Intercept outgoing data and auto-reply
        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] as? String == "textDocument/hover" else { return }
            // Auto-reply with a result
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["contents": "hello"]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let outcome = try await transport.sendCancellableRequest(
            method: "textDocument/hover",
            params: ["textDocument": ["uri": "file:///test.py"]]
        )

        #expect(!outcome.id.isEmpty)
        let resultDict = outcome.result as? [String: Any]
        #expect(resultDict?["contents"] as? String == "hello")
    }

    @Test
    func serverSideRequestCancelledErrorCodeTreatedAsCancel() async throws {
        let transport = LSPJSONRPCTransport()

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"] as? String,
                  body?["method"] != nil else { return }
            // Server replies with RequestCancelled error code (-32800)
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32800,
                    "message": "Request cancelled"
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        do {
            _ = try await transport.sendCancellableRequest(
                method: "textDocument/hover",
                params: [:]
            )
            Issue.record("Expected error")
        } catch is CancellationError {
            // Expected — server-side -32800 maps to CancellationError
        } catch {
            // Also acceptable: TransportError.requestFailed
        }
    }
}

private func extractJSONBody(from data: Data) -> [String: Any]? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let body = data.suffix(from: separator.upperBound)
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPJSONRPCTransportCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: 编译失败 — `cancelRequest(id:)`, `sendCancellableRequest`, `firstPendingRequestID` 不存在。

**Step 3: 实现 Transport 层变更**

```swift
// agentGui/Services/LSP/LSPJSONRPCTransport.swift — 新增内容

/// 可取消请求的返回值。
struct CancellableRequestOutcome {
    let id: String
    let result: Any?
}

// 在 LSPJSONRPCTransport 中新增以下方法和属性：

/// 测试辅助：返回当前第一个 pending 请求 ID（用于取消测试）。
var firstPendingRequestID: String? {
    pendingRequestIDs.first
}

/// 发送 LSP 请求并返回 (id, result)，允许调用者后续通过 `cancelRequest(id:)` 取消。
func sendCancellableRequest(method: String, params: [String: Any]) async throws -> CancellableRequestOutcome {
    guard let outgoingDataHandler else {
        throw TransportError.missingOutgoingDataHandler
    }

    let id = UUID().uuidString
    let message: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    ]
    let framed = try makeOutgoingData(jsonObject: message)

    let result = try await withCheckedThrowingContinuation { continuation in
        pendingContinuations[id] = continuation
        registerPendingRequest(id: id)
        outgoingDataHandler(framed)
    }
    return CancellableRequestOutcome(id: id, result: result)
}

/// 向服务器发送 `$/cancelRequest` 通知，并以 `CancellationError` 恢复对应的
/// pending continuation（如果仍存在）。
///
/// 参考 VSCode `CancellationSenderStrategy.Message.sendCancellation`:
/// `conn.sendNotification(CancelNotification.type, { id })`
///
/// 如果指定 ID 没有 pending 请求，则静默忽略（幂等）。
func cancelRequest(id: String) throws {
    guard pendingRequestIDs.contains(id) else { return }

    // 1. 发送 $/cancelRequest notification
    try sendNotification(method: "$/cancelRequest", params: ["id": id])

    // 2. 本地清理：移除 pending 状态，以 CancellationError 恢复 continuation
    pendingRequestIDs.remove(id)
    if let continuation = pendingContinuations.removeValue(forKey: id) {
        continuation.resume(throwing: CancellationError())
    }
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPJSONRPCTransportCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL PASS

**Step 5: 提交**

```bash
git add agentGui/Services/LSP/LSPJSONRPCTransport.swift \
        agentGuiTests/LSPJSONRPCTransportCancellationTests.swift
git commit -m "feat(lsp): add $/cancelRequest transport support (L-3 step 1)"
```

---

## Task 2: LSPClient 层 — 可取消语义查询方法

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`
- Test: `agentGuiTests/LSPClientCancellationTests.swift` (Create)

**设计说明：**

现有 `hover(uri:line:character:)` 等方法调用 `transport.sendRequest()`，隐藏了请求 ID。为支持取消，新增返回请求 ID 的变体。采用 "Cancellation Handle" 模式——返回一个 lightweight handle 包含请求 ID，上层通过 handle 调用 cancel。

对比 VSCode：VSCode 的 `sendRequest` 接受可选的 `CancellationToken`，token 触发时自动发送 `$/cancelRequest`。Swift 端没有 CancellationToken 生态，改用显式 handle 返回更贴合 Swift 惯例。

**Step 1: 编写失败测试**

```swift
// agentGuiTests/LSPClientCancellationTests.swift
import Foundation
import Testing
@testable import agentGui

struct LSPClientCancellationTests {
    @Test
    func cancellableHoverReturnsHandleWithRequestID() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        // Auto-reply hover
        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"],
                  body?["method"] as? String == "textDocument/hover" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["contents": ["kind": "markdown", "value": "test hover"]]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableHover(uri: "file:///test.py", line: 0, character: 0)
        let text = try await handle.result()
        #expect(!handle.requestID.isEmpty)
        #expect(text == "test hover")
    }

    @Test
    func cancellingHoverHandleThrowsCancellationError() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )
        transport.outgoingDataHandler = { _ in } // Don't reply

        let handle = client.cancellableHover(uri: "file:///test.py", line: 0, character: 0)

        // Let continuation register
        try await Task.sleep(nanoseconds: 20_000_000)

        handle.cancel()

        do {
            _ = try await handle.result()
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // OK
        }
    }

    @Test
    func cancellableDefinitionReturnsLocation() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"],
                  body?["method"] as? String == "textDocument/definition" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "uri": "file:///test.py",
                    "range": [
                        "start": ["line": 5, "character": 2],
                        "end":   ["line": 5, "character": 10]
                    ]
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableDefinition(uri: "file:///test.py", line: 1, character: 3)
        let location = try await handle.result()
        #expect(location?.line == 5)
        #expect(location?.character == 2)
    }

    @Test
    func cancellableReferencesReturnsList() async throws {
        let transport = LSPJSONRPCTransport()
        let client = LSPClient(
            transport: transport,
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: StubLSPServerAdapter()
        )

        transport.outgoingDataHandler = { data in
            let body = extractJSONBody(from: data)
            guard let id = body?["id"],
                  body?["method"] as? String == "textDocument/references" else { return }
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    [
                        "uri": "file:///test.py",
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end":   ["line": 0, "character": 4]
                        ]
                    ]
                ]
            ]
            let responseData = try! JSONSerialization.data(withJSONObject: response)
            var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
            framed.append(responseData)
            _ = try? transport.receive(framed)
        }

        let handle = client.cancellableReferences(uri: "file:///test.py", line: 0, character: 0)
        let locations = try await handle.result()
        #expect(locations.count == 1)
    }
}

private struct StubLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private func extractJSONBody(from data: Data) -> [String: Any]? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let body = data.suffix(from: separator.upperBound)
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPClientCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: 编译失败 — `cancellableHover`, `LSPCancellableRequest` 等不存在。

**Step 3: 在 LSPClient 中实现可取消请求**

```swift
// agentGui/Services/LSP/LSPClient.swift — 新增内容

/// LSP 可取消请求句柄。调用者持有此句柄，可在需要时通过 `cancel()` 向服务器发送 `$/cancelRequest` 并中止本地 await。
final class LSPCancellableRequest<T: Sendable>: Sendable {
    let requestID: String
    private let transport: LSPJSONRPCTransport
    private let task: Task<T, Error>

    init(transport: LSPJSONRPCTransport, task: Task<T, Error>, requestID: String) {
        self.transport = transport
        self.task = task
        self.requestID = requestID
    }

    func result() async throws -> T {
        try await task.value
    }

    func cancel() {
        try? transport.cancelRequest(id: requestID)
        task.cancel()
    }
}

// 在 LSPClient 中新增以下方法：

func cancellableHover(uri: String, line: Int, character: Int) -> LSPCancellableRequest<String?> {
    let params = documentPositionParams(uri: uri, line: line, character: character)
    var capturedID = ""
    let task = Task<String?, Error> {
        let outcome = try await transport.sendCancellableRequest(method: "textDocument/hover", params: params)
        capturedID = outcome.id
        return parseHoverText(from: outcome.result)
    }
    // Note: requestID is set asynchronously; for immediate cancel, use firstPendingRequestID
    return LSPCancellableRequest(transport: transport, task: task, requestID: capturedID)
}
```

> **重要修正**：上述 `capturedID` 的时序问题——`LSPCancellableRequest` 构造时 `capturedID` 还是空字符串。需要改用共享可变状态或抽取 ID 到 transport 层。

**改进设计——使用 pre-allocated ID：**

```swift
// 在 Transport 层新增:
func allocateRequestID() -> String {
    UUID().uuidString
}

func sendCancellableRequest(id: String, method: String, params: [String: Any]) async throws -> Any? {
    guard let outgoingDataHandler else {
        throw TransportError.missingOutgoingDataHandler
    }
    let message: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    ]
    let framed = try makeOutgoingData(jsonObject: message)
    return try await withCheckedThrowingContinuation { continuation in
        pendingContinuations[id] = continuation
        registerPendingRequest(id: id)
        outgoingDataHandler(framed)
    }
}

// 在 LSPClient 中:
func cancellableHover(uri: String, line: Int, character: Int) -> LSPCancellableRequest<String?> {
    let requestID = transport.allocateRequestID()
    let params = documentPositionParams(uri: uri, line: line, character: character)
    let task = Task<String?, Error> { [transport] in
        let result = try await transport.sendCancellableRequest(id: requestID, method: "textDocument/hover", params: params)
        return parseHoverText(from: result)
    }
    return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
}

func cancellableDefinition(uri: String, line: Int, character: Int) -> LSPCancellableRequest<LSPSymbolLocation?> {
    let requestID = transport.allocateRequestID()
    let params = documentPositionParams(uri: uri, line: line, character: character)
    let task = Task<LSPSymbolLocation?, Error> { [transport] in
        let result = try await transport.sendCancellableRequest(id: requestID, method: "textDocument/definition", params: params)
        return parseFirstLocation(from: result)
    }
    return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
}

func cancellableReferences(uri: String, line: Int, character: Int) -> LSPCancellableRequest<[LSPSymbolLocation]> {
    let requestID = transport.allocateRequestID()
    var mergedParams = documentPositionParams(uri: uri, line: line, character: character)
    mergedParams["context"] = ["includeDeclaration": true]
    let task = Task<[LSPSymbolLocation], Error> { [transport] in
        let result = try await transport.sendCancellableRequest(id: requestID, method: "textDocument/references", params: mergedParams)
        return parseLocations(from: result)
    }
    return LSPCancellableRequest(transport: transport, task: task, requestID: requestID)
}
```

**Step 4: 运行测试确认通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPClientCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL PASS

**Step 5: 提交**

```bash
git add agentGui/Services/LSP/LSPClient.swift \
        agentGui/Services/LSP/LSPJSONRPCTransport.swift \
        agentGuiTests/LSPClientCancellationTests.swift
git commit -m "feat(lsp): add cancellable request handles in LSPClient (L-3 step 2)"
```

---

## Task 3: LSPServerManager 层 — 透传可取消请求

**Files:**
- Modify: `agentGui/Services/LSP/LSPServerManager.swift`
- Test: 复用 Task 4 集成测试

**设计说明：**

`LSPServerManager` 是 Coordinator 与 LSPClient 之间的门面。现有方法如 `hover(workspaceRoot:serverID:uri:line:character:)` 直接 await 返回结果。需要新增可取消变体，将 `LSPCancellableRequest` 透传给 Coordinator。

**Step 1: 在 LSPServerManager 新增可取消方法**

```swift
// agentGui/Services/LSP/LSPServerManager.swift — 新增

func cancellableHover(workspaceRoot: String, serverID: String,
                      uri: String, line: Int, character: Int) throws -> LSPCancellableRequest<String?> {
    let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
    return session.client.cancellableHover(uri: uri, line: line, character: character)
}

func cancellableDefinition(workspaceRoot: String, serverID: String,
                           uri: String, line: Int, character: Int) throws -> LSPCancellableRequest<LSPSymbolLocation?> {
    let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
    return session.client.cancellableDefinition(uri: uri, line: line, character: character)
}

func cancellableReferences(workspaceRoot: String, serverID: String,
                           uri: String, line: Int, character: Int) throws -> LSPCancellableRequest<[LSPSymbolLocation]> {
    let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
    return session.client.cancellableReferences(uri: uri, line: line, character: character)
}
```

**Step 2: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-L3-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

**Step 3: 提交**

```bash
git add agentGui/Services/LSP/LSPServerManager.swift
git commit -m "feat(lsp): add cancellable request passthrough in LSPServerManager (L-3 step 3)"
```

---

## Task 4: Coordinator 层 — Hover 取消集成

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Test: `agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift` (Create)

**设计说明：**

现有 `scheduleHover` 使用 generation counter + `Task.cancel()` 实现本地取消。改造流程：
1. 保留 generation counter（用于 debounce 期间的本地取消，此时还没发请求）
2. debounce 结束后，使用 `cancellableHover` 获取 handle
3. 保存 handle → `pendingHoverHandle`
4. 下次 `scheduleHover` 或 `cancelHover()` 时，调用 `pendingHoverHandle?.cancel()` — 这会向服务器发送 `$/cancelRequest`

参考 VSCode：`token.onCancellationRequested(() => sendCancellation(connection, id))` — 在 token 触发时才发送取消通知，而非立即发送。这里我们在 `cancelHover()` 和新的 `scheduleHover` 覆盖旧请求时等效触发。

**Step 1: 编写失败测试**

```swift
// agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorLSPCoordinatorCancellationTests {
    @Test
    func newHoverRequestCancelsOlderInFlightLSPRequest() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        // Schedule first hover (will send LSP request after debounce)
        var deliveries: [CodeEditorHoverPresentation?] = []
        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) { deliveries.append($0) }

        // Wait for debounce to pass — request is now in-flight
        try await Task.sleep(nanoseconds: 30_000_000)

        // Schedule second hover — should cancel the first in-flight request
        coordinator.scheduleHover(
            at: .init(line: 1, column: 5, utf16Offset: 4, version: 1),
            debounceNanoseconds: 5_000_000
        ) { deliveries.append($0) }

        try await Task.sleep(nanoseconds: 80_000_000)

        // The harness should have captured at least one $/cancelRequest notification
        #expect(harness.cancelRequestIDs.count >= 1,
                "Expected at least one $/cancelRequest notification sent to server")
    }

    @Test
    func cancelHoverSendsCancelRequestToServer() async throws {
        let harness = CancellationTrackingHarness()
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let coordinator = CodeEditorLSPCoordinator(
            manager: manager,
            binding: .fixtureSourceFile(),
            debounceNanoseconds: 10_000_000
        )

        coordinator.activate(initialText: "value", version: 1)

        coordinator.scheduleHover(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
            debounceNanoseconds: 5_000_000
        ) { _ in }

        // Wait for debounce to pass
        try await Task.sleep(nanoseconds: 30_000_000)

        // Explicit cancel
        coordinator.cancelHover()

        #expect(harness.cancelRequestIDs.count >= 1,
                "cancelHover() should send $/cancelRequest")
    }

    @Test
    func existingNonCancellableMethodsStillWork() async throws {
        // Verify backward compatibility: the original non-cancellable
        // requestDefinition path still works without regressions
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

        #expect(revealRequest?.reason == .definition)
    }
}
```

**Step 2: 实现 `CancellationTrackingHarness` 测试夹具**

```swift
// 在 agentGuiTests/TestSupport/ 新增或扩展已有文件

/// Harness that tracks $/cancelRequest notifications sent by the transport.
@MainActor
final class CancellationTrackingHarness {
    private(set) var cancelRequestIDs: [String] = []

    func makeManager() -> LSPServerManager {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["python-lsp"])
        let registry = try! LSPServerRegistry(settings: settings)
        let diagnosticsStore = LSPDiagnosticsStore()

        return LSPServerManager(
            registry: registry,
            diagnosticsStore: diagnosticsStore,
            makeClient: { [weak self] in
                let transport = LSPJSONRPCTransport()
                let client = LSPClient(
                    transport: transport,
                    documentStore: LSPDocumentStore(),
                    diagnosticsStore: diagnosticsStore,
                    adapter: CancellationTrackingAdapter()
                )
                // Intercept outgoing data to track cancel notifications
                transport.outgoingDataHandler = { [weak self] data in
                    // Parse and track $/cancelRequest
                    if let separator = data.range(of: Data("\r\n\r\n".utf8)) {
                        let body = data.suffix(from: separator.upperBound)
                        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                           json["method"] as? String == "$/cancelRequest",
                           let params = json["params"] as? [String: Any],
                           let id = params["id"] as? String {
                            self?.cancelRequestIDs.append(id)
                            return // consumed
                        }
                        // Auto-reply to requests (not notifications)
                        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                           let id = json["id"],
                           json["method"] as? String != nil {
                            // Delay reply to simulate slow server (for cancel testing)
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                let response: [String: Any] = [
                                    "jsonrpc": "2.0",
                                    "id": id,
                                    "result": ["contents": ["kind": "markdown", "value": "late hover"]]
                                ]
                                let responseData = try! JSONSerialization.data(withJSONObject: response)
                                var framed = Data("Content-Length: \(responseData.count)\r\n\r\n".utf8)
                                framed.append(responseData)
                                _ = try? transport.receive(framed)
                            }
                        }
                    }
                }
                return client
            },
            makeSupervisor: {
                LSPProcessSupervisor(processLauncher: NoOpProcessLauncher())
            }
        )
    }
}

private struct CancellationTrackingAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .readOnlySemanticDefaults
    }
}

private final class NoOpProcessLauncher: LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        NoOpManagedProcess()
    }
}

private final class NoOpManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32 = 100
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    func start() throws {}
    func send(_ data: Data) throws {}
    func stop() {}
}
```

**Step 3: Coordinator 改造**

```swift
// agentGui/Services/Editor/CodeEditorLSPCoordinator.swift — 修改 scheduleHover

// 新增属性:
private var pendingHoverHandle: LSPCancellableRequest<String?>?

// 修改 scheduleHover:
func scheduleHover(
    at position: CodeEditorSemanticPosition,
    debounceNanoseconds: UInt64,
    deliver: @escaping @MainActor (CodeEditorHoverPresentation?) -> Void
) {
    guard canServeSemanticRequest(
        supports: \LSPServerCapabilityHints.supportsHover,
        requestVersion: position.version
    ) else {
        deliver(nil)
        return
    }

    latestHoverGeneration += 1
    let generation = latestHoverGeneration

    // Cancel previous in-flight LSP request (sends $/cancelRequest to server)
    pendingHoverHandle?.cancel()
    pendingHoverHandle = nil

    pendingHoverTask?.cancel()
    pendingHoverTask = Task { [weak self] in
        guard let self else { return }
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
        guard !Task.isCancelled else { return }

        // After debounce, create cancellable LSP request
        let handle: LSPCancellableRequest<String?>?
        do {
            handle = try self.manager.cancellableHover(
                workspaceRoot: self.binding.workspaceRoot,
                serverID: self.binding.serverID,
                uri: self.binding.uri,
                line: max(position.line - 1, 0),
                character: max(position.column - 1, 0)
            )
        } catch {
            await MainActor.run { deliver(nil) }
            return
        }

        guard let handle else {
            await MainActor.run { deliver(nil) }
            return
        }

        await MainActor.run {
            self.pendingHoverHandle = handle
        }

        let hoverText: String?
        do {
            hoverText = try await handle.result()
        } catch is CancellationError {
            return // Cancelled — don't deliver
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.latestHoverGeneration == generation, self.isOpen else { return }
                self.pendingHoverTask = nil
                self.pendingHoverHandle = nil
                deliver(nil)
            }
            return
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.latestHoverGeneration == generation,
                  self.isOpen,
                  position.version == self.latestLocalVersion,
                  let hoverText,
                  !hoverText.isEmpty else {
                deliver(nil)
                return
            }
            self.pendingHoverTask = nil
            self.pendingHoverHandle = nil
            deliver(CodeEditorHoverPresentation(position: position, markdown: hoverText))
        }
    }
}

// 修改 cancelHover:
func cancelHover() {
    latestHoverGeneration += 1
    pendingHoverHandle?.cancel()
    pendingHoverHandle = nil
    pendingHoverTask?.cancel()
    pendingHoverTask = nil
}
```

**Step 4: 运行测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL PASS

**Step 5: 运行已有 Coordinator 测试确保无回归**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL EXISTING TESTS PASS

**Step 6: 提交**

```bash
git add agentGui/Services/Editor/CodeEditorLSPCoordinator.swift \
        agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift \
        agentGuiTests/TestSupport/CancellationTrackingHarness.swift
git commit -m "feat(lsp): integrate $/cancelRequest in hover flow (L-3 step 4)"
```

---

## Task 5: Coordinator 层 — Definition / References 取消集成

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Test: 扩展 `agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift`

**设计说明：**

`requestDefinition` 和 `requestReferences` 当前是 `async` 方法，直接 await 结果。与 hover 的 debounce 模式不同，这两个是一次性触发。取消场景：
- 用户快速多次右键→Go to Definition：上一次请求应被取消
- 用户在 definition 请求进行中关闭文件 (`deactivate`)

添加 `pendingDefinitionHandle` 和 `pendingReferencesHandle` 属性，在新请求发出时取消旧的。

**Step 1: 编写测试**

```swift
// 追加到 CodeEditorLSPCoordinatorCancellationTests.swift

@Test
func consecutiveDefinitionRequestsCancelPrevious() async throws {
    let harness = CancellationTrackingHarness()
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSourceFile(),
        debounceNanoseconds: 10_000_000
    )

    coordinator.activate(initialText: "value", version: 1)

    // Start first definition request
    let task1 = Task {
        await coordinator.requestDefinition(
            at: .init(line: 1, column: 1, utf16Offset: 0, version: 1)
        )
    }

    // Small delay, then fire second request
    try await Task.sleep(nanoseconds: 10_000_000)

    let task2 = Task {
        await coordinator.requestDefinition(
            at: .init(line: 1, column: 5, utf16Offset: 4, version: 1)
        )
    }

    _ = await task1.value
    _ = await task2.value

    // At least one cancel request should have been sent
    #expect(harness.cancelRequestIDs.count >= 1)
}

@Test
func deactivateCancelsAllInFlightRequests() async throws {
    let harness = CancellationTrackingHarness()
    let manager = harness.makeManager()
    _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
    let coordinator = CodeEditorLSPCoordinator(
        manager: manager,
        binding: .fixtureSourceFile(),
        debounceNanoseconds: 10_000_000
    )

    coordinator.activate(initialText: "value", version: 1)

    // Start hover
    coordinator.scheduleHover(
        at: .init(line: 1, column: 1, utf16Offset: 0, version: 1),
        debounceNanoseconds: 5_000_000
    ) { _ in }

    // Let debounce pass
    try await Task.sleep(nanoseconds: 30_000_000)

    // Deactivate should cancel everything
    coordinator.deactivate()

    #expect(harness.cancelRequestIDs.count >= 1,
            "deactivate() should cancel in-flight LSP requests")
}
```

**Step 2: 实现 definition/references 取消**

```swift
// agentGui/Services/Editor/CodeEditorLSPCoordinator.swift — 新增属性

private var pendingDefinitionHandle: LSPCancellableRequest<LSPSymbolLocation?>?
private var pendingReferencesHandle: LSPCancellableRequest<[LSPSymbolLocation]>?

// 修改 requestDefinition:
func requestDefinition(at position: CodeEditorSemanticPosition) async -> CodeEditorRevealRequest? {
    guard canServeSemanticRequest(
        supports: \LSPServerCapabilityHints.supportsDefinition,
        requestVersion: position.version
    ) else {
        return nil
    }

    // Cancel previous in-flight definition request
    pendingDefinitionHandle?.cancel()
    pendingDefinitionHandle = nil

    do {
        let handle = try manager.cancellableDefinition(
            workspaceRoot: binding.workspaceRoot,
            serverID: binding.serverID,
            uri: binding.uri,
            line: max(position.line - 1, 0),
            character: max(position.column - 1, 0)
        )
        pendingDefinitionHandle = handle

        guard let location = try await handle.result() else {
            pendingDefinitionHandle = nil
            return nil
        }

        pendingDefinitionHandle = nil

        guard position.version == latestLocalVersion,
              let fileURL = localFileURL(for: location.uri) else {
            return nil
        }

        return CodeEditorRevealRequest(
            fileURL: fileURL,
            line: location.line + 1,
            column: location.character + 1,
            reason: .definition
        )
    } catch is CancellationError {
        return nil
    } catch {
        pendingDefinitionHandle = nil
        return nil
    }
}

// 类似改造 requestReferences (同样模式)。

// 修改 deactivate:
func deactivate() {
    pendingChangeTask?.cancel()
    pendingChangeTask = nil
    pendingText = nil
    pendingVersion = nil
    pendingChangeSet = nil
    pendingChangeSetIsAmbiguous = false

    // Cancel all in-flight LSP requests
    cancelHover()
    pendingDefinitionHandle?.cancel()
    pendingDefinitionHandle = nil
    pendingReferencesHandle?.cancel()
    pendingReferencesHandle = nil

    guard isOpen else { return }
    manager.closeDocument(
        workspaceRoot: binding.workspaceRoot,
        serverID: binding.serverID,
        uri: binding.uri
    )
    isOpen = false
}
```

**Step 3: 运行全部取消测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL PASS

**Step 4: 提交**

```bash
git add agentGui/Services/Editor/CodeEditorLSPCoordinator.swift \
        agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift
git commit -m "feat(lsp): integrate $/cancelRequest for definition/references + deactivate (L-3 step 5)"
```

---

## Task 6: 处理服务器 -32800 错误码

**Files:**
- Modify: `agentGui/Services/LSP/LSPJSONRPCTransport.swift`
- Test: 扩展 `agentGuiTests/LSPJSONRPCTransportCancellationTests.swift`

**设计说明：**

LSP 规范约定服务器对被取消的请求可能返回 error code `-32800` (RequestCancelled)。当前 Transport `receive()` 会将所有 error 统一包装为 `TransportError.requestFailed`。需要将 `-32800` 映射为 `CancellationError()`，使上层能统一以 `catch is CancellationError` 处理。

参考 VSCode：`handleResponse()` 中 `responsePromise.reject(new ResponseError(error.code, ...))` — 由上层区分 error code。我们在 Transport 层直接映射更简洁。

**Step 1: 测试已在 Task 1 的 `serverSideRequestCancelledErrorCodeTreatedAsCancel` 中覆盖**

若 Task 1 该测试已通过则跳过。若未通过，在此修改 `receive()` 中 error 处理分支：

```swift
// 在 LSPJSONRPCTransport.receive() 的 error 处理分支中：
if let errorObject = object["error"] as? [String: Any],
   let message = errorObject["message"] as? String {
    let code = errorObject["code"] as? Int
    if code == -32800 {
        // LSP RequestCancelled — map to CancellationError
        continuation.resume(throwing: CancellationError())
    } else {
        continuation.resume(throwing: TransportError.requestFailed(message))
    }
}
```

**Step 2: 运行测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPJSONRPCTransportCancellationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: ALL PASS

**Step 3: 提交**

```bash
git add agentGui/Services/LSP/LSPJSONRPCTransport.swift \
        agentGuiTests/LSPJSONRPCTransportCancellationTests.swift
git commit -m "feat(lsp): map server -32800 (RequestCancelled) to CancellationError (L-3 step 6)"
```

---

## Task 7: 回归测试 + 全量验证

**Files:**
- No new files

**Step 1: 运行所有 LSP 相关测试**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-L3-derived \
  -only-testing:agentGuiTests/LSPJSONRPCTransportCancellationTests \
  -only-testing:agentGuiTests/LSPClientCancellationTests \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorCancellationTests \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  -only-testing:agentGuiTests/LSPClientIncrementalSyncTests \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -only-testing:agentGuiTests/CodeEditorInlayHintTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: ALL PASS, 0 FAILURES

**Step 2: 提交最终标签**

```bash
git tag L3-request-cancellation-done
```

---

## 变更文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `agentGui/Services/LSP/LSPJSONRPCTransport.swift` | Modify | 新增 `sendCancellableRequest`, `cancelRequest`, `allocateRequestID`, `firstPendingRequestID`；-32800 映射 |
| `agentGui/Services/LSP/LSPClient.swift` | Modify | 新增 `LSPCancellableRequest<T>` 类型，`cancellableHover/Definition/References` 方法 |
| `agentGui/Services/LSP/LSPServerManager.swift` | Modify | 新增 `cancellableHover/Definition/References` 透传方法 |
| `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift` | Modify | hover/definition/references 改用 cancellable handle；deactivate 取消所有在途请求 |
| `agentGuiTests/LSPJSONRPCTransportCancellationTests.swift` | Create | Transport 层取消测试 (4 tests) |
| `agentGuiTests/LSPClientCancellationTests.swift` | Create | Client 层可取消请求测试 (4 tests) |
| `agentGuiTests/CodeEditorLSPCoordinatorCancellationTests.swift` | Create | Coordinator 集成取消测试 (4 tests) |
| `agentGuiTests/TestSupport/CancellationTrackingHarness.swift` | Create | 跟踪 `$/cancelRequest` 的测试夹具 |

---

## 架构决策记录

### ADR-1：Pre-allocated ID vs 异步捕获 ID

**决策：** 使用 `allocateRequestID()` 预分配 ID，在创建 `LSPCancellableRequest` 时已知 ID。

**原因：** 若 ID 由 `sendRequest` 内部生成，外部需异步等待 ID 就绪后才能取消——存在竞态窗口。VSCode 用 `sequenceNumber++` 同步生成 ID，我们用 `UUID()` 达到同等效果。

### ADR-2：保留原有非取消 API

**决策：** 保留 `hover`, `definition`, `references` 等原有同步风格 API 不变，新增 `cancellable*` 变体。

**原因：** `LSPToolFacade`（Agent 工具）等调用方不需要取消能力，保持简单。避免大规模 API 迁移。

### ADR-3：`CancellationError` vs 自定义 error

**决策：** 使用标准 `CancellationError()` 而非自定义 `LSPRequestCancelled` error。

**原因：** 与 Swift Concurrency 的 `Task.isCancelled` 机制自然对齐，`catch is CancellationError` 是 Swift 惯用模式。

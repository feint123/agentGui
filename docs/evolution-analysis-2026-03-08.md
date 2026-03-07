# agentGui 进化分析报告

> **版本**: 1.0
> **日期**: 2026-03-08
> **作者**: GitHub Copilot (Claude Sonnet 4.6)
> **基准代码**: ~9,951 行 Swift，46 个文件

---

## 概览

agentGui 当前已完成一个功能较为完整的 macOS 原生 AI Agent 客户端的基础搭建，核心能力（流式对话、Agentic Loop、工具调用、Skills 系统）均已实现。但在**安全性、稳定性、用户体验、功能完整度和架构健康度**等方面存在明显缺口，距离一款成熟的生产级产品仍有较大迭代空间。

本报告将问题和机会按优先级分为四级：

| 优先级 | 含义 |
|--------|------|
| 🔴 P0 | 阻断性问题：安全漏洞、数据丢失、核心功能缺失 |
| 🟠 P1 | 重要问题：明显影响用户体验或系统稳定性 |
| 🟡 P2 | 改进项：代码质量、架构优化、次要功能 |
| 🟢 P3 | 创新点：差异化特性、长期竞争力 |

---

## 一、安全性问题 🔴 P0

### 1.1 API Key 明文存储在 SwiftData

**位置**: `Models/AppSettings.swift`

当前 `AppSettings.apiKey` 作为普通字符串字段保存在 SwiftData 的 SQLite 数据库中，存储路径为 `~/.agentgui/default.store`。任何可以读取该路径的进程或用户都能直接获取 API Key。

**风险**: 高。API Key 泄露意味着攻击者可以以用户身份无限调用 Anthropic API，产生巨额费用，同时暴露用户的所有对话数据。

**解决方案**:
```swift
// 推荐：使用 macOS Keychain
import Security

extension AppSettings {
    func saveApiKey(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.agentgui.apikey",
            kSecValueData as String: key.data(using: .utf8)!
        ]
        SecItemDelete(query as CFDictionary) // 先删除旧值
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }
    
    func loadApiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.agentgui.apikey",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

---

### 1.2 Bash 工具缺乏危险命令拦截

**位置**: `Services/BashSession.swift`, `Services/ClaudeService+ToolDispatch.swift`

当前 Bash 工具可以执行 `rm -rf /`、`dd if=/dev/zero of=/dev/sda`、`curl ... | sh` 等高危命令，没有任何拦截机制。

**解决方案**:
- 维护一个危险命令黑名单（`rm -rf`, `dd`, `mkfs`, `format`, `chmod 777` 等）
- 对包含文件删除、磁盘操作的命令弹窗要求用户二次确认
- 支持目录白名单，限制文件操作范围

---

## 二、数据可靠性问题 🔴 P0

### 2.1 SwiftData 保存错误被全部静默丢弃

**位置**: 全代码库，`try? modelContext.save()` 出现约 25+ 处

`try?` 会把 SwiftData 保存时的所有错误转换为 `nil` 并静默抛弃。实际效果是：当 SQLite 磁盘已满、权限错误或数据库损坏时，应用不会告知用户，导致**消息、会话、工具调用记录静默丢失**。

**解决方案**:
```swift
// 统一错误处理 helper
extension ModelContext {
    func safeSave() {
        do {
            try save()
        } catch {
            // 至少记录到 os_log，严重时弹窗通知用户
            Logger.storage.error("SwiftData save failed: \(error)")
            // 可选：通过 NotificationCenter 广播给 UI 层显示 Toast
        }
    }
}
```

---

### 2.2 ExecutionPlan / TodoItem / CompletionVerification 不持久化

**位置**: `Models/ExecutionPlan.swift`, `Models/TodoItem.swift`

这三类数据存储在 `ClaudeService` 的内存字典（以 `sessionId` 为 key）中，应用重启后**全部丢失**。对于长时间运行的 Agent 任务，用户重启后将无法看到之前的执行计划和 Todo 进度。

**解决方案**: 将 `ExecutionPlan`、`TodoItem` 改为 `@Model` 类，与 `Session` 建立关联关系，持久化到 SwiftData。

---

## 三、核心功能缺口 🔴 P0 / 🟠 P1

### 3.1 会话标题无自动生成

**当前状态**: 所有新会话标题固定为「新对话」

用户发送第一条消息后，系统应在后台异步调用轻量模型（`claude-haiku`）生成简洁的会话标题，无需用户手动命名。这是所有主流 AI 客户端（ChatGPT、Claude.ai）的基础体验。

```swift
func generateTitle(for session: Session, firstMessage: String) async {
    let prompt = "用不超过10个字概括这个对话主题（只输出标题，不加引号）：\(firstMessage)"
    // 调用 claude-haiku 获取标题并更新 session.title
}
```

---

### 3.2 代码块无语法高亮

**当前状态**: `MarkdownMessageView` 的代码块仅用等宽字体原样显示

代码高亮是代码类 AI 工具最高频使用的功能之一。手写的 Markdown 解析器目前对代码块没有任何着色。

**推荐方案**: 集成 [Splash](https://github.com/JohnSundell/Splash) 或 [Highlightr](https://github.com/raspu/Highlightr)，两者均支持 Swift Package Manager，覆盖 Swift/Python/JavaScript/Shell 等主流语言。

---

### 3.3 停止按钮功能不完整

**当前状态**: `FEATURE_REQUIREMENTS.md` 中标记为 P0 未完成；UI 中代码路径存在但行为不明确

Agentic Loop 启动后，用户需要可靠的中断机制。当前的 `stopRequested` 标志在多个代码路径中可能存在竞态条件，需要使用 Swift Structured Concurrency 的取消机制统一管理。

---

### 3.4 session.workingDirectory 被忽略

**位置**: `Services/ClaudeService+ToolDispatch.swift`, `effectiveWorkingDirectory(session:settings:)`

`Session` 模型有 `workingDirectory` 字段，支持每个会话独立的工作目录，但 `effectiveWorkingDirectory` 函数只读取 `settings.workingDirectory`，完全忽略 `session.workingDirectory`。这是一个**功能已建模但未接通**的 bug。

**修复**:
```swift
func effectiveWorkingDirectory(session: Session, settings: AppSettings) -> String {
    if let dir = session.workingDirectory, !dir.isEmpty { return dir }
    if let dir = settings.workingDirectory, !dir.isEmpty { return dir }
    return FileManager.default.homeDirectoryForCurrentUser.path
}
```

---

### 3.5 contextWindowSize 硬编码 200k，不区分模型

**位置**: `Services/ACPClientService.swift`

当前 `contextWindowSize(for:)` 无论传入何种模型名称都返回 `200_000`。Claude 3 Haiku 的上下文窗口是 200k，但不同模型规格不同，且该数值影响上下文压缩触发时机。

```swift
func contextWindowSize(for model: String) -> Int {
    switch model {
    case let m where m.contains("haiku"):    return 200_000
    case let m where m.contains("sonnet"):   return 200_000
    case let m where m.contains("opus"):     return 200_000
    default:                                  return 200_000
    }
    // 更重要的是：当压缩阈值 75% 时，实际计算应基于 input_tokens
    // 而不是简单地与硬编码 totalSize 比较
}
```

---

## 四、架构与代码质量问题 🟠 P1 / 🟡 P2

### 4.1 Repository 层存在但从未被使用

**位置**: `Repositories/` 目录

`SessionRepository`, `MessageRepository` 实现了完整的 CRUD 接口，定义了 `SessionRepositoryProtocol` 和 `MessageRepositoryProtocol`，但 `ClaudeService` 和所有 View 从未使用这些 Repository，而是直接调用 `modelContext`。

**影响**: 
- Repository 层成为维护负担（需要同步更新）
- 无法替换存储后端进行单元测试
- 代码库中存在两种实际效果相同但路径完全不同的持久化方式

**建议**: 要么统一迁移到 Repository 层（推荐，利于测试），要么删除 Repository 层减少认知负担。

---

### 4.2 两个几乎相同的 executeTool 重载

**位置**: `Services/ClaudeService+ToolDispatch.swift`

存在两个签名不同但实现几乎相同的 `executeTool`：
- `executeTool(_:session:messageId:)` — 接受 `Session` 对象
- `executeTool(_:sessionId:messageId:)` — 接受 `sessionId: String`

两者逻辑高度重叠，任何新增工具都需要在两处同步修改，容易产生不一致。应合并为一个以 `Session` 为参数的版本。

---

### 4.3 主服务文件命名错误

**位置**: `Services/ACPClientService.swift`

该文件在 ACP→Anthropic API 迁移后从未重命名，实际包含的是整个 `ClaudeService` 的主类定义。这对新参与者造成极大困惑（找不到 `ClaudeService` 在哪里定义）。

**建议**: 重命名为 `ClaudeService.swift`。这是一个低成本、高收益的清理项。

---

### 4.4 死代码清理

以下文件为 ACP 时代遗留的空壳（每个文件仅 6 行注释），可安全删除：

| 文件 | 原用途 |
|------|--------|
| `Models/AgentConfiguration.swift` | ACP 代理配置 |
| `Models/PermissionRequest.swift` | ACP 权限模型 |
| `Services/AgentLifecycleService.swift` | ACP 生命周期 |
| `Services/SessionService.swift` | ACP 会话服务 |
| `Repositories/AgentRepository.swift` | ACP 代理仓库 |
| `Utilities/ACPAdapters.swift` | ACP 适配器 |
| `Views/AgentListView.swift` | Agent 列表 UI（空存根） |
| `Views/AgentConfigSheet.swift` | Agent 配置面板（空存根） |
| `ViewModels/AgentListViewModel.swift` | Agent ViewModel（空存根） |
| `Utilities/AgentClientError.swift` | 遗留 ACP 类型 |

---

### 4.5 Bing 网页抓取的脆弱性

**位置**: `Services/ClaudeService+WebTools.swift`

`executeWebSearchTool` 通过解析 Bing HTML 返回搜索结果，使用正则匹配 `<h2>` 标签。这类屏幕抓取方案**随时可能因 Bing 更改页面结构而失效**，且可能违反 Bing 服务条款。

**推荐替代方案**:
- Bing Search API（官方，付费）
- DuckDuckGo Instant Answer API（免费，有速率限制）
- Tavily API（专为 AI Agent 设计，高质量搜索结果）
- SerpAPI（通用搜索 API）

---

### 4.6 BashSession 轮询机制

**位置**: `Services/BashSession.swift`

当前通过轮询检测输出结束的 sentinel 字符串，在高负载时有 50-200ms 的延迟，且需要维护 50KB 的输出缓冲区上限。

**改进方向**: 使用 `DispatchIO` 或 `AsyncStream` 基于事件通知，消除轮询开销，输出截断也可以做得更智能（保留头尾，截断中间部分）。

---

### 4.7 Markdown 渲染器边缘情况

**位置**: `Views/MarkdownMessageView.swift`（447 行自定义解析器）

手写解析器在以下场景存在已知风险：
- 嵌套 Markdown（粗体内的代码、列表内的链接）
- 多行代码块中的特殊字符
- 表格单元格中的 Markdown 语法
- 超长无换行字符串导致布局溢出

**建议**: 长期考虑替换为 [swift-markdown](https://github.com/apple/swift-markdown)（Apple 官方）+ 自定义渲染器，或评估 [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)。

---

### 4.8 硬编码中文语言环境

**位置**: `Models/Message.swift`

```swift
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "zh_CN")  // 硬编码
```

应使用 `Locale.current` 或通过 `AppSettings` 支持用户选择语言。

---

## 五、用户体验完善项 🟠 P1

### 5.1 缺少消息搜索

用户无法在历史会话中搜索关键词。这是所有主流聊天工具的基础功能，SwiftData 提供 `#Predicate` 支持全文模糊搜索。

### 5.2 会话导出功能缺失

无法将对话导出为 Markdown、PDF 或 JSON，导致会话内容被锁定在应用内。导出功能可以显著提升信任度和实用价值。

### 5.3 多模态输入不完整

虽然有图片分析工具（`ClaudeService+MediaTools.swift`），但输入框的拖拽上传体验尚不完善，PDF 上传流程也不够直观。

### 5.4 深色模式适配

部分 View 使用了硬编码颜色（如 `Color.white`, `Color.black`），未使用系统语义颜色（`Color.primary`, `Color.secondary`），导致深色模式下显示异常。

### 5.5 无障碍支持（Accessibility）

所有自定义 View 缺少 `.accessibilityLabel()`, `.accessibilityHint()` 等无障碍标注，VoiceOver 用户体验差。这在 macOS 应用商店上架时是重要审核项。

### 5.6 提示词模板

用户常用的提示词（代码审查、写文档、分析日志等）无法保存为模板，每次都需要重新输入。

---

## 六、创新方向 🟢 P3

以下是超越当前竞品、构建差异化优势的创新方向：

### 6.1 MCP（Model Context Protocol）原生集成

MCP 是 Anthropic 推出的工具标准协议，已有大量社区工具（数据库、GitHub、Jira、Slack、浏览器自动化等）。将 agentGui 打造为**最佳 MCP 宿主应用**是极具竞争力的定位。

```
用户只需填写 MCP Server 命令：
 npx -y @modelcontextprotocol/server-github
即可让 Claude 获得 GitHub 操作能力
```

**实现要点**:
- MCP Server 生命周期管理（启动/停止/重启）
- JSON-RPC over stdin/stdout 通信
- 工具列表动态注入到 `ClaudeService+ToolBuilder`
- UI 上的 MCP 市场页面（展示常用 Server）

---

### 6.2 会话分支（Git-like Conversation Branching）

允许用户在任意消息处「派生」出新的对话分支，就像 Git 的 branch 操作。这解决了 AI 对话中「想重试不同方向但不想丢失当前进度」的核心痛点。

```
消息 A → 消息 B → 消息 C (主线)
                  ↓
              消息 C'（分支）→ 消息 D'
```

**数据模型**: 为 `Session` 添加 `parentSessionId` 和 `branchPointMessageId` 字段，`SessionListView` 中以树状展示。

---

### 6.3 Agent 调试器（Step-through Debugger）

为 Agentic Loop 提供类 IDE 调试体验：单步执行、断点设置、变量检查、执行回放。

- **断点**: 在特定工具调用类型上暂停（如「每次执行 Bash 前暂停」）
- **变量面板**: 实时查看 `ExecutionPlan`, `TodoItem`, 当前 token 用量
- **回放**: 以慢动作重放已完成的 Agent 执行过程
- **干预**: 暂停时允许用户修改工具输入再继续

这是目前所有 Claude 客户端**都没有**的功能，对开发者用户有极高价值。

---

### 6.4 智能上下文管理

当前的上下文压缩是基于简单的 token 阈值触发的批量压缩。可以做得更智能：

- **分层记忆**: 区分「核心事实」（不可压缩）和「工作细节」（可压缩）
- **主动遗忘**: 识别旧任务的工具输出（可能占大量 token）并智能清理
- **跨会话知识**: 从历史会话中提取用户偏好、项目知识，注入到新会话 system prompt
- **会话摘要卡片**: 长会话自动生成摘要，显示在侧边栏

---

### 6.5 本地模型支持（Ollama 集成）

当前 Ollama 搜索工具已部分实现，可以将其扩展为**完整的本地模型对话支持**：

- 通过 Ollama API 运行 Llama 3、Qwen、Mistral 等本地模型
- 对话时选择「本地」或「云端」模式
- 离线场景（飞行模式）下仍可使用 AI 功能
- 混合模式：本地模型做初步处理，复杂任务切换到 Claude

---

### 6.6 可观测 Agent 执行面板

类似 LangSmith 的 trace 可视化，为每次 Agent 执行生成详细的执行报告：

```
执行摘要
├── 总耗时: 45s  总 Token: 12,847 (约 ¥0.38)
├── 工具调用: 8 次 (bash×3, read×4, write×1)
├── 上下文压缩: 1 次（25k → 8k tokens）
└── 错误: 0 次

时间线
00:00 ─── 开始思考 (3.2s)
00:03 ─── bash: ls -la (0.1s) ✅
00:04 ─── read: src/main.swift (0.05s) ✅
...
```

---

### 6.7 Liquid Glass UI 风格升级

iOS 26 / macOS 26 引入了 Liquid Glass 设计语言。agentGui 作为一款面向开发者的现代 macOS 应用，可以率先采用：
- 毛玻璃工具栏和侧边栏
- 动态流体动画（消息气泡浮现、工具调用展开）
- 材质分层（背景/内容/覆盖层的深度感）

参考 `docs/liquid glasses.md` 中已有的设计研究。

---

### 6.8 RAG 知识库

为会话绑定本地文档库（代码库、文档、笔记），使用 Apple 的 `CoreML` + Sentence Transformers 做本地 Embedding，完全离线的 RAG 流程：

- 导入：Markdown / PDF / 代码文件
- 检索：基于 cosine 相似度的语义搜索
- 注入：将相关片段自动插入 system prompt
- 更新：文件变更后自动重建索引

---

## 七、改进路线图建议

### 近期（1-2 sprint）

| 任务 | 优先级 | 预估工作量 |
|------|--------|-----------|
| API Key 迁移到 Keychain | 🔴 P0 | 0.5 天 |
| 修复 session.workingDirectory 被忽略 | 🔴 P0 | 0.5 天 |
| 统一 SwiftData 错误处理 | 🔴 P0 | 1 天 |
| 重命名 ACPClientService.swift | 🟡 P2 | 0.5 小时 |
| 清理 9 个空壳文件 | 🟡 P2 | 0.5 小时 |
| 会话标题自动生成 | 🔴 P0 | 1 天 |
| 危险 Bash 命令确认 | 🔴 P0 | 1 天 |

### 中期（3-4 sprint）

| 任务 | 优先级 | 预估工作量 |
|------|--------|-----------|
| 代码语法高亮（Splash/Highlightr） | 🟠 P1 | 2 天 |
| ExecutionPlan/TodoItem 持久化 | 🟠 P1 | 2 天 |
| 会话搜索 | 🟠 P1 | 2 天 |
| MCP 服务器集成 | 🟢 P3 | 1-2 周 |
| 合并重复 executeTool 重载 | 🟡 P2 | 0.5 天 |
| 替换 Bing 抓取为正规 Search API | 🟡 P2 | 1 天 |

### 长期（下一个大版本）

| 任务 | 优先级 |
|------|--------|
| Agent 调试器（单步/断点） | 🟢 创新 |
| 会话分支（Git-like） | 🟢 创新 |
| 可观测执行面板 | 🟢 创新 |
| RAG 知识库 | 🟢 创新 |
| Liquid Glass UI 升级 | 🟢 创新 |

---

## 八、技术债务总结

| 项目 | 类型 | 影响 |
|------|------|------|
| API Key 明文存储 | 安全 | 🔴 高 |
| `try? modelContext.save()` 全量静默 | 数据可靠性 | 🔴 高 |
| `executeTool` 重复重载 | 可维护性 | 🟠 中 |
| Repository 层从未使用 | 架构 | 🟠 中 |
| 9 个空壳文件 | 代码整洁 | 🟡 低 |
| 手写 Markdown 解析器 | 稳定性 | 🟡 低 |
| 硬编码中文 Locale | 国际化 | 🟡 低 |
| Bing HTML 抓取 | 稳定性 | 🟡 低 |
| 测试覆盖率为 0 | 质量保证 | 🟠 中 |
| BashSession 轮询 | 性能 | 🟡 低 |

---

*本报告基于 2026-03-08 代码库状态的静态分析生成。*

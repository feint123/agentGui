# Bug 记录

## Bug: Editor 滑动卡死

**日期**: 2026-03-08
**状态**: 已修复

**描述**:
- Editor 滑动接近底部时，会造成应用卡死
- 快速滑动时也会造成应用卡死
- 控制台没有错误日志

**影响范围**:
- Editor 组件

**严重程度**: 高 - 影响用户体验，导致应用无法正常使用

**复现步骤**:
1. 打开 Editor
2. 向下滚动接近底部
3. 或快速上下滚动

**预期结果**:
- 滚动流畅，应用不卡死

**实际结果**:
- 应用卡死，需要重启

**日志**:
- 控制台无错误日志

**可能原因**:
- 虚拟列表渲染问题
- 滚动事件处理性能问题
- 内存泄漏

## 解决方案

**修复日期**: 2026-03-08

### 修改内容
- 为 `QuoteRenderedContent` 添加了文档缓存，避免每次渲染时重新解析 Markdown
- 为嵌套引用块添加了 `CachedNestedQuoteContent` 组件，避免递归解析导致性能问题
- 为 `BlockDocumentEditor` 添加了文本哈希缓存，避免重复解析相同的文档
- 为 `syncText()` 添加了 50ms 防抖机制，减少序列化频率
- 为 `BlockTextEditor` 添加了样式缓存，避免重复应用相同的 Markdown 样式
- 为 `ForEach` 中的块视图添加了 `.id()` 修饰符，帮助 SwiftUI 更好地识别不变视图

### 修改文件
- `agentGui/Views/Editor/BlockRowView.swift`
- `agentGui/Views/Editor/BlockDocumentEditor.swift`
- `agentGui/Views/Editor/BlockTextEditor.swift`

### 修复说明
问题根源是在滚动过程中频繁执行以下昂贵操作：
1. **引用块解析**：每个 `QuoteInlineBlockView` 和 `QuoteRenderedContent` 都会解析 Markdown
2. **文档序列化**：`syncText()` 在每次块变更时序列化整个文档
3. **Markdown 样式应用**：`applyInlineMarkdownStyling()` 在每次视图更新时运行多个正则表达式

通过缓存解析结果、添加防抖机制和样式缓存，大幅减少了滚动时的 CPU 使用量。

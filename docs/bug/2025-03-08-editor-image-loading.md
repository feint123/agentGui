# Bug: Editor 中网络图片无法正常加载

**日期**: 2025-03-08  
**严重程度**: 高  
**状态**: 已修复  
**组件**: Editor / Markdown 渲染器

## 问题描述

在 Editor 组件中，网络图片无法正常加载和显示。

## 复现步骤

1. 在 Editor 中插入网络图片 URL
2. 使用 Markdown 格式：`![图片描述](https://example.com/image.png)`
3. 预览或查看渲染结果
4. 观察图片是否正常显示

## 期望行为

网络图片应该能够正常加载和显示，支持常见的图片格式（PNG、JPG、GIF、WebP 等）。

## 实际行为

图片无法加载，可能显示为：
- 空白占位符
- 加载失败图标
- 或完全没有显示

## 可能的原因

- [ ] 网络请求未正确配置
- [ ] ATS (App Transport Security) 设置问题
- [ ] 图片加载逻辑缺失或错误
- [ ] URL 验证或处理问题
- [ ] 异步加载和 UI 更新同步问题

## 环境信息

- **操作系统**: macOS
- **开发框架**: SwiftUI
- **渲染器**: 自定义 Markdown 渲染器

## 相关文件

- `STTextView.md` - 文本编辑器文档
- Markdown 渲染相关代码

## 优先级

高 - 影响用户体验的核心功能

## 备注

需要检查网络图片加载的完整流程，包括：
1. URL 解析
2. 网络请求发起
3. 图片数据下载
4. 图片解码
5. UI 显示更新

## 解决方案

**修复日期**: 2026-03-08

### 修改内容
- 增强了 `BlockImagePreview` 的网络图片加载逻辑，添加完整的错误处理
- 改进了 `resourceURL` 函数，支持 URL 编码和波浪号路径扩展
- 更新了 `MediaImageViewer` 以支持网络图片加载
- 更新了 `mediaThumbImage` 函数以支持网络缩略图生成

### 修改文件
- `agentGui/Views/Editor/BlockRowView.swift`
- `agentGui/Views/MediaViewerView.swift`

### 修复说明
1. **BlockImagePreview 增强**:
   - 使用 `AsyncImage` 完整阶段处理 (success/failure/empty)
   - 添加友好的错误提示界面
   - 特别处理 HTTP vs HTTPS 的 ATS 限制提示

2. **URL 处理改进**:
   - 直接 URL 解析失败时尝试 URL 编码
   - 支持波浪号 (~) 路径展开

3. **MediaViewerView 更新**:
   - `MediaImageViewer` 使用 `URLSession` 下载网络图片
   - `mediaThumbImage` 支持网络图片缩略图生成
   - 统一的本地文件和网络资源处理流程

### 注意事项
- macOS 默认禁止 HTTP 连接，仅允许 HTTPS
- 如果需要支持 HTTP，需要在 Entitlements.plist 中添加 ATS 例外配置

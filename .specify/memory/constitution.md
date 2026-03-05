<!--
Sync Impact Report:
- Version change: N/A → 1.0.0
- New constitution created for agentGui project
- Principles added: 模块化架构, 第三方库优先, SwiftUI & HIG 遵循, SwiftData 持久化, 代码质量与设计模式
- Templates updated:
  ✅ plan-template.md - verified compatibility
  ✅ spec-template.md - verified compatibility
  ✅ tasks-template.md - verified compatibility
- Follow-up TODOs: None
-->

# agentGui 项目宪章

## 核心原则

### I. 模块化架构

项目 MUST 遵循模块化设计原则：

- **模块独立性**：每个功能模块 MUST 能够独立开发、测试和维护
- **清晰的职责边界**：模块间通过明确的接口通信，避免紧耦合
- **可扩展性优先**：新功能 SHOULD 能够以插件或扩展形式添加，无需重写核心代码
- **依赖方向单一**：高层模块 CAN 依赖低层模块，反之则必须通过抽象层解耦

**理由**：模块化架构使团队能够并行开发不同功能，降低维护成本，并为未来功能扩展奠定基础。

### II. 第三方库优先

避免重复造轮子，通用功能 MUST 优先使用成熟的第三方库：

- **成熟度评估**：选用的库 SHOULD 有活跃的维护、良好的文档和广泛的社区使用
- **Swift 6 兼容**：库 MUST 与 Swift 6 并发模型兼容，优先支持 `@preconcurrency`
- **许可证合规**：仅使用兼容项目许可证的开源库
- **依赖最小化**：在满足功能的前提下，选择依赖最少、最轻量的方案

**仅在以下情况考虑自研**：
- 现有库无法满足特定需求
- 库的维护状态不佳或存在严重安全漏洞
- 集成成本高于自研成本

**理由**：使用成熟库可减少开发和维护负担，获得经过实战验证的解决方案，让团队专注于核心业务价值。

### III. SwiftUI & Apple HIG 遵循

UI 实现 MUST 严格遵循 SwiftUI 最佳实践和 Apple Human Interface Guidelines：

- **SwiftUI 优先**：所有新 UI 组件 MUST 使用 SwiftUI 构建
- **Swift 6 并发**：充分利用 SwiftData 的 `@Observable`、Swift Concurrency 的 `async/await` 和 Actor 模式
- **HIG 合规**：
  - 使用 SF Symbols 替代自定义图标
  - 支持系统字体缩放（动态类型）
  - 遵循 macOS 原生交互模式（工具栏、侧边栏、检查器等）
  - 正确使用颜色语义（强调色、语义化颜色）
- **动效丰富**：
  - 使用 `.animation()` 和 `.transition()` 添加流畅的状态转换
  - 关键交互 SHOULD 提供视觉反馈
  - 避免过度动画影响性能

**理由**：遵循 Apple 平台规范确保应用与系统体验一致，降低用户学习成本，同时利用 SwiftUI 获得最佳性能和未来兼容性。

### IV. SwiftData 持久化

数据存储 MUST 统一使用 SwiftData 框架：

- **模型定义**：数据模型使用 `@Model` 宏定义，遵循 SwiftData 最佳实践
- **关系管理**：使用 `@Relationship` 管理对象间的关系，避免循环引用
- **查询优化**：使用 `#Predicate` 构建类型安全的查询，充分利用索引
- **迁移策略**：数据模型变更 MUST 配套 Schema 迁移计划
- **线程安全**：数据访问 MUST 通过 `ModelContext` 在正确的执行上下文进行

**理由**：SwiftData 是 Apple 推荐的现代持久化框架，与 SwiftUI 深度集成，提供声明式数据绑定和类型安全。

### V. 代码质量与设计模式

代码质量 MUST 达到生产级标准，善于运用设计模式：

- **设计模式**：根据场景选择合适的设计模式
  - **MVVM**：UI 层的标准架构，View 与 ViewModel 分离
  - **Repository**：数据访问层抽象，隔离 SwiftData 实现细节
  - **Factory/Builder**：复杂对象的构建逻辑
  - **Strategy/Command**：可互换的算法或操作
  - **Observer/Publisher**：跨模块通信
- **Swift 6 严格并发**：代码 MUST 通过 Swift 6 严格并发检查，消除数据竞争
- **命名规范**：使用清晰的中文或英文命名，保持一致性
- **错误处理**：使用 Result 类型或 Swift Concurrency 的错误传播，避免强制解包
- **代码审查**：所有代码合并前 MUST 经过审查

**理由**：高质量代码和恰当的设计模式提升可读性、可测试性和可维护性，减少 bug 并加速迭代。

## 技术约束

### 语言与平台

- **语言**：Swift 6.0+
- **最低部署目标**：macOS 26.0+
- **IDE**：Xcode 16.0+
- **包管理**：Swift Package Manager

### 强制要求

- 所有异步操作 MUST 使用 `async/await` 或 `@MainActor`
- 所有可变状态 MUST 通过 `@Observable`、`@State` 或 Actor 保护
- 禁止使用强制解包（`!`）除非能够证明其安全性
- 禁止使用隐式解包可选类型

### 文档规范

- 所有公开 API MUST 提供中文文档注释
- 复杂逻辑 SHOULD 添加解释性注释
- README 和技术文档使用中文编写

## 质量标准

### UI/UX

- 遵循 Apple HIG 设计规范
- 支持深色/浅色模式自动切换
- 关键操作提供撤销/重做能力
- 加载状态和错误 MUST 有清晰的用户反馈

### 性能

- UI 渲染 MUST 保持 60fps
- 启动时间 < 2 秒
- 内存占用 SHOULD 优化，避免不必要的缓存

### 可测试性

- 业务逻辑 SHOULD 与 UI 解耦，便于单元测试
- 关键路径 SHOULD 有 UI 测试覆盖

## 治理

### 修订流程

1. 宪章修订 MUST 先提出变更建议，说明理由
2. 重大变更（影响现有代码）需经团队评审
3. 修订后更新版本号，并记录变更历史
4. 所有模板和文档 MUST 同步更新以保持一致性

### 合规检查

- 每个 Feature 实现前 MUST 通过宪章检查（Constitution Check）
- 代码审查时验证是否符合核心原则
- 违反宪章的设计 MUST 在 plan.md 中明确说明并给出合理理由

### 版本策略

- **MAJOR**：移除或重新定义核心原则/治理规则
- **MINOR**：新增原则或大幅扩展现有指导
- **PATCH**：措辞澄清、错别字修正、非语义性改进

**版本**：1.0.0 | **批准日期**：2026-02-10 | **最后修订**：2026-02-10

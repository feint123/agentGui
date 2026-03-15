# LSP 一键安装、内建收敛与服务管理需求说明

日期：2026-03-15

关联对象：`LSPServerRegistry`、`LSPServerManager`、`LSPProcessSupervisor`、`LSPWorkspaceResolver`、`SettingsToolsView`、工作区侧栏 LSP 状态展示、未来安装器与服务管理 UI

## 1. 背景

当前项目已经具备一套可工作的通用 LSP 基础设施，包括：

- 基于 stdio 的 LSP client/runtime
- server registry 与 workspace binding 解析
- LSP 进程监督、状态投影与 diagnostics store
- 设置页中的 LSP 开关、自定义 profile JSON 与自动路由策略
- 工作区与文件编辑器中的基础 LSP 状态展示

但现阶段的 LSP 产品体验仍有三个明显问题：

1. 常用语言缺少面向普通用户的一键安装与配置能力，实际可用性取决于用户是否自己配置过命令行环境。
2. 内建 profile 同时包含 TypeScript/JavaScript、Python、Swift stub，内建范围与“真正稳定可用”和“需要外部安装”的边界不清晰。
3. 缺少独立的 LSP 服务管理 UI，用户无法集中查看安装状态、运行状态、错误原因，也无法统一执行启动、停止、重启、修复等操作。

这会直接导致两个后果：

- 对新用户而言，LSP 是“有实现、难启用、难排障”的能力。
- 对后续扩语言而言，安装逻辑、profile 定义、运行时管理和 UI 状态容易继续耦合。

因此，需要把当前 LSP 能力升级为“可安装、可管理、可扩展”的产品化平台，而不是继续只做零散 profile 堆叠。

## 2. 目标

本次需求目标如下：

1. 支持常用语言 LSP 服务的一键安装与配置，首批覆盖 JavaScript、TypeScript、C、C++、Rust、Java、Go。
2. 内建 LSP profile 收敛为仅保留 Python；其余语言改为可安装的官方/推荐 provider。
3. 提供统一的 LSP 服务管理 UI，支持查看安装状态、运行状态、绑定关系、错误信息，并支持启动、停止、重启、修复等操作。
4. 采用模块化架构，把安装、配置、运行时、绑定解析、状态展示解耦，确保后续新增语言或新增安装方式时不需要重写主链。
5. 在现有 LSP runtime 基础上增强质量与可维护性，不破坏已有 Python 语义工具链与工作区上下文集成。

## 3. 不在本次范围

- 不在本次需求中实现完整的 Swift / SourceKit-LSP 产品化闭环。
- 不在本次需求中支持所有语言的内建离线打包安装。
- 不把原始 JSON-RPC 协议细节直接暴露给用户或模型。
- 不在本次需求中扩展到 rename、code action、workspace edit 等高风险写操作能力。
- 不替换现有通用 LSP runtime 的核心通信方式，仍以本地进程 + stdio 为基础。

## 4. 产品原则

### 4.1 平台化优先

LSP 必须作为一层独立平台能力建设，而不是在每种语言上分别堆一套启动逻辑。

### 4.2 Python 稳定优先

Python 是当前唯一保留的内建 profile。内建不等于特殊分支实现，而是通过同一平台抽象接入，只是在出厂配置中默认存在。

### 4.3 安装与运行分离

“已安装”不代表“已启动”，“已启动”不代表“已绑定当前工作区”。安装状态、配置状态、运行状态必须分层建模和分层展示。

### 4.4 UI 与进程控制分离

SwiftUI 视图只消费 presentation state，不直接持有 LSP 进程或执行安装命令。

### 4.5 可诊断优先于静默失败

无论是缺少可执行文件、环境变量错误、初始化握手失败还是 workspace 绑定不匹配，都必须给出可见、可定位、可恢复的状态信息。

## 5. 功能需求

### 功能点 1：常用语言 LSP 一键安装与配置

首批需要支持以下语言或语言组：

- JavaScript / TypeScript
- C / C++
- Rust
- Java
- Go

需求：

- 提供统一的“安装”入口，用户不需要手工编辑 JSON profile 才能启用上述语言。
- 安装流程需要包含前置检查，至少识别：可用包管理器、可写安装位置、PATH 可见性、必要运行时是否存在。
- 安装完成后，系统自动生成或启用对应的 server profile、默认启动命令、参数、语言 ID、root markers 与默认 globs。
- 安装流程需要向用户展示进度状态：待安装、检查中、安装中、配置中、完成、失败。
- 安装失败时需要记录结构化失败原因，并提供重试或修复入口。
- 已安装 provider 需要支持版本识别或至少支持“检测到可执行文件路径与可运行性”。
- 同一种语言允许后续替换 provider，但默认只推荐一条官方或事实标准路径，避免首版出现多个并列选项造成决策负担。

首版推荐 provider 方向：

- JavaScript / TypeScript：`typescript-language-server`
- C / C++：`clangd`
- Rust：`rust-analyzer`
- Java：`jdtls`
- Go：`gopls`

说明：

- 这里的“一键安装”是产品体验要求，不限定底层必须使用单一包管理器实现。
- 若某语言必须依赖外部前置环境，安装器需要明确展示缺失项，并给出可执行修复建议。

### 功能点 2：内建 LSP 仅保留 Python

需求：

- `LSPServerRegistry` 的内建定义收敛为仅保留 Python profile。
- TypeScript / JavaScript、Swift stub 及未来其他语言都不再以内建 profile 形式默认出厂。
- 非 Python 语言通过“可安装 provider”进入 registry，而不是继续写死在 built-in definitions 中。
- 现有用户的自定义 profile JSON 仍需兼容，不因本次收敛而丢失或静默覆盖。
- 对于升级用户，如旧配置中存在历史内建非 Python server，需要提供平滑迁移策略：
  - 可识别旧 server ID
  - 可映射到新的安装型 provider
  - 不因迁移导致工作区绑定直接失效

验收口径：

- 新安装应用时，默认内建 profile 仅显示 Python。
- 其他常用语言通过安装目录或 provider 列表呈现，而不是直接出现在“内建 Profiles”中。

### 功能点 3：LSP 服务目录与管理 UI

产品需要新增统一的 LSP 服务管理界面，可作为设置页中的独立分区，必要时复用到工作区侧边栏详情面板。

管理 UI 至少需要展示以下信息：

- 服务名称
- 关联语言
- 当前安装状态
- 当前配置状态
- 当前运行状态
- 可执行文件路径或解析结果
- 版本信息或可用性检查结果
- 已绑定工作区数量或当前工作区绑定情况
- 最近错误摘要
- 最近一次启动时间或最近一次状态变化时间

管理 UI 至少需要支持以下操作：

- 安装
- 重新检测
- 配置/重配置
- 启动
- 停止
- 重启
- 修复
- 禁用/启用
- 查看日志

首版状态枚举至少应覆盖：

- 未安装
- 已安装未配置
- 已配置未启动
- 启动中
- 运行中
- 已停止
- 启动失败
- 运行崩溃
- 配置异常
- 当前工作区不匹配

交互要求：

- 用户在不打开 JSON 编辑器的前提下，也能完成常见 LSP 管理操作。
- 当当前文件或工作区已匹配某个语言服务时，用户能从管理 UI 直接看出“为什么没有工作”或“为什么工作在别的服务上”。
- 工作区侧栏当前已有的 LSP footer 不应删除，但应降级为摘要入口；详细状态与操作应进入管理面板。

### 功能点 4：工作区绑定与自动路由可视化

需求：

- 在服务管理 UI 中展示某服务的路由规则，包括语言 ID、root markers、默认 globs、手动绑定信息。
- 用户可以查看某个工作区当前命中了哪个服务，以及命中依据。
- 当自动路由失败时，界面需要说明失败原因，例如：
  - 未安装对应服务
  - 已安装但可执行文件不可用
  - 工作区未命中 root markers
  - 当前文件语言不受支持
- 支持从 UI 发起“为当前工作区绑定此服务”或“取消绑定”。

### 功能点 5：安装器与 provider 平台抽象

为保证后续扩展性，需要把“语言服务条目”拆分为可扩展 provider，而不是只保留静态 `LSPServerDefinition`。

需求：

- 定义独立的 provider catalog，用于描述一个可安装语言服务的元数据、支持语言、推荐安装方式、健康检查方式、默认 profile 模板。
- 定义安装器协议，允许不同 provider 使用不同安装策略，例如 npm、brew、go install、系统现成二进制、手工路径导入。
- 安装器执行结果必须结构化，至少包含：成功/失败、错误原因、建议动作、探测到的可执行文件路径、版本信息。
- provider catalog 与 runtime registry 分离：
  - catalog 负责“有什么可装”
  - registry 负责“当前有哪些可用 server 定义”
- UI 消费 provider catalog 和 runtime registry 的合成状态，不直接猜测安装可用性。

建议抽象边界：

- `LSPProviderCatalog`
- `LSPProviderDefinition`
- `LSPInstallCoordinator`
- `LSPInstallStrategy`
- `LSPServiceStateStore`
- `LSPManagementViewModel`

### 功能点 6：运行时服务管理增强

在现有 `LSPServerManager` 与 `LSPProcessSupervisor` 基础上，需要补足服务管理能力，而不是只面向 agent 工具调用。

需求：

- 支持按服务维度和按工作区维度查询当前运行状态。
- 支持手动启动、停止、重启某个服务实例。
- 支持区分“未启动”“启动失败”“运行中但未绑定当前文件”“运行中但当前文件未同步”等状态。
- 支持保留最近日志、最近错误和基础健康检查结果，供 UI 读取。
- 当服务崩溃后，需要能从 UI 发起恢复或自动恢复，并记录恢复次数。
- 不允许通过 `BashSession` 承载 LSP 通信，仍需保持 direct `Process` + stdio 的运行方式。

### 功能点 7：设置体验重构

现有设置页中的 LSP 区域需要从“若干布尔开关 + JSON 编辑器”升级为“简化主路径 + 保留高级入口”的结构。

需求：

- 默认用户路径应以服务目录和安装操作为主，不要求先理解 profile JSON。
- `lspCustomServerProfilesJSON` 可保留，但应降级为高级配置入口。
- “内建 Profiles”文案需要改为能反映新结构，例如“已启用服务”或“已安装 provider”。
- 若用户启用了高级自定义 profile，管理 UI 也必须能展示其状态，不能只管理官方 provider。

### 功能点 8：错误恢复与可观测性

需求：

- 安装失败、启动失败、initialize 握手失败、可执行文件丢失、PATH 解析失败都必须落入统一错误模型。
- UI 至少展示用户可操作的错误摘要；详细日志通过展开或日志页查看。
- 需要保留最近若干次安装/启动事件，便于用户和开发者排障。
- 运行时状态变化应能驱动现有 workspace LSP 状态展示自动刷新。

## 6. 模块化设计要求

### 6.1 模块边界

实现设计必须满足以下边界要求：

- 安装器模块不直接依赖 SwiftUI。
- runtime 管理模块不直接依赖设置界面。
- presentation store 不直接拉起进程。
- provider catalog 不直接读写工作区文档状态。
- 迁移逻辑与业务 UI 分离，避免版本兼容代码渗透到视图层。

### 6.2 推荐分层

建议按以下四层组织：

1. Provider Catalog Layer
   负责 provider 定义、安装说明、默认 profile 模板、支持语言声明。
2. Installation Layer
   负责预检、安装、版本检测、修复、迁移。
3. Runtime Layer
   负责 server registry、workspace binding、process supervision、health state、diagnostics。
4. Presentation Layer
   负责设置页、管理面板、工作区摘要状态和操作反馈。

### 6.3 扩展要求

后续新增语言时，理想流程应为：

- 新增一个 provider 定义
- 选择或实现一个安装策略
- 补充健康检查与默认 profile 模板
- 在 UI 中自动进入服务目录

不应要求同时修改多个分散的硬编码列表、多个视图分支和多个独立状态枚举。

## 7. 用户流程要求

### 流程 1：首次为 TypeScript 项目启用 LSP

- 用户打开 TypeScript 工作区。
- 系统提示“检测到可支持的语言，但未安装对应 LSP 服务”。
- 用户点击安装。
- 系统完成预检、安装、配置并展示结果。
- 用户可在服务管理 UI 中看到服务为“已配置/可启动”。
- 若自动启动开启，系统自动启动并绑定当前工作区。

### 流程 2：查看服务异常并修复

- 用户在工作区侧栏看到 LSP 状态异常。
- 用户点击进入服务管理 UI。
- UI 显示错误摘要，例如“找不到 clangd 可执行文件”。
- 用户点击修复或重新检测。
- 修复完成后状态从“配置异常”回到“已配置未启动”或“运行中”。

### 流程 3：高级用户导入自定义 provider

- 用户在高级设置中导入自定义 profile 或手工指定可执行文件。
- 系统完成校验并将其纳入统一服务目录。
- 用户仍然可以通过同一管理 UI 启停、查看状态和日志。

## 8. 数据与状态模型要求

至少需要补充以下类型或等价抽象：

- `LSPProviderDefinition`
- `LSPInstallStatus`
- `LSPConfigurationStatus`
- `LSPManagedServiceState`
- `LSPInstallResult`
- `LSPServicePresentation`
- `LSPMigrationRecord`

状态模型至少要支持区分：

- provider 是否存在
- 是否已安装
- 是否已配置成 runtime profile
- 当前是否可执行
- 当前是否已有运行中会话
- 当前工作区是否命中
- 最近错误与建议操作

## 9. 质量要求

### 9.1 测试要求

至少需要覆盖以下测试面：

- provider catalog 组装与去重
- 安装状态和配置状态的状态机转换
- 历史内建 profile 到安装型 provider 的迁移
- 运行时状态到 UI presentation 的映射
- 启动、停止、重启、崩溃恢复流程
- PATH 解析与可执行文件探测
- 工作区自动路由与手动绑定冲突处理

### 9.2 兼容性要求

- 不破坏当前 Python LSP 能力与相关 agent 工具。
- 不破坏现有 `lspCustomServerProfilesJSON` 数据兼容性。
- 不破坏当前工作区 footer 上的 LSP 摘要信息来源。

### 9.3 可维护性要求

- 服务定义、安装逻辑、UI 状态不允许相互复制同一套语言枚举。
- 错误模型必须结构化，避免 UI 直接依赖字符串匹配判断状态。
- 新增语言 provider 的代码改动范围应保持局部化。

## 10. 验收标准

满足以下条件可视为本需求完成：

1. 新用户在不手写 JSON profile 的前提下，可为 JS/TS、C/C++、Rust、Java、Go 完成安装与基本配置。
2. 新安装应用默认只保留 Python 内建 LSP profile。
3. 设置页或等价入口存在独立的 LSP 服务管理 UI，可查看服务状态并执行启动、停止、重启、修复等操作。
4. 工作区侧栏摘要状态与管理 UI 状态一致，不出现一个显示运行中、另一个显示未配置的冲突。
5. 历史用户的自定义 profile 与已有工作区绑定不因本次改造而静默失效。
6. 新增一种语言 provider 时，不需要改动 runtime 主链核心通信代码。

## 11. 优先级建议

- P0：服务管理模型、Python-only 内建收敛、JS/TS 与 Go 安装链路、统一管理 UI 基础能力
- P1：C/C++、Rust、Java provider 安装链路，错误修复与日志查看完善
- P2：更丰富的 provider 来源、离线安装包、批量工作区治理与更细粒度的策略配置

## 12. 后续实现建议

实现阶段建议拆为三步：

1. 先完成 provider/installation/runtime/presentation 四层抽象与 Python-only 内建收敛。
2. 再交付管理 UI 与首批可安装语言链路。
3. 最后补迁移、修复、日志、测试基线和回归验证。
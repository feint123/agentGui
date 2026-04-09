# 2026-03-27 Sparkle 2.0 应用更新接入设计

日期：2026-03-27

关联对象：agentGuiApp、AppMenuCommands、AppCommandRegistry、AppCommandRouter、SettingsStore、SettingsGeneralView、AppSettings、agentGui.entitlements、CI 发布脚本

## 0. 文档结论

本设计采用 Sparkle 2 标准 UI 路线（SPUStandardUpdaterController + 默认调度），以最小侵入方式接入 agentGui 的 SwiftUI 架构：

1. 更新能力不与现有对话执行 runtime 耦合，单独落在 Update 模块。
2. 前台入口复用现有 Commands 平台，新增“检查更新”命令，并在应用菜单展示。
3. 设置页新增“更新”分组，仅承载用户偏好开关与渠道策略；不重复保存 Sparkle 已持久化的字段。
4. 发布侧统一采用 Sparkle 官方 generate_appcast 工具链，产物托管到 HTTPS appcast 源。
5. 安全基线采用 EdDSA 签名 + Developer ID + notarization；可选启用签名 feed（SURequireSignedFeed + SUVerifyUpdateBeforeExtraction）。
6. 通过“先灰度后强校验”的两阶段上线策略降低发布风险。

一句话结论：

> 先以 Sparkle 2 标准方案上线“稳定、可观测、可回滚”的自动更新主链路，再逐步补齐渠道、分阶段发布和 signed feed 强安全能力。

## 1. 背景与问题定义

当前项目没有任何更新框架接入，应用版本升级依赖手工下载覆盖安装，存在以下问题：

1. 版本触达慢，用户更新时延不可控。
2. 无统一升级可观测数据，无法判断失败率与回滚需求。
3. 无客户端内“检查更新”入口，与桌面应用习惯不一致。
4. 发布流程中缺失 appcast 与增量包能力，后续版本管理成本高。

结合现状代码可得出两个重要约束：

1. 应用使用 SwiftUI App 生命周期，菜单行为已经通过 AppCommands 平台统一路由。
2. `agentGui.entitlements` 里 `com.apple.security.app-sandbox = false`，当前不是沙盒应用，可使用 Sparkle 标准更新路径，不需要先走沙盒受限分支。

## 2. 目标与非目标

### 2.1 目标

1. 支持稳定版自动检查更新与用户手动检查更新。
2. 提供标准“检查更新”菜单项，符合 macOS 应用使用习惯。
3. 支持通过 appcast 发布更新包（zip or dmg），并完成 EdDSA 校验。
4. 支持基础更新偏好（自动检查、自动下载 or 自动安装策略、Beta 渠道开关）。
5. 发布流程可脚本化，具备可回滚路径。

### 2.2 非目标

1. 第一阶段不自定义 Sparkle UI，不替换标准升级弹窗。
2. 第一阶段不做跨平台更新（仅 macOS）。
3. 第一阶段不实现复杂 license 升级策略（如付费大版本门槛），只预留 appcast 字段能力。
4. 第一阶段不做 server 端更新统计平台，只保留客户端日志与发布审计。

## 3. Sparkle 2 调研要点

基于 Sparkle 官方文档与 API 指南，落地时需要重点遵循：

1. 集成方式：优先 SPM 引入 `https://github.com/sparkle-project/Sparkle`。
2. SwiftUI 程序化接入：在 App 生命周期中创建 `SPUStandardUpdaterController`，并通过 `updater` 暴露命令入口。
3. 核心配置：
   1. `SUFeedURL`：appcast URL。
   2. `SUPublicEDKey`：EdDSA 公钥。
   3. 可选安全项：`SUVerifyUpdateBeforeExtraction`、`SURequireSignedFeed`。
4. API 预期：
   1. 不建议频繁手动调用后台检查，避免干扰 Sparkle 内部调度周期。
   2. 用户设置变化后可调用 `resetUpdateCycleAfterShortDelay`。
5. 发布工具链：
   1. `generate_keys` 生成 EdDSA 密钥。
   2. `generate_appcast` 生成 appcast 与 delta 包。
6. 安全基线：HTTPS、Developer ID 签名与 notarization、更新包 EdDSA 签名。
7. 更新包格式：推荐 dmg or zip；zip 需用 `ditto -c -k --sequesterRsrc --keepParent` 保留资源和符号链接。

## 4. 方案比较

### 4.1 方案 A：纯手工更新（维持现状）

优点：无接入成本。

缺点：无自动升级、无用户体验保障、无版本可控触达。

结论：不采用。

### 4.2 方案 B：Sparkle 2 标准 UI + 标准调度（推荐）

优点：

1. 与 macOS 桌面应用习惯一致。
2. 接入复杂度低，可快速上线。
3. 官方维护路径成熟，后续扩展渠道、分批发布、critical update 均可渐进演进。

缺点：

1. 初期 UI 定制能力有限（但可接受）。
2. 需要建立发布端 appcast 工具链规范。

结论：采用。

### 4.3 方案 C：自定义更新框架

优点：可高度定制。

缺点：研发与安全成本过高，且重复造轮子。

结论：不采用。

## 5. 推荐架构

## 5.1 模块拆分

新增 `Services/Update/` 模块：

1. `SparkleUpdateCoordinator`
   1. 封装 `SPUStandardUpdaterController` 生命周期。
   2. 对外提供 `checkForUpdates()`。
   3. 暴露 `canCheckForUpdates` 的可观察状态，供 Commands 与设置页消费。
2. `SparkleUpdateDelegate`
   1. 实现 `SPUUpdaterDelegate`。
   2. 负责渠道控制（stable or beta）、可选 feed 路由。
   3. 收集错误日志与状态事件。
3. `SparkleUpdatePreferencesBridge`
   1. 将 UI 操作映射到 Sparkle 支持的用户偏好属性。
   2. 在渠道变更后触发 `resetUpdateCycleAfterShortDelay`。

说明：

1. 不在 `ClaudeService` 中承载更新能力，保持 AI 执行与应用运维能力解耦。
2. 不新增与 Sparkle 重复的持久化字段（如自动检查周期），以 Sparkle 自身 NSUserDefaults 为准。

## 5.2 与现有工程的接入点

1. `agentGuiApp`
   1. 持有 `@State private var updateCoordinator`。
   2. 在主窗口环境注入轻量更新上下文（只暴露命令和状态）。
2. `AppCommands`
   1. 在 `AppCommandID` 新增 `checkForUpdates`。
   2. 在 `AppCommandRegistry` 注册标题、快捷键、可用性规则。
   3. 在 `AppCommandRouter` 路由到 `updateCoordinator.checkForUpdates()`。
   4. 在 `AppMenuCommands` 的应用菜单加入“检查更新…”。
3. 设置页
   1. 在 `SettingsGeneralView` 或新增 `SettingsUpdatesView` 放置更新偏好项。
   2. `SettingsStore` 提供与更新偏好桥接的方法，不直接持久化 Sparkle 已托管字段。

## 5.3 运行时数据流

1. 应用启动：`SparkleUpdateCoordinator` 初始化并启动 updater。
2. Sparkle 调度：按默认周期自动后台检查（默认 24h，遵循用户偏好）。
3. 用户操作：菜单点击“检查更新”后触发前台检查。
4. 发现更新：Sparkle 标准 UI 弹出版本信息、发布说明与安装流程。
5. 安装完成：Sparkle 拉起重启安装，应用重启进入新版本。

## 6. 配置设计

## 6.1 Info.plist 必需项

1. `SUFeedURL = https://<your-domain>/appcast.xml`
2. `SUPublicEDKey = <base64-public-key>`

## 6.2 Info.plist 建议项

1. `SUEnableAutomaticChecks = YES`
2. `SUAutomaticallyUpdate = NO`（建议初期关闭自动安装，仅自动下载 or 用户确认安装）
3. `SUVerifyUpdateBeforeExtraction = YES`（建议在发布产物固定为 Developer ID 签名 dmg 后启用）
4. `SURequireSignedFeed = NO`（第一阶段可关闭，第二阶段开启）

说明：

1. `SURequireSignedFeed = YES` 时，需要同步维护 appcast 与 release notes 签名，发布流程复杂度显著上升。
2. 若启用 signed feed，需明确密钥管理与签名失效应急策略。

## 6.3 渠道策略

采用“单 appcast + 可选 beta channel”策略：

1. 默认所有用户仅看 default channel。
2. Beta 用户在设置中开启后，delegate 返回 `allowedChannels = ["beta"]`。
3. 不建议长期并行两套互不收敛版本线，beta 更新最终应回归 default。

## 7. 发布与运维流程设计

## 7.1 标准发布流程

1. 使用 Xcode Archive 导出 Developer ID + notarized 应用。
2. 打包更新归档：
   1. zip：`ditto -c -k --sequesterRsrc --keepParent`。
   2. 或 dmg（推荐）。
3. 将归档放入 updates 目录。
4. 运行 `generate_appcast /path/to/updates` 生成 appcast 与 delta。
5. 上传 appcast、增量包、主包、release notes 到 HTTPS 服务器。
6. 在旧版本应用上手动触发“检查更新”进行验收。

## 7.2 密钥与签名规范

1. 在发布管理员机器执行 `generate_keys`，私钥仅存登录钥匙串并做离线备份。
2. 严禁把私钥部署到公网站点机器。
3. 密钥轮换流程单独维护 runbook（包含证书轮换与 EdDSA 轮换注意事项）。

## 7.3 回滚策略

1. 客户端侧回滚：通过 appcast 下架问题版本 item，并发布修复版本。
2. 渠道侧回滚：先在 beta channel 验证，再提升到 default。
3. 紧急通告：必要时发布 informational update 引导用户下载稳定包。

## 8. 安全与合规设计

1. 传输安全：appcast 与更新包必须全链路 HTTPS。
2. 产物安全：Developer ID + notarization + EdDSA。
3. 运行安全：初期可不启用 signed feed，避免流程失误导致大面积更新失败；稳定后再切换到 signed feed。
4. 配置安全：不在客户端明文存储私钥；仅存公钥。
5. 审计安全：保留每次发布对应 appcast 版本、签名指纹、构建号与操作者记录。

## 9. 测试与验收

## 9.1 功能验收

1. 菜单“检查更新…”可用，且不可用状态随 `canCheckForUpdates` 正确变化。
2. 旧版本可发现新版本并完成安装。
3. 无更新时提示准确。
4. 设置中渠道切换后可影响更新结果。

## 9.2 兼容性验收

1. Apple Silicon 与 Intel（若仍支持）均可更新。
2. 从至少两个历史版本升级到最新版本成功。
3. delta 更新与全量更新均验证可用。

## 9.3 异常验收

1. appcast 不可达。
2. 签名不匹配。
3. 更新包损坏。
4. 磁盘权限不足或应用位于只读路径。

期望：异常都有用户可理解提示，且不破坏当前可运行版本。

## 10. 分阶段实施计划

## Phase 1（MVP，1-2 天）

1. 引入 Sparkle SPM 依赖。
2. 增加 Info.plist 基础配置（SUFeedURL、SUPublicEDKey）。
3. 新增 UpdateCoordinator 并接入 App 生命周期。
4. 新增“检查更新…”命令入口。
5. 打通单一稳定渠道 appcast 更新。

交付标准：本地旧版本可升级到新版本。

## Phase 2（Hardening，1-2 天）

1. 设置页更新偏好与渠道开关。
2. delegate 渠道路由与更新事件日志。
3. 发布脚本化（生成归档 + appcast + 上传前校验）。
4. 增量更新验收。

交付标准：具备可重复发布与灰度验证能力。

## Phase 3（Security+，可选）

1. 启用 `SUVerifyUpdateBeforeExtraction`。
2. 启用 `SURequireSignedFeed` 并完善签名流水线。
3. 完成密钥轮换演练与应急预案。

交付标准：更新链路达到更高安全基线。

## 11. 风险评估

1. 风险：发布流程误操作导致 appcast 与文件不一致。
   1. 缓解：发布前自动校验脚本（URL 可达、长度、签名、版本递增）。
2. 风险：私钥管理不当。
   1. 缓解：私钥仅在发布机钥匙串，离线备份，最小权限。
3. 风险：过早启用 signed feed 导致签名维护负担。
   1. 缓解：按阶段逐步启用，先跑稳定主链路。
4. 风险：用户位于只读挂载路径无法自动替换。
   1. 缓解：升级失败提示引导用户将应用移动到 Applications 目录。

## 12. 需要你确认的决策项

1. Phase 1 是否允许 `SUAutomaticallyUpdate = YES`。
2. 更新包格式优先采用 dmg 还是 zip。
3. beta 渠道是否在首版即开放。
4. signed feed（SURequireSignedFeed）是直接开启还是延后到 Phase 3。

---

## 附录 A：建议新增文件（实施时）

1. `agentGui/Services/Update/SparkleUpdateCoordinator.swift`
2. `agentGui/Services/Update/SparkleUpdateDelegate.swift`
3. `agentGui/Services/Update/SparkleUpdatePreferencesBridge.swift`
4. `scripts/release/generate_appcast.sh`
5. `docs/release/sparkle-release-runbook.md`

## 附录 B：关键命令示例

```bash
# 1) 生成 EdDSA 密钥（仅首次）
./Sparkle/bin/generate_keys

# 2) 生成 appcast 与 delta
./Sparkle/bin/generate_appcast /path/to/updates

# 3) 清理本地上次检查时间（测试自动检查）
defaults delete com.your.bundle.id SULastCheckTime
```

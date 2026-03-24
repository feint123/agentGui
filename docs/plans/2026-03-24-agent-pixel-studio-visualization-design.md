# Agent 像素工作室可视化 —— 技术设计文档

**日期：** 2026-03-24  
**状态：** 草稿 — 待审阅  
**范围：** 全新可视化面板 · SpriteKit 场景 · SessionProjection 数据绑定

---

## 一、背景与设计目标

### 1.1 设计动机

当前 agentGui 的执行状态呈现是纯文字/气泡流（`ChatView`），无法让用户在宏观维度上一眼感知多个并发 Agent 的运行状态。将 Agent 以像素游戏角色的形式可视化，能够：

- **降低认知负担**：角色动画直觉映射执行阶段，无需阅读状态文字
- **增加存在感**：用户感知到 Agent 在"工作"，减少等待焦虑（"Anthropomorphism in HCI" 研究结论）
- **多 Agent 并发感知**：工作室空间中多角色同时工作，共存状态一目了然
- **提升情感连接**：Lester et al. (1997) "Persona Effect"——可视化角色 Agent 提升用户任务投入度

### 1.2 设计约束

| 约束 | 说明 |
|------|------|
| macOS 26+ | 部署目标已是 macOS 26；可直接使用最新 SpriteKit/SwiftUI API |
| SwiftUI 主架构 | 新面板必须能嵌入 `WorkbenchShellView` 或独立 Window |
| Swift 6 并发安全 | 场景状态更新全部发生在 `@MainActor`，不阻塞执行运行时 |
| 零副作用原则 | 纯展示层，不向执行运行时写入任何状态 |
| 资源可替换 | 像素美术资源以 Asset Catalog 管理，方便后期更换风格 |

---

## 二、技术选型调研

### 2.1 苹果平台 2D 渲染方案对比

#### 2.1.1 SpriteKit

Apple 官方 2D 游戏框架，首发于 iOS 7 / OS X 10.9，macOS 26 原生支持：

**核心能力：**
- `SKTileMapNode`：瓦片地图渲染工作室背景，支持任意大型等距/正交地图
- `SKTextureAtlas`：帧序列动画，批量纹理管理降低绘制调用次数
- `SKAction.animate(with:timePerFrame:)`：像素帧逐帧播放
- `SKEmitterNode`：粒子特效（庆祝彩纸、错误冒烟、打字飞星等）
- `SpriteView`（SwiftUI 原生）：零桥接嵌入 SwiftUI 视图树

**像素艺术渲染：**
```swift
// 关闭双线性插值，保持像素清晰锐利
texture.filteringMode = .nearest
SKTexture.defaultFilteringMode = .nearest
```

**SwiftUI 集成示例：**
```swift
import SpriteKit
import SwiftUI

struct AgentStudioView: View {
    @State private var scene = AgentStudioScene()
    let projection: AgentStudioProjection

    var body: some View {
        SpriteView(scene: scene, options: [.allowsTransparency])
            .aspectRatio(16/9, contentMode: .fit)
            .onChange(of: projection) { _, newValue in
                scene.applyProjection(newValue)  // @MainActor，线程安全
            }
    }
}
```

**优势：** 场景图（scene graph）、物理引擎、粒子系统开箱即用；帧动画 API 成熟  
**劣势：** 独立渲染循环，Swift 6 `Sendable` 边界需 `@MainActor` 显式隔离；字体渲染基于 Core Text

#### 2.1.2 SwiftUI Canvas + TimelineView

SwiftUI 内置低开销 2D 绘图 API，适合简单精灵场景：

```swift
TimelineView(.animation(minimumInterval: 1.0/30)) { timeline in
    Canvas { ctx, size in
        let frame = animationFrame(at: timeline.date)
        ctx.draw(Image("coder_typing_\(frame)"), in: characterRect)
    }
}
```

**优势：** 零额外依赖；状态与 SwiftUI `@State` 天然同步；代码量少  
**劣势：** 无场景图抽象；无内置粒子系统；帧动画需手写状态机；复杂场景（8+ 角色）代码膨胀明显

#### 2.1.3 GameplayKit

Apple 游戏逻辑框架，与 SpriteKit 配合使用：

- `GKStateMachine` — 精确映射 `AgentLoopPhase` 到角色动画状态（语义完全对齐）
- `GKAgent2D` + `GKBehavior` — 角色在工作室中的路径移动（走向工位/走向休息区）
- `GKObstacleGraph` — 处理桌椅障碍物绕行
- `GKRandomDistribution` — 角色 idle 时随机小动作时机，避免所有角色同步动作

#### 2.1.4 排除选项

| 方案 | 排除理由 |
|------|----------|
| Metal | 需要手写着色器和渲染管线，对 2D 像素场景工程成本过高 |
| RealityKit | 定位 3D AR/VR 场景，引入 `.reality` 格式依赖，与项目定位不符 |
| Unity/Godot WebView 嵌入 | 引入外部运行时，打包体积增加 > 100MB，违反 YAGNI |

### 2.2 推荐方案：SpriteKit + GameplayKit

**决策依据：**

1. **SpriteKit** 的 `SKTileMapNode` 直接支持工作室瓦片地图背景渲染，像素风格一行代码即开启
2. `SKAction.animate(with:)` 是苹果原生帧序列动画 API，与像素 Atlas 完美配合
3. **GameplayKit** 的 `GKStateMachine` 与项目已有的 `AgentLoopPhase` 状态机语义天然对齐
4. `SpriteView` 让 SpriteKit 场景以 SwiftUI 组件形式嵌入，无需额外桥接代码
5. 项目不引入任何新的 Swift Package，全部使用 Apple 系统框架

### 2.3 工程实践与学术参考

#### 工程实践文献

| 来源 | 要点 |
|------|------|
| Apple WWDC 2013 Session 503: "Introduction to SpriteKit" | `SKScene` 场景图基础、`SKAction` 动作合成 |
| Apple WWDC 2014 Session 608: "Best Practices for Building SpriteKit Games" | 纹理 Atlas 分包策略；渲染批次优化 |
| Apple WWDC 2017 Session 601: "SpriteKit in Practice" | 大型场景节点实例化；`isPaused` 生命周期管理 |
| Apple WWDC 2015 Session 608: "Introducing GameplayKit" | `GKStateMachine` 设计模式；与 SpriteKit 解耦方式 |
| Apple WWDC 2016 Session 608: "GameplayKit Best Practices" | agent 寻路（`GKObstacleGraph`）与状态解耦模式 |
| Apple Developer Doc: "SpriteKit Programming Guide" | `SKTileMapNode` 瓦片渲染；`SKEmitterNode` 粒子参数 |
| SpriteKit + SwiftUI `SpriteView` 集成指南 (Apple Doc, iOS 14+) | `@MainActor` 安全访问 `SKScene` |

#### 学术参考

| 论文 | 关键结论 |
|------|----------|
| Lester et al. (1997). "The Persona Effect: Affective Impact of Animated Pedagogical Agents" | 可视化 Agent 角色提升用户参与度与任务完成满意度，即使角色缺乏内容帮助性（纯视觉效果即有价值） |
| Nass & Moon (2000). "Machines and Mindlessness: Social Responses to Computers" | 用户对计算机系统产生社交回应；角色化 AI 呈现激活用户的社交映射心理，降低焦虑 |
| Weiser & Brown (1995). "Designing Calm Technology" | 外围感知（Peripheral Awareness）理论——工作室状态视图作为"边缘注意力"展示，无需打断主任务 |
| Johnson et al. (2000). "Animated Pedagogical Agents: Face-to-Face Interaction in Interactive Learning Environments" | 具身角色（Embodied Agent）增强用户对 AI 行为的可理解性与信任感 |
| Reeves & Nass (1996). "The Media Equation" | 人类对媒体中角色的反应等同于对真实人类的反应；角色动画比文字状态更能引发情绪共鸣 |

---

## 三、架构设计

### 3.1 总体分层

```
┌─────────────────────────────────────────────────────────────────┐
│                  WorkbenchShellView (SwiftUI)                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │               AgentStudioView (SwiftUI)                  │   │
│  │  ┌───────────────────────────────────────────────────┐  │   │
│  │  │          AgentStudioScene : SKScene               │  │   │
│  │  │  ┌─────────────┐  ┌─────────────┐               │  │   │
│  │  │  │  Character  │  │  Character  │  ...           │  │   │
│  │  │  │    Node[0]  │  │    Node[1]  │               │  │   │
│  │  │  │ (SKNode)    │  │ (SKNode)    │               │  │   │
│  │  │  └─────────────┘  └─────────────┘               │  │   │
│  │  └───────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  AgentStudioProjectionBuilder (@Observable, @MainActor)         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  builds AgentStudioProjection (pure value / Sendable)   │   │
│  └─────────────────────────────────────────────────────────┘   │
│                          ↑ observes                             │
│  SessionExecutionProjectionRegistry (existing runtime)          │
└─────────────────────────────────────────────────────────────────┘
```

**设计原则：** 渲染层（SpriteKit）与状态层（`@Observable`）严格分离；SpriteKit 场景只接收纯值投影，不直接访问任何 SwiftData 或 Observable 对象。

### 3.2 数据模型

```swift
// MARK: - 工作室顶层投影（驱动整个场景）

struct AgentStudioProjection: Equatable, Sendable {
    var characters: [AgentCharacterState]
    var studioTheme: StudioTheme
    var clockTick: Date      // 用于触发工作室时钟动画

    static let empty = AgentStudioProjection(
        characters: [],
        studioTheme: .pixelOffice,
        clockTick: .distantPast
    )
}

// MARK: - 单个 Agent 角色状态

struct AgentCharacterState: Equatable, Identifiable, Sendable {
    let id: String                           // sessionID（稳定标识）
    let displayName: String                  // Session.title 截断版本
    let characterSkin: CharacterSkin         // 角色外观，按 providerID 自动映射
    let animationState: CharacterAnimationState
    let workstation: WorkstationSlot         // 工位枚举 .slot1 .. .slot8
    let speechBubble: SpeechBubblePresentation?
    let progressRatio: Double                // 0.0–1.0，工作站进度条
    let currentToolName: String?             // 正在执行的工具名称（用于气泡提示）
}

// MARK: - 角色动画状态（与 AgentLoopPhase 对应）

enum CharacterAnimationState: String, Equatable, Sendable {
    case idle           // 空闲：轻微呼吸，随机左右摇头
    case thinking       // executing：手托下巴，头顶省略号气泡
    case typing         // awaitingToolResults：双手打字，键盘粒子
    case reading        // 读取文件工具：拿起文件夹动图
    case celebrating    // finalizing 成功：跳舞，彩纸粒子
    case error          // failed：低头，头顶红色 ! 气泡
    case sleeping       // 长时间无会话：靠椅背闭眼，zZZ 气泡
    case walking        // 移动到新工位时的过渡动画
}

// MARK: - 角色皮肤

enum CharacterSkin: String, CaseIterable, Sendable {
    case coder          // 戴耳机程序员（builtInAgent）
    case wizard         // 魔法师（claudeAdapterCLI）
    case robot          // 机器人（openCodeCLI）
    case detective      // 侦探（githubCopilotCLI）
}

extension ConversationExecutionProviderID {
    var defaultCharacterSkin: CharacterSkin {
        switch self {
        case .builtInAgent:      return .coder
        case .claudeAdapterCLI:  return .wizard
        case .openCodeCLI:       return .robot
        case .githubCopilotCLI:  return .detective
        }
    }
}

// MARK: - 工位枚举

enum WorkstationSlot: Int, CaseIterable, Sendable {
    case slot1, slot2, slot3, slot4
    case slot5, slot6, slot7, slot8

    /// 场景中的像素坐标（320×180 坐标系）
    var scenePosition: CGPoint {
        let row = rawValue / 4
        let col = rawValue % 4
        return CGPoint(
            x: 40 + col * 72,
            y: 120 - row * 70
        )
    }
}

// MARK: - 语音气泡

struct SpeechBubblePresentation: Equatable, Sendable {
    enum BubbleKind: Sendable, Equatable {
        case thought   // 圆形点气泡（thinking）
        case speech    // 对话框气泡（输出文字）
        case action    // 方框气泡（工具调用）
    }
    let text: String
    let kind: BubbleKind
}

// MARK: - 工作室主题

enum StudioTheme: String, Sendable {
    case pixelOffice   // 像素办公室（默认）
    case nightMode     // 深夜加班（暗色调）
    case retro8bit     // 8-bit 复古风格
}
```

### 3.3 AgentLoopPhase → CharacterAnimationState 完整映射

| `AgentLoopPhase` | `CharacterAnimationState` | 动画描述 | 气泡 |
|------|------|------|------|
| `.idle` | `.idle` | 角色静立，每 3s 随机左右摇头 | 无 |
| `.executing` | `.thinking` | 手托下巴，2fps 慢速；头顶省略号旋转 | `.thought("...")`|
| `.awaitingToolResults`（通用）| `.typing` | 双手飞速打字（8fps），键盘粒子 | `.action(toolName)` |
| `.awaitingToolResults`（read 类工具）| `.reading` | 举起文件，翻页动画 | `.action("Reading...")` |
| `.continuingTruncatedResponse` | `.typing` | 同打字 | 无 |
| `.resumingAfterPause` | `.thinking` | 侧身思考姿势 | `.thought("Resuming")` |
| `.finalizing` | `.celebrating` | 举手欢呼（16fps），彩纸粒子 | `.speech("Done!")` |
| `.failed` | `.error` | 低头叹气，红色感叹号 | `.speech("Error")` |
| `.cancelled` | `.idle` | 停下来，回到待机 | 无 |
| 无 Session（空位）| `.sleeping` | 靠椅背，ZZZ 气泡（6fps） | `.thought("zZZ")` |

### 3.4 投影构建器

```swift
@Observable
@MainActor
final class AgentStudioProjectionBuilder {

    private(set) var projection: AgentStudioProjection = .empty

    func rebuild(
        sessions: [Session],
        execProjections: [String: SessionExecutionProjection],
        toolCallSnapshots: [String: ToolCallSnapshot]  // sessionID → 当前工具调用名
    ) {
        let characters = sessions.prefix(8).enumerated().map { index, session in
            let exec = execProjections[session.sessionId]
            let toolName = toolCallSnapshots[session.sessionId]?.currentToolName
            return AgentCharacterState(
                id: session.sessionId,
                displayName: String(session.title.prefix(12)),
                characterSkin: skin(for: session),
                animationState: animationState(from: exec, toolName: toolName),
                workstation: WorkstationSlot(rawValue: index)!,
                speechBubble: bubble(from: exec, toolName: toolName),
                progressRatio: 0.0,
                currentToolName: toolName
            )
        }
        projection = AgentStudioProjection(
            characters: characters,
            studioTheme: .pixelOffice,
            clockTick: Date()
        )
    }

    private func skin(for session: Session) -> CharacterSkin {
        let providerID = ConversationExecutionProviderID(rawValue: session.defaultExecutionProviderID)
        return providerID?.defaultCharacterSkin ?? .coder
    }

    private func animationState(
        from exec: SessionExecutionProjection?,
        toolName: String?
    ) -> CharacterAnimationState {
        guard let exec, exec.isRunning else { return .idle }
        if let phase = exec.currentPhase {  // 需要在 SessionExecutionProjection 扩展中暴露
            switch phase {
            case .executing:             return .thinking
            case .awaitingToolResults:
                let readTools = ["read_file", "list_dir", "search_files", "grep_search"]
                if let name = toolName, readTools.contains(name) { return .reading }
                return .typing
            case .continuingTruncatedResponse: return .typing
            case .resumingAfterPause:          return .thinking
            case .finalizing:                  return .celebrating
            case .failed:                      return .error
            case .cancelled:                   return .idle
            default:                           return .idle
            }
        }
        return exec.isRunning ? .typing : .idle
    }
}
```

---

## 四、SpriteKit 场景设计

### 4.1 场景节点树

```
AgentStudioScene : SKScene
│
├── backgroundLayer : SKTileMapNode          ← 工作室地板/墙面瓦片（静态）
│   ├── floorTileMap                        ← 木地板瓦片 16×16px
│   └── wallTileMap                         ← 背景墙面
│
├── furnitureLayer : SKNode                  ← 静态装饰（不参与物理）
│   ├── deskNodes [ ]                        ← 工作桌精灵（每工位一张）
│   ├── monitorNodes [ ]                     ← 显示器精灵（带屏幕发光动画）
│   ├── bookshelfNode                        ← 书柜装饰
│   └── plantNodes [ ]                       ← 植物（idle 时轻微摇摆）
│
├── charactersLayer : SKNode                 ← 所有角色节点（z层最高）
│   ├── AgentCharacterNode[0]               ← Session A
│   ├── AgentCharacterNode[1]               ← Session B
│   └── ...（最多 8 个）
│
├── particlesLayer : SKNode                  ← 粒子特效（庆祝彩纸、打字粒子）
│
└── hudLayer : SKNode                        ← HUD：工位名称标签、进度条
    ├── workstationLabels [ ]
    └── progressBars [ ]
```

### 4.2 像素渲染关键配置

```swift
final class AgentStudioScene: SKScene {

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .aspectFill
    }

    // 在 didMove(to:) 中配置
    override func didMove(to view: SKView) {
        // 像素精确渲染：关闭抗锯齿与双线性插值
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true

        // 全局关闭纹理插值（像素风格核心设置）
        SKTexture.defaultFilteringMode = .nearest

        // 帧率：省电优先 30fps，动画激烈时可临时提升到 60fps
        view.preferredFramesPerSecond = 30
        view.shouldCullNonVisibleNodes = true

        setupBackground()
        setupFurniture()
        setupHUD()
    }
}
```

### 4.3 AgentCharacterNode 实现

```swift
final class AgentCharacterNode: SKNode {

    private let spriteNode: SKSpriteNode
    private let bubbleNode: SpeechBubbleNode
    private var stateMachine: GKStateMachine!       // GameplayKit 状态机
    private var currentSkin: CharacterSkin
    private var currentAnimation: CharacterAnimationState = .idle

    init(skin: CharacterSkin) {
        self.currentSkin = skin
        self.spriteNode = SKSpriteNode()
        self.spriteNode.texture?.filteringMode = .nearest
        self.bubbleNode = SpeechBubbleNode()
        super.init()
        setupStateMachine()
        addChild(spriteNode)
        addChild(bubbleNode)
        playAnimation(.idle)
    }

    // MARK: - 外部驱动接口

    func apply(_ state: AgentCharacterState) {
        updateBubble(state.speechBubble)
        transition(to: state.animationState)
    }

    // MARK: - 动画状态切换（幂等）

    private func transition(to newState: CharacterAnimationState) {
        guard newState != currentAnimation else { return }
        currentAnimation = newState

        // 状态出入场动画：渐隐再切换
        let fadeOut = SKAction.fadeOut(withDuration: 0.08)
        let swap    = SKAction.run { [weak self] in self?.playAnimation(newState) }
        let fadeIn  = SKAction.fadeIn(withDuration: 0.08)
        spriteNode.run(.sequence([fadeOut, swap, fadeIn]))
    }

    private func playAnimation(_ state: CharacterAnimationState) {
        let atlas = SKTextureAtlas(named: "\(currentSkin.rawValue)_\(state.rawValue)")
        let textures = (0..<atlas.textureNames.count)
            .sorted { atlas.textureNames[$0] < atlas.textureNames[$1] }
            .map { atlas.textureNamed(atlas.textureNames[$0]) }

        textures.forEach { $0.filteringMode = .nearest }

        guard !textures.isEmpty else { return }
        let animate = SKAction.animate(
            with: textures,
            timePerFrame: state.timePerFrame,
            resize: false,
            restore: false
        )
        spriteNode.size = CGSize(width: 32, height: 48)  // 2× 像素精灵尺寸
        spriteNode.removeAction(forKey: "anim")
        spriteNode.run(.repeatForever(animate), withKey: "anim")
    }
}

extension CharacterAnimationState {
    var timePerFrame: TimeInterval {
        switch self {
        case .idle:        return 1.0 / 8
        case .thinking:    return 1.0 / 6
        case .typing:      return 1.0 / 16
        case .reading:     return 1.0 / 10
        case .celebrating: return 1.0 / 12
        case .error:       return 1.0 / 8
        case .sleeping:    return 1.0 / 4
        case .walking:     return 1.0 / 10
        }
    }
}
```

### 4.4 投影更新桥接（SwiftUI → SpriteKit）

```swift
final class AgentStudioScene: SKScene {

    private var characterNodes: [String: AgentCharacterNode] = [:]  // sessionID → node

    // @MainActor 安全调用（SpriteKit scene 始终在主线程访问）
    func applyProjection(_ projection: AgentStudioProjection) {
        let incomingIDs = Set(projection.characters.map(\.id))
        let existingIDs = Set(characterNodes.keys)

        // 移除已关闭的 Session 角色
        existingIDs.subtracting(incomingIDs).forEach { id in
            characterNodes[id]?.run(.sequence([
                .fadeOut(withDuration: 0.3),
                .removeFromParent()
            ]))
            characterNodes.removeValue(forKey: id)
        }

        // 新增 / 更新角色
        for character in projection.characters {
            if let node = characterNodes[character.id] {
                node.apply(character)                           // 已存在：更新状态
                node.run(.move(to: character.workstation.scenePosition, duration: 0.4))
            } else {
                let node = AgentCharacterNode(skin: character.characterSkin)
                node.position = character.workstation.scenePosition
                node.alpha = 0
                node.apply(character)
                charactersLayer.addChild(node)
                node.run(.fadeIn(withDuration: 0.4))            // 入场动画
                characterNodes[character.id] = node
            }
        }
    }
}
```

---

## 五、工作室美术设计规范

### 5.1 场景布局（逻辑像素坐标系 320×180）

```
╔══════════════════════════════════════════════════════════╗
║  ┌─────────────────────┐         ┌─────────┐  ╔═══════╗ ║
║  │   状态板 / 黑板       │         │  时钟    │  ║ 书柜  ║ ║
║  └─────────────────────┘         └─────────┘  ╚═══════╝ ║
║                                                          ║
║  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐        ║
║  │  工位1  │  │  工位2  │  │  工位3  │  │  工位4  │        ║
║  │ [角色] │  │ [角色] │  │ [角色] │  │ [角色] │        ║
║  │  显示器 │  │  显示器 │  │  显示器 │  │  显示器 │        ║
║  └────────┘  └────────┘  └────────┘  └────────┘        ║
║                                                          ║
║  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐        ║
║  │  工位5  │  │  工位6  │  │  工位7  │  │  工位8  │        ║
║  │ [角色] │  │ [角色] │  │ [角色] │  │ [角色] │  🌿    ║
║  └────────┘  └────────┘  └────────┘  └────────┘        ║
╚══════════════════════════════════════════════════════════╝
```

### 5.2 像素美术资产规范

**精灵尺寸：** 16×24px（原始）/ 32×48px（渲染尺寸，忽略像素锯齿）

**Atlas 命名规范：**
```
Assets.xcassets/
  PixelSprites/
    coder/
      coder_idle.spriteatlas          (8帧 @ 8fps)
      coder_thinking.spriteatlas      (12帧 @ 6fps)
      coder_typing.spriteatlas        (6帧 @ 16fps)
      coder_reading.spriteatlas       (8帧 @ 10fps)
      coder_celebrating.spriteatlas   (16帧 @ 12fps)
      coder_error.spriteatlas         (8帧 @ 8fps)
      coder_sleeping.spriteatlas      (8帧 @ 4fps)
    wizard/        ← 同结构
    robot/         ← 同结构
    detective/     ← 同结构
  TileMaps/
    floor_tiles.png     (16×16 瓦片，地板材质)
    wall_tiles.png      (16×16 瓦片，背景墙)
    furniture_desk.png  (32×16，工作桌)
    furniture_monitor_off.png
    furniture_monitor_on.png  (带发光效果)
  Particles/
    celebrating_confetti.sks
    typing_sparkle.sks
    error_smoke.sks
```

**开源资源推荐：**
- [Kenney.nl](https://kenney.nl) Tiny Dungeon / Tiny Town 系列（CC0 授权）
- [itch.io PICO-8 Character Pack]（CC0 / CC-BY）

### 5.3 工作站显示器状态视觉

| 执行状态 | 显示器颜色 | 额外效果 |
|---------|-----------|---------|
| 空闲 | 灰暗（亮度 40%） | 无 |
| 执行中（thinking）| 蓝色泛光 | 缓慢脉冲（SKAction.sequence fadeTo ↔ normal，2s 周期）|
| 等待工具 | 青色泛光 | 快速脉冲（0.5s 周期）|
| 完成 | 绿色泛光 | 一次性闪烁后回归正常 |
| 失败 | 红色泛光 | 快速闪烁 3 次后熄灭 |

---

## 六、集成方案

### 6.1 独立 Window（推荐）

Agent 工作室以独立 macOS 窗口呈现，与主 Workbench 并排摆放，互不干扰。用户可自由调整位置与大小，在多显示器工作环境下尤其适用。

#### 场景 ID 定义

```swift
// AgentStudioWindowScene.swift（新建文件）
enum AgentStudioWindowScene {
    static let id = "agent-studio-window"
}
```

#### agentGuiApp.swift 注册新 Window Scene

```swift
// 在现有 Window("设置", ...) 之后追加：
Window("Agent 工作室", id: AgentStudioWindowScene.id) {
    AgentStudioWindowView()
        .environment(claudeService)
        .environment(PersistenceCoordinator.shared)
}
.modelContainer(sharedModelContainer)
.windowStyle(.titleBar)
.windowResizability(.contentSize)
.defaultSize(width: 960, height: 540)
```

#### AgentStudioWindowView

```swift
struct AgentStudioWindowView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext

    @State private var builder = AgentStudioProjectionBuilder()

    var body: some View {
        AgentStudioView(projection: builder.projection)
            .frame(minWidth: 640, minHeight: 360)
            .onAppear {
                builder.bind(to: claudeService.executionRegistry,
                             modelContext: modelContext)
            }
    }
}
```

#### 菜单命令开启窗口

在 `SettingsMenuCommands`（或新建 `StudioMenuCommands`）中追加入口：

```swift
struct StudioMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("显示 Agent 工作室") {
                openWindow(id: AgentStudioWindowScene.id)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}
```

在 `agentGuiApp.body` 的 `.commands { }` 中追加 `StudioMenuCommands()`。

#### 窗口生命周期与节能策略

```swift
struct AgentStudioWindowView: View {
    // ...
    var body: some View {
        AgentStudioView(projection: builder.projection)
            // 窗口最小化 / 切换到后台时暂停 SpriteKit 渲染循环
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            ) { _ in
                builder.suspendUpdates()     // scene.isPaused = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            ) { _ in
                builder.resumeUpdates()      // scene.isPaused = false
            }
    }
}
```

> **为何不嵌入 WorkbenchShellView：**  
> 嵌入底部 Panel 会压缩主工作区纵向空间，且 SpriteKit 渲染循环无论工作室是否可见都会消耗 GPU；独立窗口让用户自主控制可见性，关闭后场景完全卸载（`SKView` 随 Window 一同销毁），功耗归零。

### 6.2 数据流全景

```
SessionExecutionProjectionRegistry
        │   @Observable observe
        ▼
AgentStudioProjectionBuilder
        │   .rebuild(sessions:execProjections:toolCallSnapshots:)
        ▼
AgentStudioProjection (Sendable 值类型)
        │   SwiftUI .onChange(of:)
        ▼
AgentStudioScene.applyProjection(_:)
        │   per-character diff
        ▼
AgentCharacterNode.apply(_:)
        │   GKStateMachine.enter(StateClass)
        ▼
SKSpriteNode.run(animateAction) → SpriteKit 渲染循环
```

---

## 七、性能与功耗考量

### 7.1 渲染优化

| 场景 | 策略 |
|------|------|
| 零 Agent 运行时 | `scene.isPaused = true`；SpriteKit 渲染循环停止，GPU 空载 |
| macOS 切换到后台 | 监听 `NSApplication.didResignActiveNotification`，暂停场景 |
| 帧率策略 | 默认 30fps；用户可在 Settings 降至 15fps（纯装饰场景够用）|
| 纹理内存 | 仅加载当前已分配 Session 对应皮肤的 Atlas；`SKTextureAtlas.preload(completionHandler:)` 异步预加载 |
| 节点数控制 | 最多 8 个角色节点；总场景节点数 < 200，保持批次绘制高效 |

### 7.2 Swift 6 并发安全

```swift
// AgentStudioScene 全部 public 接口标注 @MainActor
// SpriteKit 渲染回调（update:, didEvaluateActions 等）在主线程，天然安全
// applyProjection 方法唯一入口，@MainActor 隔离，Sendable 参数保证跨边界安全

@MainActor
func applyProjection(_ projection: AgentStudioProjection) {
    // 安全：projection 是 Sendable 值类型
    // 安全：SKNode 访问在 MainActor
}
```

---

## 八、扩展性与未来演进

| 扩展点 | 描述 | 优先级 |
|--------|------|--------|
| 工具特定动画 | `search_*` 工具：角色拿起望远镜；`write_file`：角色拿笔写字 | P2 |
| 角色交互 | 点击角色 → 在 ChatView 中聚焦对应 Session | P1 |
| 邮件传递动画 | 多 Agent 工具调用结果传递时，角色走向另一工位置换文件 | P3 |
| 音效层 | 可选 SFX：打字声、完成叮声（默认静音，用户开启）| P3 |
| 夜间模式 | `StudioTheme.nightMode`：工作室灯光变暗，显示器成为主光源 | P2 |
| 用户自选皮肤 | Session 设置里选择该会话角色的皮肤 | P2 |
| 自定义工位布局 | 用户拖拽调整工位位置（drag to reorder） | P3 |
| isometric 视图 | 从正交视角升级为等距（isometric）视角，更具游戏感 | P3 |

---

## 九、开放问题

| # | 问题 | 默认决策 | 需确认 |
|---|------|---------|--------|
| Q1 | 像素美术资源来源？ | 使用 Kenney.nl CC0 资源快速验证，后期定制 | 是 |
| Q2 | 角色皮肤分配策略？ | 按 `ConversationExecutionProviderID` 自动分配（不同 Agent 类型不同外观）| 否 |
| Q3 | 面板默认展开还是折叠？ | 默认折叠；用户显式打开 | 否 |
| Q4 | 是否接入 SessionExecutionProjection.currentPhase？ | 需要对 `SessionExecutionProjection` 添加 `currentPhase: AgentLoopPhase?` 字段 | 是 |
| Q5 | 最大并发角色数？ | 上限 8 个（工位数量），超出部分排队不展示 | 否 |

---

## 十、MVP 实施顺序

### Phase 1 — 静态场景骨架（2-3 天）

1. 创建 `AgentStudioProjection` / `AgentCharacterState` 数据模型（新文件）
2. 创建 `AgentStudioProjectionBuilder` （@Observable，从现有 registry 读取）
3. 建立 `AgentStudioScene`（静态背景 + 工位占位节点，无帧动画）
4. `AgentStudioView` 用 `SpriteView` 嵌入，挂载到 `WorkbenchShellView` 底部 panel
5. 验证：场景正常渲染，Swift 6 编译无警告

### Phase 2 — 角色帧动画（3-4 天）

6. 引入 Kenney.nl 像素资源，配置 `coder` 皮肤所有 Atlas
7. 实现 `AgentCharacterNode` 完整状态切换逻辑
8. 接通 `SessionExecutionProjection` 驱动，验证 `AgentLoopPhase` → 动画自动切换

### Phase 3 — 视效增强（2-3 天）

9. 粒子特效：`celebrating_confetti.sks` / `error_smoke.sks`
10. 显示器发光动画（`SKAction` 脉冲序列）
11. 工位标签 HUD、进度条渲染

### Phase 4 — 完整多皮肤 + 交互（3-4 天）

12. `wizard` / `robot` / `detective` 皮肤 Atlas
13. 点击角色 → 触发 Session 聚焦（通过 `FocusState` / `NotificationCenter`）
14. 工具特定动画（`read_file` → reading；`bash` → typing with terminal icon）

---

## 参考文献

1. Lester, J. C., Converse, S. A., Kahler, S. E., Barlow, S. T., Stone, B. A., & Bhogal, R. S. (1997). *The Persona Effect: Affective Impact of Animated Pedagogical Agents*. CHI '97.
2. Nass, C., & Moon, Y. (2000). *Machines and Mindlessness: Social Responses to Computers*. Journal of Social Issues, 56(1), 81–103.
3. Weiser, M., & Brown, J. S. (1995). *Designing Calm Technology*. PowerGrid Journal.
4. Reeves, B., & Nass, C. (1996). *The Media Equation*. Cambridge University Press.
5. Johnson, W. L., Rickel, J. W., & Lester, J. C. (2000). *Animated Pedagogical Agents: Face-to-Face Interaction in Interactive Learning Environments*. International Journal of AI in Education.
6. Apple Inc. (2023). *SpriteKit Programming Guide*. Apple Developer Documentation.
7. Apple Inc. (2015). *GameplayKit Programming Guide*. Apple Developer Documentation.
8. Apple WWDC 2014 Session 608: *Best Practices for Building SpriteKit Games*.
9. Apple WWDC 2015 Session 608: *Introducing GameplayKit*.
10. Apple WWDC 2016 Session 608: *GameplayKit Best Practices*.

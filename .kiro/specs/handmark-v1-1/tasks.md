# Implementation Plan: HandMark V1.1

## Overview

本实现计划在现有 macOS 原生 Swift 项目（AppKit + AVFoundation + Vision + Core Animation，单可执行 SPM 目标 `Sources/HandMark/main.swift`，无第三方依赖，macOS 13）上做**增量加固**。实现语言为 **Swift**（设计文档全程给出具体 Swift 类型/函数签名，非伪代码，无需选择语言）。

任务严格遵循 V1.1 需求规定的**五阶段交付顺序**，每阶段完成后先 `swift build` 编译、再 `swift test` 运行该阶段新增单测，验证通过方可进入下一阶段：

- 阶段 0（前置）：抽出可单测纯逻辑 + 调整 `Package.swift`（新增 `HandMarkCore` library target 与 `HandMarkCoreTests` test target，保持可执行入口 `main.swift` 不变、无第三方依赖）。
- 阶段 1：画笔启动防抖与防挑线（`PinchStateMachine`）。对应 Requirement 1、2，Property 1~6。
- 阶段 2：合并预览窗口与控制面板为单一「HandMark Demo」窗口 + `NSStatusItem`。对应 Requirement 3、6。
- 阶段 3：五指关键点显示与清屏相关状态文案补齐。对应 Requirement 4。
- 阶段 4：六→握拳组合清屏（分类层 + `ClearGestureStateMachine` + `GesturePriorityCoordinator`）。对应 Requirement 5，Property 7~11。
- 阶段 5：集成与真实摄像头人工验收（无法用单测替代，明确列出）。

实现原则：先理解再改、尽量复用现有类型（`HandTracker`/`DrawState`/`OverlayView`/`PreviewController`/`PanelActions`/`PreviewView`/`computePalmScale`）、沿用现有命名不无谓重命名、遇权衡优先最小可行修复、不引入范围外功能（翻页/设置中心/账号/联网/后端/数据库）。纯逻辑单测以 `TimeInterval` 注入时间做确定性时序推进。

## Tasks

- [x] 1. 阶段 0 — 可测性改造：抽纯逻辑 + 调整 Package.swift
  - [x] 1.1 新增 HandMarkCore library target 的纯值类型数据模型
    - 新建 `Sources/HandMarkCore/Metrics.swift`，只 import `Foundation` 与 `CoreGraphics`（不得 import AVFoundation/AppKit/Vision）
    - 定义 `FingerFeature`（`tip/dip/pip/mcp: CGPoint`、`minConfidence: Float`）与 `HandMetrics`（`thumb/index/middle/ring/little: FingerFeature`、`wrist: CGPoint`、`palmScale: Double`、`pinchDistanceNorm: Double`、`hasHand: Bool`）
    - 坐标约定沿用 Vision 原始归一化（0...1，左下原点）；`pinchDistanceNorm` 按不变量 I1 仅由原始坐标得出
    - _Requirements: 1.9, 2.9_

  - [x] 1.2 新增捏合与清屏状态枚举及配置类型
    - 在 `Sources/HandMarkCore/` 新建 `Gesture.swift`，定义扩展后的 `PinchPhase { idle, candidate, drawing, releaseCandidate }`（复用现有 `candidate` 命名，不重命名为 `pinchCandidate`）
    - 定义 `ClearPhase { idle, sixCandidate, sixArmed, fistCandidate, clearing, cooldown }`
    - 定义 `PinchConfig`/`ClearConfig`/`GestureConfig`，字段取设计参数表初值（`PINCH_ON=0.22`、`PINCH_OFF=0.35`、`PINCH_CONFIRM_MS=150`、`RELEASE_CONFIRM_MS=80`、`MIN_CONFIDENCE=0.3`、`LOW_CONF_TOLERANCE_MS=200`、`EMA_ALPHA=0.5`、`SIX_CONFIRM_MS=180`、`SIX_TO_FIST_TIMEOUT_MS=1000`、`FIST_CONFIRM_MS=180`、`COOLDOWN_MS=800`、`EXT_HI/EXT_LO/FIST_COMPACT` 为待标定占位常量）
    - 定义输出类型 `PinchOutcome { none, begin, append, end }`、`ClearOutcome { none, performClear, suspendPinch }`、`PoseMatch { matched, confidence, reliable }`、`PreviewPhase`、`CoordinatorDecision`，均 `Equatable`
    - _Requirements: 1.10, 5.3_

  - [x] 1.3 调整 Package.swift 为三目标结构
    - 改写 `Package.swift`：`.target(name: "HandMarkCore", path: "Sources/HandMarkCore")`、`.executableTarget(name: "HandMark", dependencies: ["HandMarkCore"], path: "Sources/HandMark")`、`.testTarget(name: "HandMarkCoreTests", dependencies: ["HandMarkCore"], path: "Tests/HandMarkCoreTests")`
    - 保持可执行入口为 `Sources/HandMark/main.swift`（顶层代码 + `app.run()`）不变，不引入任何第三方依赖，platform 仍为 macOS 13
    - 在 `main.swift` 顶部 `import HandMarkCore`，确保既有编译可用
    - _Requirements: 6.6_

  - [x] 1.4 建立 HandMarkCoreTests 测试目标骨架
    - 新建 `Tests/HandMarkCoreTests/` 目录与首个 `XCTestCase` 占位（仅依赖 `HandMarkCore`，`@testable import HandMarkCore`），提供构造 `HandMetrics`/`FingerFeature` 的测试辅助工厂
    - 保证 `swift test` 可发现并运行该目标
    - _Requirements: 6.6_

  - [x] 1.5 阶段 0 验证：编译 + 运行测试目标
    - 运行 `swift build` 确认三目标编译通过、可执行入口结构未破坏
    - 运行 `swift test` 确认 `HandMarkCoreTests` 目标被发现且占位测试通过
    - _Requirements: 6.6_

- [x] 2. 阶段 1 — 画笔启动防抖与防挑线（PinchStateMachine）
  - [x] 2.1 实现 PinchStateMachine 纯逻辑状态机
    - 在 `Sources/HandMarkCore/Gesture.swift` 实现 `struct PinchStateMachine`，`step(distNorm:tipReliable:handPresent:suspended:now:config:) -> PinchOutcome`
    - 实现迟滞（`PINCH_ON < PINCH_OFF`）、`candidate` 确认计时（`PINCH_CONFIRM_MS`）、候选取消（确认前 `dist>=PINCH_ON` 回 `idle` 不建笔画）
    - 实现 `drawing → releaseCandidate` 松开去抖：`dist>PINCH_OFF` 进 `releaseCandidate` 不立即结束；窗内 `dist<=PINCH_OFF` 回 `drawing`；持续 `RELEASE_CONFIRM_MS` 才 `end` 封存
    - 实现低置信处理：`tipReliable=false` 单帧仅跳过（不 `append`/不 `end`），持续 `LOW_CONF_TOLERANCE_MS` 才 `end`
    - 实现手部丢失：`handPresent=false` 在绘画态返回 `end`、否则 `none`，并复位计时
    - `suspended=true`（清屏优先）时忽略 `idle→candidate` 与候选确认，不产生 `begin`
    - 时间以 `now: TimeInterval` 注入，内部不调用 `Date()`/`CACurrentMediaTime()`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.1, 2.2, 2.3, 2.6_

  - [x]* 2.2 为 PinchStateMachine 编写捏合确认与候选取消单测
    - **Property 1: 捏合迟滞**
    - **Validates: Requirements 1.1, 1.2, 1.3**
    - 用例：`dist<PINCH_ON` 持续 >=150ms → 首帧 `begin` 且不 `append`；确认期内单帧 `dist>=PINCH_ON` → 回 `idle` 且无 `begin`
    - 以注入 `TimeInterval` 确定性推进计时

  - [x]* 2.3 为 PinchStateMachine 编写结束去抖与结束帧不追加单测
    - **Property 2: 结束去抖 / Property 3: 结束帧不追加**
    - **Validates: Requirements 1.5, 1.6, 1.7, 2.2, 2.3**
    - 用例：`drawing` 中单帧 `dist>PINCH_OFF` 不立即 `end`；持续 >=`RELEASE_CONFIRM_MS` 才 `end`；`end` 帧及随后 `idle` 帧均无 `append`；去抖窗内 `dist<=PINCH_OFF` 恢复 `drawing` 不误断

  - [x]* 2.4 为 PinchStateMachine 编写低置信与丢失不连线单测
    - **Property 6: 丢失不桥接**
    - **Validates: Requirements 2.5, 2.6, 2.7**
    - 用例：`tipReliable=false` 单帧不 `append` 不 `end`、持续 >=200ms 才 `end`；`handPresent=false` 绘画态 `end` 且后续无 `append`（配合调用方清空平滑，断言不产生跨丢失 append 序列）

  - [x] 2.5 在 captureOutput 接入 PinchStateMachine 并固化 EMA 隔离（I1）
    - 在 `HandTracker.captureOutput` 中用 `buildHandMetrics`（新私有方法）从 Vision 关键点构造 `HandMetrics`，`pinchDistanceNorm` 复用现有原始坐标距离公式 + `computePalmScale`（保持不变）
    - 以「① 先推进 `PinchStateMachine.step` → ② 再按 `PinchOutcome` 落笔」编排：`begin→state.beginStroke`、`append→state.appendPoint`、`end/none→不追加`
    - EMA 平滑只作用于写入 `DrawState` 的屏幕坐标（沿用 `smoothed`/`EMA_ALPHA`），严禁回灌到喂状态机的 `distNorm`
    - 丢失分支沿用现有：`smoothed=nil`、不写入、不以直线连接前后点
    - 替换原内联三态 `switch phase`，`HandFrame.phase` 映射保持预览可用
    - _Requirements: 2.1, 2.4, 2.8, 2.9_

  - [ ]* 2.6 为 EMA 隔离不变量编写单测
    - **Property 5: EMA 隔离（不变量 I1）**
    - **Validates: Requirements 2.9**
    - 用例：以不同 `EMA_ALPHA` 构造写入坐标序列，断言喂给状态机的 `pinchDistanceNorm` 仅由原始归一化坐标决定、与 EMA 取值无关（通过纯 `HandMetrics` 构造验证 distNorm 来源）

  - [x] 2.7 阶段 1 验证：编译 + 运行阶段 1 单测
    - 运行 `swift build` 确认接入后可执行目标编译通过
    - 运行 `swift test` 确认阶段 1 新增 `PinchStateMachine` 相关单测全部通过
    - _Requirements: 1.1, 2.1_

- [x] 3. 阶段 2 — 合并预览窗口与控制面板为单一「HandMark Demo」窗口
  - [x] 3.1 实现 DemoWindowController 合并窗口（顶部预览 + 底部两按钮）
    - 新建 `DemoWindowController`（重构自 `PreviewController` + `makeControlPanel`），单一 `NSPanel`，标题统一「HandMark Demo」，`styleMask` 含 `.titled`/`.closable`/`.nonactivatingPanel`，`level=screenSaver+1`
    - 顶部内嵌复用 `PreviewView`（五指 + 状态），底部放「清除笔迹」与「隐藏预览」两个 `NSButton`；**删除「退出 Demo」按钮**，关闭改用标题栏原生红黄绿交通灯（`.closable`，不自绘仿系统按钮）
    - `PanelActions.clear` 继续作用于真实 `DrawState.clearAll()` + `update()`（刷新真实 `OverlayView`），而非仅清预览图
    - 「隐藏预览」按钮：隐藏整个控制窗口并置 `gTracker?.previewWanted=false`（停预览图生成/刷新，后台识别继续）
    - 隐藏时 `apply` 直接 return（沿用现有），不重复创建 UI 对象
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.9_

  - [x] 3.2 实现窗口关闭（交通灯）拦截为"仅隐藏、后台继续"
    - 为 DemoWindow 设置 `NSWindowDelegate`，`windowShouldClose` 返回 false 并 `orderOut`（关闭=隐藏控制窗口，不中断摄像头/识别/后台绘画）
    - 明确区分三语义：关闭控制窗口（仅隐藏、后台绘画继续）、隐藏预览（隐藏窗口+停预览图、后台绘画继续、提供恢复入口）、退出应用（停摄像头与后台任务）
    - _Requirements: 3.8, 3.12_

  - [x] 3.3 新增 NSStatusItem 菜单栏项（显示/退出入口）
    - 在 `main.swift` 入口创建 `NSStatusItem`（强引用持有，避免释放），菜单含「显示 HandMark Demo」与「退出 HandMark」两项
    - 「显示 HandMark Demo」：`orderFrontRegardless` 重新显示 DemoWindow 并恢复 `previewWanted=true`
    - 「退出 HandMark」：`NSApp.terminate(nil)`，真正停止摄像头会话与后台任务；保持 `activationPolicy=.accessory` 不变
    - 替换入口中原 `PreviewController`/`makeControlPanel` 装配为 `DemoWindowController`
    - _Requirements: 3.10, 3.11, 3.12_

  - [ ]* 3.4 为合并窗口交互添加可自动化的回归检查
    - 在 `HandMarkCore` 或可编译的轻量单测中验证「隐藏预览→previewWanted 置 false 的开关语义」等可纯逻辑化的部分（真实窗口交互归入阶段 5 人工验收）
    - _Requirements: 3.7, 6.5, 6.9_

  - [x] 3.5 阶段 2 验证：编译 + 运行测试
    - 运行 `swift build` 确认合并窗口与 NSStatusItem 装配后可执行目标编译通过
    - 运行 `swift test` 确认既有单测与阶段 2 新增可自动化检查通过
    - 注：真实窗口交互（交通灯关闭、显示/退出、鼠标穿透）须在阶段 5 真实摄像头人工验收，无法用单测替代
    - _Requirements: 3.1, 6.1_

- [x] 4. 阶段 3 — 五指关键点显示与清屏状态文案补齐
  - [x] 4.1 扩展 PreviewStatus 并补齐 displayText 映射
    - 为 `PreviewStatus` 新增 `clearSixCandidate`/`clearSixArmed`/`clearFistCandidate`/`clearing` 四个 case
    - 补齐 `lines`/`color` 与 `displayText` 映射文案：清屏手势候选（六）/ 六已就绪·请握拳 / 清屏手势候选（握拳）/ 正在清屏；第二行继续显示 `d/px/掌宽/置信度`
    - 新增状态须覆盖需求 4.4 全集：等待摄像头、摄像头已开启未识别到手、已识别到手、正在绘画、清屏手势候选、正在清屏、权限不足/设备异常
    - _Requirements: 4.4, 4.5_

  - [x] 4.2 校正五指关键点显示的方向、镜像与置信度区分
    - 复用并核对 `PreviewView.drawSkeleton` 的五指 `chains`、关节连线、指尖标签「拇食中无小」与低置信（`<LOW_CONF_DISPLAY`）空心灰虚线
    - 核对 `MIRROR_X`（`1-x`）/`FLIP_Y` 换算使镜像与上下方向不颠倒、不错位，关键点同步镜像；拇指尖↔食指尖连线保持
    - _Requirements: 4.1, 4.2, 4.3_

  - [x] 4.3 将清屏组合阶段透传到 HandFrame/PreviewView
    - 在 `HandFrame` 增加清屏阶段字段（或透传 `PreviewPhase`），`captureOutput` 的主线程投递中按协调器输出设置对应 `PreviewStatus`，使预览能显示清屏候选/正在清屏
    - 低置信/关键点不完整时不显示为可触发状态（为阶段 4 的 reliable 判定预留透传）
    - _Requirements: 4.4, 4.6, 4.7_

  - [ ]* 4.4 为 PreviewStatus 文案映射编写单测
    - 对可纯逻辑化的 `displayText`/`lines`（若抽到可测边界）或 `PreviewPhase→PreviewStatus` 映射做表驱动断言，覆盖新增四个清屏状态
    - _Requirements: 4.4_

  - [x] 4.5 阶段 3 验证：编译 + 运行测试
    - 运行 `swift build` 确认预览扩展后可执行目标编译通过
    - 运行 `swift test` 确认阶段 3 新增单测通过
    - 注：方向/镜像正确性须在阶段 5 真实摄像头人工验收
    - _Requirements: 4.1, 4.4_

- [x] 5. 阶段 4 — 六→握拳组合清屏（分类层 + 状态机 + 协调器）
  - [x] 5.1 实现姿势分类层 fingerExtension / classifySix / classifyFist
    - 在 `Sources/HandMarkCore/` 实现 `fingerExtension(_:palmScale:wrist:) -> Double`（基于指尖到 MCP 的伸展投影归一，并要求 tip 比 pip 更远离 wrist 否则视为弯曲）
    - 实现 `classifySix(_:minConfidence:) -> PoseMatch`（拇指+小指伸展 `>EXT_HI`、食/中/无名弯曲 `<EXT_LO`、置信达标）与 `classifyFist(_:minConfidence:) -> PoseMatch`（五指弯曲 + 收拢 `maxTipPair/palmScale < FIST_COMPACT` + 置信达标）
    - 基于关节相对位置 + 伸展度 + 置信度综合判定，不依赖单关节固定角度；`reliable=false` 时 `matched` 强制为假
    - _Requirements: 4.6, 5.1, 5.2_

  - [ ]* 5.2 为分类层编写命中、边界与低置信单测
    - **Property 11: 不可靠不清屏**
    - **Validates: Requirements 4.6, 4.7, 5.1, 5.2**
    - 用例：`classifySix` 命中（拇指+小指伸展、食中无弯曲、置信达标）；边界不命中（少一指/多一指伸展）；`classifyFist` 命中（五指弯曲+收拢+置信达标）；任一关键关节 `conf<MIN_CONFIDENCE` → `reliable=false` 且 `matched=false`

  - [x] 5.3 实现 ClearGestureStateMachine 六态状态机
    - 实现 `struct ClearGestureStateMachine`，`step(six:fist:drawing:handPresent:now:config:) -> ClearOutcome`，六态 `idle/sixCandidate/sixArmed/fistCandidate/clearing/cooldown`
    - `drawing=true` 时不从 `idle` 进 `sixCandidate`；六稳定 >=`SIX_CONFIRM_MS` 进 `sixArmed`；`sixArmed` 超 `SIX_TO_FIST_TIMEOUT_MS`(1s) 未握拳回 `idle` 不清
    - 握拳稳定 >=`FIST_CONFIRM_MS` 进 `clearing` 返回 `performClear`（先结束当前笔画禁追加再清全部）；`clearing→cooldown`；`cooldown` 必须先退出握拳（`fistExited`）且满 `COOLDOWN_MS`(800ms) 才回 `idle`
    - 关键点丢失/置信不足/切换其他不符姿势/摄像头中断 → 取消候选回 `idle` 不清；`sixArmed/fistCandidate` 返回 `suspendPinch`
    - 时间以 `now: TimeInterval` 注入
    - _Requirements: 5.1, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.14_

  - [ ]* 5.4 为清屏状态机顺序与单独姿势不清屏编写单测
    - **Property 7: 清屏需顺序 / Property 8: 单独姿势不清屏**
    - **Validates: Requirements 5.1, 5.5, 5.7, 5.14**
    - 用例：六→握拳顺序触发 `performClear` 恰一次；仅六一直命中无握拳永不 `performClear`；从 `idle` 直接给握拳（无先行六）永不 `performClear`

  - [ ]* 5.5 为清屏超时与冷却编写单测
    - **Property 9: 清屏冷却**
    - **Validates: Requirements 5.6, 5.8, 5.9**
    - 用例：`sixArmed` 后超 1000ms 未握拳 → 回 `idle` 无清屏；`performClear` 后未过 800ms 或未退出握拳不再 `performClear`，满足"先退出握拳 + 满 800ms"后才回 `idle`

  - [x] 5.6 实现 GesturePriorityCoordinator 优先级协调器
    - 实现 `struct GesturePriorityCoordinator { var pinch; var clear }`，`step(_:now:config:) -> CoordinatorDecision`
    - 固定顺序：先推进清屏状态机决定是否 `suspend`，再据 `suspend` 推进捏合状态机；合成 `previewPhase` 供状态文案
    - `sixArmed/fistCandidate/clearing` 期间使捏合不产生 `begin`（暂停新画笔、忽略捏合启动）；清屏取消后恢复画笔；清屏完成需先 `cooldown→idle` 才允许下次 `begin`
    - _Requirements: 5.11, 5.12, 5.13_

  - [ ]* 5.7 为优先级协调与绘画中不起步编写单测
    - **Property 10: 清屏优先级**
    - **Validates: Requirements 5.4, 5.11, 5.12, 5.13**
    - 用例：`drawing=true` 时六命中不进 `sixCandidate`；`sixArmed` 后对捏合返回 suspend 且捏合不 `begin`；清屏取消后捏合恢复可 `begin`；清屏完成需先冷却回 `idle` 再允许 `begin`

  - [x] 5.8 在 captureOutput 接入协调器并执行清屏
    - 用 `GesturePriorityCoordinator` 替换阶段 1 的单独 `PinchStateMachine` 调用：每帧 `coordinator.step(m, now, config)`
    - `clearOutcome==performClear` 时在 videoQueue 下先结束当前笔画（禁追加）再 `state.clearAll()`（作用于真实 `OverlayView` 对应 DrawState），随后主线程 `update()` 刷新
    - 将 `decision.previewPhase` 映射为阶段 3 的 `PreviewStatus` 透传预览
    - 全程保持 `DrawState` 访问持 `NSLock`、AppKit 更新在主线程（不变量 I2）
    - _Requirements: 5.7, 5.11, 5.12, 5.13, 6.7_

  - [x] 5.9 阶段 4 验证：编译 + 运行阶段 4 单测
    - 运行 `swift build` 确认分类层/状态机/协调器接入后可执行目标编译通过
    - 运行 `swift test` 确认阶段 4 新增全部单测通过
    - _Requirements: 5.1, 5.14_

- [ ] 6. 阶段 5 — 集成与真实摄像头人工验收（无法用单测替代）
  - [x] 6.1 构建 .app 并通过 open 启动
    - 运行 `./build.sh`（`swift build -c release` 打包 `HandMark.app`），用 `open HandMark.app` 启动以使摄像头权限弹窗与 Info.plist(`LSUIElement`/`NSCameraUsageDescription`) 正确归属
    - _Requirements: 6.3_

  - [ ] 6.2 方向标定与五指骨架方向一致性人工验收
    - **人工验收，无法用单测替代**：核对镜像/上下不颠倒不错位、五指骨架与屏幕轨迹方向一致；必要时标定 `MIRROR_X`/`FLIP_Y`
    - _Requirements: 4.2, 4.3_

  - [ ] 6.3 捏合手感与松开不挑线主观效果人工验收
    - **人工验收，无法用单测替代**：实机标定 `PINCH_ON`/`PINCH_OFF`/`RELEASE_CONFIRM_MS`，确认起笔稳定、松开末段无向上挑起尾线
    - _Requirements: 1.1, 2.2_

  - [ ] 6.4 六/握拳几何阈值实机标定（EXT_HI/EXT_LO/FIST_COMPACT）
    - **人工验收，无法用单测替代**：借预览状态条第二行 `d/px/掌宽/置信度` 观测，实机标定 `EXT_HI`/`EXT_LO`/`FIST_COMPACT` 保守初值
    - _Requirements: 5.1, 5.2_

  - [ ] 6.5 六→握拳组合清屏体感与误触率人工验收
    - **人工验收，无法用单测替代**：真实手势下验证顺序触发、1s 超时取消、800ms 冷却与"必须先退出握拳"的体感及误触/成功率
    - _Requirements: 5.6, 5.8, 5.9_

  - [ ] 6.6 合并窗口交互人工验收
    - **人工验收，无法用单测替代**：交通灯关闭=隐藏后台继续、隐藏预览=停预览图但识别继续、NSStatusItem「显示 HandMark Demo」恢复、「退出 HandMark」真正停摄像头
    - _Requirements: 3.8, 3.10, 3.11, 6.5_

  - [ ] 6.7 鼠标穿透、全屏覆盖与单路摄像头性能人工验收
    - **人工验收，无法用单测替代**：`ignoresMouseEvents` 鼠标键盘穿透到底层（如 PPT）、screenSaver 级全屏覆盖、仅单路摄像头约 30fps、心跳日志中预览帧与处理帧一致、隐藏预览后开销下降而识别不受影响
    - _Requirements: 6.2, 6.4, 6.6, 6.8, 6.10_

## Notes

- 标记 `*` 的子任务为测试类（单元/属性/集成），可为更快 MVP 跳过；核心实现任务不加 `*`。
- 阶段 5 的所有子任务为**真实摄像头人工验收**，设计 Testing Strategy 已明确其无法用单测替代；相关实现任务（阶段 1~4）在验证子任务中均注明对应人工验收归属阶段 5。
- 每个可执行任务引用其实现/验证的 Requirement 编号，测试任务额外标注对应 Correctness Property 编号。
- 纯逻辑单测时间以 `TimeInterval` 显式注入，确定性推进计时与超时；不依赖真实时钟。
- 尽量复用现有类型（`HandTracker`/`DrawState`/`OverlayView`/`PreviewController`/`PanelActions`/`PreviewView`/`computePalmScale`），沿用现有命名（如 `candidate`），不做范围外重构。
- 范围内不含翻页/设置中心/账号/联网/后端/数据库。

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2"] },
    { "id": 1, "tasks": ["1.3", "1.4"] },
    { "id": 2, "tasks": ["1.5", "2.1"] },
    { "id": 3, "tasks": ["2.2", "2.3", "2.4"] },
    { "id": 4, "tasks": ["2.5"] },
    { "id": 5, "tasks": ["2.6", "2.7"] },
    { "id": 6, "tasks": ["3.1"] },
    { "id": 7, "tasks": ["3.2", "3.3"] },
    { "id": 8, "tasks": ["3.4", "3.5"] },
    { "id": 9, "tasks": ["4.1", "4.2"] },
    { "id": 10, "tasks": ["4.3"] },
    { "id": 11, "tasks": ["4.4", "4.5"] },
    { "id": 12, "tasks": ["5.1", "5.3"] },
    { "id": 13, "tasks": ["5.2", "5.4", "5.5", "5.6"] },
    { "id": 14, "tasks": ["5.7", "5.8"] },
    { "id": 15, "tasks": ["5.9"] },
    { "id": 16, "tasks": ["6.1"] },
    { "id": 17, "tasks": ["6.2", "6.3", "6.4", "6.5", "6.6", "6.7"] }
  ]
}
```

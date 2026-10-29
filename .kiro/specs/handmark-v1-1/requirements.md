# Requirements Document

## Introduction

HandMark 是一个 macOS 原生隔空绘画 Demo：摄像头识别手部，拇指与食指捏合开始绘画、分开停止，绘画轨迹以荧光笔效果叠加在全屏透明窗口上。现有实现集中在单可执行 SPM 目标 `Sources/HandMark/main.swift`，技术栈为 Swift + AppKit + AVFoundation + Vision（`VNDetectHumanHandPoseRequest`）+ Core Animation，无第三方依赖，目标平台 macOS 13。

本需求文档描述 HandMark V1.1 的增量加固，共五项主题：(1) 画笔启动防抖；(2) 修复松开向上挑线；(3) 合并预览窗口与控制面板为单一窗口；(4) 识别并显示五指关键点并补齐清屏相关状态；(5) 新增「六→握拳」有序组合手势清屏。本文档由已批准的 design.md 反推生成（Design-First 工作流），每条需求忠实对应设计中的技术方案与验收标准。

本文档为增量开发，范围严格限定于上述五项与相关回归约束。**明确不做**：翻页、设置中心、账号、联网、后端、数据库。需求编号按五大主题组织（需求 1~5 对应设计中 Correctness Properties 的粗粒度映射：1=启动防抖、2=防挑线、3=合并窗口、4=五指显示、5=组合清屏），验收条目细分为 N.x，可被设计性质追溯；需求 6 为回归约束型需求。

## Glossary

- **HandMark_System**：HandMark 应用整体，包含摄像头采集、Vision 识别、手势判定、绘画渲染与窗口 UI。
- **Pinch_State_Machine**：捏合绘画状态机，状态集合为 `idle`、`pinchCandidate`（现有代码命名为 `candidate`）、`drawing`、`releaseCandidate`。
- **Clear_Gesture_State_Machine**：六→握拳组合清屏状态机，状态集合为 `idle`、`sixCandidate`、`sixArmed`、`fistCandidate`、`clearing`、`cooldown`。
- **Gesture_Coordinator**：手势优先级协调器，每帧先推进清屏状态机再推进捏合状态机，使清屏组合优先于普通画笔。
- **Hand_Classifier**：姿势分类层，基于关节相对位置、伸展程度与置信度综合判定「六」与「握拳」。
- **Draw_State**：线程安全的绘画状态（受 `NSLock` 保护），保存已封存笔画、当前活动笔画、指尖与捏合标志。
- **Overlay_View**：全屏透明覆盖层视图，渲染真实绘画轨迹（荧光笔效果）。
- **Demo_Window**：合并后的单一控制窗口，标题「HandMark Demo」，含摄像头预览与底部按钮。
- **Preview_View**：Demo_Window 顶部的摄像头预览叠加视图，绘制五指关键点、关节连线、置信度与状态文案。
- **Status_Item**：macOS 菜单栏状态项（NSStatusItem），提供「显示 HandMark Demo」与「退出 HandMark」入口。
- **Pinch_Distance**：拇指尖与食指尖之间的距离除以掌宽（palmScale）得到的归一化距离；由 Vision 原始归一化坐标计算，不受绘画坐标平滑影响。
- **Palm_Scale**：掌宽像素尺度，经合理性检查与指数平滑得到，用于归一化距离与伸展度。
- **Index_Tip**：食指尖关键点；绘画坐标取自食指尖。
- **EMA_Smoothing**：对食指尖绘画坐标做的轻量指数移动平均，仅用于绘画坐标写入，不影响手势距离判定。
- **PINCH_ON**：进入 `pinchCandidate` 的归一化捏合距离阈值，初值 0.22。
- **PINCH_OFF**：结束绘画的归一化捏合距离阈值，初值 0.35（与 PINCH_ON 形成迟滞）。
- **PINCH_CONFIRM_MS**：捏合候选确认时长，初值 150ms。
- **RELEASE_CONFIRM_MS**：松开去抖确认时长，初值 80ms。
- **MIN_CONFIDENCE**：指尖写入与姿势判定的最低置信度，初值 0.3。
- **LOW_CONF_TOLERANCE_MS**：绘画中持续低置信多久才结束笔画，初值 200ms。
- **SIX_CONFIRM_MS**：「六」稳定确认时长，初值 180ms（范围 150~200ms）。
- **SIX_TO_FIST_TIMEOUT_MS**：六就绪后握拳的超时时长，初值 1000ms。
- **FIST_CONFIRM_MS**：握拳稳定确认时长，初值 180ms（范围 150~200ms）。
- **COOLDOWN_MS**：清屏完成后的冷却时长，初值 800ms。

## Requirements

### Requirement 1: 画笔启动防抖

**User Story:** 作为隔空绘画用户，我希望捏合开始绘画时不会因单帧抖动误触或误断，以便获得稳定可控的起笔与持续绘画体验。

#### Acceptance Criteria

1. WHEN 拇指尖与食指尖的归一化 Pinch_Distance 首次低于 PINCH_ON 且当前处于 `idle`，THE Pinch_State_Machine SHALL 进入 `pinchCandidate` 状态并开始确认计时。
2. WHILE 处于 `pinchCandidate` 状态且 Pinch_Distance 持续低于 PINCH_ON，THE Pinch_State_Machine SHALL 在累计满足时长达到 PINCH_CONFIRM_MS 时进入 `drawing` 状态并新建一条笔画。
3. IF 处于 `pinchCandidate` 状态且在达到 PINCH_CONFIRM_MS 之前 Pinch_Distance 回升到不低于 PINCH_ON，THEN THE Pinch_State_Machine SHALL 取消候选、返回 `idle` 状态并且不新建笔画。
4. WHILE 处于 `drawing` 状态，THE Pinch_State_Machine SHALL 使用食指尖坐标作为绘画坐标。
5. WHEN 处于 `drawing` 状态且 Pinch_Distance 单帧超过 PINCH_OFF，THE Pinch_State_Machine SHALL 进入 `releaseCandidate` 状态并开始松开去抖计时，而不立即结束笔画。
6. IF 处于 `releaseCandidate` 状态且 Pinch_Distance 在达到 RELEASE_CONFIRM_MS 之前回落到不超过 PINCH_OFF，THEN THE Pinch_State_Machine SHALL 返回 `drawing` 状态并继续当前笔画。
7. WHILE 处于 `releaseCandidate` 状态且 Pinch_Distance 持续超过 PINCH_OFF 累计达到 RELEASE_CONFIRM_MS，THE Pinch_State_Machine SHALL 结束并封存当前笔画、返回 `idle` 状态。
8. THE Pinch_State_Machine SHALL 使用 PINCH_ON 作为开始阈值、PINCH_OFF 作为结束阈值，且 PINCH_ON 小于 PINCH_OFF 以形成迟滞。
9. THE HandMark_System SHALL 使用基于 Palm_Scale 的归一化方式计算 Pinch_Distance，使判定与摄像头距离和手的大小无关。
10. THE Pinch_State_Machine SHALL 至少区分 `idle`、`pinchCandidate`、`drawing`、`releaseCandidate` 四个状态，并复用现有 PinchPhase 类型进行扩展，而不是另建一套并行的捏合状态表示。

### Requirement 2: 修复松开向上挑线

**User Story:** 作为隔空绘画用户，我希望松开手指停止绘画时轨迹末端不出现向上挑起的尾线，以便绘画结果干净准确。

#### Acceptance Criteria

1. WHEN 处理每一帧摄像头数据，THE HandMark_System SHALL 先推进手势状态（识别关键点、计算 Pinch_Distance、更新 Pinch_State_Machine），再根据状态决定是否采集并写入食指尖坐标。
2. WHEN 当前帧确认结束绘画，THE HandMark_System SHALL 立即封存当前笔画且在该结束帧不再追加任何坐标。
3. WHILE 处于 `idle` 状态，THE HandMark_System SHALL 不向 Draw_State 写入任何坐标。
4. WHEN 封存笔画后下一次捏合被确认，THE HandMark_System SHALL 新建一条全新笔画，且该笔画不与上一条已封存笔画以连线相接。
5. IF 食指尖或拇指尖关键点丢失，THEN THE HandMark_System SHALL 结束当前笔画、清空绘画坐标平滑缓存，并且不写入任何异常坐标。
6. IF 关键点处于低置信（低于 MIN_CONFIDENCE），THEN THE HandMark_System SHALL 跳过该帧坐标写入，且仅当低置信持续达到 LOW_CONF_TOLERANCE_MS 时才结束笔画。
7. WHEN 关键点丢失或低置信导致坐标缺失，THE HandMark_System SHALL 不使用异常坐标延伸笔画，并且不以直线连接坐标缺失前后两点。
8. THE HandMark_System SHALL 对食指尖绘画坐标应用 EMA_Smoothing 以减少抖动，且该平滑不引入明显延迟。
9. THE HandMark_System SHALL 仅将 EMA_Smoothing 用于写入 Draw_State 的绘画坐标，并保证手势距离判定所用的 Pinch_Distance 仅由原始归一化坐标计算、不受 EMA_Smoothing 影响。

### Requirement 3: 合并预览窗口与控制面板

**User Story:** 作为用户，我希望摄像头预览与控制按钮集成在同一个窗口内，并能清楚区分关闭窗口、隐藏预览与退出应用，以便减少窗口混乱并避免误以为关窗即退出。

#### Acceptance Criteria

1. THE HandMark_System SHALL 将摄像头预览与控制按钮整合进单一 Demo_Window，统一标题为「HandMark Demo」，不再单独显示独立的摄像头预览窗口。
2. THE Demo_Window SHALL 在顶部显示摄像头预览（含五指关键点与手势状态），在底部显示「清除笔迹」与「隐藏预览」两个按钮。
3. THE Preview_View SHALL 复用与绘画识别相同的那一路摄像头，不为预览单独开启第二路摄像头。
4. WHEN 用户点击「清除笔迹」按钮，THE HandMark_System SHALL 清除 Draw_State 中全部已封存笔画以及当前未封存的活动笔画，且作用于真实绘画覆盖层而非仅清除预览图像。
5. WHEN 用户点击「清除笔迹」按钮，THE HandMark_System SHALL 保持摄像头运行、保持控制窗口显示，且不影响后续绘画。
6. WHEN 用户点击「隐藏预览」按钮，THE HandMark_System SHALL 隐藏整个控制窗口，同时保持摄像头、手势识别与后台绘画继续运行、不关闭画板。
7. WHILE 预览处于隐藏状态，THE HandMark_System SHALL 停止不必要的预览图像生成与预览 UI 刷新，同时保持识别数据处理不受影响。
8. WHEN 用户通过标题栏红色交通灯关闭控制窗口，THE HandMark_System SHALL 仅隐藏控制窗口而不中断后台绘画、识别与摄像头。
9. THE Demo_Window SHALL 使用 macOS 原生标题栏的红黄绿交通灯作为窗口关闭控件，而不自绘仿系统按钮，并且移除原有的「退出 Demo」按钮。
10. WHILE 控制窗口处于关闭或隐藏状态，THE Status_Item SHALL 提供「显示 HandMark Demo」入口以重新显示 Demo_Window。
11. WHEN 用户通过 macOS 标准应用退出入口（Status_Item 的「退出 HandMark」）退出应用，THE HandMark_System SHALL 真正停止摄像头与后台任务并结束应用。
12. THE HandMark_System SHALL 明确区分关闭控制窗口（仅隐藏窗口、后台绘画继续）、隐藏预览（隐藏窗口且停止预览图生成、后台绘画继续、提供恢复入口）、退出应用（停止摄像头与后台任务）三种语义。

### Requirement 4: 识别并显示五指关键点

**User Story:** 作为用户，我希望预览能正确显示五指关键点、关节连线与置信度，并展示包含清屏候选与正在清屏在内的清晰状态，以便我理解系统当前的识别与手势状态并便于调参。

#### Acceptance Criteria

1. THE Hand_Classifier SHALL 使用现有 Vision 手部识别接口提取拇指、食指、中指、无名指、小指的指尖与相关关节。
2. THE Preview_View SHALL 在预览上叠加五指指尖标记、关节连线以及置信度区分（可信与低可信）。
3. THE Preview_View SHALL 以方向正确的方式显示关键点，使镜像与上下方向不颠倒、不错位；WHERE 预览采用镜像显示，THE Preview_View SHALL 使关键点同步镜像。
4. THE Preview_View SHALL 在预览下方显示以下状态之一：等待摄像头、摄像头已开启未识别到手、已识别到手、正在绘画、清屏手势候选、正在清屏、摄像头权限不足或设备异常。
5. THE Preview_View SHALL 额外显示当前 Pinch_Distance，以便调试与阈值标定。
6. THE Hand_Classifier SHALL 在 Vision 返回的关键点与置信度之上实现轻量姿势分类以得出「六」与「握拳」语义，因为 Vision 本身不返回「六」或「握拳」语义。
7. IF 关键点不完整、置信不足或发生遮挡，THEN THE HandMark_System SHALL 不仅凭不可靠的单个关键点触发清屏。

### Requirement 5: 六→握拳组合手势清屏

**User Story:** 作为用户，我希望用「先做出六、再握拳」的有序组合手势清除全部笔迹，并且该手势具备防误触、超时取消与冷却机制，以便安全可靠地一键清屏而不误清。

#### Acceptance Criteria

1. THE Clear_Gesture_State_Machine SHALL 识别有先后顺序的组合手势：先识别「六」（拇指伸展、小指伸展、食指中指无名指弯曲），再识别握拳（五指弯曲收拢且置信度达标），顺序满足后才确认清屏。
2. THE Hand_Classifier SHALL 使用手指关节相对位置、伸展程度与置信度综合判定「六」与「握拳」，而不仅依据单关节固定角度。
3. THE Clear_Gesture_State_Machine SHALL 至少区分 `idle`、`sixCandidate`、`sixArmed`、`fistCandidate`、`clearing`、`cooldown` 六个状态。
4. WHILE 捏合状态处于绘画态，THE Clear_Gesture_State_Machine SHALL 不从 `idle` 进入 `sixCandidate`，即仅在非绘画状态才允许开始识别清屏组合。
5. WHILE 处于 `sixCandidate` 且「六」稳定持续达到 SIX_CONFIRM_MS，THE Clear_Gesture_State_Machine SHALL 进入 `sixArmed` 状态。
6. IF 进入 `sixArmed` 后在 SIX_TO_FIST_TIMEOUT_MS 内未检测到稳定握拳，THEN THE Clear_Gesture_State_Machine SHALL 取消当前清屏候选、返回 `idle` 并且不清除笔迹。
7. WHILE 处于 `fistCandidate` 且握拳稳定持续达到 FIST_CONFIRM_MS，THE Clear_Gesture_State_Machine SHALL 进入 `clearing` 状态，先立即结束当前笔画并禁止继续追加坐标，再清除全部已封存笔画与活动笔画。
8. WHEN 完成清屏，THE Clear_Gesture_State_Machine SHALL 进入约 COOLDOWN_MS 的 `cooldown` 冷却状态。
9. THE Clear_Gesture_State_Machine SHALL 要求用户先退出握拳状态后再次完成「六→握拳」，才允许执行下一次清屏。
10. IF「六」在达到 SIX_CONFIRM_MS 前不再稳定、或「六」之后超过 SIX_TO_FIST_TIMEOUT_MS 未握拳、或关键点丢失或置信不足、或切换为其他不符合组合条件的姿势、或摄像头中断，THEN THE Clear_Gesture_State_Machine SHALL 取消当前清屏候选、恢复正常识别并且不清除笔迹。
11. WHILE 清屏组合处于 `sixArmed`、`fistCandidate` 或 `clearing`，THE Gesture_Coordinator SHALL 使清屏组合优先于普通画笔：暂停开始新画笔、忽略拇指食指捏合的画笔启动请求、继续追踪以等待握拳确认或取消。
12. WHEN 清屏候选被取消，THE Gesture_Coordinator SHALL 恢复正常绘画识别。
13. WHEN 清屏完成，THE Gesture_Coordinator SHALL 先恢复普通状态，再允许下一次捏合启动绘画。
14. THE Clear_Gesture_State_Machine SHALL 仅在「六→握拳」组合被确认时清屏，在手势未确认时不清除任何笔迹。

### Requirement 6: 回归约束

**User Story:** 作为用户，我希望 V1.1 的改动不破坏现有的透明覆盖绘画、鼠标键盘穿透、权限处理、后台识别与性能表现，以便原有功能在加固后仍然稳定可用。

#### Acceptance Criteria

1. THE HandMark_System SHALL 保留透明全屏覆盖层用于绘画渲染。
2. THE Overlay_Window SHALL 使鼠标与键盘事件穿透到底层应用（如 PPT），不拦截用户对底层程序的操作。
3. IF 摄像头权限不足或设备异常，THEN THE HandMark_System SHALL 进入相应错误状态并显示控制窗口以提示用户。
4. THE HandMark_System SHALL 持续渲染绘画轨迹。
5. WHILE 预览处于隐藏状态，THE HandMark_System SHALL 继续进行后台手势识别与绘画。
6. THE HandMark_System SHALL 仅开启单路摄像头，供识别与预览共用。
7. THE HandMark_System SHALL 通过 NSLock 保护所有对 Draw_State 的访问，并在主线程执行所有 AppKit 视图更新，使手势判定、绘画状态与 UI 更新线程安全。
8. WHILE 处理高频摄像头回调，THE HandMark_System SHALL 不重复创建大量 UI 对象。
9. WHILE 预览处于隐藏状态，THE HandMark_System SHALL 降低预览相关开销且不影响识别数据处理。
10. THE HandMark_System SHALL 使 UI 更新不阻塞手势识别与绘画处理。

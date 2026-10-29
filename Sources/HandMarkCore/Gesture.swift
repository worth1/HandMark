//
//  Gesture.swift
//  HandMarkCore
//
//  V1.1 纯逻辑手势类型定义层。
//
//  本文件只定义手势判定所需的纯值类型：状态枚举、配置类型、输出/辅助类型。
//  严禁 import AVFoundation / AppKit / Vision —— 仅依赖 Foundation 与 CoreGraphics，
//  以保证可被 testTarget 独立单测（纯逻辑、无框架依赖、时间显式注入）。
//
//  说明：本任务（1.2）只定义类型、枚举、配置与初值，不实现状态机方法体
//  （PinchStateMachine / ClearGestureStateMachine / GesturePriorityCoordinator
//   的 step 实现分别属于任务 2.1 / 5.3 / 5.6）。
//

import Foundation
import CoreGraphics

// MARK: - 状态枚举

/// 捏合绘画状态机的相位。
/// 复用现有代码命名 `candidate`（即需求文档的 pinchCandidate），不重命名。
/// `releaseCandidate` 为 V1.1 新增的松开去抖中间态。
public enum PinchPhase {
    case idle
    case candidate        // = 需求文档的 pinchCandidate（复用现有命名，不重命名）
    case drawing
    case releaseCandidate // V1.1 新增：松开去抖中间态
}

/// 六→握拳组合清屏状态机的相位。
public enum ClearPhase {
    case idle
    case sixCandidate
    case sixArmed
    case fistCandidate
    case clearing
    case cooldown
}

// MARK: - 配置类型

/// 捏合绘画相关参数（取自设计「关键参数初始取值表」）。
public struct PinchConfig {
    /// 进入候选的归一化捏合距离阈值（掌宽归一化）。初值 0.22。
    public var pinchOn: Double
    /// 结束绘画阈值（与 pinchOn 形成迟滞，pinchOn < pinchOff）。初值 0.35。
    public var pinchOff: Double
    /// 候选确认时长（毫秒）。初值 150ms。
    public var pinchConfirmMs: Double
    /// 松开去抖确认时长（毫秒，releaseCandidate）。
    /// 由 80ms 适度加长到 160ms：掌宽(palmScale)突变造成的「假松开」通常只持续几帧（<120ms），
    /// 更长的去抖窗能等到掌宽平滑恢复、归一化距离回落，从而避免误结束笔画。
    public var releaseConfirmMs: Double
    /// 指尖写入与姿势判定的最低置信度。初值 0.3。
    public var minConfidence: Float
    /// 绘画中持续低置信多久才结束笔画（毫秒）。初值 200ms。
    public var lowConfToleranceMs: Double
    /// 食指尖绘画坐标 EMA 平滑系数（仅用于绘画坐标，I1）。初值 0.5。
    public var emaAlpha: Double
    /// 原始像素距离「真松开」判据：releaseCandidate 期间，只有当原始拇指尖↔食指尖像素距离
    /// 相对「捏合基准像素距离」增大到该倍数以上，才认可是真的松开并立即结束；否则视为
    /// palmScale 突变造成的假松开，暂缓释放、继续观察（配合去抖窗兜底）。初值 1.8。
    public var releasePxRatio: Double

    public init(pinchOn: Double = 0.22,
                pinchOff: Double = 0.35,
                pinchConfirmMs: Double = 150,
                releaseConfirmMs: Double = 160,
                minConfidence: Float = 0.3,
                lowConfToleranceMs: Double = 200,
                emaAlpha: Double = 0.5,
                releasePxRatio: Double = 1.8) {
        self.pinchOn = pinchOn
        self.pinchOff = pinchOff
        self.pinchConfirmMs = pinchConfirmMs
        self.releaseConfirmMs = releaseConfirmMs
        self.minConfidence = minConfidence
        self.lowConfToleranceMs = lowConfToleranceMs
        self.emaAlpha = emaAlpha
        self.releasePxRatio = releasePxRatio
    }
}

/// 六→握拳组合清屏相关参数（取自设计「关键参数初始取值表」）。
public struct ClearConfig {
    /// 六稳定确认时长（毫秒）。初值 180ms（范围 150~200ms）。
    public var sixConfirmMs: Double
    /// 六就绪后握拳的超时时长（毫秒）。
    ///
    /// 原为 1000ms：从「六」被确认那一刻起算，用户必须在 1 秒内完成「收指成拳 + 稳定
    /// 保持 180ms」，实测过于仓促（真机经常来不及）。放宽到 2000ms，仍远短于一次
    /// 无意识悬停，不会显著增加误触。
    public var sixToFistTimeoutMs: Double
    /// 握拳稳定确认时长（毫秒）。初值 180ms（范围 150~200ms）。
    public var fistConfirmMs: Double
    /// 握拳确认期间允许「握拳判定短暂掉帧」的容忍时长（毫秒）。
    ///
    /// Vision 在收指成拳的瞬间常有几帧指尖跳变/置信度抖动，旧逻辑一掉帧就把
    /// `fistStart` 重置回 sixArmed，用户几乎握不出连续 180ms → 表现为「握拳识别不到」。
    /// 容忍窗内不重置计时，掉帧恢复后继续累计。
    public var fistLossToleranceMs: Double
    /// 清屏完成后的冷却时长（毫秒）。初值 800ms。
    public var cooldownMs: Double

    /// 判定「伸展」的伸展度上阈。待实机标定（先给保守占位初值）。
    public var extHi: Double
    /// 判定「弯曲」的伸展度下阈。待实机标定（先给保守占位初值）。
    public var extLo: Double
    /// 握拳收拢度阈（指尖跨度/掌宽）。待实机标定（先给保守占位初值）。
    public var fistCompact: Double

    public init(sixConfirmMs: Double = 180,
                sixToFistTimeoutMs: Double = 2000,
                fistConfirmMs: Double = 180,
                fistLossToleranceMs: Double = 300,
                cooldownMs: Double = 800,
                // 以下三项为待标定占位常量，先给保守初值（待实机标定）：
                // extHi 偏高、extLo 偏低可缩小误命中区间；fistCompact 偏小要求更收拢。
                extHi: Double = 0.9,     // 待实机标定
                extLo: Double = 0.5,     // 待实机标定
                fistCompact: Double = 0.6 // 待实机标定
    ) {
        self.sixConfirmMs = sixConfirmMs
        self.sixToFistTimeoutMs = sixToFistTimeoutMs
        self.fistConfirmMs = fistConfirmMs
        self.fistLossToleranceMs = fistLossToleranceMs
        self.cooldownMs = cooldownMs
        self.extHi = extHi
        self.extLo = extLo
        self.fistCompact = fistCompact
    }
}

/// 聚合捏合与清屏配置。
public struct GestureConfig {
    public var pinch: PinchConfig
    public var clear: ClearConfig
    public var laser: LaserConfig
    public var page: PageConfig
    public var knob: KnobConfig
    public var volume: VolumeGestureConfig

    public init(pinch: PinchConfig = PinchConfig(),
                clear: ClearConfig = ClearConfig(),
                laser: LaserConfig = LaserConfig(),
                page: PageConfig = PageConfig(),
                knob: KnobConfig = KnobConfig(),
                volume: VolumeGestureConfig = VolumeGestureConfig()) {
        self.pinch = pinch
        self.clear = clear
        self.laser = laser
        self.page = page
        self.knob = knob
        self.volume = volume
    }
}

// MARK: - 输出 / 辅助类型

/// 捏合状态机每帧的落笔指令。
public enum PinchOutcome: Equatable {
    case none      // 不落笔（idle / candidate / 结束帧 / 开始帧）
    case begin     // 本帧新建笔画（justStarted，不追加）
    case append    // 本帧追加食指尖坐标
    case end       // 本帧封存笔画，禁止追加
}

/// 清屏组合状态机每帧的裁决输出。
public enum ClearOutcome: Equatable {
    case none
    case performClear   // 本帧执行清屏（协调器据此先封存笔画再 clearAll）
    case suspendPinch   // 已 sixArmed/fistCandidate：要求暂停画笔
}

/// 姿势分类结果（六 / 握拳）。
public struct PoseMatch: Equatable {
    /// 是否命中该姿势。
    public var matched: Bool
    /// 命中时的综合置信度；未命中为参与关节的可用度。
    public var confidence: Float
    /// 关键点是否完整且置信足够（不足时不得触发清屏）。
    public var reliable: Bool

    public init(matched: Bool, confidence: Float, reliable: Bool) {
        self.matched = matched
        self.confidence = confidence
        self.reliable = reliable
    }
}

/// 协调器合成的整体预览相位，供状态文案映射。
public enum PreviewPhase: Equatable {
    case idleHand
    case pinchCandidate
    case drawing
    case sixCandidate
    case sixArmed
    case fistCandidate
    case clearing
    case cooldown
    // V2.0 新增：
    case laserCandidate
    case laserActive
    case pageArmed
    case pageCooldown
    // V3.0 新增：五指旋钮与拇指音量
    case knobCandidate
    case knobActive
    /// 本次激活已切过一档，需收手后重新五指张开才能再切。
    case knobConsumed
    case volumeCandidate
    case volumeLatched
}

/// 协调器每帧的裁决结果。
public struct CoordinatorDecision: Equatable {
    public var pinchOutcome: PinchOutcome
    public var clearOutcome: ClearOutcome
    public var previewPhase: PreviewPhase
    // V2.0 新增：激光与翻页的本帧输出（由唯一协调器统一裁决，调用方据此执行动作）。
    public var laserOutcome: LaserOutcome
    public var pageOutcome: PageOutcome
    // V3.0 新增：旋钮与系统音量手势的单次动作输出。
    public var knobOutcome: KnobOutcome
    public var volumeOutcome: VolumeGestureOutcome

    public init(pinchOutcome: PinchOutcome,
                clearOutcome: ClearOutcome,
                previewPhase: PreviewPhase,
                laserOutcome: LaserOutcome = .none,
                pageOutcome: PageOutcome = .none,
                knobOutcome: KnobOutcome = .none,
                volumeOutcome: VolumeGestureOutcome = .none) {
        self.pinchOutcome = pinchOutcome
        self.clearOutcome = clearOutcome
        self.previewPhase = previewPhase
        self.laserOutcome = laserOutcome
        self.pageOutcome = pageOutcome
        self.knobOutcome = knobOutcome
        self.volumeOutcome = volumeOutcome
    }
}

// MARK: - 捏合绘画状态机（任务 2.1）

/// 捏合绘画的纯逻辑状态机（设计伪代码 A / 状态机图 1 的实现）。
///
/// 职责边界：
/// - 只做迟滞（`PINCH_ON < PINCH_OFF`）、候选确认计时、松开去抖、低置信容忍与手部丢失封存，
///   每帧输出一个 `PinchOutcome` 落笔指令（`none/begin/append/end`）。
/// - 时间完全由调用方通过 `now: TimeInterval` 注入，内部绝不调用 `Date()` / `CACurrentMediaTime()`，
///   以保证可被纯逻辑单测（时间显式、可重放）。
/// - 不碰 EMA、不碰屏幕坐标：`distNorm` 必须由调用方用 Vision **原始**归一化坐标算好传入（不变量 I1）。
///
/// 不变量：
/// - I2/需求 2.2、2.4：产生 `.end` 的那一帧，以及其后直到下一次 `.begin` 之间（即 `idle` / `candidate`
///   / `releaseCandidate` 恢复前），绝不返回 `.append`——由下面的状态流天然保证（只有 `drawing` 的
///   可靠分支会返回 `.append`）。
/// - 需求 1.8：`PINCH_ON` 为开始阈值、`PINCH_OFF` 为结束阈值，二者形成迟滞（阈值取自传入的 `config`）。
/// - `suspended == true`（清屏优先）时，`idle`/`candidate` 均不得前进到 `drawing`，因此不会产生 `.begin`。
public struct PinchStateMachine {

    /// 当前相位（外部只读）。初始 `.idle`。
    public private(set) var phase: PinchPhase = .idle

    /// 进入 `candidate` 的时间戳（用于 `PINCH_CONFIRM_MS` 确认计时）。
    private var candidateStart: TimeInterval = 0
    /// 进入 `releaseCandidate` 的时间戳（用于 `RELEASE_CONFIRM_MS` 去抖计时）。
    private var releaseStart: TimeInterval = 0
    /// `drawing` 中首次观测到低置信的时间戳；`nil` 表示当前未处于低置信累计中。
    private var lowConfSince: TimeInterval? = nil
    /// 「捏合基准像素距离」：进入 drawing 的那一帧记录的原始拇指尖↔食指尖像素距离，
    /// 随后在 drawing 中用较近的捏合帧持续更新为「最小值附近」的参照，
    /// 作为 releaseCandidate 判断「是否真松开」的像素证据基准（不受 palmScale 突变影响）。
    private var pinchBasePx: Double = 0

    public init() {}

    /// 推进一帧，返回本帧的落笔指令。
    ///
    /// - Parameters:
    ///   - distNorm: 归一化捏合距离（原始坐标算得，不含 EMA，不变量 I1）。
    ///   - tipReliable: 本帧指尖关键点是否置信可靠（低置信为 false）。
    ///   - handPresent: 本帧是否检测到可用手部。
    ///   - suspended: 清屏优先是否要求暂停画笔。
    ///   - now: 调用方注入的当前时间（秒）。
    ///   - config: 捏合参数（阈值与各计时窗口，毫秒）。
    /// - Returns: `PinchOutcome`（`none`/`begin`/`append`/`end`）。
    public mutating func step(distNorm: Double,
                              distPx: Double = 0,
                              tipReliable: Bool,
                              handPresent: Bool,
                              suspended: Bool,
                              now: TimeInterval,
                              config: PinchConfig) -> PinchOutcome {
        // 手部丢失：立即结束，禁止写入（需求 2.5 / I3）；EMA 清空由调用方负责。
        if !handPresent {
            let wasDrawing = (phase == .drawing || phase == .releaseCandidate)
            phase = .idle
            lowConfSince = nil
            pinchBasePx = 0
            return wasDrawing ? .end : .none
        }

        // === ① 先处理状态变化（需求 2.1：每帧先状态后落笔）===
        switch phase {
        case .idle:
            // 清屏优先：忽略捏合启动，绝不建笔画。
            if suspended { return .none }
            if distNorm < config.pinchOn {
                phase = .candidate
                candidateStart = now
            }
            return .none

        case .candidate:
            // 候选取消：清屏优先，或距离回升到不低于开始阈值 → 回 idle 不建笔画（需求 1.3）。
            if suspended || distNorm >= config.pinchOn {
                phase = .idle
                return .none
            }
            // 持续满足确认时长 → 进入 drawing，新建笔画，本帧不追加（需求 1.2）。
            if (now - candidateStart) * 1000 >= config.pinchConfirmMs {
                phase = .drawing
                pinchBasePx = distPx           // 记录捏合基准像素距离
                return .begin
            }
            return .none

        case .drawing:
            // 捏合持续时，用较小的像素距离更新基准（跟踪真实捏合的最近像素尺度，
            // 使后续「真松开」判定以当前捏合紧密度为参照，而非最初起笔那一帧）。
            if distNorm <= config.pinchOff, distPx > 0 {
                pinchBasePx = pinchBasePx > 0 ? min(pinchBasePx, distPx) * 0.7 + distPx * 0.3 : distPx
            }
            // 归一化越过结束阈值 → 进入松开去抖，不立即结束也不追加本帧（需求 1.5 / 2）。
            if distNorm > config.pinchOff {
                phase = .releaseCandidate
                releaseStart = now
                return .none
            }
            // 低置信容忍：持续不可靠累计达阈值才结束（需求 2.6）。
            if !tipReliable {
                if lowConfSince == nil { lowConfSince = now }
                if let since = lowConfSince,
                   (now - since) * 1000 >= config.lowConfToleranceMs {
                    phase = .idle
                    lowConfSince = nil
                    return .end
                }
                // 低置信帧跳过写入：不结束、不追加（需求 2.6 / 2.7）。
                return .none
            }
            // 可靠且持续绘画才追加食指尖坐标（需求 1.4 / 2）。
            lowConfSince = nil
            return .append

        case .releaseCandidate:
            // 抖动恢复：归一化回落到不超过结束阈值 → 回 drawing，本帧不追加以避免跳点（需求 1.6）。
            if distNorm <= config.pinchOff {
                phase = .drawing
                return .none
            }
            // 像素辅助证据：若原始像素距离相对捏合基准没有明显增大（< releasePxRatio 倍），
            // 说明手指其实仍捏着，归一化距离变大多半是 palmScale 突变造成的「假松开」——
            // 此时不以去抖超时结束，一直暂缓观察，等归一化回落或像素真正拉大。
            let pxGrewEnough = pinchBasePx <= 0 || distPx <= 0 ||
                               distPx >= pinchBasePx * config.releasePxRatio
            // 仅当「归一化持续越阈达去抖窗」且「像素距离确实显著增大」才确认真松开。
            if pxGrewEnough, (now - releaseStart) * 1000 >= config.releaseConfirmMs {
                phase = .idle
                pinchBasePx = 0
                return .end
            }
            return .none
        }
    }
}

// MARK: - V2.0 激光 / 翻页：状态枚举

/// 激光指示状态机相位。
public enum LaserPhase: Equatable {
    case idle
    case candidate   // 检测到四指伸出手形，等待稳定确认
    case active      // 已确认，正在显示激光光点
}

/// PPT 翻页状态机相位。
public enum PagePhase: Equatable {
    case idle
    case armed       // 双指手形稳定成立，开始采集水平轨迹
    case cooldown    // 已翻一页，冷却中（防重复）
    case waitReset   // V4.2 已翻一页，需先「解除双指手型」才能再次 armed，防回摆误翻页
}

/// 翻页方向。
public enum PageDirection: Equatable {
    case left   // 向左挥 → 上一页
    case right  // 向右挥 → 下一页
}

// MARK: - V2.0 激光 / 翻页：配置

/// 激光指示参数。
public struct LaserConfig {
    /// 手形稳定确认时长（毫秒）。
    public var confirmMs: Double
    /// 关键点持续不可靠多久才退出激光（毫秒，短暂波动不退出）。
    public var lossToleranceMs: Double
    /// 中指指尖光点 EMA 平滑系数（仅用于光点坐标）。
    public var emaAlpha: Double
    public init(confirmMs: Double = 200, lossToleranceMs: Double = 200, emaAlpha: Double = 0.5) {
        self.confirmMs = confirmMs
        self.lossToleranceMs = lossToleranceMs
        self.emaAlpha = emaAlpha
    }
}

/// PPT 翻页参数（初始调试值，集中管理便于标定）。
///
/// V4.1 「跟手」调优：原参数需要先把手形**定住** 200ms 才开始记录轨迹，用户挥出去的
/// 前 200ms 位移被整段丢弃，感觉「挥了没反应、要多挥一大截」。现改为：
/// 手形确认期内同步记录起点（边确认边跟踪），确认一成立就把这段位移计入，
/// 同时下调确认时长、触发位移与冷却，做到「挥到即翻」。
public struct PageConfig {
    /// 双指手形稳定确认时长（毫秒）。
    public var holdMs: Double
    /// 挥动轨迹观察窗口（毫秒）：armed 后在此窗口内累计水平位移。
    public var swipeWindowMs: Double
    /// 水平位移阈值（归一化：相对画面宽度的比例，0.12 = 12%）。
    public var horizontalThreshold: Double
    /// 翻页后冷却时长（毫秒）。
    public var cooldownMs: Double
    /// 垂直/水平比：竖直位移超过水平位移该倍数时判为竖向移动，不翻页。
    public var verticalRejectRatio: Double
    /// armed 期间「手形短暂失效」的容忍时长（毫秒）。
    ///
    /// 挥动瞬间 Vision 常有几帧指尖跳变/置信度抖动，旧逻辑一掉帧就退回 idle，
    /// 用户必须再定住 holdMs 才能重新 armed → 表现为「挥了不翻、要重来」。
    /// 容忍窗内保持 armed 继续跟踪，恢复后照常判定位移。
    public var poseLossToleranceMs: Double
    /// 手形确认期最多追溯多久的位移作为挥动起点（毫秒）。
    ///
    /// 确认期一开始就在挥 → 起点用确认期起点，位移完整计入（最跟手）；
    /// 若用户先定住不动很久再挥（超过本值），则改用当前点为起点，避免
    /// 长时间悬停后一点点漂移就触发翻页（防误触）。
    public var holdTraceMaxMs: Double

    public init(holdMs: Double = 100,
                swipeWindowMs: Double = 400,
                horizontalThreshold: Double = 0.12,
                cooldownMs: Double = 600,
                verticalRejectRatio: Double = 1.0,
                poseLossToleranceMs: Double = 150,
                holdTraceMaxMs: Double = 200) {
        self.holdMs = holdMs
        self.swipeWindowMs = swipeWindowMs
        self.horizontalThreshold = horizontalThreshold
        self.cooldownMs = cooldownMs
        self.verticalRejectRatio = verticalRejectRatio
        self.poseLossToleranceMs = poseLossToleranceMs
        self.holdTraceMaxMs = holdTraceMaxMs
    }
}

// MARK: - V2.0 激光 / 翻页：输出类型

/// 激光状态机每帧输出。
public enum LaserOutcome: Equatable {
    case none            // 不激活
    case show(CGPoint)   // 显示/更新光点（归一化坐标，0...1，左下原点）
    case hide            // 退出激光，隐藏光点
}

/// 翻页状态机每帧输出。
public enum PageOutcome: Equatable {
    case none
    case flip(PageDirection)   // 本帧确认翻页（恰一次）
}

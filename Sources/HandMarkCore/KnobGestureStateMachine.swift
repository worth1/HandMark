import Foundation

/// 五指旋钮状态。
///
/// `.consumed` = 本次激活已经切过一档，必须等手离开「五指张开」才能退出并重新进入。
/// 这是为了让「一次激活 = 一次切换」：否则用户切完档把手转回原位时，
/// 回程的反向旋转会被计成反向切换（顺时针切完粗细、回手却把颜色改了）。
public enum KnobPhase: Equatable {
    case idle
    case candidate
    case active
    case consumed
}

/// 以用户看到的统一屏幕坐标定义旋转方向：正角度为顺时针。
public enum KnobRotationDirection: Equatable {
    case clockwise
    case counterclockwise
}

public enum KnobOutcome: Equatable {
    case none
    case entered
    case rotate(KnobRotationDirection)
    case exited
}

public struct KnobConfig: Equatable {
    /// 五指张开稳定多久后进入旋钮模式。
    public var confirmMs: Double
    /// 每次切换所需的累计旋转角度。
    public var triggerDegrees: Double
    /// 掌心角度 EMA 系数。
    public var emaAlpha: Double
    /// 单帧角度变化大于该值时视为跟踪跳变，不计入累计旋转。
    public var maxFrameDeltaDegrees: Double
    /// 小于该值的角度变化视为抖动（但仍会累积到 `pendingDelta`，
    /// 累计超过死区后一次性入账，避免慢速旋转被逐帧丢弃而永远无法触发）。
    public var jitterDeadZoneDegrees: Double
    /// 激活后关键点短暂不可靠的容忍时间。
    public var lossToleranceMs: Double
    /// 已切过一档后，手离开「五指张开」多久才正式退出旋钮模式（防抖）。
    ///
    /// 退出后用户必须重新五指张开并稳定 `confirmMs` 才能再次进入 —— 这正是
    /// 「改变了粗细后，必须重新五指伸展再旋转才能改颜色」的实现方式。
    public var reopenReleaseMs: Double

    public init(confirmMs: Double = 300,
                triggerDegrees: Double = 30,
                emaAlpha: Double = 0.35,
                maxFrameDeltaDegrees: Double = 30,
                jitterDeadZoneDegrees: Double = 0.6,
                lossToleranceMs: Double = 400,
                reopenReleaseMs: Double = 160) {
        self.confirmMs = confirmMs
        self.triggerDegrees = triggerDegrees
        self.emaAlpha = emaAlpha
        self.maxFrameDeltaDegrees = maxFrameDeltaDegrees
        self.jitterDeadZoneDegrees = jitterDeadZoneDegrees
        self.lossToleranceMs = lossToleranceMs
        self.reopenReleaseMs = reopenReleaseMs
    }
}

/// 五指旋钮纯逻辑状态机。调用方传入的 `palmAngle` 已统一到用户看到的屏幕坐标，
/// 因此正角度恒表示顺时针，不受摄像头镜像影响。
public struct KnobGestureStateMachine {
    public private(set) var phase: KnobPhase = .idle

    private var candidateStart: TimeInterval?
    private var lossSince: TimeInterval?
    private var lastRawAngle = 0.0
    private var unwrappedAngle = 0.0
    private var smoothedAngle = 0.0
    private var triggerBaseline = 0.0
    private var hasAngleState = false
    /// 小于死区的碎增量暂存区：慢速旋转时每帧增量可能只有零点几度，
    /// 若逐帧丢弃则永远达不到触发阈值（这正是「转了但没反应」的根因）。
    private var pendingDelta = 0.0
    /// `.consumed` 期间：手离开「五指张开」的起始时刻（防抖后正式退出）。
    private var releaseSince: TimeInterval?

    public init() {}

    public var isBusy: Bool { phase != .idle }
    public var isActive: Bool { phase == .active }
    /// 已激活（尚未切档）或已切档待重开 —— 这两种情况都应用宽松手形维持判据。
    public var isEngaged: Bool { phase == .active || phase == .consumed }

    /// 当前相对基准的累计旋转量（度，正值=顺时针）。诊断与日志用。
    public var accumulatedDegrees: Double {
        guard hasAngleState else { return 0 }
        return (smoothedAngle - triggerBaseline) * 180 / .pi
    }

    /// 未经 EMA 的原始累计旋转量（度）。用于判断掌心角是否真的在动。
    public var rawAccumulatedDegrees: Double {
        guard hasAngleState else { return 0 }
        return (unwrappedAngle + pendingDelta - triggerBaseline) * 180 / .pi
    }

    public mutating func step(knob: PoseMatch,
                              palmAngle: Double,
                              hasPalmAngle: Bool,
                              suspended: Bool,
                              handPresent: Bool,
                              now: TimeInterval,
                              config: KnobConfig) -> KnobOutcome {
        if suspended || !handPresent {
            // 已切档待重开的状态同样要清理，避免手离开画面后残留「已消费」标记。
            let wasBusy = phase != .idle
            reset()
            return wasBusy ? .exited : .none
        }

        let validPose = knob.matched && knob.reliable && hasPalmAngle && palmAngle.isFinite

        switch phase {
        case .idle:
            guard validPose else { return .none }
            phase = .candidate
            candidateStart = now
            resetAngle(to: palmAngle)
            return .none

        case .candidate:
            guard validPose else {
                reset()
                return .none
            }
            _ = ingest(palmAngle, config: config)
            if let start = candidateStart,
               (now - start) * 1000 >= config.confirmMs {
                phase = .active
                triggerBaseline = smoothedAngle
                lossSince = nil
                return .entered
            }
            return .none

        case .active:
            guard validPose else {
                if lossSince == nil { lossSince = now }
                if let since = lossSince,
                   (now - since) * 1000 >= config.lossToleranceMs {
                    reset()
                    return .exited
                }
                return .none
            }

            // 跟踪从短暂丢失中恢复时重新建立基准，避免把丢失期间的角度跳变当成旋转。
            if lossSince != nil {
                lossSince = nil
                resetAngle(to: palmAngle)
                triggerBaseline = smoothedAngle
                return .none
            }

            guard ingest(palmAngle, config: config) else { return .none }

            let threshold = config.triggerDegrees * .pi / 180
            let accumulated = smoothedAngle - triggerBaseline
            if accumulated >= threshold {
                // 一次激活只切一档：切完立刻进入 .consumed，
                // 此后无论怎么转（包括把手转回原位的反向行程）都不再触发，
                // 必须收手离开「五指张开」→ 重新五指伸展进入 → 才能再切。
                phase = .consumed
                releaseSince = nil
                return .rotate(.clockwise)
            }
            if accumulated <= -threshold {
                phase = .consumed
                releaseSince = nil
                return .rotate(.counterclockwise)
            }
            return .none

        case .consumed:
            // 已切过一档。手仍是五指张开时保持本状态（吞掉回程旋转）；
            // 手一旦不再是张开手形并持续 reopenReleaseMs，就退出，等待下一次重新张开。
            guard validPose else {
                if releaseSince == nil { releaseSince = now }
                if let since = releaseSince,
                   (now - since) * 1000 >= config.reopenReleaseMs {
                    reset()
                    return .exited
                }
                return .none
            }
            releaseSince = nil
            // 持续跟踪角度，保持基准跟随，退出重建前的角度漂移不会累积成误触发。
            _ = ingest(palmAngle, config: config)
            return .none
        }
    }

    private mutating func reset() {
        phase = .idle
        candidateStart = nil
        lossSince = nil
        hasAngleState = false
        lastRawAngle = 0
        unwrappedAngle = 0
        smoothedAngle = 0
        triggerBaseline = 0
        pendingDelta = 0
        releaseSince = nil
    }

    private mutating func resetAngle(to angle: Double) {
        lastRawAngle = angle
        unwrappedAngle = angle
        smoothedAngle = angle
        hasAngleState = true
        pendingDelta = 0
        releaseSince = nil
    }

    /// 返回 false 表示本帧角度是异常跳变，已保守丢弃。
    private mutating func ingest(_ angle: Double, config: KnobConfig) -> Bool {
        guard hasAngleState else {
            resetAngle(to: angle)
            return true
        }
        var delta = angle - lastRawAngle
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        lastRawAngle = angle

        let maxDelta = config.maxFrameDeltaDegrees * .pi / 180
        guard abs(delta) <= maxDelta else { return false }

        // 死区只用于「攒够再入账」，绝不丢弃增量：慢速旋转时每帧增量可能不足 1°，
        // 若直接 return 则累计旋转永远达不到阈值（用户会觉得转了没反应）。
        let deadZone = config.jitterDeadZoneDegrees * .pi / 180
        pendingDelta += delta
        if abs(pendingDelta) < deadZone { return true }
        unwrappedAngle += pendingDelta
        pendingDelta = 0

        let alpha = min(1, max(0.01, config.emaAlpha))
        smoothedAngle += (unwrappedAngle - smoothedAngle) * alpha
        return true
    }
}

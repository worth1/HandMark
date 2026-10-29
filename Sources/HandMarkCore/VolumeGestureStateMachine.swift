import Foundation

public enum VolumeGestureDirection: Equatable {
    case up
    case down
}

public enum VolumeGesturePhase: Equatable {
    case idle
    case candidate(VolumeGestureDirection)
    case latched(VolumeGestureDirection)
}

public enum VolumeGestureOutcome: Equatable {
    case none
    case adjust(VolumeGestureDirection)
}

public struct VolumeGestureConfig: Equatable {
    /// 拇指姿势稳定确认时长。
    public var confirmMs: Double
    /// 两次真实触发之间的最短间隔。
    public var cooldownMs: Double

    public init(confirmMs: Double = 300, cooldownMs: Double = 500) {
        self.confirmMs = confirmMs
        self.cooldownMs = cooldownMs
    }
}

/// 拇指上下音量手势状态机：稳定确认后只触发一次，必须完全退出目标手势才可再次触发。
public struct VolumeGestureStateMachine {
    public private(set) var phase: VolumeGesturePhase = .idle

    private var candidateStart: TimeInterval?
    private var lastTriggerAt: TimeInterval = -.greatestFiniteMagnitude

    public init() {}

    public var isBusy: Bool {
        if case .idle = phase { return false }
        return true
    }

    public mutating func step(up: PoseMatch,
                              down: PoseMatch,
                              suspended: Bool,
                              handPresent: Bool,
                              now: TimeInterval,
                              config: VolumeGestureConfig) -> VolumeGestureOutcome {
        if suspended || !handPresent {
            phase = .idle
            candidateStart = nil
            return .none
        }

        let target: VolumeGestureDirection?
        let upValid = up.matched && up.reliable
        let downValid = down.matched && down.reliable
        if upValid != downValid {
            target = upValid ? .up : .down
        } else {
            // 两者同时命中或都未命中均视为不确定，不执行。
            target = nil
        }

        switch phase {
        case .idle:
            guard let target,
                  (now - lastTriggerAt) * 1000 >= config.cooldownMs else {
                return .none
            }
            phase = .candidate(target)
            candidateStart = now
            return .none

        case .candidate(let direction):
            guard let target else {
                phase = .idle
                candidateStart = nil
                return .none
            }
            if target != direction {
                // 确认前方向改变：从新方向重新计时，不沿用旧姿势的停留时间。
                phase = .candidate(target)
                candidateStart = now
                return .none
            }
            if let start = candidateStart,
               (now - start) * 1000 >= config.confirmMs,
               (now - lastTriggerAt) * 1000 >= config.cooldownMs {
                phase = .latched(direction)
                lastTriggerAt = now
                candidateStart = nil
                return .adjust(direction)
            }
            return .none

        case .latched:
            // 持续保持任意拇指音量姿势时不重复触发；必须先回到非目标手势。
            guard target == nil else { return .none }
            if (now - lastTriggerAt) * 1000 >= config.cooldownMs {
                phase = .idle
            }
            return .none
        }
    }
}

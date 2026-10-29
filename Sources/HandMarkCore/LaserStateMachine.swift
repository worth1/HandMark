//
//  LaserStateMachine.swift
//  HandMarkCore
//
//  V2.0 激光指示状态机（纯逻辑，时间注入）。
//  idle → candidate（四指伸出手形稳定确认）→ active（显示中指指尖光点）。
//  手形失效或关键点持续丢失 → 退出并隐藏光点。激光模式不产生任何持久轨迹。
//
//  只 import Foundation / CoreGraphics，严禁 import AVFoundation/AppKit/Vision。
//

import Foundation
import CoreGraphics

public struct LaserStateMachine {
    public private(set) var phase: LaserPhase = .idle
    private var candidateStart: TimeInterval = 0
    private var lossSince: TimeInterval? = nil
    private var smoothed: CGPoint? = nil   // 光点 EMA（仅用于光点坐标）

    public init() {}

    /// 推进一帧。
    /// - Parameters:
    ///   - laser: 本帧「激光手形」分类结果（四指伸+拇指弯）。
    ///   - midTip: 中指指尖归一化坐标（0...1，左下原点），仅当 hasMidTip 为真时有效。
    ///   - hasMidTip: 中指指尖本帧是否可用。
    ///   - suspended: 更高优先级（清屏）是否要求让出操作权。
    ///   - handPresent: 本帧是否检测到可用手部。
    ///   - now: 注入时间（秒）。
    ///   - config: 激光参数。
    public mutating func step(laser: PoseMatch,
                              midTip: CGPoint,
                              hasMidTip: Bool,
                              suspended: Bool,
                              handPresent: Bool,
                              now: TimeInterval,
                              config: LaserConfig) -> LaserOutcome {
        // 更高优先级占用或手部丢失：立即退出激光、复位。
        if suspended || !handPresent {
            return exit()
        }

        switch phase {
        case .idle:
            if laser.matched && laser.reliable {
                phase = .candidate
                candidateStart = now
            }
            return .none

        case .candidate:
            if !(laser.matched && laser.reliable) {
                phase = .idle
                return .none
            }
            if (now - candidateStart) * 1000 >= config.confirmMs {
                phase = .active
                lossSince = nil
                smoothed = hasMidTip ? midTip : nil
                if let p = smoothed { return .show(p) }
                return .none
            }
            return .none

        case .active:
            // 手形仍需大体成立；短暂关键点波动可容忍（保持最后光点），持续丢失才退出。
            let formOK = laser.matched && laser.reliable
            if formOK && hasMidTip {
                lossSince = nil
                let p = emaStep(midTip, alpha: config.emaAlpha)
                return .show(p)
            }
            // 手形明确失效（可靠地判定为非激光手形）→ 立即退出。
            if laser.reliable && !laser.matched {
                return exit()
            }
            // 关键点波动/中指尖暂丢：容忍一小段时间，保持最后光点。
            if lossSince == nil { lossSince = now }
            if let since = lossSince, (now - since) * 1000 >= config.lossToleranceMs {
                return exit()
            }
            if let p = smoothed { return .show(p) }   // 保持最后可信光点
            return .none
        }
    }

    private mutating func emaStep(_ raw: CGPoint, alpha: Double) -> CGPoint {
        if let s = smoothed {
            let p = CGPoint(x: s.x + (raw.x - s.x) * CGFloat(alpha),
                            y: s.y + (raw.y - s.y) * CGFloat(alpha))
            smoothed = p
            return p
        }
        smoothed = raw
        return raw
    }

    private mutating func exit() -> LaserOutcome {
        let wasActive = (phase == .active)
        phase = .idle
        lossSince = nil
        smoothed = nil
        return wasActive ? .hide : .none
    }
}

//
//  PageSwipeStateMachine.swift
//  HandMarkCore
//
//  V2.0 PPT 翻页状态机（纯逻辑，时间注入）。
//  核心原则：静态手形不等于翻页。必须「双指手形稳定 + 随后出现足够的水平挥动」才翻页。
//  idle →（双指手形稳定 holdMs）→ armed（在 swipeWindowMs 窗口内采集水平位移）
//     → 位移超阈且方向明确 → flip 一次 → cooldown →（手型仍保持）waitReset
//     →（手型解除 / 手离开）idle。
//  waitReset 的作用：翻页后必须「先收手再比✌️」才能触发下一次翻页，
//  从而彻底避免「挥完回摆」被误判为反向翻页（一次手势 = 一次翻页）。
//
//  坐标：参考点用归一化坐标（0...1，相对画面宽度）；水平阈值按画面宽度比例。
//  只 import Foundation / CoreGraphics，严禁 import AVFoundation/AppKit/Vision。
//

import Foundation
import CoreGraphics

public struct PageSwipeStateMachine {
    public private(set) var phase: PagePhase = .idle
    private var holdStart: TimeInterval? = nil   // 手形稳定计时起点（nil=未开始计时，避免与 now==0 冲突）
    private var holdRefX: CGFloat = 0            // 手形确认期起点的参考 x（让确认期内的挥动位移也被计入）
    private var holdRefY: CGFloat = 0
    private var windowStart: TimeInterval = 0   // armed 后挥动观察窗起点
    private var startX: CGFloat = 0             // 挥动窗起点的参考 x（归一化）
    private var startY: CGFloat = 0
    private var cooldownStart: TimeInterval = 0
    /// armed 期间手形失效的起始时刻；nil 表示当前手形正常。
    private var poseLostSince: TimeInterval? = nil
    /// waitReset 期间「手型已解除」的起始时刻；用于去抖，避免回摆途中手形短暂抖动即提前解锁。
    private var resetReleasedSince: TimeInterval? = nil

    public init() {}

    /// 推进一帧。
    /// - Parameters:
    ///   - page: 本帧「翻页手形」分类结果（仅食中伸）。
    ///   - refPoint: 运动参考点归一化坐标（0...1，建议用食指尖经平滑后的点）。
    ///   - hasRef: 参考点本帧是否可用。
    ///   - suspended: 更高优先级（清屏/激光）是否要求让出操作权。
    ///   - handPresent: 本帧是否检测到可用手部。
    ///   - now: 注入时间（秒）。
    ///   - config: 翻页参数。
    public mutating func step(page: PoseMatch,
                              refPoint: CGPoint,
                              hasRef: Bool,
                              suspended: Bool,
                              handPresent: Bool,
                              now: TimeInterval,
                              config: PageConfig) -> PageOutcome {
        // 更高优先级占用或手部丢失：取消候选（cooldown 仍按时间自然结束）。
        if suspended || !handPresent {
            if phase == .armed {
                phase = .idle
                poseLostSince = nil
            }
            if phase == .cooldown { advanceCooldown(now: now, config: config) }
            // waitReset 仅因「手部丢失」才提前解锁；若只是被更高优先级手势占用，
            // 仍保持 waitReset，等占用结束、手型解除后再回 idle。
            if phase == .waitReset && !handPresent {
                phase = .idle
                poseLostSince = nil
                resetReleasedSince = nil
            }
            return .none
        }

        switch phase {
        case .idle:
            if page.matched && page.reliable && hasRef {
                // 手形成立：开始稳定计时（首次进入记录起点）。
                if holdStart == nil {
                    holdStart = now
                    // 关键（V4.1 跟手）：确认期一开始就记录参考点。用户往往是「边伸出双指边挥」，
                    // 若等确认成立后才有起点，确认期这段位移会被整段丢弃，必须多挥一大截才触发。
                    holdRefX = refPoint.x
                    holdRefY = refPoint.y
                }
                if (now - (holdStart ?? now)) * 1000 >= config.holdMs {
                    phase = .armed
                    windowStart = now
                    poseLostSince = nil
                    // 起点取「确认期起点」还是「当前点」：
                    // - 确认期很短（<= holdTraceMaxMs）→ 说明是一气呵成的挥动，用确认期起点，位移完整计入；
                    // - 定住不动很久才挥 → 用当前点，避免长时间悬停后微小漂移就误翻页。
                    let held = (now - (holdStart ?? now)) * 1000
                    if held <= config.holdTraceMaxMs {
                        startX = holdRefX
                        startY = holdRefY
                    } else {
                        startX = refPoint.x
                        startY = refPoint.y
                    }
                    // 确认成立这一帧就立即判定位移：旧逻辑要等下一帧才判，
                    // 30fps 下白白多付 ~33ms 延迟，正是「挥完了还要等一下才翻」的来源。
                    return evaluateSwipe(refPoint: refPoint, now: now, config: config)
                }
            } else {
                holdStart = nil   // 手形不成立，重置稳定计时
            }
            return .none

        case .armed:
            // 手形中途失效 → 容忍窗内继续跟踪（挥动瞬间 Vision 抖动是常态），
            // 超出容忍才取消候选。旧逻辑一掉帧就回 idle，是「挥了不翻」的主因之一。
            if !(page.matched && page.reliable) || !hasRef {
                if config.poseLossToleranceMs <= 0 {
                    phase = .idle
                    holdStart = nil
                    poseLostSince = nil
                    return .none
                }
                if poseLostSince == nil { poseLostSince = now }
                if (now - (poseLostSince ?? now)) * 1000 >= config.poseLossToleranceMs {
                    phase = .idle
                    holdStart = nil
                    poseLostSince = nil
                }
                return .none
            }
            poseLostSince = nil   // 手形恢复，清掉失效计时
            return evaluateSwipe(refPoint: refPoint, now: now, config: config)

        case .cooldown:
            if (now - cooldownStart) * 1000 >= config.cooldownMs {
                // 冷却结束：无论此时手型是否仍保持，都进入 waitReset 等待「解除手型」。
                // 旧逻辑在冷却结束且手型短暂丢失时直接回 idle，导致回摆途中手型一掉就解锁、
                // 回摆被误判为反向翻页。现统一进入 waitReset，只有手型被**稳定解除**才解锁。
                phase = .waitReset
                resetReleasedSince = nil
                holdStart = nil
            }
            return .none

        case .waitReset:
            // 已翻一页：必须「双指手型先解除」（或手离开画面）才允许再次 armed。
            // 回摆/继续比着 ✌️ 不动都不算「解除」，因此不会触发第二次翻页。
            // 手型在回摆途中可能短暂丢失（Vision 抖动），用 poseLossToleranceMs 去抖：
            // 只有持续解除达到容忍窗，才真正解锁，避免一帧掉线就提前解锁导致回摆误翻。
            if !(page.matched && page.reliable) || !hasRef {
                if resetReleasedSince == nil { resetReleasedSince = now }
                if (now - (resetReleasedSince ?? now)) * 1000 >= config.poseLossToleranceMs {
                    phase = .idle
                    holdStart = nil
                    poseLostSince = nil
                    resetReleasedSince = nil
                }
            } else {
                resetReleasedSince = nil
            }
            return .none
        }
    }

    /// 判定当前 armed 状态下是否已达成翻页条件；达成则进入 cooldown 并返回 `.flip`，否则返回 `.none`。
    ///
    /// 抽成方法是为了让「手形确认成立的那一帧」与「armed 期间的每一帧」共用同一套判定，
    /// 避免确认帧空转一帧造成的额外延迟。
    private mutating func evaluateSwipe(refPoint: CGPoint, now: TimeInterval,
                                        config: PageConfig) -> PageOutcome {
        let dx = refPoint.x - startX
        let dy = refPoint.y - startY
        let adx = abs(dx), ady = abs(dy)
        // 水平位移达阈值且不是以竖直运动为主 → 翻页一次。
        if Double(adx) >= config.horizontalThreshold &&
           Double(ady) <= Double(adx) * config.verticalRejectRatio {
            phase = .cooldown
            cooldownStart = now
            holdStart = nil
            poseLostSince = nil
            return .flip(dx < 0 ? .left : .right)
        }
        // 观察窗超时仍未达阈值 → 重开一个窗口（以当前点为新起点，允许连续尝试）。
        if (now - windowStart) * 1000 >= config.swipeWindowMs {
            windowStart = now
            startX = refPoint.x
            startY = refPoint.y
        }
        return .none
    }

    private mutating func advanceCooldown(now: TimeInterval, config: PageConfig) {
        if (now - cooldownStart) * 1000 >= config.cooldownMs {
            phase = .idle
            holdStart = nil
        }
    }
}

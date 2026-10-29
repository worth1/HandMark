//
//  ClearGestureStateMachine.swift
//  HandMarkCore
//
//  V1.1 六→握拳组合清屏的纯逻辑六态状态机（设计伪代码 D / 状态机图 2 的实现）。
//
//  职责边界：
//  - 只做六态流转（idle/sixCandidate/sixArmed/fistCandidate/clearing/cooldown）、
//    六稳定确认计时、六就绪→握拳超时、握拳稳定确认计时、清屏后冷却（含"必须先退出握拳"），
//    每帧输出一个 `ClearOutcome`（`none/performClear/suspendPinch`）。
//  - 时间完全由调用方通过 `now: TimeInterval` 注入，内部绝不调用 `Date()` /
//    `CACurrentMediaTime()`，以保证可被纯逻辑单测（时间显式、可重放）。
//  - 只 import Foundation 与 CoreGraphics（经 Foundation 传递的 TimeInterval），
//    严禁 import AVFoundation/AppKit/Vision。
//
//  关键保证（对应设计 Correctness Property）：
//  - Property 7（清屏需顺序）：`performClear` 恰在「六稳定 → sixArmed → 1s 内握拳稳定」
//    的合法先后顺序后产生一次。
//  - Property 8（单独姿势不清屏）：仅六或仅握拳（无合法先后）永不 `performClear`。
//  - Property 9（清屏冷却）：两次 `performClear` 间必有 >= `COOLDOWN_MS` 的冷却且握拳
//    曾被释放（`fistExited`）。
//  - Property 11（不可靠不清屏，状态机侧）：`reliable == false` 的 six/fist 不推进到
//    `performClear`（各判定均要求 `matched && reliable`）。
//

import Foundation
import CoreGraphics

/// 六→握拳组合清屏的纯逻辑状态机（设计伪代码 D / 状态机图 2 的实现）。
///
/// 职责边界见文件头注释。本类型只实现状态机本体：
/// - 不触碰摄像头 / Vision / AppKit；
/// - 不负责分类（`classifySix` / `classifyFist` 的结果以 `PoseMatch` 注入，属任务 5.1）；
/// - 不负责与捏合的优先级协调（`GesturePriorityCoordinator` 属任务 5.6）；
/// - 不负责接入 `captureOutput` 执行真正的 `clearAll`（属任务 5.8）。
public struct ClearGestureStateMachine {

    /// 当前相位（外部只读）。初始 `.idle`。
    public private(set) var phase: ClearPhase = .idle

    /// 进入 `sixCandidate` 的时间戳（用于 `SIX_CONFIRM_MS` 六稳定确认计时）。
    private var sixStart: TimeInterval = 0
    /// 进入 `sixArmed` 的时间戳（用于 `SIX_TO_FIST_TIMEOUT_MS` 握拳超时计时）。
    private var armedAt: TimeInterval = 0
    /// 进入 `fistCandidate` 的时间戳（用于 `FIST_CONFIRM_MS` 握拳稳定确认计时）。
    private var fistStart: TimeInterval = 0
    /// 产生 `performClear`（进入 `clearing`）的时间戳（用于 `COOLDOWN_MS` 冷却计时）。
    private var clearedAt: TimeInterval = 0
    /// 冷却期间是否已检测到握拳释放（必须先退出握拳才允许离开冷却，防连清）。
    private var fistExited = false
    /// `fistCandidate` 期间「握拳判定掉帧」的起始时间戳；nil 表示当前没有掉帧。
    private var fistLostSince: TimeInterval? = nil

    public init() {}

    /// 推进一帧，返回本帧的清屏裁决。
    ///
    /// - Parameters:
    ///   - six: 本帧「六」姿势分类结果（`matched`/`confidence`/`reliable`）。
    ///   - fist: 本帧「握拳」姿势分类结果。
    ///   - drawing: 普通画笔是否正在绘画（为 true 时不得从 `idle` 起步，需求 5.4）。
    ///   - handPresent: 本帧是否检测到可用手部（false 立即取消回 `idle`）。
    ///   - now: 调用方注入的当前时间（秒）。
    ///   - config: 清屏参数（各确认/超时/冷却窗口，毫秒）。
    /// - Returns: `ClearOutcome`（`none`/`performClear`/`suspendPinch`）。
    public mutating func step(six: PoseMatch,
                              fist: PoseMatch,
                              drawing: Bool,
                              handPresent: Bool,
                              now: TimeInterval,
                              config: ClearConfig) -> ClearOutcome {
        // 摄像头中断 / 关键点丢失 → 取消（不清）。对应伪代码 D 的 `IF NOT handPresent`。
        if !handPresent {
            phase = .idle
            fistLostSince = nil
            return .none
        }

        switch phase {
        case .idle:
            // 只有非绘画态才开始识别清屏（需求 5.4）。
            if drawing { return .none }
            // 六稳定命中且关键点可靠 → 进入候选并开始确认计时。
            if six.matched && six.reliable {
                phase = .sixCandidate
                sixStart = now
            }
            return .none

        case .sixCandidate:
            // 六不稳定 / 置信不足 / 丢失 → 取消回 idle。
            if !(six.matched && six.reliable) {
                phase = .idle
                return .none
            }
            // 六持续稳定达 SIX_CONFIRM_MS → 就绪，暂停画笔。
            if (now - sixStart) * 1000 >= config.sixConfirmMs {
                phase = .sixArmed
                armedAt = now
                return .suspendPinch
            }
            return .none

        case .sixArmed:
            // 超 `sixToFistTimeoutMs` 未握拳 → 超时取消（需求 5.6）。
            if (now - armedAt) * 1000 > config.sixToFistTimeoutMs {
                phase = .idle
                return .none
            }
            // 开始握拳稳定命中 → 进入握拳候选并开始确认计时。
            if fist.matched && fist.reliable {
                phase = .fistCandidate
                fistStart = now
                fistLostSince = nil
            } else if !isNeutralOrSix(six: six, fist: fist) {
                // 切换为其他明确不符姿势（既非六也非中性过渡）→ 取消（需求 5.10）。
                phase = .idle
                return .none
            }
            // 六就绪 / 中性过渡：恒要求暂停画笔，靠超时兜底。
            return .suspendPinch

        case .fistCandidate:
            // 总超时兜底：六就绪后累计超 `sixToFistTimeoutMs` 一律取消。
            if (now - armedAt) * 1000 > config.sixToFistTimeoutMs {
                phase = .idle
                fistLostSince = nil
                return .none
            }
            // 握拳中断：容忍 `fistLossToleranceMs` 内的掉帧（收指成拳瞬间 Vision 常抖动），
            // 容忍期内**不重置** fistStart，恢复后继续累计；超容忍才退回等待（仍暂停画笔）。
            if !(fist.matched && fist.reliable) {
                if fistLostSince == nil { fistLostSince = now }
                if let lost = fistLostSince,
                   (now - lost) * 1000 >= config.fistLossToleranceMs {
                    phase = .sixArmed
                    fistLostSince = nil
                    return .suspendPinch
                }
                return .suspendPinch
            }
            fistLostSince = nil
            // 握拳持续稳定达 FIST_CONFIRM_MS → 执行清屏（协调器据此先封存笔画再 clearAll）。
            if (now - fistStart) * 1000 >= config.fistConfirmMs {
                phase = .clearing
                clearedAt = now
                fistExited = false
                return .performClear
            }
            return .suspendPinch

        case .clearing:
            // 单帧完成清屏后转冷却。
            phase = .cooldown
            return .none

        case .cooldown:
            // 必须先退出握拳（防止同一次握拳连触多次清屏，Property 9）。
            if !fist.matched {
                fistExited = true
            }
            // 已退出握拳且冷却满 COOLDOWN_MS → 回 idle，接受下一次清屏（需求 5.8/5.9）。
            if fistExited && (now - clearedAt) * 1000 >= config.cooldownMs {
                phase = .idle
            }
            // 冷却期间不接受新的清屏。
            return .none
        }
    }

    /// 判定当前姿势是否属于「六 / 中性过渡」——即仍在六→握拳组合流程中、不应取消。
    ///
    /// 设计伪代码 D 在 `sixArmed` 中用它来区分「切换为其他不符姿势」应取消，还是
    /// 「手正从六过渡到握拳的中间态」应容忍等待（靠超时兜底）。
    ///
    /// 定义（近似）：
    /// - `six.matched`：手仍摆着六，流程继续；
    /// - `!six.matched && !fist.matched`：既不像六也不像握拳的中性过渡态（容忍）。
    /// 只有「检测到一个明确非六非握拳的可靠其他姿势」（即 six 不 matched 但 fist matched
    /// 的分支已在上层处理，此处 `isNeutralOrSix == false` 仅当 six 不 matched 且 fist 不
    /// matched 为假，等价于出现了某种非中性信号）才返回 false，从而触发取消。
    private func isNeutralOrSix(six: PoseMatch, fist: PoseMatch) -> Bool {
        return six.matched || (!six.matched && !fist.matched)
    }
}

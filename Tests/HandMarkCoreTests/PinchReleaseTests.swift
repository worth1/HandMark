//
//  PinchReleaseTests.swift
//  HandMarkCoreTests
//
//  任务 2.3：为 PinchStateMachine 编写结束去抖与结束帧不追加单测。
//
//  Property 2: 结束去抖
//  Property 3: 结束帧不追加
//  **Validates: Requirements 1.5, 1.6, 1.7, 2.2, 2.3**
//
//  约束：
//  - 时间完全以注入的 `now: TimeInterval` 确定性推进，不使用真实时钟。
//  - 仅测试，不改动生产代码 / main.swift / 其它测试文件（2.2 / 2.4 的文件）。
//
//  被测 API（Sources/HandMarkCore/Gesture.swift）：
//    PinchStateMachine.step(distNorm:tipReliable:handPresent:suspended:now:config:) -> PinchOutcome
//    PinchStateMachine.phase: PinchPhase（外部只读）
//  PinchConfig 默认：pinchOn=0.22, pinchOff=0.35, pinchConfirmMs=150, releaseConfirmMs=80。
//

import XCTest
@testable import HandMarkCore

final class PinchReleaseTests: XCTestCase {

    private let config = PinchConfig()

    // MARK: - Helpers

    /// 把状态机确定性推进到 `.drawing`：持续喂捏合距离（低于 pinchOn）的可靠帧，
    /// 跨过 `pinchConfirmMs`(150ms) 使其 candidate→drawing。
    /// 返回推进完成后的「下一帧」时间戳（秒），供后续时序继续从此处推进。
    ///
    /// 时序：
    ///   t=0.00s   idle → candidate（distNorm<pinchOn）
    ///   t=0.05s   candidate（未满 150ms）→ none
    ///   t=0.16s   candidate 满 150ms → drawing，返回 .begin（本帧不 append）
    /// 返回 0.20s（begin 之后的下一帧起点）。
    @discardableResult
    private func driveToDrawing(_ sm: inout PinchStateMachine,
                                startNow: TimeInterval = 0) -> TimeInterval {
        // 第 1 帧：进入 candidate。
        let o0 = step(&sm, dist: 0.1, now: startNow)
        XCTAssertEqual(o0, .none, "首帧应进入 candidate 而不落笔")
        XCTAssertEqual(sm.phase, .candidate)

        // 第 2 帧：确认窗内（50ms < 150ms），仍 none。
        let o1 = step(&sm, dist: 0.1, now: startNow + 0.05)
        XCTAssertEqual(o1, .none, "确认窗内不应起笔")
        XCTAssertEqual(sm.phase, .candidate)

        // 第 3 帧：满 150ms → begin，进入 drawing。
        let o2 = step(&sm, dist: 0.1, now: startNow + 0.16)
        XCTAssertEqual(o2, .begin, "满确认时长应 begin")
        XCTAssertEqual(sm.phase, .drawing)

        return startNow + 0.20
    }

    /// 便捷单帧推进：默认可靠、有手、未暂停。
    @discardableResult
    private func step(_ sm: inout PinchStateMachine,
                      dist: Double,
                      tipReliable: Bool = true,
                      handPresent: Bool = true,
                      suspended: Bool = false,
                      now: TimeInterval) -> PinchOutcome {
        sm.step(distNorm: dist,
                tipReliable: tipReliable,
                handPresent: handPresent,
                suspended: suspended,
                now: now,
                config: config)
    }

    // MARK: - Property 2: 结束去抖（Requirements 1.5, 1.7）

    /// drawing 中单帧 dist>pinchOff 不立即 end，进入 releaseCandidate；
    /// 未达 releaseConfirmMs(160ms) 内的若干帧仍 none；累计 >=160ms 才 end 且回 idle。
    func testReleaseDebounce_singleOpenFrameDoesNotEndImmediately_confirmsAfterWindow() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        // 先确认 drawing 中可靠帧会 append（基线）。
        XCTAssertEqual(step(&sm, dist: 0.1, now: t), .append)
        XCTAssertEqual(sm.phase, .drawing)

        // 单帧张开（dist=0.5 > pinchOff=0.35）：不立即 end，进入 releaseCandidate。
        let rStart = t + 0.01
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart), .none,
                       "单帧越过 pinchOff 不应立即结束")
        XCTAssertEqual(sm.phase, .releaseCandidate)

        // 去抖窗内继续张开，但未满 160ms：仍 none，停留 releaseCandidate。
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart + 0.06), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)
        XCTAssertEqual(step(&sm, dist: 0.6, now: rStart + 0.12), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)

        // 累计 >=160ms（0.17s）仍持续张开 → 确认松开：end 且回 idle。
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart + 0.17), .end,
                       "持续越过 pinchOff 达 releaseConfirmMs 应结束")
        XCTAssertEqual(sm.phase, .idle)
    }

    /// 恰好在去抖窗边界（刚满 80ms）确认结束。
    func testReleaseDebounce_endExactlyAtReleaseConfirmBoundary() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        let rStart = t
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)

        // 恰好 160ms（releaseConfirmMs），(now-releaseStart)*1000 >= 160 成立 → end。
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart + 0.165), .end)
        XCTAssertEqual(sm.phase, .idle)
    }

    // MARK: - Property 2: 去抖恢复不误断（Requirement 1.6）

    /// drawing→releaseCandidate 后，窗内某帧 dist<=pinchOff 恢复 drawing（抖动恢复不误断），
    /// 随后可靠帧继续 append。
    func testReleaseDebounce_recoveryWithinWindowResumesDrawing_noFalseEnd() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        // 进入 releaseCandidate。
        let rStart = t
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)

        // 窗内（30ms < 80ms）回落到 <=pinchOff（dist=0.3）：恢复 drawing，本帧不 append（避免跳点）。
        XCTAssertEqual(step(&sm, dist: 0.3, now: rStart + 0.03), .none,
                       "去抖窗内回落应恢复 drawing 且本帧不追加")
        XCTAssertEqual(sm.phase, .drawing)

        // 恢复后可靠帧继续 append。
        XCTAssertEqual(step(&sm, dist: 0.1, now: rStart + 0.04), .append)
        XCTAssertEqual(sm.phase, .drawing)
        XCTAssertEqual(step(&sm, dist: 0.1, now: rStart + 0.05), .append)
        XCTAssertEqual(sm.phase, .drawing)
    }

    /// 恢复以 dist 恰等于 pinchOff（边界 `<=`）也应视为回落恢复 drawing。
    func testReleaseDebounce_recoveryAtPinchOffBoundaryResumesDrawing() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        let rStart = t
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)

        // dist == pinchOff(0.35)，`<=` 边界成立 → 回 drawing。
        XCTAssertEqual(step(&sm, dist: config.pinchOff, now: rStart + 0.02), .none)
        XCTAssertEqual(sm.phase, .drawing)
    }

    // MARK: - Property 3: 结束帧不追加（Requirements 2.2, 2.3）

    /// 产生 .end 的那一帧不是 .append；.end 之后进入 idle，再喂张开手若干帧均为 .none（无 .append）；
    /// 直到重新捏合确认才再 .begin。断言从 end 到下一次 begin 之间整个输出序列里没有任何 .append。
    func testEndFrameIsNotAppend_andNoAppendUntilNextBegin() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        // 记录从「产生 end」起直到「下一次 begin」之间的全部输出。
        var outcomes: [PinchOutcome] = []

        // 进入 releaseCandidate 并确认结束。
        _ = step(&sm, dist: 0.5, now: t)               // → none（releaseCandidate）
        let endOutcome = step(&sm, dist: 0.5, now: t + 0.17) // → end（去抖窗 160ms + 余量）
        XCTAssertEqual(endOutcome, .end)
        XCTAssertNotEqual(endOutcome, .append, "结束帧绝不能是 append")
        XCTAssertEqual(sm.phase, .idle)
        outcomes.append(endOutcome)

        // end 之后张开手若干帧（idle）：均 none，无 append。
        for i in 0..<5 {
            let o = step(&sm, dist: 0.8, now: t + 0.19 + Double(i) * 0.02)
            outcomes.append(o)
            XCTAssertEqual(o, .none, "idle 张开帧应为 none")
            XCTAssertEqual(sm.phase, .idle)
        }

        // 重新捏合：进入 candidate（但确认窗内尚未 begin）。
        let reStart = t + 0.40
        outcomes.append(step(&sm, dist: 0.1, now: reStart))        // idle→candidate: none
        XCTAssertEqual(sm.phase, .candidate)
        outcomes.append(step(&sm, dist: 0.1, now: reStart + 0.05)) // candidate 窗内: none

        // 满 150ms → begin（重新起笔）。
        let begin = step(&sm, dist: 0.1, now: reStart + 0.16)
        XCTAssertEqual(begin, .begin)
        XCTAssertEqual(sm.phase, .drawing)

        // 核心断言：从 end 到下一次 begin 之间的整个输出序列里没有任何 append。
        XCTAssertFalse(outcomes.contains(.append),
                       "end 到下一次 begin 之间不得出现任何 append，实际序列=\(outcomes)")
    }

    /// 结束帧不追加的另一路径验证：去抖恢复→再结束，整段 end→begin 之间仍无 append 泄漏。
    /// 该用例覆盖「去抖中途恢复过 drawing（会 append），但一旦真正 end 后到下次 begin 之间不得再 append」。
    func testNoAppendBetweenEndAndBegin_afterDebounceRecovery() {
        var sm = PinchStateMachine()
        let t = driveToDrawing(&sm)

        // 先 append 一帧（drawing 基线）。
        XCTAssertEqual(step(&sm, dist: 0.1, now: t), .append)

        // 进 releaseCandidate 后窗内恢复 drawing（这里允许 append，属于 end 之前）。
        XCTAssertEqual(step(&sm, dist: 0.5, now: t + 0.01), .none)
        XCTAssertEqual(sm.phase, .releaseCandidate)
        XCTAssertEqual(step(&sm, dist: 0.2, now: t + 0.03), .none) // 回 drawing
        XCTAssertEqual(sm.phase, .drawing)
        XCTAssertEqual(step(&sm, dist: 0.1, now: t + 0.04), .append)

        // 这次真正松开并确认结束。
        let rStart = t + 0.05
        XCTAssertEqual(step(&sm, dist: 0.5, now: rStart), .none)
        let end = step(&sm, dist: 0.5, now: rStart + 0.17)
        XCTAssertEqual(end, .end)
        XCTAssertEqual(sm.phase, .idle)

        // 从 end 后开始收集，直到下一次 begin。
        var outcomes: [PinchOutcome] = [end]
        for i in 0..<4 {
            outcomes.append(step(&sm, dist: 0.8, now: rStart + 0.19 + Double(i) * 0.02))
        }
        let reStart = rStart + 0.40
        outcomes.append(step(&sm, dist: 0.1, now: reStart))
        outcomes.append(step(&sm, dist: 0.1, now: reStart + 0.05))
        let begin = step(&sm, dist: 0.1, now: reStart + 0.16)
        XCTAssertEqual(begin, .begin)

        XCTAssertFalse(outcomes.contains(.append),
                       "去抖恢复路径下，end 到下一次 begin 之间同样不得出现 append，实际序列=\(outcomes)")
    }
}

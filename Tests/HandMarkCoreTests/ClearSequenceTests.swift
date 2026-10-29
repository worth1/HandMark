//
//  ClearSequenceTests.swift
//  HandMarkCoreTests
//
//  任务 5.4：为清屏状态机顺序与单独姿势不清屏编写单测。
//
//  Property 7: 清屏需顺序 / Property 8: 单独姿势不清屏
//  Validates: Requirements 5.1, 5.5, 5.7, 5.14
//
//  覆盖（被测：ClearGestureStateMachine）：
//  1. 六→握拳合法先后顺序 → performClear 恰一次，phase 到 clearing（Property 7）。
//  2. 仅六一直命中、无握拳，跨越多个 confirm 窗口乃至超时 → 永不 performClear（Property 8）。
//  3. 从 idle 直接只喂握拳（无先行六）→ 永不进入 sixCandidate、永不 performClear（Property 8）。
//  4. drawing=true 时六命中不从 idle 起步（不进 sixCandidate、不 performClear，需求 5.4）。
//  5. 可靠性：six.reliable=false（matched=true 但 reliable=false）→ 不进入 sixCandidate
//     （状态机各判定要求 matched && reliable）。
//
//  时间完全以注入的 now: TimeInterval 确定性推进（毫秒换算成秒），不使用真实时钟 / sleep。
//

import XCTest
@testable import HandMarkCore

final class ClearSequenceTests: XCTestCase {

    /// 固定使用默认参数：sixConfirmMs=180, sixToFistTimeoutMs=2000, fistConfirmMs=180,
    /// fistLossToleranceMs=300, cooldownMs=800。
    private let config = ClearConfig()

    // MARK: - PoseMatch 构造辅助

    /// 构造「六」姿势分类结果。默认高置信可靠；可单独关掉 reliable 以测可靠性门槛。
    private func six(_ matched: Bool, reliable: Bool = true) -> PoseMatch {
        PoseMatch(matched: matched, confidence: 0.9, reliable: reliable)
    }

    /// 构造「握拳」姿势分类结果。默认高置信可靠。
    private func fist(_ matched: Bool, reliable: Bool = true) -> PoseMatch {
        PoseMatch(matched: matched, confidence: 0.9, reliable: reliable)
    }

    // MARK: - 用例 1：六→握拳顺序触发 performClear 恰一次（Property 7）

    /// 合法先后：六稳定 >=180ms → sixArmed；1s 内握拳稳定 >=180ms → performClear 一次、phase=clearing。
    /// 断言整个过程 performClear 只出现恰一次。
    func testSixThenFistSequenceTriggersPerformClearExactlyOnce() {
        var sm = ClearGestureStateMachine()
        var performClearCount = 0

        func feed(six s: PoseMatch, fist f: PoseMatch, nowMs: Double) -> ClearOutcome {
            let out = sm.step(six: s, fist: f, drawing: false, handPresent: true,
                              now: nowMs / 1000.0, config: config)
            if out == .performClear { performClearCount += 1 }
            return out
        }

        // t=0ms：idle 下六稳定命中 → 进入 sixCandidate（本帧 .none）。
        XCTAssertEqual(feed(six: six(true), fist: fist(false), nowMs: 0), .none)
        XCTAssertEqual(sm.phase, .sixCandidate, "六首次稳定命中应进入 sixCandidate")

        // t=100ms：仍在六确认窗内（100 < 180）→ .none，停 sixCandidate。
        XCTAssertEqual(feed(six: six(true), fist: fist(false), nowMs: 100), .none)
        XCTAssertEqual(sm.phase, .sixCandidate)

        // t=200ms：六确认达 >=180ms → sixArmed，返回 suspendPinch。
        XCTAssertEqual(feed(six: six(true), fist: fist(false), nowMs: 200), .suspendPinch)
        XCTAssertEqual(sm.phase, .sixArmed, "六稳定达 SIX_CONFIRM_MS 应进入 sixArmed")

        // t=300ms：1s 超时窗内开始握拳稳定命中 → 进入 fistCandidate，仍 suspendPinch。
        XCTAssertEqual(feed(six: six(false), fist: fist(true), nowMs: 300), .suspendPinch)
        XCTAssertEqual(sm.phase, .fistCandidate, "sixArmed 下握拳命中应进入 fistCandidate")

        // t=400ms：握拳确认窗内（400-300=100 < 180）→ 仍 suspendPinch，停 fistCandidate。
        XCTAssertEqual(feed(six: six(false), fist: fist(true), nowMs: 400), .suspendPinch)
        XCTAssertEqual(sm.phase, .fistCandidate)

        // t=480ms：握拳确认达 >=180ms（480-300=180）→ performClear，进入 clearing。
        XCTAssertEqual(feed(six: six(false), fist: fist(true), nowMs: 480), .performClear)
        XCTAssertEqual(sm.phase, .clearing, "握拳稳定达 FIST_CONFIRM_MS 应 performClear 并进入 clearing")

        // 断言整个过程 performClear 恰一次。
        XCTAssertEqual(performClearCount, 1, "合法顺序应恰触发一次 performClear")
    }

    /// 顺序触发后继续推进（clearing→cooldown），冷却期内不应再次 performClear（保证“恰一次”）。
    func testPerformClearNotRepeatedWhileHoldingFist() {
        var sm = ClearGestureStateMachine()
        var performClearCount = 0

        func feed(six s: PoseMatch, fist f: PoseMatch, nowMs: Double) {
            let out = sm.step(six: s, fist: f, drawing: false, handPresent: true,
                              now: nowMs / 1000.0, config: config)
            if out == .performClear { performClearCount += 1 }
        }

        feed(six: six(true), fist: fist(false), nowMs: 0)     // → sixCandidate
        feed(six: six(true), fist: fist(false), nowMs: 200)   // → sixArmed
        feed(six: six(false), fist: fist(true), nowMs: 300)   // → fistCandidate
        feed(six: six(false), fist: fist(true), nowMs: 480)   // → clearing (performClear)
        XCTAssertEqual(sm.phase, .clearing)

        // 继续按住握拳推进：clearing→cooldown，随后冷却期内一直按住握拳，不得再次 performClear。
        for ms in stride(from: 500.0, through: 2000.0, by: 50.0) {
            feed(six: six(false), fist: fist(true), nowMs: ms)
        }
        XCTAssertEqual(performClearCount, 1, "一次握拳持续按住期间只应 performClear 一次")
    }

    // MARK: - 用例 2：仅六不清屏（Property 8）

    /// 只喂 six.matched=true、fist.matched=false，跨越多个 confirm 窗口甚至超时 → 永不 performClear。
    func testSixOnlyNeverPerformClear() {
        var sm = ClearGestureStateMachine()

        // 覆盖 0ms..3000ms（跨越 sixConfirm=180 多次、sixToFistTimeout=1000），
        // 全程六命中、无握拳：绝不 performClear。
        for ms in stride(from: 0.0, through: 3000.0, by: 20.0) {
            let out = sm.step(six: six(true), fist: fist(false), drawing: false,
                              handPresent: true, now: ms / 1000.0, config: config)
            XCTAssertNotEqual(out, .performClear, "仅六命中不应 performClear (t=\(ms)ms)")
            XCTAssertNotEqual(sm.phase, .clearing, "仅六命中不应进入 clearing (t=\(ms)ms)")
        }
        // 仅六会停在 sixArmed（六持续命中，isNeutralOrSix 恒真，靠超时兜底但六不断续命）。
        XCTAssertEqual(sm.phase, .sixArmed, "六持续命中应停在 sixArmed，不前进到清屏")
    }

    /// 仅六命中但在 sixArmed 后撤手（six/fist 都不命中），超时应回 idle，全程无 performClear。
    func testSixOnlyThenReleaseTimesOutToIdleNeverClears() {
        var sm = ClearGestureStateMachine()

        // 六稳定 → sixArmed。
        _ = sm.step(six: six(true), fist: fist(false), drawing: false, handPresent: true,
                    now: 0.0, config: config)
        _ = sm.step(six: six(true), fist: fist(false), drawing: false, handPresent: true,
                    now: 0.2, config: config)
        XCTAssertEqual(sm.phase, .sixArmed)

        // 之后既不六也不握拳（中性过渡），持续到超过超时窗（2000ms）→ 回 idle，全程无 performClear。
        for ms in stride(from: 300.0, through: 2600.0, by: 50.0) {
            let out = sm.step(six: six(false), fist: fist(false), drawing: false,
                              handPresent: true, now: ms / 1000.0, config: config)
            XCTAssertNotEqual(out, .performClear, "六就绪后未握拳超时不应 performClear (t=\(ms)ms)")
        }
        XCTAssertEqual(sm.phase, .idle, "sixArmed 后超过 sixToFistTimeoutMs 未握拳应回 idle")
    }

    // MARK: - 用例 3：仅握拳不清屏（Property 8）

    /// 从 idle 开始只喂 fist.matched=true（无先行六）→ 永不进入 sixCandidate、永不 performClear。
    func testFistOnlyFromIdleNeverEntersSixCandidateNorClears() {
        var sm = ClearGestureStateMachine()

        for ms in stride(from: 0.0, through: 3000.0, by: 20.0) {
            let out = sm.step(six: six(false), fist: fist(true), drawing: false,
                              handPresent: true, now: ms / 1000.0, config: config)
            XCTAssertEqual(out, .none, "仅握拳（无先行六）不应产生任何裁决 (t=\(ms)ms)")
            XCTAssertEqual(sm.phase, .idle,
                           "仅握拳（无先行六）应始终停在 idle，不进 sixCandidate (t=\(ms)ms)")
        }
    }

    // MARK: - 用例 4：drawing=true 时不起步（Req 5.4）

    /// drawing 传 true 且六命中 → 不进入 sixCandidate（停 idle），不 performClear。
    func testDrawingTrueDoesNotStartSixCandidate() {
        var sm = ClearGestureStateMachine()

        for ms in stride(from: 0.0, through: 1000.0, by: 20.0) {
            let out = sm.step(six: six(true), fist: fist(false), drawing: true,
                              handPresent: true, now: ms / 1000.0, config: config)
            XCTAssertEqual(out, .none, "drawing 时六命中不应产生裁决 (t=\(ms)ms)")
            XCTAssertEqual(sm.phase, .idle, "drawing=true 时不应从 idle 进入 sixCandidate (t=\(ms)ms)")
        }
    }

    // MARK: - 用例 5：可靠性门槛（matched 但 !reliable 不起步）

    /// six.matched=true 但 reliable=false → 不进入 sixCandidate（要求 matched && reliable），不 performClear。
    func testUnreliableSixDoesNotStartSixCandidate() {
        var sm = ClearGestureStateMachine()

        for ms in stride(from: 0.0, through: 1000.0, by: 20.0) {
            let out = sm.step(six: six(true, reliable: false), fist: fist(false),
                              drawing: false, handPresent: true,
                              now: ms / 1000.0, config: config)
            XCTAssertEqual(out, .none, "六不可靠时不应产生裁决 (t=\(ms)ms)")
            XCTAssertEqual(sm.phase, .idle,
                           "six.reliable=false 时不应进入 sixCandidate (t=\(ms)ms)")
        }
    }

    // MARK: - 用例 6：握拳确认期的掉帧容忍（真机「握拳识别不到」的主要修复点）

    /// 握拳确认途中短暂掉帧（< fistLossToleranceMs=300）不应重置确认计时：
    /// 掉帧恢复后继续累计，仍能在总确认时长到达时 performClear。
    func testBriefFistDropWithinToleranceStillClears() {
        var sm = ClearGestureStateMachine()
        var performClearCount = 0

        func feed(six s: PoseMatch, fist f: PoseMatch, nowMs: Double) -> ClearOutcome {
            let out = sm.step(six: s, fist: f, drawing: false, handPresent: true,
                              now: nowMs / 1000.0, config: config)
            if out == .performClear { performClearCount += 1 }
            return out
        }

        feed(six: six(true), fist: fist(false), nowMs: 0)      // → sixCandidate
        feed(six: six(true), fist: fist(false), nowMs: 200)    // → sixArmed
        feed(six: six(false), fist: fist(true), nowMs: 300)    // → fistCandidate
        // t=400~450：握拳判定掉帧 50ms（< 300ms 容忍）→ 不回退、不重置 fistStart
        XCTAssertEqual(feed(six: six(false), fist: fist(false), nowMs: 400), .suspendPinch)
        XCTAssertEqual(sm.phase, .fistCandidate, "容忍期内掉帧不应退回 sixArmed")
        XCTAssertEqual(feed(six: six(false), fist: fist(false), nowMs: 450), .suspendPinch)
        XCTAssertEqual(sm.phase, .fistCandidate)
        // t=500：恢复握拳，距 fistStart(300) 已 >=180ms → 立即 performClear
        XCTAssertEqual(feed(six: six(false), fist: fist(true), nowMs: 500), .performClear)
        XCTAssertEqual(performClearCount, 1)
    }

    /// 掉帧超过容忍窗（>=300ms）→ 退回 sixArmed 重新等待，不得 performClear。
    func testFistDropBeyondToleranceReturnsToArmed() {
        var sm = ClearGestureStateMachine()

        func feed(six s: PoseMatch, fist f: PoseMatch, nowMs: Double) -> ClearOutcome {
            sm.step(six: s, fist: f, drawing: false, handPresent: true,
                    now: nowMs / 1000.0, config: config)
        }

        feed(six: six(true), fist: fist(false), nowMs: 0)      // → sixCandidate
        feed(six: six(true), fist: fist(false), nowMs: 200)    // → sixArmed
        feed(six: six(false), fist: fist(true), nowMs: 300)    // → fistCandidate
        // 掉帧持续 400ms（> 300ms 容忍）
        _ = feed(six: six(false), fist: fist(false), nowMs: 400)
        XCTAssertEqual(sm.phase, .fistCandidate, "容忍窗内仍应停留")
        XCTAssertEqual(feed(six: six(false), fist: fist(false), nowMs: 750), .suspendPinch)
        XCTAssertEqual(sm.phase, .sixArmed, "掉帧超过容忍窗应退回 sixArmed 重新等待")
    }

    /// 在 sixArmed 后，握拳 matched=true 但 reliable=false → 不进入 fistCandidate，不 performClear。
    func testUnreliableFistDoesNotAdvanceToPerformClear() {
        var sm = ClearGestureStateMachine()

        // 六稳定 → sixArmed。
        _ = sm.step(six: six(true), fist: fist(false), drawing: false, handPresent: true,
                    now: 0.0, config: config)
        _ = sm.step(six: six(true), fist: fist(false), drawing: false, handPresent: true,
                    now: 0.2, config: config)
        XCTAssertEqual(sm.phase, .sixArmed)

        // 不可靠握拳：不应前进到 fistCandidate/clearing；全程无 performClear（最终靠超时回 idle）。
        for ms in stride(from: 300.0, through: 2600.0, by: 50.0) {
            let out = sm.step(six: six(false), fist: fist(true, reliable: false),
                              drawing: false, handPresent: true,
                              now: ms / 1000.0, config: config)
            XCTAssertNotEqual(out, .performClear, "不可靠握拳不应 performClear (t=\(ms)ms)")
            XCTAssertNotEqual(sm.phase, .clearing, "不可靠握拳不应进入 clearing (t=\(ms)ms)")
        }
    }
}

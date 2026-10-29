//
//  PinchConfirmTests.swift
//  HandMarkCoreTests
//
//  任务 2.2：为 PinchStateMachine 编写捏合确认与候选取消单测。
//
//  Property 1: 捏合迟滞（起笔侧）
//  Validates: Requirements 1.1, 1.2, 1.3
//
//  覆盖：
//  - 1.1 idle 下 Pinch_Distance 首次 < PINCH_ON → 进入 candidate 并开始确认计时（本帧仅 .none）。
//  - 1.2 candidate 持续 < PINCH_ON 累计达 PINCH_CONFIRM_MS(150ms) → 进入 drawing 并新建笔画（.begin），
//        且该首帧只 begin 不 append（随后的可靠捏合帧才返回 .append）。
//  - 1.3 candidate 在达到 PINCH_CONFIRM_MS 之前 Pinch_Distance 回升到 >= PINCH_ON → 取消候选、回 idle、
//        不新建笔画，且其后继续喂张开手不产生 .begin。
//  - 边界：时间语义为 `>= PINCH_CONFIRM_MS`，构造 now 使其正好等于阈值的那一帧应确认（.begin）。
//
//  时间完全以注入的 now: TimeInterval 确定性推进（毫秒换算成秒），不使用真实时钟 / sleep。
//

import XCTest
@testable import HandMarkCore

final class PinchConfirmTests: XCTestCase {

    /// 本任务固定使用默认参数：pinchOn=0.22, pinchOff=0.35, pinchConfirmMs=150。
    private let config = PinchConfig()

    /// 便捷常量：稳定「捏合」距离（远低于 pinchOn=0.22）。
    private let pinchDist = 0.1
    /// 便捷常量：稳定「张开」距离（不低于 pinchOn=0.22，用于候选取消 / 不起步）。
    private let openDist = 0.3

    // MARK: - 1.1 / 1.2：捏合确认（首帧仅 begin 不 append）

    /// 持续捏合可靠，累计达 150ms 的那一帧返回 .begin 且 phase==.drawing；
    /// 在此之前每帧 .none 且停在 .candidate；begin 之后的下一帧才返回 .append。
    func testPinchConfirmedAfterConfirmMsEmitsBeginThenAppend() {
        var sm = PinchStateMachine()

        // t=0ms：idle 下首次 dist<pinchOn → 进入 candidate，本帧只 .none（需求 1.1）。
        let f0 = sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                         suspended: false, now: 0.0, config: config)
        XCTAssertEqual(f0, .none, "进入 candidate 的首帧不应落笔")
        XCTAssertEqual(sm.phase, .candidate, "首次低于 pinchOn 应进入 candidate")

        // t=50ms：仍在确认窗内（50 < 150）→ .none，停在 candidate。
        let f1 = sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                         suspended: false, now: 0.05, config: config)
        XCTAssertEqual(f1, .none, "确认期未达 150ms 不应 begin")
        XCTAssertEqual(sm.phase, .candidate)

        // t=100ms：仍在确认窗内（100 < 150）→ .none，停在 candidate。
        let f2 = sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                         suspended: false, now: 0.10, config: config)
        XCTAssertEqual(f2, .none, "确认期未达 150ms 不应 begin")
        XCTAssertEqual(sm.phase, .candidate)

        // t=160ms：(160-0)>=150ms → 确认，返回 .begin 且进入 drawing（需求 1.2）。
        let f3 = sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                         suspended: false, now: 0.16, config: config)
        XCTAssertEqual(f3, .begin, "累计达 PINCH_CONFIRM_MS 应新建笔画（begin）")
        XCTAssertEqual(sm.phase, .drawing, "确认后应进入 drawing")

        // t=200ms：仍捏合可靠的下一帧 → .append（验证首帧仅 begin、不在同帧 append）。
        let f4 = sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                         suspended: false, now: 0.20, config: config)
        XCTAssertEqual(f4, .append, "begin 之后的持续捏合帧应 append")
        XCTAssertEqual(sm.phase, .drawing)
    }

    /// 边界：now 正好等于 candidateStart + PINCH_CONFIRM_MS（150ms）的那一帧应确认（`>=` 语义）。
    func testPinchConfirmExactlyAtThresholdEmitsBegin() {
        var sm = PinchStateMachine()

        // t=0ms：进入 candidate。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.0, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // t=149ms：恰好差 1ms，仍不确认。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.149, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // t=150ms：恰好等于阈值 → begin（`(now-start)*1000 >= 150` 为真）。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.150, config: config), .begin)
        XCTAssertEqual(sm.phase, .drawing)
    }

    // MARK: - 1.3：候选取消（确认前距离回升 → 回 idle，无 begin）

    /// candidate 期内（未达 150ms）某帧 dist>=pinchOn → .none 且 phase 回 idle，
    /// 其后继续喂张开手不产生 begin。
    func testCandidateCanceledWhenDistanceRisesBeforeConfirm() {
        var sm = PinchStateMachine()

        // t=0ms：进入 candidate。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.0, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // t=50ms：仍捏合，确认窗内。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.05, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // t=100ms：距离回升到 >= pinchOn（未达 150ms）→ 取消候选，回 idle，不 begin（需求 1.3）。
        let cancel = sm.step(distNorm: openDist, tipReliable: true, handPresent: true,
                             suspended: false, now: 0.10, config: config)
        XCTAssertEqual(cancel, .none, "候选取消帧不应落笔")
        XCTAssertEqual(sm.phase, .idle, "确认前回升到 pinchOn 应回到 idle")

        // 其后继续喂张开手：不应产生 begin，始终停在 idle。
        for ms in stride(from: 150.0, through: 400.0, by: 50.0) {
            let out = sm.step(distNorm: openDist, tipReliable: true, handPresent: true,
                              suspended: false, now: ms / 1000.0, config: config)
            XCTAssertEqual(out, .none, "取消后持续张开手不应落笔 (t=\(ms)ms)")
            XCTAssertEqual(sm.phase, .idle, "取消后持续张开手应停在 idle (t=\(ms)ms)")
        }
    }

    /// 边界：恰好 dist==pinchOn（而非严格大于）时也应取消候选（需求 1.3 的「不低于」语义）。
    func testCandidateCanceledWhenDistanceEqualsPinchOn() {
        var sm = PinchStateMachine()

        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.0, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // dist 恰好等于 pinchOn → `distNorm >= config.pinchOn` 为真 → 取消。
        let out = sm.step(distNorm: config.pinchOn, tipReliable: true, handPresent: true,
                          suspended: false, now: 0.05, config: config)
        XCTAssertEqual(out, .none)
        XCTAssertEqual(sm.phase, .idle, "dist 等于 pinchOn（不低于）应取消候选")
    }

    /// 取消后重新捏合，确认计时应从新的候选起点重新累计（不沿用旧 candidateStart）。
    func testCandidateRestartsTimerAfterCancel() {
        var sm = PinchStateMachine()

        // 第一次候选在 t=0 进入，t=100ms 取消。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.0, config: config), .none)
        XCTAssertEqual(sm.step(distNorm: openDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.10, config: config), .none)
        XCTAssertEqual(sm.phase, .idle)

        // 第二次候选在 t=120ms 重新进入。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.12, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate)

        // t=200ms：相对首个候选起点(0)已 200ms，但相对新起点(120)仅 80ms(<150) → 仍不确认。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.20, config: config), .none)
        XCTAssertEqual(sm.phase, .candidate, "确认计时应从新候选起点重新累计，不应提前 begin")

        // t=270ms：相对新起点已 150ms → 确认 begin。
        XCTAssertEqual(sm.step(distNorm: pinchDist, tipReliable: true, handPresent: true,
                               suspended: false, now: 0.27, config: config), .begin)
        XCTAssertEqual(sm.phase, .drawing)
    }
}

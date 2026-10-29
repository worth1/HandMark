//
//  PinchLowConfLossTests.swift
//  HandMarkCoreTests
//
//  任务 2.4：PinchStateMachine 低置信容忍与手部丢失「不连线/不桥接」单测。
//
//  Property 6: 丢失不桥接
//  Validates: Requirements 2.5, 2.6, 2.7
//
//  覆盖点：
//  1. 低置信单帧仅跳过写入（不 append / 不 end），phase 仍 drawing（Req 2.6/2.7）。
//  2. 低置信持续累计达 LOW_CONF_TOLERANCE_MS 才结束笔画（Req 2.6）。
//  3. 低置信在未超时前恢复可靠 → 继续 append，且低置信计时被清零
//     （之后再低置信需重新从 0 计满 200ms 才结束）。
//  4. 手部丢失即结束、禁止追加，且从丢失到下一次 begin 之间绝无 append
//     （不把丢失前后两点以直线相连 —— Req 2.5/2.7，Property 6）；
//     candidate 态遇丢失直接回 idle 且返回 none（未在绘画不产生 end）。
//
//  说明：本文件只写测试、以注入 now 做确定性时序推进，不改任何生产代码，
//  也不触碰 2.2/2.3 的测试文件（本文件独立）。
//

import XCTest
@testable import HandMarkCore

final class PinchLowConfLossTests: XCTestCase {

    // MARK: - 固定输入常量（与 PinchConfig 默认初值对齐）

    /// 远低于 pinchOn(0.22)：持续满足捏合的「绘画中」距离。
    private let drawingDist = 0.10
    /// 介于 pinchOn(0.22) 与 pinchOff(0.35) 之间：既不触发结束去抖，也不满足开始阈值。
    /// 用于低置信帧，确保走的是「低置信」分支而不是「距离超 pinchOff」分支。
    private let midDist = 0.30

    // MARK: - helper：把状态机推进到 drawing

    /// 以持续 distNorm=0.1、reliable=true、handPresent=true 的帧把机器推进到 `.drawing`。
    ///
    /// 时序：t=0 首帧 idle→candidate（.none）；t=confirm 帧 candidate→drawing（.begin）。
    /// 返回时 `now` 停在 begin 那一帧的时间点；调用方后续应从 `startNow` 之后继续推进。
    ///
    /// - Returns: (机器, begin 帧的 now)
    @discardableResult
    private func makeDrawing(config: PinchConfig = PinchConfig())
        -> (machine: PinchStateMachine, now: TimeInterval) {
        var m = PinchStateMachine()

        // 首帧：idle → candidate，开始确认计时。
        let first = m.step(distNorm: drawingDist,
                           tipReliable: true,
                           handPresent: true,
                           suspended: false,
                           now: 0,
                           config: config)
        XCTAssertEqual(first, .none, "首帧应仅进入 candidate，不落笔")
        XCTAssertEqual(m.phase, .candidate, "首帧后应处于 candidate")

        // 确认帧：累计 >=pinchConfirmMs → candidate → drawing，新建笔画（.begin）。
        // 加 1ms 余量越过确认阈值，规避浮点误差落在边界之下。
        let confirmNow = config.pinchConfirmMs / 1000.0 + 0.001
        let begin = m.step(distNorm: drawingDist,
                           tipReliable: true,
                           handPresent: true,
                           suspended: false,
                           now: confirmNow,
                           config: config)
        XCTAssertEqual(begin, .begin, "满足 pinchConfirmMs 应产生 begin")
        XCTAssertEqual(m.phase, .drawing, "begin 后应处于 drawing")

        return (m, confirmNow)
    }

    // MARK: - 用例 1：低置信单帧仅跳过（Req 2.6 / 2.7）

    func testLowConfidenceSingleFrameSkipsWithoutAppendOrEnd() {
        let config = PinchConfig()
        var (m, now) = makeDrawing(config: config)

        // 先确认一帧可靠绘画会 append（基线）。
        now += 0.016
        let appendOutcome = m.step(distNorm: drawingDist,
                                   tipReliable: true,
                                   handPresent: true,
                                   suspended: false,
                                   now: now,
                                   config: config)
        XCTAssertEqual(appendOutcome, .append, "可靠绘画帧应 append")

        // 低置信单帧：距离仍 <=pinchOff，仅因 tipReliable=false 跳过写入。
        now += 0.016
        let lowConf = m.step(distNorm: midDist,
                             tipReliable: false,
                             handPresent: true,
                             suspended: false,
                             now: now,
                             config: config)
        XCTAssertEqual(lowConf, .none, "低置信单帧既不 append 也不 end")
        XCTAssertEqual(m.phase, .drawing, "低置信单帧后 phase 仍为 drawing")
    }

    // MARK: - 用例 2：低置信持续超时才结束（Req 2.6）

    func testLowConfidenceEndsOnlyAfterToleranceElapsed() {
        let config = PinchConfig() // lowConfToleranceMs = 200
        var (m, startNow) = makeDrawing(config: config)

        // 首个低置信帧：记录 lowConfSince = thisNow，返回 none。
        let firstLowNow = startNow + 0.016
        let firstLow = m.step(distNorm: midDist,
                              tipReliable: false,
                              handPresent: true,
                              suspended: false,
                              now: firstLowNow,
                              config: config)
        XCTAssertEqual(firstLow, .none, "首个低置信帧不结束")
        XCTAssertEqual(m.phase, .drawing)

        // 低置信持续但累计 <200ms：仍返回 none，不结束。
        let belowThresholdNow = firstLowNow + 0.150 // 自 lowConfSince 起 150ms < 200ms
        let stillLow = m.step(distNorm: midDist,
                              tipReliable: false,
                              handPresent: true,
                              suspended: false,
                              now: belowThresholdNow,
                              config: config)
        XCTAssertEqual(stillLow, .none, "低置信累计 <200ms 不应结束")
        XCTAssertEqual(m.phase, .drawing)

        // 低置信累计 >=200ms 的那一帧：结束并封存，回 idle。
        let atThresholdNow = firstLowNow + config.lowConfToleranceMs / 1000.0 + 0.001 // >=200ms
        let ended = m.step(distNorm: midDist,
                           tipReliable: false,
                           handPresent: true,
                           suspended: false,
                           now: atThresholdNow,
                           config: config)
        XCTAssertEqual(ended, .end, "低置信累计 >=lowConfToleranceMs 应结束笔画")
        XCTAssertEqual(m.phase, .idle, "结束后应回到 idle")
    }

    // MARK: - 用例 3：低置信恢复后继续 append，且低置信计时被清零

    func testLowConfidenceRecoveryResumesAppendAndResetsTimer() {
        let config = PinchConfig() // lowConfToleranceMs = 200
        var (m, startNow) = makeDrawing(config: config)

        // 几帧低置信（未超 200ms）。
        let low1 = startNow + 0.016
        XCTAssertEqual(m.step(distNorm: midDist, tipReliable: false, handPresent: true,
                              suspended: false, now: low1, config: config), .none)
        let low2 = low1 + 0.100 // 自 lowConfSince 起 100ms < 200ms
        XCTAssertEqual(m.step(distNorm: midDist, tipReliable: false, handPresent: true,
                              suspended: false, now: low2, config: config), .none)
        XCTAssertEqual(m.phase, .drawing, "未超时的低置信期间仍应处于 drawing")

        // 恢复可靠：应返回 append，并把 lowConf 计时清零。
        let recoverNow = low2 + 0.016
        let resumed = m.step(distNorm: drawingDist, tipReliable: true, handPresent: true,
                             suspended: false, now: recoverNow, config: config)
        XCTAssertEqual(resumed, .append, "恢复可靠绘画应继续 append")
        XCTAssertEqual(m.phase, .drawing)

        // 验证计时确已清零：再走一轮低置信，必须重新从 0 计满 200ms。
        // 若上一轮未清零，则「recover 之后」很快就会越过旧的累计阈值而提前 end。
        let reLow1 = recoverNow + 0.016 // 新一轮低置信起点
        XCTAssertEqual(m.step(distNorm: midDist, tipReliable: false, handPresent: true,
                              suspended: false, now: reLow1, config: config), .none,
                       "新一轮低置信首帧不结束")

        // 距新一轮起点 150ms（<200ms）：若计时被正确清零则不结束。
        let reLow2 = reLow1 + 0.150
        XCTAssertEqual(m.step(distNorm: midDist, tipReliable: false, handPresent: true,
                              suspended: false, now: reLow2, config: config), .none,
                       "新一轮累计 <200ms 不应结束（证明旧计时已清零）")
        XCTAssertEqual(m.phase, .drawing)

        // 距新一轮起点 200ms：此时才结束。
        let reLow3 = reLow1 + config.lowConfToleranceMs / 1000.0 + 0.001
        XCTAssertEqual(m.step(distNorm: midDist, tipReliable: false, handPresent: true,
                              suspended: false, now: reLow3, config: config), .end,
                       "新一轮累计满 200ms 才结束")
        XCTAssertEqual(m.phase, .idle)
    }

    // MARK: - 用例 4：丢失即结束、不桥接（Property 6，Req 2.5 / 2.7）

    func testHandLossEndsImmediatelyAndNeverBridgesToNextStroke() {
        let config = PinchConfig()
        var (m, startNow) = makeDrawing(config: config)

        // 丢失前一帧可靠绘画（基线 append）。
        var now = startNow + 0.016
        XCTAssertEqual(m.step(distNorm: drawingDist, tipReliable: true, handPresent: true,
                              suspended: false, now: now, config: config), .append)

        // 手部丢失：drawing 态立即结束、禁止追加，回 idle。
        now += 0.016
        let lossOutcome = m.step(distNorm: drawingDist, tipReliable: true, handPresent: false,
                                 suspended: false, now: now, config: config)
        XCTAssertEqual(lossOutcome, .end, "丢失发生在绘画态应立即 end")
        XCTAssertEqual(m.phase, .idle, "丢失后应回到 idle")

        // 丢失持续若干帧：既不 append 也不 end（已结束，无笔画可封存）。
        for _ in 0..<5 {
            now += 0.016
            let whileLost = m.step(distNorm: drawingDist, tipReliable: true, handPresent: false,
                                   suspended: false, now: now, config: config)
            XCTAssertEqual(whileLost, .none, "持续丢失帧应返回 none（不 append / 不 end）")
            XCTAssertEqual(m.phase, .idle)
        }

        // 手部恢复并重新捏合确认 → 产生新笔画 begin。
        // 关键断言：从丢失（end）到下一次 begin 之间，全程没有出现过任何 append，
        // 因此不会把丢失前的点与恢复后的点用直线相接（Property 6：丢失不桥接）。
        now += 0.016
        let reCandidate = m.step(distNorm: drawingDist, tipReliable: true, handPresent: true,
                                 suspended: false, now: now, config: config)
        XCTAssertEqual(reCandidate, .none, "恢复后首帧仅进入 candidate，不 append")
        XCTAssertEqual(m.phase, .candidate)

        // 加 1ms 余量越过确认阈值，规避浮点累计误差落在边界之下。
        let reBeginNow = now + config.pinchConfirmMs / 1000.0 + 0.001
        let reBegin = m.step(distNorm: drawingDist, tipReliable: true, handPresent: true,
                             suspended: false, now: reBeginNow, config: config)
        XCTAssertEqual(reBegin, .begin, "重新捏合确认应新建一条全新笔画（begin）")
        XCTAssertEqual(m.phase, .drawing)
    }

    // MARK: - 用例 4 补充：candidate 态遇丢失直接回 idle 且返回 none（未绘画不产生 end）

    func testHandLossInCandidateReturnsNoneAndGoesIdle() {
        let config = PinchConfig()
        var m = PinchStateMachine()

        // idle → candidate。
        let enter = m.step(distNorm: drawingDist, tipReliable: true, handPresent: true,
                           suspended: false, now: 0, config: config)
        XCTAssertEqual(enter, .none)
        XCTAssertEqual(m.phase, .candidate)

        // candidate 态丢失：未处于绘画，不产生 end，直接回 idle。
        let lossInCandidate = m.step(distNorm: drawingDist, tipReliable: true, handPresent: false,
                                     suspended: false, now: 0.05, config: config)
        XCTAssertEqual(lossInCandidate, .none, "candidate 态丢失不产生 end")
        XCTAssertEqual(m.phase, .idle, "candidate 态丢失应直接回 idle")
    }
}

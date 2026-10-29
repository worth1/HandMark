import XCTest
@testable import HandMarkCore

/// 捏合「假松开」修复的专项测试：palmScale 突变使归一化距离越过 PINCH_OFF，
/// 但原始像素距离没有明显增大时，不得误结束笔画（根因：dist = distPx / palmScale）。
final class PinchFalseReleaseTests: XCTestCase {
    private let cfg = PinchConfig()  // pinchOn=0.22, pinchOff=0.35, releaseConfirmMs=160, releasePxRatio=1.8

    private func step(_ sm: inout PinchStateMachine, distNorm: Double, distPx: Double,
                      now: TimeInterval, reliable: Bool = true, present: Bool = true) -> PinchOutcome {
        sm.step(distNorm: distNorm, distPx: distPx, tipReliable: reliable,
                handPresent: present, suspended: false, now: now, config: cfg)
    }

    /// 推进到 drawing，捏合基准像素距离 ≈ 12px（手指捏紧）。
    private func toDrawing(_ sm: inout PinchStateMachine) -> TimeInterval {
        XCTAssertEqual(step(&sm, distNorm: 0.08, distPx: 12, now: 0.0), .none)   // candidate
        XCTAssertEqual(step(&sm, distNorm: 0.08, distPx: 12, now: 0.16), .begin) // drawing，基准=12px
        return 0.20
    }

    /// 核心：手指仍捏着（原始像素距离仍小 ≈13px），但 palmScale 突然塌陷使归一化 d 冲到 0.66，
    /// 越过 pinchOff —— 不得结束笔画，应保持可继续绘画。
    func testPalmScaleSpikeDoesNotFalselyRelease() {
        var sm = PinchStateMachine()
        var t = toDrawing(&sm)
        // 连续多帧「归一化越阈但像素几乎不变」——模拟 palmScale 从 180→80 塌陷
        for _ in 0..<12 {   // 覆盖远超 releaseConfirmMs(160ms) 的时长
            let out = step(&sm, distNorm: 0.66, distPx: 13, now: t)  // 像素几乎没变（12→13）
            XCTAssertNotEqual(out, .end, "手指仍捏着（像素未增大），palmScale 突变不应结束笔画")
            t += 0.033
        }
        XCTAssertNotEqual(sm.phase, .idle, "不应回到 idle（没有真松开）")
        // palmScale 恢复、归一化回落 → 回 drawing（该帧不追加，避免跳点），再下一帧才 append
        XCTAssertEqual(step(&sm, distNorm: 0.08, distPx: 12, now: t), .none)
        XCTAssertEqual(sm.phase, .drawing)
        t += 0.033
        XCTAssertEqual(step(&sm, distNorm: 0.08, distPx: 12, now: t), .append)
    }

    /// 对照：真松开（原始像素距离确实大幅增大）→ 去抖窗满后正常结束。
    func testRealReleaseStillEnds() {
        var sm = PinchStateMachine()
        var t = toDrawing(&sm)
        // 张开手：归一化越阈 + 原始像素距离从 ~12px 增大到 ~120px（远超 1.8 倍基准）
        XCTAssertEqual(step(&sm, distNorm: 0.70, distPx: 120, now: t), .none) // releaseCandidate
        XCTAssertEqual(sm.phase, .releaseCandidate)
        t += 0.17  // 超过 releaseConfirmMs 160ms
        let out = step(&sm, distNorm: 0.70, distPx: 120, now: t)
        XCTAssertEqual(out, .end, "真松开（像素显著增大）应在去抖窗满后结束")
        XCTAssertEqual(sm.phase, .idle)
    }

    /// 关键点丢失仍立即安全收笔（不被像素辅助影响）。
    func testHandLossStillEndsImmediately() {
        var sm = PinchStateMachine()
        let t = toDrawing(&sm)
        let out = step(&sm, distNorm: 0.08, distPx: 12, now: t, present: false)
        XCTAssertEqual(out, .end, "手部丢失应立即结束")
        XCTAssertEqual(sm.phase, .idle)
    }

    /// 假松开期间若归一化回落（palmScale 恢复）→ 立即回 drawing 继续画。
    func testRecoveryWhenNormDistFallsBack() {
        var sm = PinchStateMachine()
        var t = toDrawing(&sm)
        XCTAssertEqual(step(&sm, distNorm: 0.66, distPx: 13, now: t), .none) // releaseCandidate（假松开）
        XCTAssertEqual(sm.phase, .releaseCandidate)
        t += 0.05
        XCTAssertEqual(step(&sm, distNorm: 0.10, distPx: 12, now: t), .none) // 归一化回落 → 回 drawing
        XCTAssertEqual(sm.phase, .drawing)
        t += 0.033
        XCTAssertEqual(step(&sm, distNorm: 0.09, distPx: 12, now: t), .append)
    }
}

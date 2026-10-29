import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 旋钮 / 音量与原有手势的协调器互斥测试。
final class KnobVolumeCoordinatorTests: XCTestCase {
    private let cfg = GestureConfig()

    private func step(_ c: inout GesturePriorityCoordinator,
                      _ m: HandMetrics,
                      _ now: TimeInterval) -> CoordinatorDecision {
        c.step(m, midTip: CGPoint(x: 0.5, y: 0.5), hasMidTip: true,
               refPoint: CGPoint(x: 0.5, y: 0.5), hasRef: true, now: now, config: cfg)
    }

    private func knobHand(angle: Double) -> HandMetrics {
        var m = ControlGestureFixtures.openKnobHand()
        m.palmAngle = angle
        m.hasPalmAngle = true
        return m
    }

    private func activateKnob(_ c: inout GesturePriorityCoordinator,
                              _ now: inout TimeInterval) {
        for _ in 0..<15 {
            _ = step(&c, knobHand(angle: 0), now)
            now += 0.033
            if c.knob.phase == .active { return }
        }
    }

    func testKnobActivatesThenSuspendsPinching() {
        var c = GesturePriorityCoordinator()
        var now: TimeInterval = 0
        activateKnob(&c, &now)
        XCTAssertEqual(c.knob.phase, .active)

        // 旋钮激活期间即使做出捏合手形也不得落笔。
        var pinch = ControlGestureFixtures.openKnobHand()
        pinch.pinchDistanceNorm = 0.05
        for _ in 0..<10 {
            let d = step(&c, pinch, now)
            now += 0.033
            XCTAssertNotEqual(d.pinchOutcome, .begin, "旋钮激活期间不得开始绘画")
        }
    }

    /// 一次「激活」只切一档：切完后无论怎么转（含把手转回原位的反向行程）都不再触发；
    /// 必须先收手（离开五指张开）退出，再重新五指张开进入，才能切下一档。
    func testOneActivationYieldsExactlyOneStepAndRequiresReopen() {
        var c = GesturePriorityCoordinator()
        var now: TimeInterval = 0
        activateKnob(&c, &now)

        // ① 连贯旋转 120°：只应切一档。
        var triggered = 0
        var angle = 0.0
        for _ in 0..<12 {
            angle += 10 * .pi / 180
            if case .rotate = step(&c, knobHand(angle: angle), now).knobOutcome { triggered += 1 }
            now += 0.033
        }
        XCTAssertEqual(triggered, 1, "一次激活内连贯旋转 120° 只应切一档")

        // ② 把手转回原位（反向 120°，手仍是五指张开）：不得触发第二次（否则回程会改颜色/粗细）。
        var onTheWayBack = 0
        for _ in 0..<12 {
            angle -= 10 * .pi / 180
            if case .rotate = step(&c, knobHand(angle: angle), now).knobOutcome { onTheWayBack += 1 }
            now += 0.033
        }
        XCTAssertEqual(onTheWayBack, 0, "回程的反向旋转不得触发切换")

        // ③ 收手（捏合 → 不再是张开手形）→ 应退出旋钮模式。
        var closed = knobHand(angle: angle)
        closed.pinchDistanceNorm = 0.05
        var exited = false
        for _ in 0..<20 {
            if step(&c, closed, now).knobOutcome == .exited { exited = true; break }
            now += 0.033
        }
        XCTAssertTrue(exited, "收手后应退出旋钮模式")
        XCTAssertEqual(c.knob.phase, .idle)

        // ④ 重新五指张开 → 再次旋转 → 才允许切下一档。
        activateKnob(&c, &now)
        var second = 0
        var angle2 = 0.0
        for _ in 0..<12 {
            angle2 += 10 * .pi / 180
            if case .rotate = step(&c, knobHand(angle: angle2), now).knobOutcome { second += 1 }
            now += 0.033
        }
        XCTAssertEqual(second, 1, "重新张开后应能再切一档，且仍只切一档")
    }

    func testKnobExitRestoresDrawing() {
        var c = GesturePriorityCoordinator()
        var now: TimeInterval = 0
        activateKnob(&c, &now)

        var pinch = ControlGestureFixtures.openKnobHand()
        pinch.pinchDistanceNorm = 0.05
        var exited = false
        for _ in 0..<20 {
            let d = step(&c, pinch, now)
            now += 0.033
            if d.knobOutcome == .exited { exited = true }
            if exited { break }
        }
        XCTAssertTrue(exited, "手形离开五指张开后应退出旋钮模式")
        XCTAssertEqual(c.knob.phase, .idle)

        var began = false
        for _ in 0..<20 {
            if step(&c, pinch, now).pinchOutcome == .begin { began = true; break }
            now += 0.033
        }
        XCTAssertTrue(began, "退出旋钮后应恢复绘画")
    }

    func testVolumeAndKnobAreMutuallyExclusive() {
        var c = GesturePriorityCoordinator()
        var now: TimeInterval = 0
        activateKnob(&c, &now)
        XCTAssertEqual(c.knob.phase, .active)

        // 拇指朝上 + 四指弯曲：不是五指张开，旋钮会退出；但在退出的同一路径上
        // 音量也不得与旋钮同时生效（协调器逐帧只允许一个控制手势推进）。
        var thumbUp = ControlGestureFixtures.openKnobHand()
        thumbUp.thumb = ControlGestureFixtures.feature(tip: CGPoint(x: 0.36, y: 0.72),
                                                       dip: CGPoint(x: 0.36, y: 0.58),
                                                       pip: CGPoint(x: 0.37, y: 0.46),
                                                       mcp: CGPoint(x: 0.38, y: 0.36))
        thumbUp.index = ControlGestureFixtures.feature(tip: CGPoint(x: 0.46, y: 0.49),
                                                       dip: CGPoint(x: 0.47, y: 0.50),
                                                       pip: CGPoint(x: 0.47, y: 0.51),
                                                       mcp: CGPoint(x: 0.47, y: 0.50))
        thumbUp.middle = ControlGestureFixtures.feature(tip: CGPoint(x: 0.50, y: 0.50),
                                                        dip: CGPoint(x: 0.50, y: 0.51),
                                                        pip: CGPoint(x: 0.50, y: 0.52),
                                                        mcp: CGPoint(x: 0.50, y: 0.49))
        thumbUp.ring = ControlGestureFixtures.feature(tip: CGPoint(x: 0.54, y: 0.49),
                                                      dip: CGPoint(x: 0.54, y: 0.50),
                                                      pip: CGPoint(x: 0.54, y: 0.51),
                                                      mcp: CGPoint(x: 0.54, y: 0.48))
        thumbUp.little = ControlGestureFixtures.feature(tip: CGPoint(x: 0.58, y: 0.47),
                                                        dip: CGPoint(x: 0.58, y: 0.48),
                                                        pip: CGPoint(x: 0.58, y: 0.49),
                                                        mcp: CGPoint(x: 0.58, y: 0.46))

        for _ in 0..<20 {
            let d = step(&c, thumbUp, now)
            now += 0.033
            if c.knob.isBusy {
                XCTAssertEqual(d.volumeOutcome, .none, "旋钮仍占用时不得同时触发音量")
            }
            if d.volumeOutcome != .none {
                XCTAssertFalse(c.knob.isBusy, "音量触发帧旋钮必须已让出操作权")
            }
        }
    }
}

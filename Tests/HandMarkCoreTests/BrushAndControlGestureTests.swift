import XCTest
import CoreGraphics
@testable import HandMarkCore

enum ControlGestureFixtures {
    static func feature(tip: CGPoint, dip: CGPoint, pip: CGPoint, mcp: CGPoint,
                        confidence: Float = 0.9) -> FingerFeature {
        FingerFeature(tip: tip, dip: dip, pip: pip, mcp: mcp,
                      minConfidence: confidence, hasTip: true, hasMcp: true)
    }

    /// 五指全部伸直且拇指与食指分开的旋钮手形。
    static func openKnobHand() -> HandMetrics {
        HandMetrics(
            thumb: feature(tip: CGPoint(x: 0.28, y: 0.60),
                           dip: CGPoint(x: 0.31, y: 0.53),
                           pip: CGPoint(x: 0.34, y: 0.46),
                           mcp: CGPoint(x: 0.38, y: 0.38)),
            index: feature(tip: CGPoint(x: 0.42, y: 0.80),
                           dip: CGPoint(x: 0.43, y: 0.72),
                           pip: CGPoint(x: 0.44, y: 0.62),
                           mcp: CGPoint(x: 0.45, y: 0.48)),
            middle: feature(tip: CGPoint(x: 0.50, y: 0.84),
                            dip: CGPoint(x: 0.50, y: 0.75),
                            pip: CGPoint(x: 0.50, y: 0.64),
                            mcp: CGPoint(x: 0.50, y: 0.49)),
            ring: feature(tip: CGPoint(x: 0.57, y: 0.80),
                          dip: CGPoint(x: 0.56, y: 0.72),
                          pip: CGPoint(x: 0.55, y: 0.62),
                          mcp: CGPoint(x: 0.54, y: 0.48)),
            little: feature(tip: CGPoint(x: 0.63, y: 0.72),
                            dip: CGPoint(x: 0.62, y: 0.66),
                            pip: CGPoint(x: 0.61, y: 0.58),
                            mcp: CGPoint(x: 0.58, y: 0.46)),
            wrist: CGPoint(x: 0.50, y: 0.25),
            palmScale: 180,
            pinchDistanceNorm: 0.8,
            hasHand: true,
            palmConfidence: 0.9,
            palmAngle: 0,
            hasPalmAngle: true)
    }
    /// 真实摄像头量级的手（2026-10-27 实测：掌长 169px，
    /// curl 食0.90 中0.97 无0.94 **小0.66**，伸直比 食1.91 中1.96 无1.99 小1.76）。
    /// 小指天生短，curl 只有 0.66；若按统一阈值 0.70 判定，五指永远凑不齐 → 进不了旋钮。
    static func realisticOpenHand() -> HandMetrics {
        HandMetrics(
            thumb: feature(tip: CGPoint(x: 0.30, y: 0.45),
                           dip: CGPoint(x: 0.33, y: 0.40),
                           pip: CGPoint(x: 0.36, y: 0.35),
                           mcp: CGPoint(x: 0.39, y: 0.30), confidence: 0.72),
            index: feature(tip: CGPoint(x: 0.44, y: 0.696),
                           dip: CGPoint(x: 0.445, y: 0.62),
                           pip: CGPoint(x: 0.447, y: 0.55),
                           mcp: CGPoint(x: 0.45, y: 0.48), confidence: 0.72),
            middle: feature(tip: CGPoint(x: 0.50, y: 0.718),
                            dip: CGPoint(x: 0.50, y: 0.63),
                            pip: CGPoint(x: 0.50, y: 0.56),
                            mcp: CGPoint(x: 0.50, y: 0.49), confidence: 0.72),
            ring: feature(tip: CGPoint(x: 0.55, y: 0.703),
                          dip: CGPoint(x: 0.545, y: 0.62),
                          pip: CGPoint(x: 0.543, y: 0.55),
                          mcp: CGPoint(x: 0.54, y: 0.48), confidence: 0.72),
            little: feature(tip: CGPoint(x: 0.60, y: 0.618),
                            dip: CGPoint(x: 0.595, y: 0.56),
                            pip: CGPoint(x: 0.59, y: 0.51),
                            mcp: CGPoint(x: 0.58, y: 0.46), confidence: 0.72),
            wrist: CGPoint(x: 0.50, y: 0.25),
            palmScale: 212,
            pinchDistanceNorm: 0.8,
            hasHand: true,
            palmConfidence: 0.68,
            palmAngle: 0,
            hasPalmAngle: true)
    }
}

final class BrushAndControlGestureTests: XCTestCase {
    private let yes = PoseMatch(matched: true, confidence: 0.9, reliable: true)
    private let no = PoseMatch(matched: false, confidence: 0.9, reliable: true)

    func testBrushSizeCyclesInRequiredOrder() {
        var brush = BrushSelection(size: .coarse, color: .yellow)
        XCTAssertEqual(brush.cycleSizeClockwise(), .medium)
        XCTAssertEqual(brush.cycleSizeClockwise(), .fine)
        XCTAssertEqual(brush.cycleSizeClockwise(), .coarse)
        XCTAssertEqual(brush.size.width, 12)
    }

    /// 回归：真实手部量级下小指 curl 只有 0.66，仍必须判为「伸直」，
    /// 否则五指全伸恒不成立（用户张开手掌也进不了旋钮模式）。
    func testRealisticOpenHandMatchesKnobDespiteShortLittleFinger() {
        let m = ControlGestureFixtures.realisticOpenHand()
        let d = knobDiagnostics(m, minConfidence: 0.15)
        XCTAssertEqual(d.straightCount, 4, "真实手型下小指（curl≈0.66）必须计入伸直")
        XCTAssertTrue(d.thumbExtended)
        XCTAssertTrue(d.reliable)
        XCTAssertTrue(classifyKnob(m, minConfidence: 0.15).matched)
    }

    func testBrushColorCyclesInRequiredOrder() {
        var brush = BrushSelection(size: .medium, color: .yellow)
        XCTAssertEqual(brush.cycleColorCounterclockwise(), .blue)
        XCTAssertEqual(brush.cycleColorCounterclockwise(), .black)
        XCTAssertEqual(brush.cycleColorCounterclockwise(), .green)
        XCTAssertEqual(brush.cycleColorCounterclockwise(), .white)
        XCTAssertEqual(brush.cycleColorCounterclockwise(), .yellow)
    }

    func testKnobRequiresStableOpenHandBeforeActivation() {
        var machine = KnobGestureStateMachine()
        let cfg = KnobConfig(confirmMs: 300, emaAlpha: 1)
        XCTAssertEqual(machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0, config: cfg), .none)
        XCTAssertEqual(machine.phase, .candidate)
        XCTAssertEqual(machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0.29, config: cfg), .none)
        XCTAssertEqual(machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0.31, config: cfg), .entered)
        XCTAssertEqual(machine.phase, .active)
    }

    func testKnobClockwiseAndCounterclockwiseTriggerOneStep() {
        let cfg = KnobConfig(confirmMs: 0, triggerDegrees: 30, emaAlpha: 1,
                             maxFrameDeltaDegrees: 40, jitterDeadZoneDegrees: 0)

        var clockwise = KnobGestureStateMachine()
        _ = clockwise.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                           suspended: false, handPresent: true, now: 0, config: cfg)
        _ = clockwise.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                           suspended: false, handPresent: true, now: 0.01, config: cfg)
        XCTAssertEqual(clockwise.step(knob: yes, palmAngle: 0.6, hasPalmAngle: true,
                                      suspended: false, handPresent: true, now: 0.02, config: cfg),
                       .rotate(.clockwise))
        XCTAssertEqual(clockwise.step(knob: yes, palmAngle: 0.6, hasPalmAngle: true,
                                      suspended: false, handPresent: true, now: 0.03, config: cfg), .none,
                       "同一段旋转保持不动不得重复触发")

        var counterclockwise = KnobGestureStateMachine()
        _ = counterclockwise.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                                  suspended: false, handPresent: true, now: 0, config: cfg)
        _ = counterclockwise.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                                  suspended: false, handPresent: true, now: 0.01, config: cfg)
        XCTAssertEqual(counterclockwise.step(knob: yes, palmAngle: -0.6, hasPalmAngle: true,
                                             suspended: false, handPresent: true, now: 0.02, config: cfg),
                       .rotate(.counterclockwise))
    }

    /// 回归：慢速旋转（每帧增量小于抖动死区）必须仍能累计并触发，
    /// 否则用户「慢慢转手掌」会因为逐帧丢弃而永远切不了档。
    func testSlowRotationStillAccumulatesAcrossDeadZone() {
        var machine = KnobGestureStateMachine()
        let cfg = KnobConfig(confirmMs: 0, triggerDegrees: 30, emaAlpha: 1,
                             jitterDeadZoneDegrees: 0.6)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0, config: cfg)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0.01, config: cfg)

        var triggered = 0
        var now: Double = 0.02
        // 每帧仅 +0.3°（小于死区 0.6°），共 240 帧 = 72°：
        // 死区若丢弃增量则一次都不会触发；正常累计则触发一次（一次激活只切一档）。
        for i in 1...240 {
            let angle = Double(i) * 0.3 * .pi / 180
            if case .rotate = machine.step(knob: yes, palmAngle: angle, hasPalmAngle: true,
                                           suspended: false, handPresent: true, now: now, config: cfg) {
                triggered += 1
            }
            now += 0.033
        }
        XCTAssertEqual(triggered, 1, "每帧 0.3° 的慢速旋转必须能触发（死区不得丢弃增量）；按一次激活只切一档的规则切一档")
    }

    func testKnobRejectsSingleFrameAngleJump() {
        var machine = KnobGestureStateMachine()
        let cfg = KnobConfig(confirmMs: 0, triggerDegrees: 30, emaAlpha: 1,
                             maxFrameDeltaDegrees: 20, jitterDeadZoneDegrees: 0)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0, config: cfg)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0.01, config: cfg)
        XCTAssertEqual(machine.step(knob: yes, palmAngle: 1.5, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0.02, config: cfg), .none)
    }

    func testKnobExitsWhenOpenHandIsLost() {
        var machine = KnobGestureStateMachine()
        let cfg = KnobConfig(confirmMs: 0, lossToleranceMs: 100)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0, config: cfg)
        _ = machine.step(knob: yes, palmAngle: 0, hasPalmAngle: true,
                         suspended: false, handPresent: true, now: 0.01, config: cfg)
        XCTAssertEqual(machine.step(knob: no, palmAngle: 0, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0.05, config: cfg), .none)
        XCTAssertEqual(machine.step(knob: no, palmAngle: 0, hasPalmAngle: true,
                                    suspended: false, handPresent: true, now: 0.16, config: cfg), .exited)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testVolumeGestureTriggersOnceUntilNeutralAndCooldown() {
        var machine = VolumeGestureStateMachine()
        let cfg = VolumeGestureConfig(confirmMs: 300, cooldownMs: 500)
        XCTAssertEqual(machine.step(up: yes, down: no, suspended: false, handPresent: true,
                                    now: 0, config: cfg), .none)
        XCTAssertEqual(machine.step(up: yes, down: no, suspended: false, handPresent: true,
                                    now: 0.31, config: cfg), .adjust(.up))
        XCTAssertEqual(machine.step(up: yes, down: no, suspended: false, handPresent: true,
                                    now: 1.0, config: cfg), .none, "持续保持不得连调")
        _ = machine.step(up: no, down: no, suspended: false, handPresent: true,
                         now: 1.01, config: cfg)
        XCTAssertEqual(machine.phase, .idle)
        _ = machine.step(up: yes, down: no, suspended: false, handPresent: true,
                         now: 1.02, config: cfg)
        XCTAssertEqual(machine.step(up: yes, down: no, suspended: false, handPresent: true,
                                    now: 1.33, config: cfg), .adjust(.up))
    }

    func testVolumeGestureInvalidPointsNeverTrigger() {
        var machine = VolumeGestureStateMachine()
        let unreliable = PoseMatch(matched: true, confidence: 0.05, reliable: false)
        let cfg = VolumeGestureConfig(confirmMs: 250, cooldownMs: 500)
        for i in 0..<30 {
            XCTAssertEqual(machine.step(up: unreliable, down: no, suspended: false, handPresent: true,
                                        now: Double(i) / 30, config: cfg), .none)
        }
    }

    // MARK: - 几何分类

    private func feature(tip: CGPoint, dip: CGPoint, pip: CGPoint, mcp: CGPoint,
                         confidence: Float = 0.9) -> FingerFeature {
        FingerFeature(tip: tip, dip: dip, pip: pip, mcp: mcp,
                      minConfidence: confidence, hasTip: true, hasMcp: true)
    }

    private func curled(x: CGFloat, mcpY: CGFloat = 0.50) -> FingerFeature {
        feature(tip: CGPoint(x: x, y: mcpY - 0.01),
                dip: CGPoint(x: x + 0.01, y: mcpY + 0.01),
                pip: CGPoint(x: x + 0.01, y: mcpY + 0.02),
                mcp: CGPoint(x: x, y: mcpY))
    }

    private func volumeMetrics(up: Bool) -> HandMetrics {
        let thumb = up
            ? feature(tip: CGPoint(x: 0.38, y: 0.82), dip: CGPoint(x: 0.38, y: 0.68),
                      pip: CGPoint(x: 0.39, y: 0.54), mcp: CGPoint(x: 0.40, y: 0.40))
            : feature(tip: CGPoint(x: 0.38, y: 0.12), dip: CGPoint(x: 0.38, y: 0.26),
                      pip: CGPoint(x: 0.39, y: 0.40), mcp: CGPoint(x: 0.40, y: 0.54))
        return HandMetrics(thumb: thumb,
                           index: curled(x: 0.46), middle: curled(x: 0.50),
                           ring: curled(x: 0.54), little: curled(x: 0.58),
                           wrist: CGPoint(x: 0.50, y: 0.20), palmScale: 180,
                           pinchDistanceNorm: 0.8, hasHand: true, palmConfidence: 0.9)
    }

    func testThumbUpAndDownGeometryAreDistinct() {
        let upMetrics = volumeMetrics(up: true)
        XCTAssertTrue(classifyThumbVolume(upMetrics, direction: .up, minConfidence: 0.15).matched)
        XCTAssertFalse(classifyThumbVolume(upMetrics, direction: .down, minConfidence: 0.15).matched)

        let downMetrics = volumeMetrics(up: false)
        XCTAssertTrue(classifyThumbVolume(downMetrics, direction: .down, minConfidence: 0.15).matched)
        XCTAssertFalse(classifyThumbVolume(downMetrics, direction: .up, minConfidence: 0.15).matched)
    }

    func testNewStrokesUseCurrentBrushWhileHistoryKeepsItsOwn() {
        let state = DrawState()
        state.beginStroke(at: CGPoint(x: 10, y: 10))
        _ = state.cycleBrushSizeClockwise()          // 中 → 细（2px）
        _ = state.cycleBrushColorCounterclockwise()  // 黄 → 蓝
        state.beginStroke(at: CGPoint(x: 20, y: 20))
        state.appendPoint(CGPoint(x: 30, y: 30))

        let strokes = state.strokesSnapshot()
        XCTAssertEqual(strokes.count, 2)
        XCTAssertEqual(strokes[0].brush.size, .medium)
        XCTAssertEqual(strokes[0].brush.color, .yellow, "切换颜色不得改写历史笔迹")
        XCTAssertEqual(strokes[1].brush.size, .fine)
        XCTAssertEqual(strokes[1].brush.color, .blue)
        XCTAssertEqual(strokes[1].brush.size.width, 2)
        XCTAssertEqual(strokes[1].points.count, 2)
    }

    func testKnobClassifierRequiresFiveStraightFingers() {
        var metrics = ControlGestureFixtures.openKnobHand()
        XCTAssertTrue(classifyKnob(metrics, minConfidence: 0.15).matched)

        metrics.little = curled(x: 0.62)
        XCTAssertFalse(classifyKnob(metrics, minConfidence: 0.15).matched,
                       "任一长指弯曲都不得进入旋钮模式")

        var unreliable = ControlGestureFixtures.openKnobHand()
        unreliable.palmConfidence = 0.02
        XCTAssertFalse(classifyKnob(unreliable, minConfidence: 0.15).matched)
    }

    func testThumbVolumeRejectsWhenAnotherFingerIsStraight() {
        var metrics = volumeMetrics(up: true)
        metrics.little = feature(tip: CGPoint(x: 0.60, y: 0.82), dip: CGPoint(x: 0.60, y: 0.70),
                                 pip: CGPoint(x: 0.60, y: 0.60), mcp: CGPoint(x: 0.58, y: 0.48))
        XCTAssertFalse(classifyThumbVolume(metrics, direction: .up, minConfidence: 0.15).matched,
                       "四根长指未全部弯曲时不得调音量")
    }
}

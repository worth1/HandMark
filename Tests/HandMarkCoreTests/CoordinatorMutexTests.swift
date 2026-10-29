import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 四手势优先级互斥测试：验证「同一帧只有一个模式获操作权」与清屏锁定优先。
/// 复用 FistGeometryTests 已验证可命中的 six/fist 几何构造。
final class CoordinatorMutexTests: XCTestCase {
    private let cfg = GestureConfig()
    private func finger(tip: CGPoint, mcp: CGPoint) -> FingerFeature {
        FingerFeature(tip: tip, dip: tip, pip: tip, mcp: mcp, minConfidence: 0.9, hasTip: true, hasMcp: true)
    }
    private func metrics(wrist: CGPoint, thumb: (CGPoint, CGPoint), index: (CGPoint, CGPoint),
                         middle: (CGPoint, CGPoint), ring: (CGPoint, CGPoint), little: (CGPoint, CGPoint),
                         pinchNorm: Double = 1.0) -> HandMetrics {
        HandMetrics(thumb: finger(tip: thumb.0, mcp: thumb.1), index: finger(tip: index.0, mcp: index.1),
                    middle: finger(tip: middle.0, mcp: middle.1), ring: finger(tip: ring.0, mcp: ring.1),
                    little: finger(tip: little.0, mcp: little.1), wrist: wrist, palmScale: 180,
                    pinchDistanceNorm: pinchNorm, hasHand: true, palmConfidence: 0.9)
    }
    private var six: HandMetrics {
        metrics(wrist: CGPoint(x: 0.50, y: 0.28),
                thumb: (CGPoint(x: 0.36, y: 0.48), CGPoint(x: 0.46, y: 0.31)),
                index: (CGPoint(x: 0.48, y: 0.44), CGPoint(x: 0.47, y: 0.46)),
                middle: (CGPoint(x: 0.50, y: 0.44), CGPoint(x: 0.50, y: 0.47)),
                ring: (CGPoint(x: 0.52, y: 0.44), CGPoint(x: 0.53, y: 0.46)),
                little: (CGPoint(x: 0.52, y: 0.68), CGPoint(x: 0.56, y: 0.45)))
    }
    private var fist: HandMetrics {
        metrics(wrist: CGPoint(x: 0.50, y: 0.30),
                thumb: (CGPoint(x: 0.48, y: 0.47), CGPoint(x: 0.46, y: 0.33)),
                index: (CGPoint(x: 0.48, y: 0.46), CGPoint(x: 0.47, y: 0.48)),
                middle: (CGPoint(x: 0.50, y: 0.47), CGPoint(x: 0.50, y: 0.485)),
                ring: (CGPoint(x: 0.52, y: 0.46), CGPoint(x: 0.53, y: 0.48)),
                little: (CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.56, y: 0.47)),
                pinchNorm: 0.05)  // 握拳时食指拇指也近，但清屏锁定应阻止捏合 begin
    }
    private func step(_ c: inout GesturePriorityCoordinator, _ m: HandMetrics, _ now: TimeInterval) -> CoordinatorDecision {
        c.step(m, midTip: CGPoint(x: 0.5, y: 0.5), hasMidTip: true,
               refPoint: CGPoint(x: 0.5, y: 0.5), hasRef: true, now: now, config: cfg)
    }

    /// 先确认 six 能被协调器识别并推进到清屏锁定（sixArmed 及之后）。
    func testSixDrivesClearLock() {
        var c = GesturePriorityCoordinator()
        var now = 0.0
        for _ in 0..<20 {   // 持续喂六，跨过 sixConfirmMs(180ms)
            _ = step(&c, six, now); now += 0.033
        }
        XCTAssertTrue(c.clear.phase == .sixArmed || c.clear.phase == .fistCandidate,
                      "持续六应进入清屏锁定态，实际 \(c.clear.phase)")
    }

    /// 清屏锁定期间：捏合不 begin（即便 fist 的指尖很近）。
    func testClearLockSuspendsPinch() {
        var c = GesturePriorityCoordinator()
        var now = 0.0
        for _ in 0..<20 { _ = step(&c, six, now); now += 0.033 }   // → sixArmed
        XCTAssertEqual(c.clear.phase, .sixArmed)
        // 此后喂握拳（指尖很近，pinchNorm=0.05 本会触发捏合候选）
        for _ in 0..<3 {
            let d = step(&c, fist, now); now += 0.033
            XCTAssertNotEqual(d.pinchOutcome, .begin, "清屏锁定期间捏合不得 begin")
            XCTAssertNotEqual(d.laserOutcome, .show(CGPoint(x: 0.5, y: 0.5)), "清屏锁定期间不得激活激光")
        }
    }

    /// 六→握拳完整序列触发 performClear，且该帧捏合为 none（不同帧既清屏又落笔）。
    func testSixThenFistPerformsClearWithoutPinch() {
        var c = GesturePriorityCoordinator()
        var now = 0.0
        for _ in 0..<20 { _ = step(&c, six, now); now += 0.033 }   // sixArmed
        var cleared = false
        for _ in 0..<20 {   // 持续握拳跨过 fistConfirmMs
            let d = step(&c, fist, now); now += 0.033
            if d.clearOutcome == .performClear {
                cleared = true
                XCTAssertEqual(d.pinchOutcome, .none, "清屏执行帧捏合必须为 none")
            }
        }
        XCTAssertTrue(cleared, "六→握拳应触发一次 performClear")
    }
}

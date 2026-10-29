import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 激光手势废除后的行为回归（V2.1）。
///
/// 需求变更：不再用「四指伸出 + 拇指收回」触发激光；屏幕上的红色光点改为跟随
/// 食指指尖常驻显示（由调用方的覆盖层按指尖坐标绘制，与落笔坐标同源）。
///
/// 因此协调器上的 `laserEnabled = false` 必须保证两点：
///  1) 激光状态机恒不激活、不产生 .show 输出（不再有「进入/退出激光模式」）；
///  2) 激光不再参与优先级抢占 —— 翻页与捏合绘画都不会被激光挂起。
final class LaserGestureDisabledTests: XCTestCase {

    private let minConf: Float = 0.3

    private func finger(tip: CGPoint, mcp: CGPoint) -> FingerFeature {
        FingerFeature(tip: tip, dip: tip, pip: tip, mcp: mcp,
                      minConfidence: 0.9, hasTip: true, hasMcp: true)
    }

    private func metrics(gap: Double,
                         thumbTip: CGPoint,
                         indexTip: CGPoint,
                         middleTip: CGPoint,
                         ringTip: CGPoint,
                         littleTip: CGPoint) -> HandMetrics {
        HandMetrics(
            thumb: finger(tip: thumbTip,  mcp: CGPoint(x: 0.46, y: 0.34)),
            index: finger(tip: indexTip,  mcp: CGPoint(x: 0.47, y: 0.45)),
            middle: finger(tip: middleTip, mcp: CGPoint(x: 0.50, y: 0.46)),
            ring: finger(tip: ringTip,    mcp: CGPoint(x: 0.55, y: 0.45)),
            little: finger(tip: littleTip, mcp: CGPoint(x: 0.59, y: 0.43)),
            wrist: CGPoint(x: 0.50, y: 0.30),
            palmScale: 180,
            pinchDistanceNorm: gap,
            hasHand: true,
            palmConfidence: 0.9)
    }

    /// 激光手形（四指伸出 + 拇指收回，张开未捏合）。
    private func laserFrame() -> HandMetrics {
        metrics(gap: 0.90,
                thumbTip: CGPoint(x: 0.475, y: 0.355),
                indexTip: CGPoint(x: 0.43, y: 0.72),
                middleTip: CGPoint(x: 0.50, y: 0.78),
                ringTip: CGPoint(x: 0.57, y: 0.74),
                littleTip: CGPoint(x: 0.62, y: 0.66))
    }

    /// 捏合手形（拇指尖↔食指尖很近）。
    private func pinchFrame() -> HandMetrics {
        metrics(gap: 0.10,
                thumbTip: CGPoint(x: 0.475, y: 0.355),
                indexTip: CGPoint(x: 0.478, y: 0.360),
                middleTip: CGPoint(x: 0.50, y: 0.78),
                ringTip: CGPoint(x: 0.57, y: 0.74),
                littleTip: CGPoint(x: 0.62, y: 0.66))
    }

    private func makeCoordinator(enabled: Bool) -> GesturePriorityCoordinator {
        var co = GesturePriorityCoordinator()
        co.laserEnabled = enabled
        return co
    }

    /// 前置断言：同样的手形在开关打开时确实会命中激光（证明本组用例不是在测一具空壳）。
    func testLaserEnabledBaselineActivates() {
        var co = makeCoordinator(enabled: true)
        let cfg = GestureConfig()
        var t = 0.0
        var activated = false
        for _ in 0..<40 {
            let d = co.step(laserFrame(), midTip: laserFrame().middle.tip, hasMidTip: true,
                            refPoint: laserFrame().index.tip, hasRef: true,
                            now: t, config: cfg)
            t += 1.0 / 30.0
            if case .show = d.laserOutcome { activated = true }
        }
        XCTAssertTrue(activated, "开关打开时，稳定激光手形应激活激光（基线，非本需求目标）")
    }

    /// 核心：开关关闭后，激光手形连续输入也不得激活、不得产生 .show。
    func testLaserDisabledNeverActivates() {
        var co = makeCoordinator(enabled: false)
        let cfg = GestureConfig()
        var t = 0.0
        for _ in 0..<40 {
            let d = co.step(laserFrame(), midTip: laserFrame().middle.tip, hasMidTip: true,
                            refPoint: laserFrame().index.tip, hasRef: true,
                            now: t, config: cfg)
            t += 1.0 / 30.0
            XCTAssertEqual(co.laser.phase, .idle, "激光关闭后状态机必须恒为 idle")
            if case .show = d.laserOutcome {
                XCTFail("激光关闭后不得产生 .show 输出（光点已改为指尖常驻）")
            }
        }
    }

    /// 核心：开关关闭后，激光不得挂起捏合 —— 稳定捏合仍能正常起笔。
    func testLaserDisabledDoesNotBlockPinch() {
        var co = makeCoordinator(enabled: false)
        let cfg = GestureConfig()
        var t = 0.0
        // 先喂一段激光手形（若激光仍参与抢占，会先把状态机搞成 active）
        for _ in 0..<20 {
            _ = co.step(laserFrame(), midTip: laserFrame().middle.tip, hasMidTip: true,
                        refPoint: laserFrame().index.tip, hasRef: true,
                        now: t, config: cfg)
            t += 1.0 / 30.0
        }
        // 再稳定捏合，必须能进入绘画
        var began = false
        for _ in 0..<15 {
            let d = co.step(pinchFrame(), midTip: pinchFrame().middle.tip, hasMidTip: true,
                            refPoint: pinchFrame().index.tip, hasRef: true,
                            now: t, config: cfg)
            t += 1.0 / 30.0
            if d.pinchOutcome == .begin { began = true; break }
        }
        XCTAssertTrue(began, "激光废除后，捏合绘画不得被激光抢占，应能正常起笔")
        XCTAssertEqual(co.pinch.phase, .drawing)
    }
}

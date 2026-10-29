import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 激光 / 翻页 与「捏合绘画」的互斥回归测试（纯几何，不依赖摄像头）。
///
/// 背景（真机问题）：捏合绘画时四根长指往往仍是伸直的
/// （实测捏合帧弯曲度 食0.71 中0.73 无0.63 小0.50，伸直门限 0.70），
/// 单看「四指伸直 + 拇指弯」无法区分「激光手形」与「捏合绘画」。
/// 一旦激光在捏合途中命中，就会以更高优先级挂起捏合：
/// 候选被反复打回 idle（150ms 确认计时重启）→ 表现为「起笔困难、时断时续」。
///
/// 本组用例固定两条防线：
///  1) 几何防线：激光/翻页手形必须「非捏合」（拇指尖↔食指尖归一化距离 >= POSE_MIN_PINCH_GAP）；
///  2) 占用防线：捏合已上手时，协调器挂起激光与翻页（见 testLaserDoesNotPreemptEngagedPinch）。
final class LaserVsPinchTests: XCTestCase {

    private let minConf: Float = 0.3

    private func finger(tip: CGPoint, mcp: CGPoint) -> FingerFeature {
        FingerFeature(tip: tip, dip: tip, pip: tip, mcp: mcp,
                      minConfidence: 0.9, hasTip: true, hasMcp: true)
    }

    /// 组装一帧手部数据；`gap` 为拇指尖↔食指尖的归一化距离（捏合绘画时很小）。
    private func metrics(gap: Double,
                         thumbTip: CGPoint,
                         indexTip: CGPoint,
                         middleTip: CGPoint,
                         ringTip: CGPoint,
                         littleTip: CGPoint) -> HandMetrics {
        // 掌长基准 palmBase = dist(wrist, middleMCP) = 0.16
        return HandMetrics(
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

    /// 激光手形：拇指收回、四指伸出（手指几何与「宽捏合」几乎一致，唯一差别是拇指-食指张开度）。
    private func laserGeometry(gap: Double) -> HandMetrics {
        metrics(gap: gap,
                thumbTip: CGPoint(x: 0.475, y: 0.355),   // 拇指收回掌心（弯曲）
                indexTip: CGPoint(x: 0.43, y: 0.72),
                middleTip: CGPoint(x: 0.50, y: 0.78),
                ringTip: CGPoint(x: 0.57, y: 0.74),
                littleTip: CGPoint(x: 0.62, y: 0.66))
    }

    /// 翻页手形：食指 + 中指伸出，拇指/无名/小指弯曲（V 字手形）。
    private func pageGeometry(gap: Double) -> HandMetrics {
        metrics(gap: gap,
                thumbTip: CGPoint(x: 0.475, y: 0.355),
                indexTip: CGPoint(x: 0.43, y: 0.72),
                middleTip: CGPoint(x: 0.50, y: 0.78),
                ringTip: CGPoint(x: 0.55, y: 0.47),     // 蜷曲
                littleTip: CGPoint(x: 0.585, y: 0.45))  // 蜷曲
    }

    // MARK: - 几何防线

    func testLaserMatchesWhenFingersOpen() {
        let r = classifyLaser(laserGeometry(gap: 0.90), minConfidence: minConf)
        XCTAssertTrue(r.matched, "四指伸出 + 拇指收回 + 非捏合，应命中激光手形")
        XCTAssertTrue(r.reliable)
    }

    /// 关键回归：同一套手指几何，只要拇指与食指是捏合的（gap 小），就绝不能判成激光。
    func testLaserRejectedWhilePinching() {
        let r = classifyLaser(laserGeometry(gap: 0.10), minConfidence: minConf)
        XCTAssertFalse(r.matched,
                       "捏合中（gap=0.10）不得判为激光手形，否则会抢占画笔导致起笔困难")
    }

    func testPageMatchesWhenFingersOpen() {
        let r = classifyPage(pageGeometry(gap: 0.90), minConfidence: minConf)
        XCTAssertTrue(r.matched, "V 字手形 + 非捏合，应命中翻页手形")
    }

    func testPageRejectedWhilePinching() {
        let r = classifyPage(pageGeometry(gap: 0.10), minConfidence: minConf)
        XCTAssertFalse(r.matched, "捏合中不得判为翻页手形")
    }

    // MARK: - 占用防线（协调器）

    /// 捏合已上手（drawing）时，即使手形被判成激光，激光也不得激活、不得打断笔画。
    func testLaserDoesNotPreemptEngagedPinch() {
        var co = GesturePriorityCoordinator()
        let cfg = GestureConfig()
        let pinchFrame = laserGeometry(gap: 0.10)     // 捏合中，gap 小于 pinchOn
        let laserFrame = laserGeometry(gap: 0.90)     // 张开，激光手形

        var t = 0.0
        func step(_ m: HandMetrics) -> CoordinatorDecision {
            let d = co.step(m,
                            midTip: m.middle.tip, hasMidTip: true,
                            refPoint: m.index.tip, hasRef: true,
                            now: t, config: cfg)
            t += 1.0 / 30.0
            return d
        }

        // 先稳定捏合进入 drawing
        var began = false
        for _ in 0..<12 {
            if step(pinchFrame).pinchOutcome == .begin { began = true; break }
        }
        XCTAssertTrue(began, "稳定捏合应进入绘画")
        XCTAssertEqual(co.pinch.phase, .drawing)

        // 保持捏合并混入激光手形（手指几何相同、只有 gap 变大时不该被喂进来；
        // 这里直接喂激光帧，验证「捏合上手」这一层的保护是否生效）
        var laserActivated = false
        for _ in 0..<20 {
            let d = step(laserFrame)
            if case .show = d.laserOutcome { laserActivated = true }
            if co.pinch.phase == .idle { break }   // 捏合已松开，保护自然解除
        }
        XCTAssertFalse(laserActivated,
                       "捏合占用期间激光不得激活（激活会挂起捏合、打断绘画）")
    }
}

import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 握拳判定的几何回归测试（不依赖摄像头，纯几何构造）。
///
/// 覆盖：握拳命中 / 张开手不命中 / 「六」不误判为握拳 /
/// 指尖被遮挡（缺失）时仍能命中且不被 (0,0) 污染。
final class FistGeometryTests: XCTestCase {

    private let clearConfig = ClearConfig()

    private func finger(tip: CGPoint, mcp: CGPoint, hasTip: Bool = true) -> FingerFeature {
        FingerFeature(tip: hasTip ? tip : .zero, dip: tip, pip: tip, mcp: mcp,
                      minConfidence: 0.9, hasTip: hasTip, hasMcp: true)
    }

    private func metrics(wrist: CGPoint,
                         thumb: (CGPoint, CGPoint),
                         index: (CGPoint, CGPoint),
                         middle: (CGPoint, CGPoint),
                         ring: (CGPoint, CGPoint),
                         little: (CGPoint, CGPoint),
                         littleHasTip: Bool = true,
                         ringHasTip: Bool = true,
                         palmConfidence: Float = 0.9) -> HandMetrics {
        HandMetrics(
            thumb: finger(tip: thumb.0, mcp: thumb.1),
            index: finger(tip: index.0, mcp: index.1),
            middle: finger(tip: middle.0, mcp: middle.1),
            ring: finger(tip: ring.0, mcp: ring.1, hasTip: ringHasTip),
            little: finger(tip: little.0, mcp: little.1, hasTip: littleHasTip),
            wrist: wrist, palmScale: 180, pinchDistanceNorm: 1.0,
            hasHand: true, palmConfidence: palmConfidence)
    }

    /// 握拳：五指指尖全部回收到指根附近，指尖彼此收拢。
    private var fistMetrics: HandMetrics {
        metrics(
            wrist: CGPoint(x: 0.50, y: 0.30),
            thumb: (CGPoint(x: 0.48, y: 0.47), CGPoint(x: 0.46, y: 0.33)),
            index: (CGPoint(x: 0.48, y: 0.46), CGPoint(x: 0.47, y: 0.48)),
            middle: (CGPoint(x: 0.50, y: 0.47), CGPoint(x: 0.50, y: 0.485)),
            ring: (CGPoint(x: 0.52, y: 0.46), CGPoint(x: 0.53, y: 0.48)),
            little: (CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.56, y: 0.47)))
    }

    /// 张开手掌：五指均伸直。
    private var openMetrics: HandMetrics {
        metrics(
            wrist: CGPoint(x: 0.50, y: 0.25),
            thumb: (CGPoint(x: 0.32, y: 0.42), CGPoint(x: 0.45, y: 0.28)),
            index: (CGPoint(x: 0.43, y: 0.72), CGPoint(x: 0.45, y: 0.45)),
            middle: (CGPoint(x: 0.50, y: 0.78), CGPoint(x: 0.50, y: 0.46)),
            ring: (CGPoint(x: 0.57, y: 0.74), CGPoint(x: 0.55, y: 0.45)),
            little: (CGPoint(x: 0.62, y: 0.66), CGPoint(x: 0.59, y: 0.43)))
    }

    /// 「六」手势：拇指与小指伸直，食/中/无名蜷曲。
    private var sixMetrics: HandMetrics {
        metrics(
            wrist: CGPoint(x: 0.50, y: 0.28),
            thumb: (CGPoint(x: 0.36, y: 0.48), CGPoint(x: 0.46, y: 0.31)),
            index: (CGPoint(x: 0.48, y: 0.44), CGPoint(x: 0.47, y: 0.46)),
            middle: (CGPoint(x: 0.50, y: 0.44), CGPoint(x: 0.50, y: 0.47)),
            ring: (CGPoint(x: 0.52, y: 0.44), CGPoint(x: 0.53, y: 0.46)),
            little: (CGPoint(x: 0.52, y: 0.68), CGPoint(x: 0.56, y: 0.45)))
    }

    func testFistMatches() {
        let m = fistMetrics
        let r = classifyFist(m, minConfidence: CLEAR_MIN_CONFIDENCE, config: clearConfig)
        XCTAssertTrue(r.matched, "标准握拳应命中")
        XCTAssertTrue(r.reliable)
        let d = fistDiagnostics(m)
        XCTAssertEqual(d.straightCount, 0)
        XCTAssertTrue(d.compact)
    }

    func testOpenHandDoesNotMatchFist() {
        let r = classifyFist(openMetrics, minConfidence: CLEAR_MIN_CONFIDENCE, config: clearConfig)
        XCTAssertFalse(r.matched, "张开手掌不应命中握拳")
    }

    func testSixDoesNotMatchFist() {
        XCTAssertFalse(classifyFist(sixMetrics, minConfidence: CLEAR_MIN_CONFIDENCE, config: clearConfig).matched,
                       "「六」手势不应被判为握拳")
        XCTAssertTrue(classifySix(sixMetrics, minConfidence: CLEAR_MIN_CONFIDENCE, config: clearConfig).matched,
                      "「六」手势仍应命中六（不得因本次改动退化）")
    }

    /// 关键回归：握拳时无名指/小指指尖被遮挡（Vision 不返回）时也必须命中，
    /// 且缺失点不得被当成 (0,0) 参与收拢度计算（旧实现因此把收拢度放大到 1.11 而卡死）。
    func testFistMatchesWithOccludedTips() {
        let m = metrics(
            wrist: CGPoint(x: 0.50, y: 0.30),
            thumb: (CGPoint(x: 0.48, y: 0.47), CGPoint(x: 0.46, y: 0.33)),
            index: (CGPoint(x: 0.48, y: 0.46), CGPoint(x: 0.47, y: 0.48)),
            middle: (CGPoint(x: 0.50, y: 0.47), CGPoint(x: 0.50, y: 0.485)),
            ring: (CGPoint(x: 0.52, y: 0.46), CGPoint(x: 0.53, y: 0.48)),
            little: (CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.56, y: 0.47)),
            littleHasTip: false, ringHasTip: false)
        let d = fistDiagnostics(m)
        XCTAssertEqual(d.validCount, 2, "无名指/小指指尖缺失时应只剩两根可判定")
        XCTAssertTrue(d.matched, "指尖被遮挡的握拳仍应命中（缺失点不得污染判定）")
        // 缺失指尖若被当成 (0,0)，收拢度会被放大到远大于 1；断言其未被污染。
        XCTAssertLessThan(d.spread ?? 999, 1.0, "收拢度不得被缺失的 (0,0) 坐标污染")
    }

    /// 关键回归：拇指位置**不得**影响握拳收拢度。
    ///
    /// 握拳时拇指绕在四指外侧/前方，与四指是否收拢无关。旧实现把拇指指尖算进
    /// 「有效指尖最大跨度」，实测把收拢度顶到 1.9~3.0（阈值 1.3），
    /// 表现为「六能识别、握拳却永远识别不到」。
    func testThumbPositionDoesNotAffectFistSpread() {
        let base = fistDiagnostics(fistMetrics)
        // 把拇指指尖甩到很远的地方（模拟握拳时拇指外翘/贴在外侧）
        var moved = fistMetrics
        moved.thumb = FingerFeature(tip: CGPoint(x: 0.20, y: 0.10), dip: CGPoint(x: 0.20, y: 0.10),
                                    pip: CGPoint(x: 0.20, y: 0.10), mcp: fistMetrics.thumb.mcp,
                                    minConfidence: 0.9, hasTip: true, hasMcp: true)
        let movedDiag = fistDiagnostics(moved)
        XCTAssertEqual(movedDiag.spread ?? -1, base.spread ?? -2, accuracy: 1e-9,
                       "拇指指尖位置不应改变收拢度")
        XCTAssertTrue(movedDiag.matched, "拇指外翘时握拳仍应命中")
    }

    /// 收拢度只由**四根长指**指尖决定：长指指尖外移 → 判为不收拢（作为对照，
    /// 上面那个用例证明拇指指尖外移不影响）。
    func testSpreadRespondsToLongFingerTips() {
        var splayed = fistMetrics
        splayed.little = FingerFeature(tip: CGPoint(x: 0.95, y: 0.10),
                                       dip: CGPoint(x: 0.95, y: 0.10),
                                       pip: CGPoint(x: 0.95, y: 0.10),
                                       mcp: fistMetrics.little.mcp,
                                       minConfidence: 0.9, hasTip: true, hasMcp: true)
        XCTAssertFalse(fistDiagnostics(splayed).compact, "长指指尖外移应判为不收拢")
    }

    /// 掌部骨架不可靠（置信度过低）时不得命中。
    func testLowPalmConfidenceRejects() {
        let m = metrics(
            wrist: CGPoint(x: 0.50, y: 0.30),
            thumb: (CGPoint(x: 0.48, y: 0.47), CGPoint(x: 0.46, y: 0.33)),
            index: (CGPoint(x: 0.48, y: 0.46), CGPoint(x: 0.47, y: 0.48)),
            middle: (CGPoint(x: 0.50, y: 0.47), CGPoint(x: 0.50, y: 0.485)),
            ring: (CGPoint(x: 0.52, y: 0.46), CGPoint(x: 0.53, y: 0.48)),
            little: (CGPoint(x: 0.55, y: 0.45), CGPoint(x: 0.56, y: 0.47)),
            palmConfidence: 0.02)
        XCTAssertFalse(fistDiagnostics(m).reliable)
        XCTAssertFalse(classifyFist(m, minConfidence: CLEAR_MIN_CONFIDENCE, config: clearConfig).matched)
    }
}

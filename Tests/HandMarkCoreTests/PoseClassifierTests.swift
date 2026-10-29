import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 翻页手形（仅食指+中指伸直，无名指/小指未伸直）的分类专项测试。
///
/// 覆盖本次专项修复的关键点：
/// 1. 中指在挥动中自然微屈（curl≈0.38、ratio≈1.38）应被独立下限 `PAGE_MIDDLE_CURL_MIN` 接纳；
///    旧下限 0.48 会把它误判为「未伸直」，导致翻页中途掉线（修复回归）。
/// 2. 即便 curl 落在 [0.33, 0.48) 区间，若 `straightenRatio` 不足（<1.28）仍判「未伸直」，
///    守住所长比下限，避免真蜷曲/侧手被误放进来。
/// 3. 无名指/小指「未伸直」仍是翻页必要条件——五指全伸不应命中翻页，
///    否则协调器会把五指张开抢先判成翻页，旋钮模式永远进不去（冲突防护）。
final class PoseClassifierTests: XCTestCase {

    private let minConf: Float = 0.3

    /// 核心定义：食指+中指伸直、无名指与小指未伸直（剪刀/V 手形）应命中翻页手形。
    func testPageIndexMiddleStraightRingLittleCurled_matched() {
        let m = TestFactories.handMetrics(
            index:  TestFactories.finger(baseX: 0.44),
            middle: TestFactories.finger(baseX: 0.50, tipY: 0.92),
            ring:   TestFactories.curledFinger(baseX: 0.56),
            little: TestFactories.curledFinger(baseX: 0.62),
            pinchDistanceNorm: 0.8
        )
        let d = pageDiagnostics(m, minConfidence: minConf)
        XCTAssertTrue(d.indexStraight,  "食指应判为伸直")
        XCTAssertTrue(d.middleStraight, "中指应判为伸直")
        XCTAssertTrue(d.ringNotStraight,   "无名指应判为未伸直")
        XCTAssertTrue(d.littleNotStraight, "小指应判为未伸直")
        XCTAssertTrue(d.matched, "食指+中指伸直、无名指小指未伸直 应命中翻页手形")
    }

    /// 回归：挥动时中指随手掌侧转/前推自然微屈（curl≈0.38、ratio≈1.38）。
    /// 旧阈值 0.48 会误判为「未伸直」→ 翻页中途掉线；放宽到 `PAGE_MIDDLE_CURL_MIN=0.33`
    /// 后应被接纳（仍受 `straightenRatio>=1.28` 兜底）。
    func testPageMiddleMicroFlexAccepted() {
        // 中指自然微屈：tip=(0.5,0.652)、mcp=(0.5,0.5)，掌长 0.4 → curl≈0.38；ratio≈1.38
        let middleMicroFlex = TestFactories.finger(baseX: 0.50, tipY: 0.652, dipY: 0.62, pipY: 0.56, mcpY: 0.5)
        let m = TestFactories.handMetrics(
            index:  TestFactories.finger(baseX: 0.44),
            middle: middleMicroFlex,
            ring:   TestFactories.curledFinger(baseX: 0.56),
            little: TestFactories.curledFinger(baseX: 0.62),
            pinchDistanceNorm: 0.8
        )
        let d = pageDiagnostics(m, minConfidence: minConf)
        XCTAssertTrue(d.middleStraight, "中指自然微屈(curl≈0.38) 应被独立阈值 PAGE_MIDDLE_CURL_MIN 接纳")
        XCTAssertTrue(d.matched, "中指微屈 + 食直 + 无名小指未伸 应命中翻页手形")
    }

    /// 守住下限：curl 落在 [0.33,0.48) 但 straightenRatio 不足（<1.28）仍判「未伸直」。
    func testPageMiddleLowRatioRejected() {
        // 中指横向贴回：tip=(0.66,0.5)、mcp=(0.5,0.5) → curl≈0.40（>0.33 新下限），
        // 但 straightenRatio≈1.08（<1.28）→ 不应判为伸直。
        let middleLowRatio = TestFactories.finger(baseX: 0.66, tipY: 0.5, dipY: 0.5, pipY: 0.5, mcpY: 0.5)
        let m = TestFactories.handMetrics(
            index:  TestFactories.finger(baseX: 0.44),
            middle: middleLowRatio,
            ring:   TestFactories.curledFinger(baseX: 0.56),
            little: TestFactories.curledFinger(baseX: 0.62),
            pinchDistanceNorm: 0.8
        )
        let d = pageDiagnostics(m, minConfidence: minConf)
        XCTAssertFalse(d.middleStraight, "curl 达标但 straightenRatio 不足，仍应判未伸直")
        XCTAssertFalse(d.matched)
    }

    /// 真握拳式中指（明显蜷曲）不应被翻页手形接纳。
    func testPageCurledMiddleRejected() {
        let m = TestFactories.handMetrics(
            index:  TestFactories.finger(baseX: 0.44),
            middle: TestFactories.curledFinger(baseX: 0.50),
            ring:   TestFactories.curledFinger(baseX: 0.56),
            little: TestFactories.curledFinger(baseX: 0.62),
            pinchDistanceNorm: 0.8
        )
        let d = pageDiagnostics(m, minConfidence: minConf)
        XCTAssertFalse(d.middleStraight, "蜷曲的中指不应判为伸直")
        XCTAssertFalse(d.matched, "仅食直+中蜷 不应命中翻页手形")
    }

    /// 冲突防护：五指全伸（含无名指、小指伸直）不应命中翻页手形。
    /// 协调器评估翻页早于旋钮，若放开无名/小指，五指张开会被翻页抢先匹配，
    /// 旋钮模式永远进不去——故无名/小指「未伸直」仍是翻页必要条件。
    func testPageFourFingerExtendRejected() {
        let m = TestFactories.openHand()  // 五指全伸
        let d = pageDiagnostics(m, minConfidence: minConf)
        XCTAssertFalse(d.ringNotStraight,   "五指全伸时无名指是伸直的")
        XCTAssertFalse(d.littleNotStraight, "五指全伸时小指是伸直的")
        XCTAssertFalse(d.matched, "无名/小指也伸直时不应命中翻页手形（保留旋钮冲突防护）")
    }
}

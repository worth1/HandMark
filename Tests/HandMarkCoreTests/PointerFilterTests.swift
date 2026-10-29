import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 1€ Filter 与 Legacy EMA 的对比单元测试（阶段 2）。
///
/// 说明：这里的参数只验证「滤波器行为符合理论预期」，
/// 不能证明某组参数在你的摄像头与手势下最优 —— 最终参数必须由实测确定（需求 6.2）。
final class PointerFilterTests: XCTestCase {

    private let dt = 1.0 / 30.0

    /// 确定性伪随机（LCG），避免测试因随机源不同而不稳定。
    private func makeNoise(_ seed: UInt64, count: Int) -> [Double] {
        var s = seed
        var out: [Double] = []
        for _ in 0..<count {
            s = (s &* 6364136223846793005) &+ 1442695040888963407
            let v = Double((s >> 11) % 2000) / 1000.0 - 1.0   // [-1, 1)
            out.append(v)
        }
        return out
    }

    private func std(_ a: [Double]) -> Double {
        guard a.count > 1 else { return 0 }
        let m = a.reduce(0, +) / Double(a.count)
        let v = a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)
        return sqrt(v)
    }

    // MARK: - 基本行为

    func testFirstSampleReturnsRawValue() {
        var f = OneEuroFilter1D()
        XCTAssertFalse(f.isInitialized)
        let out = f.filter(120.0, timestamp: 0)
        XCTAssertEqual(out, 120.0, accuracy: 1e-9, "首帧必须原样输出，不得从 0 平滑过来")
        XCTAssertTrue(f.isInitialized)
    }

    func testZeroOrNegativeDeltaHoldsPreviousOutput() {
        var f = OneEuroFilter1D()
        _ = f.filter(100, timestamp: 1.0)
        let out = f.filter(500, timestamp: 1.0)   // dt == 0
        XCTAssertEqual(out, 100, accuracy: 1e-9, "dt<=0 时保持上一帧输出，不得产生 NaN 或崩溃")
        XCTAssertTrue(out.isFinite)
        let back = f.filter(500, timestamp: 0.5)  // dt < 0
        XCTAssertEqual(back, 100, accuracy: 1e-9, "dt<0 时同样保持上一帧输出，不跳变、不崩溃")
        XCTAssertTrue(back.isFinite)
    }

    func testLargeGapHoldsPreviousOutputInsteadOfLongLine() {
        var f = OneEuroFilter1D(config: OneEuroConfig(maxDeltaT: 0.25))
        _ = f.filter(100, timestamp: 0.0)
        for i in 1..<10 { _ = f.filter(100, timestamp: Double(i) * dt) }
        // 手部丢失 2 秒后在新位置出现：恢复首帧必须保持丢失前的位置（不插值），
        // 下一帧起自动收敛到新位置；跨中断的笔画已被 seal，不会把两段连成一条长线（需求 6.2）。
        let out = f.filter(1400, timestamp: 10.0)
        XCTAssertEqual(out, 100, accuracy: 1e-9,
                       "丢失后恢复首帧必须保持原位置，不得平滑跨越产生长线（需求 6.2）")
    }

    func testNonFiniteInputDoesNotPoisonState() {
        var f = OneEuroFilter1D()
        _ = f.filter(100, timestamp: 0)
        let out = f.filter(Double.nan, timestamp: dt)
        XCTAssertTrue(out.isFinite, "非有限输入不得让输出变成 NaN")
        let next = f.filter(110, timestamp: 2 * dt)
        XCTAssertTrue(next.isFinite)
    }

    // MARK: - 静止抖动抑制

    func testOneEuroReducesStationaryJitter() {
        let noise = makeNoise(20261028, count: 240)
        let base = 700.0
        var raw: [Double] = []
        var filtered: [Double] = []
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0))
        for (i, n) in noise.enumerated() {
            let v = base + n * 6.0          // ±6px 抖动
            let out = f.filter(v, timestamp: Double(i) * dt)
            if i >= 40 { raw.append(v); filtered.append(out) }   // 跳过预热
        }
        let rawStd = std(raw)
        let filteredStd = std(filtered)
        XCTAssertGreaterThan(rawStd, 2.0, "输入抖动应确实存在")
        XCTAssertLessThan(filteredStd, rawStd * 0.75,
                          "静止时应显著抑制抖动：raw=" + String(format: "%.2f", rawStd)
                          + " filtered=" + String(format: "%.2f", filteredStd))
        // 均值不得被滤波器带偏
        XCTAssertEqual(filtered.reduce(0, +) / Double(filtered.count), base, accuracy: 1.5)
    }

    // MARK: - 快速运动滞后

    /// 匀速直线运动的稳态滞后：EMA 固定系数滞后恒定，1€ 随速度升高截止频率从而减小滞后。
    /// 保留为文档性说明，实际断言在下方 `testOneEuroHasLessLagThanLegacyEMAOnFastMotion` 中完成。
    private func steadyStateLagExample(velocity: Double) -> Double {
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0))
        var t = 0.0
        var out = 0.0
        for i in 0..<400 {
            t = Double(i) * dt
            out = f.filter(velocity * t, timestamp: t)
        }
        return abs(velocity * t - out)
    }

    func testOneEuroHasLessLagThanLegacyEMAOnFastMotion() {
        let velocity = 1200.0   // px/s，接近快速划线的量级
        var ema = LegacyEMAFilter2D(alpha: 0.5)
        var one = OneEuroFilter2D(config: OneEuroConfig(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0))
        var t = 0.0
        var emaOut = 0.0, oneOut = 0.0
        for i in 0..<400 {
            t = Double(i) * dt
            let truth = velocity * t
            emaOut = Double(ema.filter(CGPoint(x: truth, y: 0), timestamp: t).x)
            oneOut = Double(one.filter(CGPoint(x: truth, y: 0), timestamp: t).x)
        }
        let emaLag = abs(velocity * t - emaOut)
        let oneLag = abs(velocity * t - oneOut)
        XCTAssertGreaterThan(emaLag, 20,
                             "EMA 滞后应确实存在（实测 " + String(format: "%.1f", emaLag) + "px）")
        XCTAssertLessThan(oneLag, emaLag * 0.6,
                          "1€ 在快速运动时滞后应明显更小：EMA=" + String(format: "%.1f", emaLag)
                          + "px 1€=" + String(format: "%.1f", oneLag) + "px")
        XCTAssertLessThan(steadyStateLagExample(velocity: velocity), emaLag)
    }

    func testHigherBetaTracksFasterButAmplifiesNoise() {
        let noise = makeNoise(777, count: 240)
        func run(beta: Double) -> Double {
            var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0, beta: beta, dCutoff: 1.0))
            var outs: [Double] = []
            for (i, n) in noise.enumerated() {
                let out = f.filter(700 + n * 6.0, timestamp: Double(i) * dt)
                if i >= 40 { outs.append(out) }
            }
            return std(outs)
        }
        let lowBeta = run(beta: 0.005)
        let highBeta = run(beta: 0.20)
        XCTAssertGreaterThan(highBeta, lowBeta,
                             "beta 越大越跟手、静止噪声越大 —— 参数必须实测权衡，不存在通用最优值")
    }

    // MARK: - Legacy EMA 保留

    func testLegacyEMABehaviourIsPreserved() {
        var f = LegacyEMAFilter2D(alpha: 0.5)
        let first = f.filter(CGPoint(x: 100, y: 200), timestamp: 0)
        XCTAssertEqual(first.x, 100, accuracy: 1e-9)
        let second = f.filter(CGPoint(x: 200, y: 200), timestamp: dt)
        XCTAssertEqual(second.x, 150, accuracy: 1e-9, "α=0.5 时应取中点")
    }

    func testLegacyEMAHoldsOnLargeGap() {
        var f = LegacyEMAFilter2D(alpha: 0.5)
        _ = f.filter(CGPoint(x: 0, y: 0), timestamp: 0)
        _ = f.filter(CGPoint(x: 100, y: 0), timestamp: dt)
        let out = f.filter(CGPoint(x: 1200, y: 0), timestamp: 5.0)   // 间隔 5 秒
        XCTAssertEqual(out.x, 50, accuracy: 1e-9, "长间隔后保持上一帧位置，避免拖尾长线")
    }

    func testLegacyEMAResetClearsState() {
        var f = LegacyEMAFilter2D(alpha: 0.5)
        _ = f.filter(CGPoint(x: 50, y: 0), timestamp: 0)
        XCTAssertTrue(f.isInitialized)
        f.reset()
        XCTAssertFalse(f.isInitialized)
        let out = f.filter(CGPoint(x: 900, y: 0), timestamp: 1.0)
        XCTAssertEqual(out.x, 900, accuracy: 1e-9)
    }

    // MARK: - 二维

    func testTwoDimensionalFilterHandlesBothAxes() {
        var f = OneEuroFilter2D(config: OneEuroConfig())
        let p0 = f.filter(CGPoint(x: 10, y: 20), timestamp: 0)
        XCTAssertEqual(p0.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p0.y, 20, accuracy: 1e-9)
        var last = p0
        for i in 1..<100 {
            last = f.filter(CGPoint(x: 10 + Double(i), y: 20), timestamp: Double(i) * dt)
        }
        XCTAssertEqual(last.x, 109, accuracy: 3.0, "恒速运动应基本跟手")
        XCTAssertEqual(last.y, 20, accuracy: 3.0, "静止轴不应被带动")
    }
}

import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 1€ 滤波器专项测试：验证绘画抖动修复的两点核心行为。
///
/// 修复要点：
/// 1. 异常间隔（丢帧/暂停/手部恢复）必须**保持上一帧输出**，不能跳变到原始（带噪）坐标——
///    否则绘画直线在暂停/恢复处会出现折点（"画不直"）。
/// 2. `seed` 重锚落位：恢复后首帧落到已确认位置，不跳变。
/// 3. 降低 `minCutoff` 能抑制静止段抖动（慢漂移框更小），且对移动跟手无影响（beta 补偿）。
final class OneEuroFilterTests: XCTestCase {

    // MARK: - 异常间隔保持（不跳变）

    func testAbnormalDtHoldsPreviousOutput() {
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0, maxDeltaT: 0.25))
        _ = f.filter(100, timestamp: 0.0)   // 首帧：返回原始 100
        _ = f.filter(100, timestamp: 0.1)   // 恒定输入，输出应停留 ~100
        let before = f.filter(100, timestamp: 0.2)
        XCTAssertEqual(before, 100, accuracy: 1e-6)

        // 大间隔（手部恢复/暂停后）：原始坐标跳到 500，但必须保持上一帧输出，不跳变。
        let after = f.filter(500, timestamp: 1.0)
        XCTAssertEqual(after, before, accuracy: 1e-6,
                       "异常间隔帧必须保持上一帧输出，而非跳到原始坐标 500")
    }

    func testLegacyEMAAbnormalDtHoldsPreviousOutput() {
        var f = LegacyEMAFilter2D(alpha: 0.5)
        _ = f.filter(CGPoint(x: 100, y: 100), timestamp: 0.0)
        _ = f.filter(CGPoint(x: 100, y: 100), timestamp: 0.1)
        let before = f.filter(CGPoint(x: 100, y: 100), timestamp: 0.2)
        // 大间隔后原始坐标跳到远处，必须保持而非跳变
        let after = f.filter(CGPoint(x: 900, y: 900), timestamp: 1.0)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
    }

    // MARK: - seed 重锚落位

    func testSeedReseatsWithoutJump() {
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0))
        f.seed(200)
        // 恢复后首帧：原始坐标很远(900)，且间隔很大 -> 必须保持 seed 值 200，不跳变
        let out = f.filter(900, timestamp: 5.0)
        XCTAssertEqual(out, 200, accuracy: 1e-6,
                       "seed 后恢复首帧必须保持落位点，而非跳到原始坐标")
    }

    func testSeedThenNormalTrackingCatchesUp() {
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0, maxDeltaT: 0.25))
        f.seed(200)
        // 连续正常间隔喂入恒定新位置 400，应当平滑收敛到 400（不卡在 200）
        var last = 200.0
        for i in 1...10 {
            last = f.filter(400, timestamp: Double(i) * 0.03)
        }
        XCTAssertEqual(last, 400, accuracy: 1.0,
                       "seed 后正常跟踪应能收敛到目标值")
    }

    // MARK: - 降低 minCutoff 抑制静止抖动（设计依据）

    /// 静止段叠加慢漂移+微噪，较低 minCutoff 应产生更小的输出散布。
    private func restingSpread(minCutoff: Double) -> Double {
        var f = OneEuroFilter1D(config: OneEuroConfig(minCutoff: minCutoff,
                                                      beta: 0.02, dCutoff: 1.0, maxDeltaT: 0.25))
        var outs: [Double] = []
        for i in 0..<200 {
            // 0.27Hz 慢漂移（主因）+ 微小高频噪声
            let noise = sin(Double(i) * 0.05) * 3.0 + ((Double((i * 7) % 13) / 13.0) - 0.5) * 2.0
            outs.append(f.filter(100 + noise, timestamp: Double(i) * 0.03))
        }
        return outs.max()! - outs.min()!
    }

    func testLowerMinCutoffReducesRestingSpread() {
        let high = restingSpread(minCutoff: 1.0)
        let low = restingSpread(minCutoff: 0.5)
        XCTAssertLessThan(low, high,
                          "minCutoff 0.5 的静止散布(\(String(format: "%.2f", low)))应小于 1.0(\(String(format: "%.2f", high)))")
    }
}

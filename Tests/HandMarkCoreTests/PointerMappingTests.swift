import XCTest
import CoreGraphics
@testable import HandMarkCore

/// 固定 ROI 映射与校准的单元测试（阶段 1）。
final class PointerMappingTests: XCTestCase {

    private let screen = CGSize(width: 1512, height: 982)

    private func mapper(mode: MappingMode, roi: MappingROI?) -> PointerMapper {
        PointerMapper(mode: mode, roi: roi, mirrorX: true, flipY: false, screenSize: screen)
    }

    // MARK: - 方向变换

    func testDisplayPointAppliesMirrorAndFlip() {
        let m = mapper(mode: .legacy, roi: nil)
        // Vision 归一化：原点左下、y 向上。mirrorX=true → x 翻转；flipY=false → y 翻转。
        let d = m.displayPoint(visionX: 0.25, visionY: 0.75)
        XCTAssertEqual(d.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(d.y, 0.25, accuracy: 1e-9)
    }

    func testLegacyMappingCoversFullScreen() {
        let m = mapper(mode: .legacy, roi: nil)
        let topLeft = m.map(visionX: 1.0, visionY: 1.0)      // 镜像后 = 显示空间 (0,0)
        let bottomRight = m.map(visionX: 0.0, visionY: 0.0)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
        XCTAssertEqual(bottomRight.x, 1512, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 982, accuracy: 0.001)
    }

    // MARK: - ROI 映射

    func testROIMapsComfortZoneToFullScreen() {
        let roi = MappingROI(minX: 0.30, minY: 0.20, maxX: 0.70, maxY: 0.80,
                             mirrorX: true, flipY: false,
                             screenWidth: 1512, screenHeight: 982)
        let m = mapper(mode: .fixedROI, roi: roi)
        XCTAssertEqual(m.effectiveMode, .fixedROI)

        let tl = m.map(displayPoint: DisplayPoint(x: 0.30, y: 0.20))
        let br = m.map(displayPoint: DisplayPoint(x: 0.70, y: 0.80))
        let mid = m.map(displayPoint: DisplayPoint(x: 0.50, y: 0.50))
        XCTAssertEqual(tl.x, 0, accuracy: 0.001)
        XCTAssertEqual(tl.y, 0, accuracy: 0.001)
        XCTAssertEqual(br.x, 1512, accuracy: 0.001)
        XCTAssertEqual(br.y, 982, accuracy: 0.001)
        XCTAssertEqual(mid.x, 756, accuracy: 0.001)
        XCTAssertEqual(mid.y, 491, accuracy: 0.001)
    }

    func testROIModeClampsInsteadOfExtrapolating() {
        let roi = MappingROI(minX: 0.30, minY: 0.20, maxX: 0.70, maxY: 0.80,
                             mirrorX: true, flipY: false)
        let m = mapper(mode: .fixedROI, roi: roi)
        // ROI 之外一律钳制到边界，不得无界外推（需求 5.3）。
        let far = m.map(displayPoint: DisplayPoint(x: 0.95, y: -0.4))
        XCTAssertEqual(far.x, 1512, accuracy: 0.001)
        XCTAssertEqual(far.y, 0, accuracy: 0.001)
        let near = m.map(displayPoint: DisplayPoint(x: 0.10, y: 1.2))
        XCTAssertEqual(near.x, 0, accuracy: 0.001)
        XCTAssertEqual(near.y, 982, accuracy: 0.001)
    }

    func testROIModeFallsBackToLegacyWhenROIInvalid() {
        let tiny = MappingROI(minX: 0.50, minY: 0.50, maxX: 0.55, maxY: 0.55,
                              mirrorX: true, flipY: false)
        XCTAssertFalse(tiny.isValid)
        let m = mapper(mode: .fixedROI, roi: tiny)
        XCTAssertEqual(m.effectiveMode, .legacy, "ROI 无效时必须回退 Legacy（需求 5.4）")
    }

    func testROIModeFallsBackWhenMirrorFlagDiffers() {
        let roi = MappingROI(minX: 0.2, minY: 0.2, maxX: 0.8, maxY: 0.8,
                             mirrorX: false, flipY: false)   // 标定于 mirrorX=false
        let m = mapper(mode: .fixedROI, roi: roi)            // 运行于 mirrorX=true
        XCTAssertEqual(m.effectiveMode, .legacy, "方向开关变化后标定结果不再适用，必须回退")
    }

    func testROIModeFallsBackWhenROIMissing() {
        let m = mapper(mode: .fixedROI, roi: nil)
        XCTAssertEqual(m.effectiveMode, .legacy, "校准未完成时继续使用原有映射（需求 5.2.6）")
    }

    func testROIRaisesGainComparedToLegacy() {
        let roi = MappingROI(minX: 0.35, minY: 0.25, maxX: 0.65, maxY: 0.75,
                             mirrorX: true, flipY: false)
        let legacy = mapper(mode: .legacy, roi: nil)
        let roiMapper = mapper(mode: .fixedROI, roi: roi)
        XCTAssertGreaterThan(roiMapper.gainX, legacy.gainX * 2,
                             "ROI 放大了增益（代价是噪声同步放大，须配合滤波）")
    }

    // MARK: - 校准器

    private func sample(_ x: Double, _ y: Double) -> DisplayPoint {
        DisplayPoint(x: x, y: y)
    }

    func testCalibratorCollectsFourCornersAndBuildsROI() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        let corners: [(DisplayPoint, DisplayPoint)] = [
            (sample(0.30, 0.20), sample(0.70, 0.20)),
            (sample(0.70, 0.20), sample(0.70, 0.80)),
            (sample(0.30, 0.80), sample(0.70, 0.80)),
            (sample(0.30, 0.20), sample(0.30, 0.80))
        ]
        // 故意打乱顺序提交：实现用包围盒，不应因左右搞反作废整轮校准。
        let order = [sample(0.30, 0.20), sample(0.70, 0.20), sample(0.30, 0.80), sample(0.70, 0.80)]
        XCTAssertTrue(c.isRunning)
        for p in order {
            for _ in 0..<10 { c.addSample(p) }
            XCTAssertTrue(c.commitCurrentCorner(), "样本充足时该角应提交成功")
        }
        XCTAssertTrue(c.isComplete)
        XCTAssertFalse(c.isRunning)
        let roi = c.buildROI(mirrorX: true, flipY: false, screenWidth: 1512, screenHeight: 982)
        XCTAssertNotNil(roi)
        XCTAssertEqual(roi!.minX, 0.30, accuracy: 1e-9)
        XCTAssertEqual(roi!.maxX, 0.70, accuracy: 1e-9)
        XCTAssertEqual(roi!.minY, 0.20, accuracy: 1e-9)
        XCTAssertEqual(roi!.maxY, 0.80, accuracy: 1e-9)
        _ = corners
    }

    func testCalibratorRejectsCornerWithTooFewSamples() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        for _ in 0..<3 { c.addSample(sample(0.3, 0.2)) }
        XCTAssertFalse(c.commitCurrentCorner(), "样本不足必须判失败，不得用抖动帧凑数")
        XCTAssertTrue(c.isRunning, "失败后仍停在当前角，由调用方决定中止或重来")
    }

    func testCalibratorMedianIgnoresOutliers() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        for _ in 0..<9 { c.addSample(sample(0.30, 0.20)) }
        c.addSample(sample(0.95, 0.95))    // 单个跳变帧
        XCTAssertTrue(c.commitCurrentCorner())
        for _ in 0..<10 { c.addSample(sample(0.70, 0.20)) }
        XCTAssertTrue(c.commitCurrentCorner())
        for _ in 0..<10 { c.addSample(sample(0.30, 0.80)) }
        XCTAssertTrue(c.commitCurrentCorner())
        for _ in 0..<10 { c.addSample(sample(0.70, 0.80)) }
        XCTAssertTrue(c.commitCurrentCorner())
        let roi = c.buildROI(mirrorX: true, flipY: false, screenWidth: 1512, screenHeight: 982)
        XCTAssertEqual(roi?.minX ?? -1, 0.30, accuracy: 1e-9, "中位数应吃掉离群帧")
        XCTAssertEqual(roi?.maxY ?? -1, 0.80, accuracy: 1e-9)
    }

    func testCalibratorRejectsDegenerateROI() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        // 四个角几乎重合 → 跨度远小于 minimumSpan
        for _ in 0..<4 {
            for _ in 0..<10 { c.addSample(sample(0.50, 0.50)) }
            _ = c.commitCurrentCorner()
        }
        XCTAssertTrue(c.isComplete)
        XCTAssertNil(c.buildROI(mirrorX: true, flipY: false, screenWidth: 1512, screenHeight: 982),
                     "手部几乎没动的校准必须拒绝，否则增益爆炸")
    }

    func testCalibratorIgnoresOutOfRangeSamples() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        for _ in 0..<6 { c.addSample(sample(-0.2, 1.7)) }   // 越界，应被丢弃
        for _ in 0..<10 { c.addSample(sample(0.30, 0.20)) }
        XCTAssertEqual(c.currentSampleCount, 10, "越界样本不计入")
        XCTAssertTrue(c.commitCurrentCorner())
    }

    func testCalibratorAbortClearsState() {
        var c = ROICalibrator(minSamplesPerCorner: 8)
        c.start()
        for _ in 0..<10 { c.addSample(sample(0.3, 0.2)) }
        _ = c.commitCurrentCorner()
        c.abort()
        XCTAssertFalse(c.isRunning)
        XCTAssertFalse(c.isComplete)
        XCTAssertNil(c.buildROI(mirrorX: true, flipY: false, screenWidth: 1512, screenHeight: 982))
    }

    // MARK: - 笔画封存（阶段 3）

    func testSealPreventsConnectingAcrossTrackingGap() {
        let s = DrawState()
        s.beginStroke(at: CGPoint(x: 10, y: 10))
        s.appendPoint(CGPoint(x: 20, y: 20))
        s.sealStroke()                       // 手部丢失
        s.appendPoint(CGPoint(x: 900, y: 700))  // 手在远处重新出现
        let strokes = s.strokesSnapshot()
        XCTAssertEqual(strokes.count, 2, "封存后必须另起一笔，不得跨越丢失区间连线")
        XCTAssertEqual(strokes[0].points.count, 2)
        XCTAssertEqual(strokes[1].points.count, 1)
    }

    func testAppendBeforeBeginCreatesStroke() {
        let s = DrawState()
        s.appendPoint(CGPoint(x: 1, y: 1))
        s.appendPoint(CGPoint(x: 2, y: 2))
        XCTAssertEqual(s.strokesSnapshot().count, 1, "未起笔时的 append 沿用旧行为：建一条笔画")
        XCTAssertEqual(s.strokesSnapshot()[0].points.count, 2)
    }

    func testBeginResumesAppendingToSameStroke() {
        let s = DrawState()
        s.beginStroke(at: CGPoint(x: 0, y: 0))
        s.appendPoint(CGPoint(x: 5, y: 5))
        s.appendPoint(CGPoint(x: 6, y: 6))
        XCTAssertEqual(s.strokesSnapshot().count, 1)
        XCTAssertEqual(s.strokesSnapshot()[0].points.count, 3)
        XCTAssertFalse(s.isSealed)
    }

    func testSealDoesNotAlterExistingPoints() {
        let s = DrawState()
        s.beginStroke(at: CGPoint(x: 1, y: 1))
        s.appendPoint(CGPoint(x: 2, y: 2))
        let before = s.strokesSnapshot()[0].points
        s.sealStroke()
        XCTAssertEqual(s.strokesSnapshot()[0].points, before, "封存不得改写已有点")
        XCTAssertTrue(s.isSealed)
    }
}

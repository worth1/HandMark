import XCTest
@testable import HandMarkCore

/// 需求 7.1：绘制状态机（Idle / Drawing / TrackingLost）与「不跨越丢失区间连线」。
///
/// 这些规则如果只写在 I/O 层（main.swift）就无法自动化验证；因此把相位放进 DrawState，
/// 用单测锁死行为，I/O 层只负责在正确的时机调用 begin/end/markTrackingLost。
final class DrawStateTrackingTests: XCTestCase {

    private func state() -> DrawState { DrawState() }

    func testInitialPhaseIsIdle() {
        let s = state()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.isSealed, "初始状态必须是已封存：未起笔时任何 append 都不得凭空造点")
    }

    func testBeginStrokeEntersDrawing() {
        let s = state()
        s.beginStroke(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(s.phase, .drawing)
        XCTAssertFalse(s.isSealed)
        s.appendPoint(CGPoint(x: 20, y: 20))
        XCTAssertEqual(s.strokesSnapshot().count, 1, "同一笔画内 append 不得新建笔画")
        XCTAssertEqual(s.strokesSnapshot()[0].points.count, 2)
    }

    func testEndStrokeReturnsToIdleAndSeals() {
        let s = state()
        s.beginStroke(at: CGPoint(x: 0, y: 0))
        s.appendPoint(CGPoint(x: 5, y: 5))
        s.endStroke()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.isSealed)
        // 结束后若还收到 append，只能另起一笔，绝不续写已结束的笔画。
        s.appendPoint(CGPoint(x: 500, y: 500))
        XCTAssertEqual(s.strokesSnapshot().count, 2)
        XCTAssertEqual(s.strokesSnapshot()[0].points.count, 2, "旧笔画不得被续写")
    }

    /// 核心：手部短暂丢失后，恢复时的新坐标**不得**与丢失前的点连成一条线。
    func testTrackingLostSealsAndNeverBridgesTheGap() {
        let s = state()
        s.beginStroke(at: CGPoint(x: 100, y: 100))
        s.appendPoint(CGPoint(x: 110, y: 110))
        s.markTrackingLost()
        XCTAssertEqual(s.phase, .trackingLost)
        XCTAssertTrue(s.isSealed)

        // 手在屏幕另一端重新出现：必须另起一笔（哪怕调用方错误地继续 append）。
        s.appendPoint(CGPoint(x: 1400, y: 900))
        let strokes = s.strokesSnapshot()
        XCTAssertEqual(strokes.count, 2, "丢失后必须另起一笔，不得续写")
        XCTAssertEqual(strokes[0].points.count, 2)
        XCTAssertEqual(strokes[1].points.count, 1)
        // 关键断言：不存在任何一条笔画同时包含丢失前后的坐标（即没有跨越区间的长线）。
        for st in strokes {
            let hasBefore = st.points.contains { $0.x < 200 }
            let hasAfter = st.points.contains { $0.x > 1000 }
            XCTAssertFalse(hasBefore && hasAfter, "不得出现跨越丢失区间的连线：\(st.points)")
        }
    }

    func testRecoveringRequiresExplicitBeginStroke() {
        let s = state()
        s.beginStroke(at: CGPoint(x: 1, y: 1))
        s.markTrackingLost()
        // 仅 append 不足以回到 drawing：必须重新确认起笔（对应「重新确认有效定位」）。
        s.appendPoint(CGPoint(x: 2, y: 2))
        XCTAssertEqual(s.phase, .trackingLost, "未重新起笔前不应回到 drawing")
        s.beginStroke(at: CGPoint(x: 3, y: 3))
        XCTAssertEqual(s.phase, .drawing)
    }

    /// 笔刷快照在起笔时固定：切换只影响新笔画（需求 3.3 / 7.1.6）。
    func testBrushSnapshotIsFrozenPerStroke() {
        let s = state()
        s.beginStroke(at: CGPoint(x: 0, y: 0))
        s.appendPoint(CGPoint(x: 1, y: 1))
        s.endStroke()
        _ = s.cycleBrushColorCounterclockwise()      // 黄 → 蓝
        s.beginStroke(at: CGPoint(x: 2, y: 2))
        let strokes = s.strokesSnapshot()
        XCTAssertEqual(strokes[0].brush.color, .yellow, "历史笔迹不得被改色")
        XCTAssertEqual(strokes[1].brush.color, .blue)
    }

    func testClearAllKeepsBrushSettings() {
        let s = state()
        _ = s.cycleBrushSizeClockwise()               // 中 → 细
        s.beginStroke(at: CGPoint(x: 0, y: 0))
        s.clearAll()
        XCTAssertTrue(s.strokesSnapshot().isEmpty)
        XCTAssertEqual(s.brushSnapshot().size, .fine, "清屏不得重置笔刷设置")
        XCTAssertTrue(s.isSealed)
    }
}

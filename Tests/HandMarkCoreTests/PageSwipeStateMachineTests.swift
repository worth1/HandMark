import XCTest
import CoreGraphics
@testable import HandMarkCore

final class PageSwipeStateMachineTests: XCTestCase {
    private let cfg = PageConfig()  // holdMs=120, swipeWindowMs=400, horizontalThreshold=0.12,
                                    // cooldownMs=600, poseLossToleranceMs=150, holdTraceMaxMs=200
    private func page(_ m: Bool) -> PoseMatch { PoseMatch(matched: m, confidence: 0.9, reliable: true) }
    private func p(_ x: CGFloat, _ y: CGFloat = 0.5) -> CGPoint { CGPoint(x: x, y: y) }

    /// 静态双指手形（无水平位移）永不翻页。
    func testStaticFormNeverFlips() {
        var sm = PageSwipeStateMachine()
        var t = 0.0
        for _ in 0..<60 {  // ~2s，远超 holdMs
            let out = sm.step(page: page(true), refPoint: p(0.5), hasRef: true,
                              suspended: false, handPresent: true, now: t, config: cfg)
            XCTAssertEqual(out, .none, "静态手形不应翻页")
            t += 0.033
        }
    }

    /// 稳定手形 + 向右挥动超阈 → 翻一页（.right），且冷却期内不重复。
    func testRightSwipeFlipsOnce() {
        var sm = PageSwipeStateMachine()
        // 稳定 holdMs 进入 armed（起点 x=0.4）
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        XCTAssertEqual(sm.phase, .armed)
        // 向右挥：x 从 0.4 → 0.6（位移 0.2 > 0.15）
        let out = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(out, .flip(.right))
        XCTAssertEqual(sm.phase, .cooldown)
        // 冷却期内继续同样输入不再翻
        let out2 = sm.step(page: page(true), refPoint: p(0.8), hasRef: true, suspended: false, handPresent: true, now: 0.35, config: cfg)
        XCTAssertEqual(out2, .none, "冷却期不应重复翻页")
    }

    /// 向左挥 → .left。
    func testLeftSwipe() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        let out = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(out, .flip(.left))
    }

    /// 位移不足不翻页。
    func testInsufficientDisplacementNoFlip() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.5), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.5), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        let out = sm.step(page: page(true), refPoint: p(0.58), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(out, .none, "位移 0.08 < 0.15 不翻页")
    }

    /// 竖直为主不翻页（ady > adx）。
    func testVerticalDominantNoFlip() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.4, 0.3), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4, 0.3), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        // dx=0.16(>阈) 但 dy=0.40 远大于 dx → 竖直为主，不翻
        let out = sm.step(page: page(true), refPoint: p(0.56, 0.7), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(out, .none, "竖直位移为主不应翻页")
    }

    /// 冷却结束后需先解除手型才能再次翻页（V4.2：防回摆误翻）。
    func testCanFlipAgainAfterCooldown() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        XCTAssertEqual(sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg), .flip(.right))
        // 冷却结束（>800ms）但手型仍保持 → 进入 waitReset（等待松手，防回摆误翻）
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 1.2, config: cfg)
        XCTAssertEqual(sm.phase, .waitReset)
        // 手型解除（放下双指）→ 回到 idle
        _ = sm.step(page: page(false), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 1.25, config: cfg)
        XCTAssertEqual(sm.phase, .idle)
        // 重新比✌️并稳定 + 挥动 → 可再次翻页
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 1.3, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 1.6, config: cfg)
        XCTAssertEqual(sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 1.65, config: cfg), .flip(.right))
    }

    /// 回归：翻页成功后若手型仍保持、随后发生反向回摆，不应触发反向翻页。
    func testReturnSwingAfterFlipDoesNotReverse() {
        var sm = PageSwipeStateMachine()
        // 稳定 + 向左挥 → 翻一页（.left = 下一页）
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        XCTAssertEqual(sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg), .flip(.left))
        // 冷却结束但手型仍保持 → waitReset
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 1.0, config: cfg)
        XCTAssertEqual(sm.phase, .waitReset)
        // 关键：手型一直保持，期间发生「回摆」向右挥到 0.6（位移 0.2）——不应翻反向页
        let ret = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 1.1, config: cfg)
        XCTAssertEqual(ret, .none, "回摆不应触发反向翻页")
        XCTAssertEqual(sm.phase, .waitReset, "保持手型期间应仍被锁定在 waitReset")
    }

    /// 手形中途失效：**容忍窗内保持 armed**，超出容忍才取消。
    ///
    /// V4.1 行为变更：挥动瞬间 Vision 常有几帧手形抖动，旧逻辑一掉帧就退回 idle，
    /// 用户必须再定住 holdMs 才能重新 armed，表现为「挥了不翻」。现改为容忍 150ms。
    func testFormLostCancelsAfterTolerance() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        XCTAssertEqual(sm.phase, .armed)

        // 失效 50ms：仍在 150ms 容忍窗内 → 不掉出 armed（抖动不该中断这次挥动）
        let during = sm.step(page: page(false), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(during, .none)
        XCTAssertEqual(sm.phase, .armed, "容忍窗内的短暂失效不应取消候选")

        // 失效累计达 150ms → 取消候选
        _ = sm.step(page: page(false), refPoint: p(0.6), hasRef: true, suspended: false, handPresent: true, now: 0.45, config: cfg)
        XCTAssertEqual(sm.phase, .idle)
    }

    /// 「边伸出双指边挥动」：手形确认期内的位移也要计入（V4.1 跟手）。
    ///
    /// 旧逻辑等确认成立后才开始记录起点，确认期那段位移被整段丢弃，用户要多挥一大截。
    func testSwipeDuringHoldCounts() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.50), hasRef: true, suspended: false, handPresent: true, now: 0.00, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.42), hasRef: true, suspended: false, handPresent: true, now: 0.08, config: cfg)
        // 到 0.14s 手形确认成立（holdMs=120）；起点取确认期起点 0.50，总位移 0.14 > 0.12 → 立即翻页
        let out = sm.step(page: page(true), refPoint: p(0.36), hasRef: true, suspended: false, handPresent: true, now: 0.14, config: cfg)
        XCTAssertEqual(out, .flip(.left), "确认期内的挥动位移应被计入，做到挥到即翻")
    }

    /// suspended 取消候选。
    func testSuspendedCancels() {
        var sm = PageSwipeStateMachine()
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(page: page(true), refPoint: p(0.4), hasRef: true, suspended: false, handPresent: true, now: 0.25, config: cfg)
        XCTAssertEqual(sm.phase, .armed)
        _ = sm.step(page: page(true), refPoint: p(0.6), hasRef: true, suspended: true, handPresent: true, now: 0.30, config: cfg)
        XCTAssertEqual(sm.phase, .idle)
    }
}

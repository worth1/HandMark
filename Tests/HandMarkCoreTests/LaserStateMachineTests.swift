import XCTest
import CoreGraphics
@testable import HandMarkCore

final class LaserStateMachineTests: XCTestCase {
    private let cfg = LaserConfig()  // confirmMs=200, lossToleranceMs=200, emaAlpha=0.5
    private func laser(_ m: Bool, _ r: Bool = true) -> PoseMatch { PoseMatch(matched: m, confidence: 0.9, reliable: r) }
    private let mid = CGPoint(x: 0.5, y: 0.6)

    /// idle→candidate→active，确认后输出 .show。
    func testActivatesAfterConfirm() {
        var sm = LaserStateMachine()
        var out = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        XCTAssertEqual(out, .none); XCTAssertEqual(sm.phase, .candidate)
        out = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.1, config: cfg)
        XCTAssertEqual(out, .none); XCTAssertEqual(sm.phase, .candidate)
        out = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.21, config: cfg)
        if case .show = out {} else { XCTFail("确认后应 .show，实际 \(out)") }
        XCTAssertEqual(sm.phase, .active)
    }

    /// 确认前手形消失 → 取消回 idle，无 show。
    func testCancelBeforeConfirm() {
        var sm = LaserStateMachine()
        _ = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        let out = sm.step(laser: laser(false), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.1, config: cfg)
        XCTAssertEqual(out, .none); XCTAssertEqual(sm.phase, .idle)
    }

    private func toActive(_ sm: inout LaserStateMachine) {
        _ = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.0, config: cfg)
        _ = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.21, config: cfg)
        XCTAssertEqual(sm.phase, .active)
    }

    /// active 中手形明确失效（reliable 且 !matched）→ .hide 回 idle。
    func testExitOnFormLost() {
        var sm = LaserStateMachine(); toActive(&sm)
        let out = sm.step(laser: laser(false, true), midTip: mid, hasMidTip: true, suspended: false, handPresent: true, now: 0.3, config: cfg)
        XCTAssertEqual(out, .hide); XCTAssertEqual(sm.phase, .idle)
    }

    /// suspended（清屏优先）→ 立即 .hide。
    func testSuspendedExits() {
        var sm = LaserStateMachine(); toActive(&sm)
        let out = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: true, handPresent: true, now: 0.3, config: cfg)
        XCTAssertEqual(out, .hide); XCTAssertEqual(sm.phase, .idle)
    }

    /// 手部丢失 → 立即 .hide。
    func testHandLossExits() {
        var sm = LaserStateMachine(); toActive(&sm)
        let out = sm.step(laser: laser(true), midTip: mid, hasMidTip: true, suspended: false, handPresent: false, now: 0.3, config: cfg)
        XCTAssertEqual(out, .hide); XCTAssertEqual(sm.phase, .idle)
    }

    /// active 中中指尖短暂丢失（未超容忍）不退出；持续超过容忍才 .hide。
    func testMidTipLossToleranceThenExit() {
        var sm = LaserStateMachine(); toActive(&sm)
        // 短暂丢失（距 active 起点未超 200ms）：不 hide
        let out1 = sm.step(laser: laser(true), midTip: mid, hasMidTip: false, suspended: false, handPresent: true, now: 0.3, config: cfg)
        XCTAssertNotEqual(out1, .hide, "短暂丢失不应退出")
        XCTAssertEqual(sm.phase, .active)
        // 持续丢失超过 lossToleranceMs(200ms)：hide
        let out2 = sm.step(laser: laser(true), midTip: mid, hasMidTip: false, suspended: false, handPresent: true, now: 0.55, config: cfg)
        XCTAssertEqual(out2, .hide); XCTAssertEqual(sm.phase, .idle)
    }
}

//
//  SmokeTests.swift
//  HandMarkCoreTests
//
//  任务 1.4：测试目标骨架 + 冒烟测试。
//
//  目的：
//  1) 验证 HandMarkCoreTests 测试目标可被 `swift test` 发现并运行。
//  2) 顺带锁定设计「关键参数初始取值表」中 PinchConfig / ClearConfig 的默认初值，
//     作为回归护栏（后续若无意改动默认值会被此测试捕获）。
//
//  本文件不包含任何后续具体 Property 的实现测试
//  （2.2/2.3/2.4/2.6/4.4/5.2/5.4/5.5/5.7 的职责），仅为骨架 + 冒烟。
//

import XCTest
@testable import HandMarkCore

final class SmokeTests: XCTestCase {

    /// 锁定 PinchConfig 默认初值（设计关键参数初值表）。
    func testPinchConfigDefaults() {
        let c = PinchConfig()
        XCTAssertEqual(c.pinchOn, 0.22, accuracy: 1e-9)
        XCTAssertEqual(c.pinchOff, 0.35, accuracy: 1e-9)
        XCTAssertEqual(c.pinchConfirmMs, 150, accuracy: 1e-9)
        XCTAssertEqual(c.releaseConfirmMs, 160, accuracy: 1e-9)  // 修复假松开：80→160ms
        XCTAssertEqual(c.minConfidence, 0.3, accuracy: 1e-6)
        XCTAssertEqual(c.lowConfToleranceMs, 200, accuracy: 1e-9)
        XCTAssertEqual(c.emaAlpha, 0.5, accuracy: 1e-9)
    }

    /// 锁定 ClearConfig 默认初值（设计关键参数初值表）。
    /// 注：extHi/extLo/fistCompact 为待实机标定占位，不在本任务锁定范围。
    func testClearConfigDefaults() {
        let c = ClearConfig()
        XCTAssertEqual(c.sixConfirmMs, 180, accuracy: 1e-9)
        XCTAssertEqual(c.sixToFistTimeoutMs, 2000, accuracy: 1e-9)
        XCTAssertEqual(c.fistConfirmMs, 180, accuracy: 1e-9)
        XCTAssertEqual(c.fistLossToleranceMs, 300, accuracy: 1e-9)
        XCTAssertEqual(c.cooldownMs, 800, accuracy: 1e-9)
    }

    /// GestureConfig 默认聚合应委托给各子配置默认值。
    func testGestureConfigDefaultsComposeChildDefaults() {
        let g = GestureConfig()
        XCTAssertEqual(g.pinch.pinchOn, PinchConfig().pinchOn, accuracy: 1e-9)
        XCTAssertEqual(g.clear.sixConfirmMs, ClearConfig().sixConfirmMs, accuracy: 1e-9)
    }

    /// 冒烟：工厂 helper 构造的默认「张开手」场景应可用且自洽。
    func testFactorySmoke() {
        let hand = TestFactories.openHand()
        XCTAssertTrue(hand.hasHand)
        XCTAssertGreaterThan(hand.palmScale, 0)
    }
}

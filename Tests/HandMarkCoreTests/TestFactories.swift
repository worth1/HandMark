//
//  TestFactories.swift
//  HandMarkCoreTests
//
//  任务 1.4：测试辅助工厂（仅存在于测试目标，不污染 HandMarkCore 生产代码）。
//
//  提供便捷构造 FingerFeature / HandMetrics 的 helper，并预置若干典型场景
//  （张开手 / 捏合 / 六 / 握拳 / 手部丢失），供后续 2.x / 5.x 测试快速搭建输入。
//
//  说明：
//  - 坐标沿用 Vision 归一化坐标系（x、y ∈ 0...1，左下原点）。
//  - 这里的场景坐标是「形态上合理」的粗略占位，目的是让各手指呈现可区分的伸展/弯曲
//    几何关系，便于后续姿势分类/状态机测试在此基础上微调；并非实机标定数据。
//  - 所有 helper 参数都带默认值，调用方可只覆盖关心的字段。
//

import Foundation
import CoreGraphics
@testable import HandMarkCore

enum TestFactories {

    // MARK: - 基础构造

    /// 构造单指特征。默认给出一根「竖直伸展」的手指：tip 在最上，mcp 在最下。
    /// 传入 `baseX` 控制该指所在横向位置；`tipY`/`mcpY` 控制纵向跨度。
    static func finger(
        baseX: CGFloat = 0.5,
        tipY: CGFloat = 0.9,
        dipY: CGFloat = 0.78,
        pipY: CGFloat = 0.66,
        mcpY: CGFloat = 0.5,
        confidence: Float = 0.9
    ) -> FingerFeature {
        FingerFeature(
            tip: CGPoint(x: baseX, y: tipY),
            dip: CGPoint(x: baseX, y: dipY),
            pip: CGPoint(x: baseX, y: pipY),
            mcp: CGPoint(x: baseX, y: mcpY),
            minConfidence: confidence
        )
    }

    /// 构造一根「弯曲」手指：tip 回收到接近 pip/mcp 高度（指尖不高于近端关节）。
    static func curledFinger(
        baseX: CGFloat = 0.5,
        mcpY: CGFloat = 0.5,
        confidence: Float = 0.9
    ) -> FingerFeature {
        FingerFeature(
            tip: CGPoint(x: baseX, y: mcpY + 0.04),
            dip: CGPoint(x: baseX, y: mcpY + 0.06),
            pip: CGPoint(x: baseX, y: mcpY + 0.08),
            mcp: CGPoint(x: baseX, y: mcpY),
            minConfidence: confidence
        )
    }

    /// 通用 HandMetrics 构造器：各手指 / 腕 / 标量全部可覆盖，默认拼成一只张开手。
    static func handMetrics(
        thumb: FingerFeature? = nil,
        index: FingerFeature? = nil,
        middle: FingerFeature? = nil,
        ring: FingerFeature? = nil,
        little: FingerFeature? = nil,
        wrist: CGPoint = CGPoint(x: 0.5, y: 0.1),
        palmScale: Double = 120,
        pinchDistanceNorm: Double = 0.8,
        hasHand: Bool = true,
        palmConfidence: Float = 0.9,
        palmAngle: Double = 0,
        hasPalmAngle: Bool = true
    ) -> HandMetrics {
        HandMetrics(
            thumb: thumb ?? finger(baseX: 0.30, tipY: 0.72, dipY: 0.66, pipY: 0.60, mcpY: 0.52),
            index: index ?? finger(baseX: 0.44),
            middle: middle ?? finger(baseX: 0.50, tipY: 0.92),
            ring: ring ?? finger(baseX: 0.56, tipY: 0.88),
            little: little ?? finger(baseX: 0.62, tipY: 0.82),
            wrist: wrist,
            palmScale: palmScale,
            pinchDistanceNorm: pinchDistanceNorm,
            hasHand: hasHand,
            palmConfidence: palmConfidence,
            palmAngle: palmAngle,
            hasPalmAngle: hasPalmAngle
        )
    }

    // MARK: - 典型场景

    /// 张开手：五指伸展，拇指与食指分开（捏合距离大）。
    static func openHand() -> HandMetrics {
        handMetrics(pinchDistanceNorm: 0.8)
    }

    /// 捏合：拇指尖与食指尖靠拢，归一化捏合距离很小（低于 pinchOn=0.22）。
    static func pinchHand(pinchDistanceNorm: Double = 0.12) -> HandMetrics {
        let thumb = finger(baseX: 0.46, tipY: 0.70, dipY: 0.64, pipY: 0.58, mcpY: 0.52)
        let index = finger(baseX: 0.46, tipY: 0.72)
        return handMetrics(thumb: thumb,
                           index: index,
                           pinchDistanceNorm: pinchDistanceNorm)
    }

    /// 六：拇指 + 小指伸展，食/中/无名弯曲。
    static func sixHand() -> HandMetrics {
        handMetrics(
            thumb: finger(baseX: 0.26, tipY: 0.70, dipY: 0.64, pipY: 0.58, mcpY: 0.50),
            index: curledFinger(baseX: 0.44),
            middle: curledFinger(baseX: 0.50),
            ring: curledFinger(baseX: 0.56),
            little: finger(baseX: 0.64, tipY: 0.86),
            pinchDistanceNorm: 0.7
        )
    }

    /// 握拳：五指全部弯曲收拢，指尖跨度小。
    static func fistHand() -> HandMetrics {
        handMetrics(
            thumb: curledFinger(baseX: 0.42),
            index: curledFinger(baseX: 0.46),
            middle: curledFinger(baseX: 0.50),
            ring: curledFinger(baseX: 0.54),
            little: curledFinger(baseX: 0.58),
            pinchDistanceNorm: 0.3
        )
    }

    /// 手部丢失：hasHand=false，标量清零（供「低置信/丢失」分支测试）。
    static func noHand() -> HandMetrics {
        handMetrics(palmScale: 0,
                    pinchDistanceNorm: 0,
                    hasHand: false)
    }
}

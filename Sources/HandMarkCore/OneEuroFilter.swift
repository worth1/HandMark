import Foundation
import CoreGraphics

// MARK: - 1€ Filter（One Euro Filter）
//
// 出处：Casiez, Roussel & Vogel, CHI 2012，《1€ Filter: A Simple Speed-based Low-pass Filter
// for Noisy Input in Interactive Systems》。
//
// 为什么替换固定 EMA：
// - EMA 只有一个固定系数 α，静止时压不住抖动（要压住就得把 α 调小），
//   一动起来又会明显滞后、把转角抹圆 —— 两个目标互相冲突。
// - 1€ Filter 用「速度自适应截止频率」解开这个矛盾：速度低 → 截止频率低 → 强滤波（稳）；
//   速度高 → 截止频率升高 → 弱滤波（跟手）。
//
// 参数含义（均为**调试起点**，最终值必须由实测确定，不存在对所有设备通用的最优值）：
// - minCutoff：最小截止频率（Hz）。越小越稳，静止抖动越小，但起步越"黏"。
// - beta：速度系数。越大越快跟上运动，滞后越小，但快速段噪声越大。
// - dCutoff：速度估计本身的截止频率（Hz），用于平滑速度，避免用噪声速度去调截止频率。
// - maxDeltaT：两次采样间隔超过该值（秒）视为异常（丢帧/暂停/手部丢失），直接重新初始化，
//   避免用旧状态把新旧位置连成一条长线。

public struct OneEuroConfig: Equatable {
    /// 最小截止频率（Hz）。
    public var minCutoff: Double
    /// 速度系数。
    public var beta: Double
    /// 速度估计的截止频率（Hz）。
    public var dCutoff: Double
    /// 采样间隔上限（秒）：超过即重新初始化。
    public var maxDeltaT: Double

    public init(minCutoff: Double = 1.0,
                beta: Double = 0.02,
                dCutoff: Double = 1.0,
                maxDeltaT: Double = 0.25) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.maxDeltaT = maxDeltaT
    }
}

/// 一维 1€ Filter。
public struct OneEuroFilter1D {
    private var config: OneEuroConfig
    private var initialized = false
    private var xPrev: Double = 0
    private var dxPrev: Double = 0
    private var tPrev: Double = 0

    public init(config: OneEuroConfig = OneEuroConfig()) {
        self.config = config
    }

    public var isInitialized: Bool { initialized }

    public mutating func reset() {
        initialized = false
        xPrev = 0
        dxPrev = 0
        tPrev = 0
    }

    /// 低通系数：α = 1 / (1 + τ/dt)，τ = 1 / (2π·fc)。
    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * max(cutoff, 1e-6))
        return 1.0 / (1.0 + tau / dt)
    }

    /// 推入一个新采样。
    /// - Returns: 滤波后的值。首帧、异常间隔、非有限值都会触发重新初始化并返回原始值。
    @discardableResult
    public mutating func filter(_ value: Double, timestamp: Double) -> Double {
        guard value.isFinite, timestamp.isFinite else { return lastOr(value) }

        if !initialized {
            initialized = true
            xPrev = value
            dxPrev = 0
            tPrev = timestamp
            return value
        }
        let dt = timestamp - tPrev
        // 异常间隔（首帧重复时间戳、丢帧、长时间丢失后恢复）：不做平滑，直接重锚。
        if !dt.isFinite || dt <= 0 || dt > config.maxDeltaT {
            xPrev = value
            dxPrev = 0
            tPrev = timestamp
            return value
        }

        let dx = (value - xPrev) / dt
        let ad = alpha(cutoff: config.dCutoff, dt: dt)
        let dxHat = ad * dx + (1 - ad) * dxPrev

        let cutoff = config.minCutoff + config.beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * value + (1 - a) * xPrev

        xPrev = xHat
        dxPrev = dxHat
        tPrev = timestamp
        return xHat
    }

    private func lastOr(_ fallback: Double) -> Double {
        initialized ? xPrev : fallback
    }
}

/// 二维 1€ Filter（x/y 独立滤波，参数共用）。
public struct OneEuroFilter2D {
    private var fx: OneEuroFilter1D
    private var fy: OneEuroFilter1D

    public init(config: OneEuroConfig = OneEuroConfig()) {
        self.fx = OneEuroFilter1D(config: config)
        self.fy = OneEuroFilter1D(config: config)
    }

    public var isInitialized: Bool { fx.isInitialized && fy.isInitialized }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func filter(_ point: CGPoint, timestamp: Double) -> CGPoint {
        CGPoint(x: fx.filter(Double(point.x), timestamp: timestamp),
                y: fy.filter(Double(point.y), timestamp: timestamp))
    }
}

/// 固定系数 EMA（Legacy 滤波，保留用于 A/B 对比）。
public struct LegacyEMAFilter2D {
    public var alpha: Double
    private var value: CGPoint?
    /// 连续异常间隔计数：用于让调用方判断是否需要重置（与 1€ 的 maxDeltaT 语义对齐）。
    public private(set) var lastTimestamp: Double?

    public init(alpha: Double = 0.5) {
        self.alpha = min(1, max(0.01, alpha))
    }

    public var isInitialized: Bool { value != nil }

    public mutating func reset() {
        value = nil
        lastTimestamp = nil
    }

    public mutating func filter(_ point: CGPoint, timestamp: Double) -> CGPoint {
        // 与 1€ 一致：异常间隔（回退/重复/超大间隔）直接重锚，不做平滑跨越。
        if let t = lastTimestamp {
            let dt = timestamp - t
            if !dt.isFinite || dt <= 0 || dt > 0.25 {
                value = point
                lastTimestamp = timestamp
                return point
            }
        }
        lastTimestamp = timestamp
        guard let v = value else {
            value = point
            return point
        }
        let out = CGPoint(x: v.x + (point.x - v.x) * CGFloat(alpha),
                          y: v.y + (point.y - v.y) * CGFloat(alpha))
        value = out
        return out
    }
}

//
//  Metrics.swift
//  HandMarkCore
//
//  V1.1 任务 1.1：纯值类型数据模型。
//
//  本文件只依赖 Foundation 与 CoreGraphics，严禁 import AVFoundation / AppKit / Vision。
//  这些类型是手势判定纯逻辑的输入契约：把 Vision 关键点先降维成值类型特征，
//  从而让状态机/分类层可被 XCTest 单测（@testable import HandMarkCore）。
//
//  坐标约定：所有关键点坐标沿用 Vision 原始归一化坐标系（x、y ∈ 0...1，左下原点），
//  不含任何 EMA 平滑。EMA 平滑只作用于写入 DrawState 的屏幕坐标，二者互不污染。
//

import Foundation
import CoreGraphics

/// 单根手指的归一化特征（由 captureOutput 从 Vision 关键点预先提取，纯值类型）。
///
/// - 坐标 (`tip`/`dip`/`pip`/`mcp`) 为 Vision 原始归一化坐标（0...1，左下原点），不含 EMA。
/// - `minConfidence` 为该指各关节中的最低置信度，参与 `reliable` 判定；
///   低于 `MIN_CONFIDENCE` 的手指不得单独触发清屏。
public struct FingerFeature: Equatable {
    /// 指尖关键点（归一化，左下原点）。
    public var tip: CGPoint
    /// 远端指间关节（DIP）关键点。
    public var dip: CGPoint
    /// 近端指间关节（PIP）关键点。
    public var pip: CGPoint
    /// 掌指关节（MCP）关键点。
    public var mcp: CGPoint
    /// 该指各关节中的最低置信度。
    public var minConfidence: Float
    /// 指尖关键点是否真实可用（Vision 返回且置信度 > 0）。
    ///
    /// 握拳/遮挡时指尖常不可用，此时 `tip` 坐标无意义（可能为零点）。
    /// **缺失点严禁参与任何距离/比值计算**，否则会把几何判据污染成 0 或异常大值
    /// （实测：小指/无名指缺失时收拢度被放大到 1.11，直接卡死握拳判定）。
    public var hasTip: Bool
    /// 掌指关节（MCP）是否真实可用。MCP 是握拳时最稳的参照点。
    public var hasMcp: Bool

    public init(tip: CGPoint,
                dip: CGPoint,
                pip: CGPoint,
                mcp: CGPoint,
                minConfidence: Float,
                hasTip: Bool = true,
                hasMcp: Bool = true) {
        self.tip = tip
        self.dip = dip
        self.pip = pip
        self.mcp = mcp
        self.minConfidence = minConfidence
        self.hasTip = hasTip
        self.hasMcp = hasMcp
    }
}

/// 一帧用于手势判定的纯特征集合（不含任何 Vision / AppKit 类型）。
///
/// - `palmScale`：掌宽像素尺度，已做合理性检查 + 指数平滑后的值，用于归一化距离与伸展度。
/// - `pinchDistanceNorm`：归一化捏合距离（拇指尖↔食指尖 / palmScale）。
///   按不变量 I1，必须由 Vision **原始**归一化坐标计算得出，不受 EMA 平滑影响。
/// - `hasHand`：本帧是否检测到可用手部关键点。
public struct HandMetrics: Equatable {
    /// 拇指特征。
    public var thumb: FingerFeature
    /// 食指特征。
    public var index: FingerFeature
    /// 中指特征。
    public var middle: FingerFeature
    /// 无名指特征。
    public var ring: FingerFeature
    /// 小指特征。
    public var little: FingerFeature
    /// 手腕关键点（归一化，左下原点）。
    public var wrist: CGPoint
    /// 掌宽像素（已做合理性检查 + 平滑后的值）。
    public var palmScale: Double
    /// 原始坐标算出的归一化捏合距离（不变量 I1：不含 EMA）。
    public var pinchDistanceNorm: Double
    /// 原始拇指尖↔食指尖像素距离（未经 palmScale 归一化）。
    /// 作为捏合「真松开」判定的辅助证据：palmScale 突变会放大归一化距离，但原始像素距离不受影响。
    public var pinchDistancePx: Double
    /// 本帧是否检测到可用手部。
    public var hasHand: Bool
    /// 掌部骨架（腕关节 + 各指 MCP）的最低置信度。
    ///
    /// 握拳时蜷曲手指的指尖/DIP 置信度天然很低，不能拿它当「手是否可靠」的判据；
    /// 掌部骨架（wrist + MCP）在握拳时依然可见且稳定，故用它判定可靠性。
    public var palmConfidence: Float
    /// 腕关节指向中指 MCP 的朝向角（弧度），已映射到用户看到的屏幕坐标；正方向为顺时针。
    public var palmAngle: Double
    /// 本帧是否有足够可靠的 wrist / middleMCP 来估算掌心角。
    public var hasPalmAngle: Bool

    public init(thumb: FingerFeature,
                index: FingerFeature,
                middle: FingerFeature,
                ring: FingerFeature,
                little: FingerFeature,
                wrist: CGPoint,
                palmScale: Double,
                pinchDistanceNorm: Double,
                pinchDistancePx: Double = 0,
                hasHand: Bool,
                palmConfidence: Float = 0,
                palmAngle: Double = 0,
                hasPalmAngle: Bool = false) {
        self.thumb = thumb
        self.index = index
        self.middle = middle
        self.ring = ring
        self.little = little
        self.wrist = wrist
        self.palmScale = palmScale
        self.pinchDistanceNorm = pinchDistanceNorm
        self.pinchDistancePx = pinchDistancePx
        self.hasHand = hasHand
        self.palmConfidence = palmConfidence
        self.palmAngle = palmAngle
        self.hasPalmAngle = hasPalmAngle
    }
}

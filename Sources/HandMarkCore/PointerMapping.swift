import Foundation
import CoreGraphics

// MARK: - 指针坐标映射与固定 ROI 校准（V4.0）
//
// 设计要点：
// 1. 本文件只做「纯逻辑」：坐标变换、ROI 有效性判定、校准采样聚合。
//    文件读写、UI 提示、摄像头帧循环一律留在 I/O 层（HandMark/main.swift），便于单测。
// 2. 坐标空间定义（务必与调用方一致）：
//    - **Vision 归一化空间**：`VNRecognizedPoint.location`，原点在**左下**，y 轴向上，x/y ∈ [0,1]。
//    - **显示空间（display）**：原点在**左上**，x 向右、y 向下，x/y ∈ [0,1]。
//      由 Vision 空间经 `(mirrorX ? 1-x : x, flipY ? y : 1-y)` 得到。ROI 存的是这个空间，
//      因为它与「用户在屏幕上看到的左右上下」一一对应，镜像开关变化后不再适用，
//      故 ROI 同时记录标定当时的 mirrorX/flipY，运行时不一致即判为失效（回退 Legacy）。
// 3. ROI 是**固定**的：一旦标定完成，在一次会话内不随手部瞬时位置自动改变
//    （自适应 ROI 不属于本阶段，见需求 8.3）。

/// 显示空间中的一点（左上原点，x 向右、y 向下，均已归一化到 [0,1]）。
public struct DisplayPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 坐标映射模式。
public enum MappingMode: String, Equatable, CaseIterable {
    /// 旧方案：摄像头整幅画面归一化坐标直接映射到全屏。
    case legacy
    /// 新方案：只把标定出的固定活动区域（ROI）放大到全屏。
    case fixedROI
}

/// 固定活动区域（ROI），存于显示空间。
///
/// 四个边界含义：`minX`=左、`maxX`=右、`minY`=上、`maxY`=下（与屏幕方向一致）。
public struct MappingROI: Equatable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double
    /// 标定时的方向开关。运行时不一致说明标定结果已不适用，必须回退 Legacy。
    public var mirrorX: Bool
    public var flipY: Bool
    /// 标定时的屏幕尺寸（点）。仅用于日志与问题追溯，不参与归一化映射计算。
    public var screenWidth: Double
    public var screenHeight: Double

    /// 单轴最小跨度：小于该值说明标定动作幅度太小，放大后会把噪声放大到不可用。
    public static let minimumSpan = 0.15

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double,
                mirrorX: Bool, flipY: Bool,
                screenWidth: Double = 0, screenHeight: Double = 0) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.mirrorX = mirrorX
        self.flipY = flipY
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    /// 是否有效：边界有序、跨度足够、且完全落在 [0,1] 内（外溢出画面说明标定点本身不可信）。
    public var isValid: Bool {
        guard minX >= 0, minY >= 0, maxX <= 1, maxY <= 1 else { return false }
        guard width >= MappingROI.minimumSpan, height >= MappingROI.minimumSpan else { return false }
        return true
    }

    /// 无效原因（用于日志与屏幕提示，避免只说「失败」）。nil 表示有效。
    public var invalidReason: String? {
        if minX < 0 || minY < 0 || maxX > 1 || maxY > 1 { return "标定边界超出画面范围" }
        if width < MappingROI.minimumSpan { return "左右幅度过小（需 ≥ \(Int(MappingROI.minimumSpan * 100))% 画面宽）" }
        if height < MappingROI.minimumSpan { return "上下幅度过小（需 ≥ \(Int(MappingROI.minimumSpan * 100))% 画面高）" }
        return nil
    }
}

/// 指针映射器：Vision 归一化坐标 → 屏幕坐标（点）。
///
/// 两种模式共用同一套方向变换，保证「镜像/翻转」的语义只有一处定义，避免 Legacy 与 ROI 行为不一致。
public struct PointerMapper {

    public var mode: MappingMode
    public var roi: MappingROI?
    public var mirrorX: Bool
    public var flipY: Bool
    public var screenSize: CGSize

    public init(mode: MappingMode = .legacy,
                roi: MappingROI? = nil,
                mirrorX: Bool,
                flipY: Bool,
                screenSize: CGSize) {
        self.mode = mode
        self.roi = roi
        self.mirrorX = mirrorX
        self.flipY = flipY
        self.screenSize = screenSize
    }

    /// Vision 归一化坐标（左下原点）→ 显示空间（左上原点）。镜像/翻转只在这里应用一次。
    public func displayPoint(visionX: Double, visionY: Double) -> DisplayPoint {
        DisplayPoint(x: mirrorX ? 1 - visionX : visionX,
                     y: flipY ? visionY : 1 - visionY)
    }

    /// 当前实际生效的模式：声明为 fixedROI 但 ROI 缺失/失效/方向开关不一致时，自动回退 Legacy。
    public var effectiveMode: MappingMode {
        guard mode == .fixedROI, let roi, roi.isValid else { return .legacy }
        guard roi.mirrorX == mirrorX, roi.flipY == flipY else { return .legacy }
        return .fixedROI
    }

    /// 映射增益（画面 1 个归一化单位对应多少屏幕点）。用于日志对比两种模式的灵敏度。
    public var gainX: Double {
        guard screenSize.width > 0 else { return 0 }
        if effectiveMode == .fixedROI, let roi { return screenSize.width / roi.width }
        return screenSize.width
    }
    public var gainY: Double {
        guard screenSize.height > 0 else { return 0 }
        if effectiveMode == .fixedROI, let roi { return screenSize.height / roi.height }
        return screenSize.height
    }

    /// Vision 归一化坐标 → 屏幕坐标（左上原点，点）。
    ///
    /// - ROI 模式下，落在 ROI 之外的坐标一律**钳制**到屏幕边界（不做任何外推）。
    /// - Legacy 模式同样钳制，保证两种模式都不产生越界坐标。
    public func map(visionX: Double, visionY: Double) -> CGPoint {
        let d = displayPoint(visionX: visionX, visionY: visionY)
        return map(displayPoint: d)
    }

    public func map(displayPoint d: DisplayPoint) -> CGPoint {
        let w = Double(screenSize.width)
        let h = Double(screenSize.height)
        var u = d.x
        var v = d.y
        if effectiveMode == .fixedROI, let roi {
            u = (d.x - roi.minX) / roi.width
            v = (d.y - roi.minY) / roi.height
        }
        // 钳制：不允许无界外推（需求 5.3）。
        u = min(1, max(0, u))
        v = min(1, max(0, v))
        return CGPoint(x: u * w, y: v * h)
    }
}

// MARK: - ROI 校准器（纯逻辑，可单测）

/// 校准四个角：用户把手移到「舒适活动范围」的四个角，而不是屏幕四角。
///
/// 关键区别：若要求指针真的指到屏幕四角，在 Legacy 映射下就必须把手伸到画面边缘——
/// 这正是本方案要消除的问题。因此只要求用户移动到**自己觉得舒服的极限位置**即可。
public enum ROICalibrationCorner: Int, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// 每一步的提示文案（I/O 层显示用）。
    public var prompt: String {
        switch self {
        case .topLeft:     return "①/4 把手移到舒适范围的左上角，保持不动"
        case .topRight:    return "②/4 把手移到舒适范围的右上角，保持不动"
        case .bottomLeft:  return "③/4 把手移到舒适范围的左下角，保持不动"
        case .bottomRight: return "④/4 把手移到舒适范围的右下角，保持不动"
        }
    }
    public var shortName: String {
        switch self {
        case .topLeft: return "左上"; case .topRight: return "右上"
        case .bottomLeft: return "左下"; case .bottomRight: return "右下"
        }
    }
}

public struct ROICalibrator {
    /// 当前正在采集的角；nil 表示未开始或已结束。
    public private(set) var corner: ROICalibrationCorner?
    /// 当前角已采集的样本（显示空间）。
    public private(set) var currentSamples: [DisplayPoint] = []
    /// 已完成的角及其聚合结果（中位点）。
    public private(set) var collected: [DisplayPoint] = []

    /// 单个角所需的最少有效样本数。低于该值说明该角没稳定识别到手，应判失败。
    public var minSamplesPerCorner: Int

    public init(minSamplesPerCorner: Int = 8) {
        self.minSamplesPerCorner = minSamplesPerCorner
    }

    public var isRunning: Bool { corner != nil }
    /// 已完成全部四个角。
    public var isComplete: Bool { collected.count == ROICalibrationCorner.allCases.count }

    public mutating func start() {
        corner = .topLeft
        currentSamples = []
        collected = []
    }

    public mutating func abort() {
        corner = nil
        currentSamples = []
        collected = []
    }

    /// 采集一个样本。仅在某个角正在采集时生效，并要求坐标在 [0,1] 内。
    public mutating func addSample(_ p: DisplayPoint) {
        guard corner != nil else { return }
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return }
        currentSamples.append(p)
    }

    /// 结束当前角并进入下一个角。
    /// - Returns: false 表示样本不足，校准失败（调用方应 abort 并提示用户重来）。
    public mutating func commitCurrentCorner() -> Bool {
        guard let c = corner else { return false }
        guard currentSamples.count >= minSamplesPerCorner else { return false }
        collected.append(median(of: currentSamples))
        currentSamples = []
        corner = ROICalibrationCorner(rawValue: c.rawValue + 1)
        return true
    }

    /// 当前角已采集的样本数（用于 UI 显示进度）。
    public var currentSampleCount: Int { currentSamples.count }

    /// 由四个已完成角生成 ROI。
    ///
    /// 用**所有角样本的 min/max 求包围盒**，而不是假定「左上」一定 x 最小：
    /// 用户在镜像画面下很容易把左右搞反，用包围盒可以避免一次手误就让整轮校准作废。
    /// 跨度过小则判定无效（返回 nil），由调用方提示重来。
    public func buildROI(mirrorX: Bool, flipY: Bool,
                         screenWidth: Double, screenHeight: Double) -> MappingROI? {
        guard isComplete else { return nil }
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in collected {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let roi = MappingROI(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                             mirrorX: mirrorX, flipY: flipY,
                             screenWidth: screenWidth, screenHeight: screenHeight)
        return roi.isValid ? roi : nil
    }

    /// 中位数：比均值更抗抖，避免个别跳变帧把边界带偏。
    private func median(of points: [DisplayPoint]) -> DisplayPoint {
        let xs = points.map { $0.x }.sorted()
        let ys = points.map { $0.y }.sorted()
        let mid = points.count / 2
        if points.count % 2 == 1 {
            return DisplayPoint(x: xs[mid], y: ys[mid])
        }
        return DisplayPoint(x: (xs[mid - 1] + xs[mid]) / 2,
                            y: (ys[mid - 1] + ys[mid]) / 2)
    }
}

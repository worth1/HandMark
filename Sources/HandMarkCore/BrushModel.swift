import Foundation

/// 画笔粗细档位。顺时针旋钮按 `粗 -> 中 -> 细 -> 粗` 循环。
public enum BrushSizeLevel: Int, CaseIterable, Equatable {
    case coarse
    case medium
    case fine

    public var width: Double {
        switch self {
        case .coarse: return 12
        case .medium: return 6
        case .fine: return 2
        }
    }

    public var displayName: String {
        switch self {
        case .coarse: return "粗"
        case .medium: return "中"
        case .fine: return "细"
        }
    }

    public var nextClockwise: BrushSizeLevel {
        switch self {
        case .coarse: return .medium
        case .medium: return .fine
        case .fine: return .coarse
        }
    }
}

/// 画笔颜色。逆时针旋钮按 `黄 -> 蓝 -> 黑 -> 绿 -> 白 -> 黄` 循环。
public enum BrushColorOption: Int, CaseIterable, Equatable {
    case yellow
    case blue
    case black
    case green
    case white

    public var displayName: String {
        switch self {
        case .yellow: return "黄色"
        case .blue: return "蓝色"
        case .black: return "黑色"
        case .green: return "绿色"
        case .white: return "白色"
        }
    }

    public var hex: String {
        switch self {
        case .yellow: return "#FFD84D"
        case .blue: return "#3478F6"
        case .black: return "#1C1C1E"
        case .green: return "#34C759"
        case .white: return "#FFFFFF"
        }
    }

    public var nextCounterclockwise: BrushColorOption {
        switch self {
        case .yellow: return .blue
        case .blue: return .black
        case .black: return .green
        case .green: return .white
        case .white: return .yellow
        }
    }
}

/// 当前画笔设置。每条新笔画在开始时复制一份，保证后续切换不改历史笔迹。
public struct BrushSelection: Equatable {
    public var size: BrushSizeLevel
    public var color: BrushColorOption

    public init(size: BrushSizeLevel = .medium,
                color: BrushColorOption = .yellow) {
        self.size = size
        self.color = color
    }

    @discardableResult
    public mutating func cycleSizeClockwise() -> BrushSizeLevel {
        size = size.nextClockwise
        return size
    }

    @discardableResult
    public mutating func cycleColorCounterclockwise() -> BrushColorOption {
        color = color.nextCounterclockwise
        return color
    }
}

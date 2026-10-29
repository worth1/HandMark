import Foundation

/// 屏幕上一条笔画：坐标 + 起笔时的笔刷快照。
///
/// 笔刷快照在起笔时复制，因此后续旋钮切换只影响新笔画，不会改写历史笔迹的粗细与颜色。
public struct DrawStroke: Equatable {
    public var points: [CGPoint]
    public var brush: BrushSelection

    public init(points: [CGPoint] = [], brush: BrushSelection = BrushSelection()) {
        self.points = points
        self.brush = brush
    }
}

/// 绘制状态机的显式相位（需求 7.1）。
///
/// - `idle`：未绘制。
/// - `drawing`：捏合确认后持续绘制。
/// - `trackingLost`：手部关键点丢失或不可信，已封存当前笔画。
///   从此相位**只能**经 `beginStroke` 回到 `drawing`，且会另起一笔，
///   不允许跨丢失区间续写（不生成跨越丢失区间的异常长线）。
public enum DrawTrackingPhase: Equatable {
    case idle
    case drawing
    case trackingLost
}

/// 线程安全的绘画状态：笔画集合、当前笔刷、指尖与绘制相位。
/// 由后台采集队列写入、主线程渲染读取，全部经 NSLock 保护。
public final class DrawState {
    private let lock = NSLock()
    private var strokes: [DrawStroke] = []
    private var currentBrush = BrushSelection(size: .medium, color: .yellow)
    private var finger: CGPoint?
    private var pinching = false
    /// 当前笔画是否已封存。
    ///
    /// V4.0 新增：手部关键点短暂丢失（TrackingLost）后，绝不能把丢失前后的两段笔迹连成一条线。
    /// 封存之后即使调用方继续 `appendPoint`，也会**新建**一条笔画而不是续写旧笔画 ——
    /// 这样即使 I/O 层因时序问题多发了一次 append，也不会产生跨越丢失区间的长线（需求 7.1.3）。
    private var sealed = true
    private var drawPhase: DrawTrackingPhase = .idle

    public init() {}

    /// 当前绘制相位（Idle / Drawing / TrackingLost）。
    public var phase: DrawTrackingPhase {
        lock.lock(); defer { lock.unlock() }
        return drawPhase
    }

    /// 当前笔画是否已封存（调试/单测用）。
    public var isSealed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    public func beginStroke(at point: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        // 起笔时复制当前笔刷，后续旋钮切换只影响新笔画，不改历史笔迹。
        strokes.append(DrawStroke(points: [point], brush: currentBrush))
        sealed = false
        drawPhase = .drawing
    }

    /// 结束当前笔画（捏合松开）。不改变已有坐标，仅回到 idle 并封存。
    public func endStroke() {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        drawPhase = .idle
    }

    /// 标记追踪丢失：立即封存当前笔画。之后若仍收到 appendPoint，只会另起一笔，
    /// 不会把丢失前后的坐标连成一条线（需求 7.1.3 / 6.2）。
    public func markTrackingLost() {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        if drawPhase == .drawing { drawPhase = .trackingLost }
    }

    public func appendPoint(_ point: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        if sealed || strokes.isEmpty {
            strokes.append(DrawStroke(points: [point], brush: currentBrush))
            sealed = false
        } else {
            strokes[strokes.count - 1].points.append(point)
        }
    }

    /// 封存当前笔画：后续 appendPoint 会另起一笔，不再续写。
    /// 不改变已有数据，因此可以随时安全调用（需求 7.1：不制造虚假轨迹）。
    public func sealStroke() {
        lock.lock(); defer { lock.unlock() }
        sealed = true
    }

    /// 清空全部笔迹。清屏等同于「结束当前笔画」，因此一并封存并回到 idle：
    /// 否则清屏后仍停留在 drawing 相位，后续 append 会悄悄续写一条已被清掉的笔画。
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        strokes.removeAll()
        sealed = true
        drawPhase = .idle
    }

    public func strokesSnapshot() -> [DrawStroke] {
        lock.lock(); defer { lock.unlock() }
        return strokes
    }

    public func brushSnapshot() -> BrushSelection {
        lock.lock(); defer { lock.unlock() }
        return currentBrush
    }

    @discardableResult
    public func cycleBrushSizeClockwise() -> BrushSizeLevel {
        lock.lock(); defer { lock.unlock() }
        return currentBrush.cycleSizeClockwise()
    }

    @discardableResult
    public func cycleBrushColorCounterclockwise() -> BrushColorOption {
        lock.lock(); defer { lock.unlock() }
        return currentBrush.cycleColorCounterclockwise()
    }

    public func setFinger(_ point: CGPoint?) {
        lock.lock(); finger = point; lock.unlock()
    }

    public func fingerSnapshot() -> CGPoint? {
        lock.lock(); defer { lock.unlock() }
        return finger
    }

    public func setPinching(_ value: Bool) {
        lock.lock(); pinching = value; lock.unlock()
    }

    public func isPinching() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pinching
    }
}

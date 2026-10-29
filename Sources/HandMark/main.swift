// HandMark - macOS 隔空绘画（摄像头手势 → 全屏透明画板）
// 摄像头识别手部 → 拇指食指捏合开始绘画，松开停止 → 轨迹叠加在透明全屏窗口上
import AppKit
import AVFoundation
import Vision
import Security
import HandMarkCore

// MARK: - 版本信息（取自 Info.plist，随打包写入）
let appVersionText: String = {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "v\(short) (\(build))"
}()

// MARK: - 可调配置（P0：捏合状态机）
let MIRROR_X = true        // 摄像头画面左右镜像；若手指左右移动与屏幕相反，改为 false
let FLIP_Y = false         // 上下方向开关；若上下仍相反改为 true（同时作用于屏幕轨迹与预览叠层）

// 捏合距离 = 拇指尖↔食指尖距离 / 手掌尺度（掌宽），与摄像头距离、手的大小无关
let PINCH_ON  = 0.22       // 进入「候选」的归一化距离阈值（低于此值才开始计时）
let PINCH_OFF = 0.35       // 结束绘画的归一化距离阈值（高于此值立即松笔，形成滞回）
let PINCH_CONFIRM_MS = 150.0   // 候选持续满足该时长后才真正开始绘画（120~180ms）
// 置信度阈值：实测（夜间/普通室内光）捏合时指尖置信度常在 0.15~0.45，
// 旧值 0.3 会让大量正常帧被判为不可靠 → 频繁跳过写入（不连贯）并在 200ms 后断笔（提前跳出）。
let MIN_CONFIDENCE: Float = 0.15      // 指尖置信度低于此值的帧不写入坐标
let LOW_CONF_DISPLAY: Float = 0.6    // 预览中低于此值的点画成空心灰点（仅视觉区分，不影响绘画）
let LOW_CONF_TOLERANCE_MS = 400.0    // 持续这么久仍不可靠才结束笔画（短暂跳帧不断笔）
// 单帧落笔位移上限：超过该像素数且本帧置信度偏低时，视为异常跳变（指尖识别抖动/瞬时丢失），
// 只跳过不写入、不断笔；置信度高时按「手真的快速划过」处理，照常写入（避免快速画大字时断线）。
let DRAW_MAX_STEP: CGFloat = 220.0

/// 诊断日志用：把可能为 nil 的 Double 格式化为两位小数（nil 显示为「—」）。
private func fmtNum(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    return String(format: "%.2f", v)
}
private func fmtNum(_ v: Double) -> String { String(format: "%.2f", v) }
let DRAW_JUMP_MAX_CONF: Double = 0.5   // 超过位移上限时，低于此置信度才判为异常跳变
let EMA_ALPHA = 0.5        // 指尖位置指数平滑系数（光点与落笔同源；恢复改动前的跟手度）
// 绘画专用再平滑：在光点 EMA 之上对「写入轨迹的点」再做一道更强的低通，吃掉手悬空微颤。
// 落笔死区：相对上一个已记录点移动不足该像素数的帧不记点，只滤「手停住时」的静止抖动。
// 取很小值（1.0），几乎不影响移动跟手；顺滑主要靠渲染层贝塞尔平滑（无滞后）。
let DRAW_MIN_STEP: CGFloat = 1.0

// MARK: - 指尖光点（激光笔观感）
let LASER_HALO_R: CGFloat = 46   // 红色光晕半径（px，屏幕上看到的大光斑大小）
let LASER_CORE_R: CGFloat = 12   // 中心红点半径（px）
let LASER_HALO_DRAW_SCALE: CGFloat = 1.25  // 捏合绘画时光晕/核心放大倍数（落笔反馈）

// MARK: - V3.0 五指旋钮（笔刷粗细 / 颜色）
let KNOB_CONFIRM_MS = 300.0           // 五指张开稳定多久进入旋钮模式
let KNOB_TRIGGER_DEGREES = 30.0       // 每次切换所需的累计旋转角度
let KNOB_ANGLE_EMA_ALPHA = 0.35       // 掌心角度 EMA（吃掉抖动）
let KNOB_MAX_FRAME_DELTA_DEG = 30.0   // 单帧角度跳变阈值（超过不计入旋转，防连跳多档）
let KNOB_JITTER_DEADZONE_DEG = 0.6    // 小于该角度的变化先暂存，攒够再入账（不吃掉慢速旋转）
let KNOB_LOSS_TOLERANCE_MS = 400.0    // 关键点短暂丢失的容忍时间，超时退出旋钮
// 一次激活只切一档：切完进入「已切档」状态，必须收手离开五指张开并持续这么久，
// 才退出旋钮模式；之后需重新五指伸展稳定确认才能再次进入并切换（回程旋转不会被计成反向切换）。
let KNOB_REOPEN_RELEASE_MS = 160.0

// MARK: - V3.0 拇指上下音量
let VOLUME_CONFIRM_MS = 300.0         // 拇指朝上/朝下稳定确认时长（250~350ms）
let VOLUME_COOLDOWN_MS = 500.0        // 两次调节之间的冷却
let VOLUME_STEP_PERCENT = 10          // 每档 10 个百分点

// MARK: - V4.0 全屏可达性与精细绘制：实验开关
//
// 原则（需求六）：每项优化都能单独启用/关闭，保留旧方案作为可比较基线。
// 所有参数都是**调试起点**；不存在对所有摄像头/坐姿通用的最优值，最终值必须由实测确定。

/// 坐标映射模式。`.fixedROI` 在未完成校准或 ROI 失效时会自动回退到 Legacy。
let MAPPING_MODE: MappingMode = .fixedROI

/// 指针滤波模式。
enum PointerFilterMode: Equatable { case legacyEMA, oneEuro }
let POINTER_FILTER_MODE: PointerFilterMode = .oneEuro

/// 1€ Filter 参数（调试起点，见 OneEuroFilter.swift 说明）。
let ONE_EURO_MIN_CUTOFF = 1.0     // 最小截止频率(Hz)：越小越稳，起步越黏
let ONE_EURO_BETA = 0.02          // 速度系数：越大越跟手，快速段噪声越大
let ONE_EURO_D_CUTOFF = 1.0       // 速度估计的截止频率(Hz)
let ONE_EURO_MAX_DELTA_T = 0.25   // 采样间隔上限(秒)：超过即重锚，防跨越丢失区间长线

/// 笔尖定位方案。默认沿用现有「食指尖」；`.pinchMidpoint` 为候选实验（捏合时取拇指尖与食指尖中点，
/// 两点平均可降低单点噪声，但会改变笔尖与手指的相对位置），切换后需重新实测。
enum TipAnchorMode: Equatable { case indexTip, pinchMidpoint }
let TIP_ANCHOR_MODE: TipAnchorMode = .indexTip

/// 追踪中断判定（毫秒）：食指尖连续不可用超过该值即封存当前笔画，
/// 防止手在别处重新出现时把两段笔迹连成一条线。
let TRACKING_SEAL_MS = 120.0
/// 追踪中断超过该值后，恢复时强制重置滤波器（毫秒）。
let TRACKING_RESET_MS = 250.0

/// 调试覆盖层：在预览窗口内画 ROI 边界与实时映射/滤波信息（不影响投影画面）。
let DEBUG_OVERLAY_ENABLED = true

/// 逐帧抖动测量窗口（秒）：每积累 1 秒评估一次「手是否静止」以及滤波前后的抖动量。
///
/// 为什么需要：心跳是 1 Hz 采样，相邻两次心跳的位移包含了真实手部移动，
/// 不能证明「静止漂移」。这里用**逐帧**坐标做评估：若一个窗口内**原始**坐标的包围盒很小，
/// 说明手确实没动，此时**滤波后**坐标的包围盒就是真正的静止漂移量（验收 §10.C）。
let JITTER_WINDOW_SEC = 1.0
/// 判定「手静止」的原始坐标包围盒对角线阈值（px）。
let STATIC_WINDOW_PX = 30.0
/// 一个窗口内至少需要的帧数（帧率过低时统计不可信）。
let STATIC_MIN_FRAMES = 15

/// 校准节奏（秒）：每个角先静置 SETTLE 秒再采集 COLLECT 秒。
let ROI_CALIB_SETTLE_SEC = 1.2
let ROI_CALIB_COLLECT_SEC = 1.0

// MARK: - 手势开关
/// 是否启用「四指伸出 + 拇指收回」的激光手势。
/// V2.1 起默认关闭（已废除）：红色光点改为跟随食指指尖常驻显示，不再需要专门手势触发，
/// 也彻底消除激光手势与捏合绘画的手形重叠导致的抢占问题。
let LASER_GESTURE_ENABLED = false

// MARK: - 手势翻页开关与最近一次状态（供 UI 状态显示）
/// 是否启用「双指（食指+中指）挥动翻页」手势。默认开启；关闭后仅停止手势翻页，
/// 不影响摄像头/绘画/其他手势（摄像头生命周期与绘画共用，不在此关闭）。
var gesturePageEnabled = true
/// 最近一次手势翻页的挥动方向（供状态显示）。
var lastPageFlipDir: PageDirection? = nil
/// 最近一次手势翻页的翻页结果（供状态显示，区分「事件已投递」与「失败/未运行/权限不足」）。
var lastPageFlipResult: PresentationResult? = nil
/// 用于「翻页手形识别态」变化日志（armed/cooldown/idle 之间跳变时打印一次）。
var lastPagePhase: PagePhase = .idle
/// 最近一帧「双指翻页手形」的逐项诊断（供状态条显示与实机标定，nil=当前无手部数据）。
var lastPageDiag: PageDiag? = nil
/// 上一帧双指手形是否命中（仅在命中状态翻转时打日志，避免每帧刷屏）。
var lastPageMatched = false

// MARK: - 捏合状态机
// PinchPhase 已统一由 HandMarkCore 提供（含 V1.1 新增的 releaseCandidate 去抖中间态），
// 此处不再本地另建一套并行定义（需求 1.10）。

/// 一帧的手部数据（供预览与调试显示，主线程消费）
struct HandFrame {
    var image: CGImage?
    var joints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint] = [:]
    var pinchDistance: Double = 0      // 归一化距离（拇指尖↔食指尖 / 掌宽）
    var pinchDistancePx: Double = 0    // 原始像素距离
    var palmScale: Double = 0          // 掌宽（像素）
    var phase: PinchPhase = .idle
    var candidateElapsed: TimeInterval = 0
    var tipConfidence: Double = 0     // 拇指尖/食指尖中较低的置信度
    // V4.0：调试覆盖层用（ROI 边界与实时映射/滤波信息，仅显示在预览窗口内）。
    var roi: MappingROI? = nil
    var debugInfo: String = ""
    // V1.1 阶段4 透传字段（任务 4.3）：清屏/整体预览阶段。
    // 阶段3 captureOutput 尚不接入清屏状态机，故此处默认 nil；
    // 阶段4（task 5.8）协调器接入后给它赋值即可驱动 PreviewStatus。
    var previewPhase: PreviewPhase? = nil

    var hasHand: Bool { !joints.isEmpty }
}

// MARK: - 绘画状态（线程安全）
// 注：DrawState / DrawStroke / BrushSelection 由 HandMarkCore 提供（纯逻辑，可单测），
// 本文件只负责实例化与渲染消费，行为与 V2.1 完全一致。

private func nsColor(for option: BrushColorOption) -> NSColor {
    switch option {
    case .yellow: return NSColor(red: 1.0, green: 216.0 / 255.0, blue: 77.0 / 255.0, alpha: 0.92)
    case .blue: return NSColor(red: 52.0 / 255.0, green: 120.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.92)
    case .black: return NSColor(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 0.96)
    case .green: return NSColor(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0, alpha: 0.92)
    case .white: return NSColor.white
    }
}

// MARK: - 透明全屏覆盖窗口（鼠标键盘事件全部穿透）
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 覆盖层顶部的短暂反馈。窗口本身 ignoresMouseEvents，因此不会阻挡 PPT 或鼠标键盘。
final class OverlayFeedbackView: NSView {
    override var isFlipped: Bool { true }
    var message = ""
    var swatchColor: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        let swatchSize: CGFloat = swatchColor == nil ? 0 : 24
        if let swatchColor {
            let swatchRect = CGRect(x: 16, y: (bounds.height - swatchSize) / 2,
                                    width: swatchSize, height: swatchSize)
            swatchColor.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 6, yRadius: 6).fill()
            // 白色色块使用深色轮廓，浅色背景下仍可确认当前选择。
            (swatchColor == .white ? NSColor.darkGray : NSColor.white.withAlphaComponent(0.75)).setStroke()
            let border = NSBezierPath(roundedRect: swatchRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1.5
            border.stroke()
        }

        let textX: CGFloat = swatchColor == nil ? 16 : 50
        let textRect = CGRect(x: textX, y: 13, width: bounds.width - textX - 16, height: 26)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        (message as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

// MARK: - 覆盖层视图：荧光笔轨迹 + 指尖指示点
final class OverlayView: NSView {
    private let state: DrawState
    private let strokeContainerLayer = CALayer()
    private var strokeLayers: [CAShapeLayer] = []
    private let feedbackView = OverlayFeedbackView(frame: .zero)
    private var feedbackHideWork: DispatchWorkItem?
    // 指尖光点（激光笔观感）：红色大光晕 + 高亮核心，跟随食指指尖常驻显示。
    // 三层叠加：halo（径向渐变大光晕）→ core（实心红点 + 强红投影）→ hot（中心白心，模拟激光笔热点）。
    // 说明：V2.1 起废除「四指伸出+拇指收回」的激光手势，光点改由指尖指示点直接呈现；
    //      捏合绘画时光晕放大，作为「正在落笔」的视觉反馈（原蓝点变红的等价提示）。
    private let laserHaloLayer = CAGradientLayer()
    private let laserCoreLayer = CALayer()
    private let laserHotLayer = CALayer()

    // 关键：图层坐标系必须与「屏幕坐标（左上原点）」一致，否则轨迹会上下颠倒
    override var isFlipped: Bool { true }

    init(frame: CGRect, state: DrawState) {
        self.state = state
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidMoveToWindow() {
        guard window != nil, strokeContainerLayer.superlayer == nil else { return }
        wantsLayer = true
        layer?.isGeometryFlipped = true   // 显式指定左上原点，避免依赖默认约定
        layer?.addSublayer(strokeContainerLayer)
        layer?.addSublayer(laserHaloLayer)
        layer?.addSublayer(laserCoreLayer)
        layer?.addSublayer(laserHotLayer)
        addSubview(feedbackView)
        feedbackView.isHidden = true

        // 指尖光点：红色大光晕 + 实心红核 + 中心高亮白心（激光笔观感）。
        // 光晕用径向渐变：中心不透明红 → 外围透明，半径 LASER_HALO_R（默认 46px）。
        laserHaloLayer.type = .radial
        laserHaloLayer.colors = [
            NSColor(red: 1.0, green: 0.16, blue: 0.10, alpha: 0.95).cgColor,
            NSColor(red: 1.0, green: 0.10, blue: 0.06, alpha: 0.55).cgColor,
            NSColor(red: 1.0, green: 0.06, blue: 0.04, alpha: 0.18).cgColor,
            NSColor(red: 1.0, green: 0.04, blue: 0.02, alpha: 0.0).cgColor
        ]
        laserHaloLayer.locations = [0.0, 0.22, 0.55, 1.0]
        laserHaloLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        laserHaloLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        laserHaloLayer.isHidden = true

        laserCoreLayer.backgroundColor = NSColor(red: 1.0, green: 0.18, blue: 0.10, alpha: 1).cgColor
        laserCoreLayer.cornerRadius = LASER_CORE_R
        laserCoreLayer.shadowColor = NSColor(red: 1.0, green: 0.08, blue: 0.04, alpha: 1).cgColor
        laserCoreLayer.shadowOpacity = 1.0
        laserCoreLayer.shadowRadius = 18
        laserCoreLayer.shadowOffset = .zero
        laserCoreLayer.isHidden = true

        laserHotLayer.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        laserHotLayer.cornerRadius = 5
        laserHotLayer.isHidden = true

        // 光晕轻微呼吸，强化「激光笔」观感（只在显示时可见）。
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.72
        pulse.toValue = 1.0
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .greatestFiniteMagnitude
        laserHaloLayer.add(pulse, forKey: "laserPulse")

        refresh()
    }

    override func layout() {
        super.layout()
        strokeContainerLayer.frame = bounds
        strokeLayers.forEach { $0.frame = bounds }
        let feedbackWidth: CGFloat = min(330, max(220, bounds.width - 40))
        feedbackView.frame = CGRect(x: (bounds.width - feedbackWidth) / 2,
                                    y: 36,
                                    width: feedbackWidth,
                                    height: 52)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let f = state.fingerSnapshot() {
            layoutPointer(at: f, drawing: state.isPinching())
        }
        CATransaction.commit()
    }

    /// 按指尖屏幕坐标摆放光点三层（drawing 时光晕放大，作为正在落笔的反馈）。
    private func layoutPointer(at p: CGPoint, drawing: Bool) {
        let haloR = drawing ? LASER_HALO_R * LASER_HALO_DRAW_SCALE : LASER_HALO_R
        let coreR = drawing ? LASER_CORE_R * LASER_HALO_DRAW_SCALE : LASER_CORE_R
        laserHaloLayer.frame = CGRect(x: p.x - haloR, y: p.y - haloR,
                                      width: haloR * 2, height: haloR * 2)
        laserCoreLayer.cornerRadius = coreR
        laserCoreLayer.frame = CGRect(x: p.x - coreR, y: p.y - coreR,
                                      width: coreR * 2, height: coreR * 2)
        laserHotLayer.frame = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
    }

    // 主线程调用：用当前状态重建路径并更新指示点
    func refresh() {
        guard window != nil else { return }
        let strokes = state.strokesSnapshot()
        while strokeLayers.count < strokes.count {
            let strokeLayer = CAShapeLayer()
            strokeLayer.fillColor = NSColor.clear.cgColor
            strokeLayer.lineCap = .round
            strokeLayer.lineJoin = .round
            strokeLayer.shadowOpacity = 0.7
            strokeLayer.shadowRadius = 4
            strokeLayer.shadowOffset = .zero
            strokeContainerLayer.addSublayer(strokeLayer)
            strokeLayers.append(strokeLayer)
        }
        while strokeLayers.count > strokes.count {
            strokeLayers.removeLast().removeFromSuperlayer()
        }

        for (index, stroke) in strokes.enumerated() {
            let path = CGMutablePath()
            let points = stroke.points
            if let first = points.first {
                if points.count == 1 {
                    // 极短线段配合 round lineCap 渲染为实心圆点。
                    path.move(to: first)
                    path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y + 0.01))
                } else if points.count == 2 {
                    path.move(to: first)
                    path.addLine(to: points[1])
                } else {
                    path.move(to: first)
                    for i in 1..<(points.count - 1) {
                        let ctrl = points[i]
                        let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                                          y: (points[i].y + points[i + 1].y) / 2)
                        path.addQuadCurve(to: mid, control: ctrl)
                    }
                    path.addLine(to: points[points.count - 1])
                }
            }
            let strokeLayer = strokeLayers[index]
            let color = nsColor(for: stroke.brush.color)
            strokeLayer.frame = bounds
            strokeLayer.path = path
            strokeLayer.strokeColor = color.cgColor
            strokeLayer.lineWidth = CGFloat(stroke.brush.size.width)
            strokeLayer.shadowColor = color.cgColor
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let f = state.fingerSnapshot(), !state.isPinching() {
            // 看到食指指尖且未在捏合绘画 → 显示激光式红色光点。
            laserHaloLayer.isHidden = false
            laserCoreLayer.isHidden = false
            laserHotLayer.isHidden = false
            layoutPointer(at: f, drawing: false)
        } else {
            // 手部丢失，或正在捏合绘画 → 隐藏激光点，避免与笔迹/落笔同时显示（用户要求）。
            laserHaloLayer.isHidden = true
            laserCoreLayer.isHidden = true
            laserHotLayer.isHidden = true
        }
        CATransaction.commit()
    }

    /// 显示约 1.4 秒的非阻挡式反馈；重复动作会刷新计时，不堆叠面板。
    func showFeedback(_ message: String, swatch: NSColor? = nil) {
        feedbackHideWork?.cancel()
        feedbackView.message = message
        feedbackView.swatchColor = swatch
        feedbackView.alphaValue = 1
        feedbackView.isHidden = false
        feedbackView.needsDisplay = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.feedbackView.animator().alphaValue = 0
            } completionHandler: {
                self.feedbackView.isHidden = true
                self.feedbackView.alphaValue = 1
            }
        }
        feedbackHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    /// 常驻提示（校准流程用）：不自动隐藏，需显式调用 `hidePrompt`。
    /// 与 `showFeedback` 互斥复用同一块面板，不新增窗口、不阻挡 PPT。
    func showPrompt(_ message: String) {
        feedbackHideWork?.cancel()
        feedbackHideWork = nil
        feedbackView.message = message
        feedbackView.swatchColor = nil
        feedbackView.alphaValue = 1
        feedbackView.isHidden = false
        feedbackView.needsDisplay = true
    }

    func hidePrompt() {
        feedbackHideWork?.cancel()
        feedbackHideWork = nil
        feedbackView.isHidden = true
        feedbackView.alphaValue = 1
    }

    // 注：V2.1 起激光手势已废除，不再有 setLaser/hideLaser 外部驱动；
    //     光点由 refresh() 依据指尖坐标常驻更新，手部丢失时自动隐藏，且不写入 strokes。
}

// MARK: - 控制面板动作
// 合并窗口后仅保留「清除笔迹」与「隐藏预览」两个动作；退出改由菜单栏 NSStatusItem 提供。
final class PanelActions: NSObject {
    let state: DrawState
    let update: () -> Void
    weak var previewWindow: PreviewWindowController?   // 用于「隐藏预览」动作，避免循环强引用
    init(state: DrawState, update: @escaping () -> Void) {
        self.state = state
        self.update = update
    }
    // 清除笔迹：作用于真实 DrawState（刷新真实 OverlayView），而非仅清预览图
    @objc func clear(_ sender: Any?) {
        state.clearAll()
        update()
    }
    // 隐藏预览：隐藏整个预览窗口并停预览图生成（后台识别/绘画继续）
    @objc func togglePreview(_ sender: NSButton) {
        previewWindow?.hide()
    }

    // 阶段 A 独立测试入口：直接调用 PowerPoint 控制服务翻页，不经过手势识别。
    // 结果（成功/未运行/未放映/未授权/脚本错误）由控制服务各自记录日志，便于本机实测定位。
    @objc func devPrevSlide(_ sender: NSButton) {
        log("🧪 [测试按钮] 请求上一页（不经手势）")
        gPresentation.detectTargets()
        let result = gPresentation.previousSlide()
        log("🧪 [测试按钮] 上一页返回：\(result)（\(result.logMessage)）")
    }
    @objc func devNextSlide(_ sender: NSButton) {
        log("🧪 [测试按钮] 请求下一页（不经手势）")
        gPresentation.detectTargets()
        let result = gPresentation.nextSlide()
        log("🧪 [测试按钮] 下一页返回：\(result)（\(result.logMessage)）")
    }
}

// MARK: - 预览状态
enum PreviewStatus {
    case waiting
    case noPermission
    case noDevice
    case error(String)
    case cameraOnNoHand
    case handDetected
    case drawing
    // V1.1 新增（需求 4.4）：六→握拳组合清屏的四个阶段文案
    case clearSixCandidate    // 清屏手势候选（六识别中）
    case clearSixArmed        // 六就绪，等待握拳
    case clearFistCandidate   // 握拳候选
    case clearing             // 正在清屏
    // V2.0 新增：激光 / 翻页
    case laser                // 激光指示中
    case pageArmed            // 翻页候选（双指手形稳定，等待挥动）
    case pageCooldown         // 翻页冷却中
    // V3.0 新增：五指旋钮 / 拇指音量
    case knobCandidate
    case knobActive
    case knobConsumed     // 本次激活已切过一档，需收手后重新张开才能再切
    case volumeCandidate
    case volumeLatched
    // V4.0 手势翻页状态（需求第三/八节）：关闭 / 等待双指 / WPS 未运行 / 权限不足 / 识别+最近一次
    case pageDisabled
    case pageWaiting(PageDiag?)   // 关联值：本帧双指手形的逐项诊断（nil=当前无手部数据）
    case pageWPSNotFound
    case pagePermissionDenied
    case pageFlip(dir: PageDirection?, result: PresentationResult?, armed: Bool, cooldown: Bool)

    var lines: [String] {
        switch self {
        case .waiting: return ["等待摄像头…"]
        case .noPermission: return ["摄像头不可用：权限被拒绝", "系统设置 > 隐私与安全性 > 摄像头 中授权后重启"]
        case .noDevice: return ["摄像头不可用：未找到内置摄像头设备"]
        case .error(let m): return ["摄像头错误：\(m)"]
        case .cameraOnNoHand: return ["摄像头已开启，未识别到手"]
        case .handDetected: return ["已识别到手"]
        case .drawing: return ["正在绘画（拇指与食指捏合）"]
        case .clearSixCandidate: return ["清屏手势候选（六）"]
        case .clearSixArmed: return ["六已就绪 · 请握拳"]
        case .clearFistCandidate: return ["清屏手势候选（握拳）"]
        case .clearing: return ["正在清屏"]
        case .laser: return ["激光指示（已废除，仅保留枚举）"]
        case .pageArmed: return ["翻页候选 · 水平挥动"]
        case .pageCooldown: return ["翻页冷却中"]
        case .knobCandidate: return ["五指旋钮候选"]
        case .knobActive: return ["旋钮模式 · 顺时针粗细 / 逆时针颜色"]
        case .knobConsumed: return ["已切换一档 · 请收手后重新张开再转"]
        case .volumeCandidate: return ["音量手势候选"]
        case .volumeLatched: return ["音量已调节 · 请先退出手势"]
        case .pageDisabled: return ["手势翻页：已关闭", "（可用菜单栏重新开启）"]
        case .pageWaiting(let diag):
            // 第二行显示逐项判定（如「食✓ 中✗ 无✓ 小✓」）：实机能一眼看出卡在哪根手指，
            // 而不是只能看到一句「等待双指」却无从下手。
            if let d = diag { return ["等待双指（食指+中指伸出）", d.summary] }
            return ["等待双指（食指 + 中指伸出）"]
        case .pageWPSNotFound: return ["翻页控制：未找到 WPS / PowerPoint", "请先打开并进入放映"]
        case .pagePermissionDenied: return ["翻页控制：权限不足", "系统设置 > 隐私与安全性 > 辅助功能 中勾选 HandMark"]
        case .pageFlip(let dir, let result, let armed, let cooldown):
            var lines = [armed ? "双指已识别 · 水平挥动" : (cooldown ? "翻页冷却中" : "等待双指（食指+中指伸出）")]
            if let dir = dir, let result = result {
                let dirText = (dir == .left) ? "← 向左 → 下一页" : "→ 向右 → 上一页"
                lines.append("最近：\(dirText)")
                lines.append("结果：\(result.logMessage)")
            }
            return lines
        }
    }
    var color: NSColor {
        switch self {
        case .waiting: return .systemYellow
        case .noPermission, .noDevice, .error: return .systemRed
        case .cameraOnNoHand: return .lightGray
        case .handDetected: return .systemGreen
        case .drawing: return .systemOrange
        case .clearSixCandidate: return .systemCyan
        case .clearSixArmed: return .systemTeal
        case .clearFistCandidate: return .systemCyan
        case .clearing: return .systemRed
        case .laser: return .systemRed
        case .pageArmed: return .systemBlue
        case .pageCooldown: return .systemGray
        case .knobCandidate: return .systemPurple
        case .knobActive: return .systemPurple
        case .knobConsumed: return .systemPurple
        case .volumeCandidate: return .systemIndigo
        case .volumeLatched: return .systemIndigo
        case .pageDisabled: return .systemGray
        case .pageWaiting: return .systemBlue
        case .pageWPSNotFound: return .systemYellow
        case .pagePermissionDenied: return .systemRed
        case .pageFlip: return .systemBlue
        }
    }

    /// PreviewPhase → PreviewStatus 纯映射（任务 4.3）。
    /// 阶段4 协调器接入后，只需给 `HandFrame.previewPhase` 赋值，
    /// 预览即可按此映射显示清屏候选/正在清屏等状态。
    static func from(previewPhase: PreviewPhase) -> PreviewStatus {
        switch previewPhase {
        case .idleHand:        return .handDetected
        case .pinchCandidate:  return .handDetected
        case .drawing:         return .drawing
        case .sixCandidate:    return .clearSixCandidate
        case .sixArmed:        return .clearSixArmed
        case .fistCandidate:   return .clearFistCandidate
        case .clearing:        return .clearing
        case .cooldown:        return .handDetected
        case .laserCandidate:  return .handDetected
        case .laserActive:     return .laser
        case .pageArmed:       return .pageArmed
        case .pageCooldown:    return .pageCooldown
        case .knobCandidate:   return .knobCandidate
        case .knobActive:      return .knobActive
        case .knobConsumed:    return .knobConsumed
        case .volumeCandidate: return .volumeCandidate
        case .volumeLatched:   return .volumeLatched
        }
    }
}

// MARK: - 手势翻页综合状态（需求第三/八节）
/// 融合「开关态 + 翻页目标态 + 识别态 + 最近一次翻页结果」为单一 PreviewStatus 供预览面板显示。
/// 非翻页相位（绘画 / 清屏 / 旋钮等）回退到原 PreviewStatus.from，不破坏既有状态显示。
private func pageGestureStatus(previewPhase: PreviewPhase) -> PreviewStatus {
    guard gesturePageEnabled else { return .pageDisabled }
    // 仅翻页相关相位（含待机/识别中）显示翻页状态；绘画/清屏/旋钮等保持原显示。
    let pageRelated = previewPhase == .pageArmed || previewPhase == .pageCooldown ||
                      previewPhase == .idleHand
    guard pageRelated else { return PreviewStatus.from(previewPhase: previewPhase) }
    switch gPresentation.targetStatus() {
    case .noTarget:       return .pageWPSNotFound
    case .noPermission:   return .pagePermissionDenied
    case .ready:          break
    }
    switch previewPhase {
    case .pageArmed:    return .pageFlip(dir: lastPageFlipDir, result: lastPageFlipResult, armed: true, cooldown: false)
    case .pageCooldown: return .pageFlip(dir: lastPageFlipDir, result: lastPageFlipResult, armed: false, cooldown: true)
    default:
        // idleHand 既可能是「画面里没手」，也可能是「有手但没做任何手势」：
        // 有诊断数据时显示「等待双指 + 逐项判定」，无数据时才显示「未识别到手」。
        if previewPhase == .idleHand {
            return lastPageDiag.map { PreviewStatus.pageWaiting($0) } ?? .cameraOnNoHand
        }
        return .pageFlip(dir: lastPageFlipDir, result: lastPageFlipResult, armed: false, cooldown: false)
    }
}

// MARK: - 预览视图：摄像头画面 + 关键点叠层 + 状态条
final class PreviewView: NSView {
    override var isFlipped: Bool { true }   // 坐标原点改为左上，方便与 Vision 归一化坐标换算

    var status: PreviewStatus = .waiting
    var handFrame = HandFrame()
    /// 当前笔刷（预览右上角常驻显示，含白色色块的深色轮廓以便浅色背景辨识）。
    var brush = BrushSelection()
    /// 绿灯放大模式：整个视图只铺摄像头画面，不画骨架/状态条/笔刷/调试层。
    var cameraOnly = false

    private let statusHeight: CGFloat = 60
    // 五指骨架：手腕 → 掌指 → 近节 → 中节 → 指尖
    private let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
    private let chainColors: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemCyan]

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 绿灯放大模式：整屏只铺摄像头画面（镜像方向与常规预览一致），不加任何叠层。
        if cameraOnly {
            NSColor.black.setFill()
            bounds.fill()
            if let img = handFrame.image {
                ctx.saveGState()
                ctx.translateBy(x: w, y: bounds.height)
                ctx.scaleBy(x: -1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: bounds.height))
                ctx.restoreGState()
            }
            return
        }

        let camH = bounds.height - statusHeight

        // 画面区域
        if let img = handFrame.image {
            ctx.saveGState()
            // 本视图 isFlipped=true（y 轴朝下），画 CGImage 需补一次垂直翻转；
            // 同时做水平镜像，使画面方向与屏幕上的绘画方向一致
            ctx.translateBy(x: w, y: camH)
            ctx.scaleBy(x: -1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: camH))
            ctx.restoreGState()
        } else {
            NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: w, height: camH).fill()
        }

        // 五指关键点叠层
        if handFrame.hasHand { drawSkeleton(width: w, height: camH) }

        // V4.0 调试覆盖层：ROI 边界 + 实时映射/滤波/追踪信息。仅调试 HUD 开启时显示（需求：平时不干扰）。
        if DEBUG_OVERLAY_ENABLED && SHOW_DEBUG_HUD { drawDebugOverlay(width: w, height: camH) }

        // 当前笔刷（右上角常驻磨砂胶囊）
        drawBrushBadge(width: w)

        // 状态条：半透明深色材质 + 顶部细发丝线，避免纯黑硬切块。
        let barRect = CGRect(x: 0, y: camH, width: w, height: statusHeight)
        NSColor(calibratedWhite: 0.10, alpha: 0.78).setFill()
        barRect.fill()
        // 顶部 1px 高光发丝线，制造「面板浮在画面上」的层次。
        NSColor.white.withAlphaComponent(0.08).setFill()
        CGRect(x: 0, y: camH, width: w, height: 1).fill()

        let (lines, color) = displayText
        if SHOW_DEBUG_HUD {
            // 调试模式：保留原两行（状态 + 原始参数），左侧彩色竖条。
            color.setFill()
            CGRect(x: 0, y: camH, width: 4, height: statusHeight).fill()
            for (idx, text) in lines.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: idx == 0 ? 12 : 11),
                    .foregroundColor: idx == 0 ? color : NSColor.lightGray
                ]
                NSAttributedString(string: text, attributes: attrs)
                    .draw(at: CGPoint(x: 12, y: camH + 6 + CGFloat(idx) * 16))
            }
        } else {
            // 精简模式：一个状态圆点 + 一行简短文案，垂直居中。
            let dotR: CGFloat = 5
            let cy = camH + statusHeight / 2
            let dotRect = CGRect(x: 14, y: cy - dotR, width: dotR * 2, height: dotR * 2)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            // 柔和光晕，呼应「呼吸灯」观感。
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -3, dy: -3)).fill()

            let text = lines.first ?? ""
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: 30, y: cy - size.height / 2), withAttributes: attrs)
        }
    }

    /// V4.0 调试覆盖层：ROI 边界与映射/滤波状态。
    ///
    /// 与 `drawSkeleton` 使用同一套坐标换算（预览画面已水平镜像，故显示空间 x 可直接乘宽度），
    /// 保证 ROI 框与实际手部位置对齐。
    private func drawDebugOverlay(width w: CGFloat, height h: CGFloat) {
        if let roi = handFrame.roi {
            let rect = CGRect(x: roi.minX * w, y: roi.minY * h,
                              width: (roi.maxX - roi.minX) * w,
                              height: (roi.maxY - roi.minY) * h)
            NSColor.systemGreen.setStroke()
            let box = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            box.lineWidth = 2
            let dash: [CGFloat] = [5, 3]
            box.setLineDash(dash, count: 2, phase: 0)
            box.stroke()
            let label = "活动区域 ROI"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.systemGreen
            ]
            (label as NSString).draw(at: CGPoint(x: rect.minX + 3, y: rect.maxY - 14),
                                     withAttributes: attrs)
        }

        if !handFrame.debugInfo.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.55)
            ]
            let size = (handFrame.debugInfo as NSString).size(withAttributes: attrs)
            (handFrame.debugInfo as NSString)
                .draw(in: CGRect(x: 6, y: 6, width: min(w - 12, size.width + 4), height: 14),
                      withAttributes: attrs)
        }
    }

    /// 右上角磨砂质感胶囊：实心色点（当前颜色）+ 精简文案（粗细·颜色）。
    private func drawBrushBadge(width w: CGFloat) {
        let text = "\(brush.size.displayName) · \(brush.color.displayName)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let dot: CGFloat = 10
        let padL: CGFloat = 10, gap: CGFloat = 7, padR: CGFloat = 12
        let badgeH: CGFloat = 24
        let totalWidth = padL + dot + gap + size.width + padR
        let badge = CGRect(x: w - totalWidth - 10, y: 10, width: totalWidth, height: badgeH)

        // 磨砂底：半透明深色 + 细边框 + 轻阴影，营造胶囊质感（圆角=高度一半）。
        let radius = badgeH / 2
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            NSColor(calibratedWhite: 0.12, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius).fill()
            ctx.restoreGState()
        }
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()

        // 当前颜色小圆点（呼应「颜色小圆点实时反馈」），白色点加深色描边以便辨识。
        let dotRect = CGRect(x: badge.minX + padL, y: badge.midY - dot / 2, width: dot, height: dot)
        nsColor(for: brush.color).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        (brush.color == .white ? NSColor.gray : NSColor.white.withAlphaComponent(0.6)).setStroke()
        let dotBorder = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
        dotBorder.lineWidth = 1
        dotBorder.stroke()

        let ty = badge.midY - size.height / 2
        (text as NSString).draw(at: CGPoint(x: dotRect.maxX + gap, y: ty), withAttributes: attrs)
    }

    /// 状态文案：第一行状态，第二行调参用原始数值
    private var displayText: ([String], NSColor) {
        // 手势翻页开启时，翻页状态优先：否则只要画面里有手，状态条就会被捏合的
        // 「空闲/绘画中」文案覆盖，用户永远看不到「等待双指」与逐项判定。
        if gesturePageEnabled {
            switch status {
            case .pageDisabled, .pageWaiting, .pageWPSNotFound, .pagePermissionDenied, .pageFlip:
                return (status.lines, status.color)
            default: break
            }
        }
        switch status {
        case .waiting, .noPermission, .noDevice, .error:
            return (status.lines, status.color)
        case .clearSixCandidate, .clearSixArmed, .clearFistCandidate, .clearing:
            // 清屏相关状态（需求 4.4）：第一行直接用 status 文案，
            // 第二行若该帧有手部数据则继续显示 d/px/掌宽/置信度 调试串（需求 4.5）。
            let head = status.lines.first ?? ""
            let f = handFrame
            if f.hasHand {
                let debug = String(format: "d=%.3f (%.0fpx) 掌宽=%.0fpx 置信度=%.2f",
                                   f.pinchDistance, f.pinchDistancePx, f.palmScale, f.tipConfidence)
                return ([head, debug], status.color)
            }
            return (status.lines, status.color)
        default:
            break
        }
        let f = handFrame
        if !f.hasHand {
            // 精简模式只用第一行；措辞改为引导式，而非调试式。
            return (["请把手放到镜头前", "捏合距离=—  状态=空闲"], .systemGray)
        }
        let stateName: String
        let color: NSColor
        switch f.phase {
        case .idle:
            stateName = "空闲"; color = .systemGreen
        case .candidate:
            stateName = "候选 \(Int(f.candidateElapsed * 1000))/\(Int(PINCH_CONFIRM_MS))ms"; color = .systemYellow
        case .drawing:
            stateName = "绘画中（已确认）"; color = .systemOrange
        case .releaseCandidate:
            // 松开去抖中间态：视觉上仍按「绘画中」呈现，避免状态条在抖动时跳变
            stateName = "绘画中（松开去抖）"; color = .systemOrange
        }
        // releaseCandidate 视为仍在绘画态呈现
        let drawingLike = f.phase == .drawing || f.phase == .releaseCandidate
        let head = drawingLike ? "正在绘画（捏合已确认）"
            : (f.phase == .candidate ? "已识别到手 · 捏合候选" : "已识别到手")
        let debug = String(format: "d=%.3f (%.0fpx) 掌宽=%.0fpx 置信度=%.2f 状态=%@",
                           f.pinchDistance, f.pinchDistancePx, f.palmScale, f.tipConfidence, stateName)
        return ([head, debug], color)
    }

    private func drawSkeleton(width w: CGFloat, height h: CGFloat) {
        let joints = handFrame.joints
        for (idx, chain) in chains.enumerated() {
            let color = chainColors[idx]
            var pts: [CGPoint] = []
            for name in chain {
                guard let jp = joints[name] else { continue }
                pts.append(CGPoint(x: (1 - jp.location.x) * w,
                                   y: (FLIP_Y ? jp.location.y : 1 - jp.location.y) * h))
            }
            if pts.count > 1 {
                let path = NSBezierPath()
                path.move(to: pts[0])
                for pt in pts.dropFirst() { path.line(to: pt) }
                color.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            // 关节点
            for name in chain {
                guard let jp = joints[name] else { continue }
                let p = CGPoint(x: (1 - jp.location.x) * w,
                                y: (FLIP_Y ? jp.location.y : 1 - jp.location.y) * h)
                let isTip = name == .thumbTip || name == .indexTip ||
                            name == .middleTip || name == .ringTip || name == .littleTip
                let low = jp.confidence < LOW_CONF_DISPLAY
                let r: CGFloat = isTip ? 5 : 3
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let dot = NSBezierPath(ovalIn: rect)
                if low {
                    // 低置信度：空心灰点，虚线描边
                    NSColor.lightGray.setStroke()
                    dot.lineWidth = 1
                    let dash: [CGFloat] = [2, 2]
                    dot.setLineDash(dash, count: 2, phase: 0)
                    dot.stroke()
                } else {
                    color.setFill()
                    NSColor.white.setStroke()
                    dot.lineWidth = 1.5
                    dot.fill()
                    dot.stroke()
                }
                if isTip {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: 9),
                        .foregroundColor: low ? NSColor.lightGray : NSColor.white
                    ]
                    let label = tipLabel(name)
                    let s = NSString(string: label)
                    let size = s.size(withAttributes: attrs)
                    s.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - r - size.height - 1),
                           withAttributes: attrs)
                }
            }
        }
        // 拇指尖↔食指尖连线：捏合距离的可视化
        if let t = joints[.thumbTip], let i = joints[.indexTip],
           t.confidence >= MIN_CONFIDENCE, i.confidence >= MIN_CONFIDENCE {
            let pt = CGPoint(x: (1 - t.location.x) * w, y: (FLIP_Y ? t.location.y : 1 - t.location.y) * h)
            let pi = CGPoint(x: (1 - i.location.x) * w, y: (FLIP_Y ? i.location.y : 1 - i.location.y) * h)
            let line = NSBezierPath()
            line.move(to: pt); line.line(to: pi)
            let drawingLike = handFrame.phase == .drawing || handFrame.phase == .releaseCandidate
            (drawingLike ? NSColor.systemRed : NSColor.white).setStroke()
            line.lineWidth = drawingLike ? 3 : 1.5
            line.stroke()
        }
    }

    private func tipLabel(_ name: VNHumanHandPoseObservation.JointName) -> String {
        switch name {
        case .thumbTip: return "拇"
        case .indexTip: return "食"
        case .middleTip: return "中"
        case .ringTip: return "无"
        case .littleTip: return "小"
        default: return ""
        }
    }
}

// MARK: - 合并后的「HandMark」预览窗口控制器
// 由原 PreviewController + makeControlPanel 合并重构：单一 NSPanel，顶部摄像头预览（五指 + 状态），
// 底部「清除笔迹 / 隐藏预览」两个按钮。关闭改用标题栏原生交通灯。
// 不额外开启摄像头，复用主程序单路画面。自身作为 NSWindowDelegate，交通灯关闭 = 仅隐藏。
final class PreviewWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    let view: PreviewView
    private let actions: PanelActions

    // 布局常量
    private static let previewWidth: CGFloat = 320
    private static let previewHeight: CGFloat = previewWidth * 9.0 / 16.0 + 60   // 画面 + 状态条
    private static let buttonAreaHeight: CGFloat = 50                            // 底部按钮区（单行浮岛）

    init(screenFrame: CGRect, actions: PanelActions) {
        self.actions = actions
        let w = PreviewWindowController.previewWidth
        let previewH = PreviewWindowController.previewHeight
        let btnH = PreviewWindowController.buttonAreaHeight
        let totalH = previewH + btnH

        // 预览视图尺寸沿用现有（宽 320、9/16 + 60 状态条）；内部 isFlipped=true 的绘制逻辑不改
        view = PreviewView(frame: NSRect(x: 0, y: 0, width: w, height: previewH))

        window = NSPanel(
            contentRect: NSRect(x: 24, y: screenFrame.maxY - totalH - 60, width: w, height: totalH),
            // .closable 必须有（原生红黄绿交通灯关闭）；.utilityWindow 仍保留标题栏按钮。
            // V4.1：补上 .miniaturizable / .resizable —— 缺这两项时黄灯（最小化）与绿灯（缩放）
            // 是灰的、点不动。现在黄灯=最小化、绿灯=摄像头全屏放大/还原（均为自定义行为）。
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        window.title = "HandMark"
        // 预览与面板合一，单级即可：screenSaver + 1（比透明绘图覆盖层 .screenSaver 高一级，
        // 保证控制面板始终压在笔迹之上，而不是被自己画的线挡住）。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        // 关闭交通灯时我们只是 orderOut 隐藏（windowShouldClose 返回 false → terminate），
        // 但显式关掉「关闭即释放」，避免任何路径下窗口对象被提前释放后再被引用。
        window.isReleasedWhenClosed = false
        // 关键修复（全屏置顶）：PPT / Keynote 进入全屏会创建独立的全屏 Space，
        // 默认 NSPanel 只属于创建它的那个普通桌面 Space，于是全屏播放时预览框「消失」——
        // 不是被盖住，而是根本不在那个 Space 里。单纯提高 window.level 无法跨 Space。
        // .canJoinAllSpaces：让面板出现在所有 Space（含切换桌面后）。
        // .fullScreenAuxiliary：允许作为辅助窗口浮在别的 App 的全屏 Space 之上。
        // 这两项与透明绘图覆盖层 OverlayWindow 的配置一致（那层本来就能跨全屏显示），
        // 之所以预览框被盖/消失而绘图层没有，正是因为此前漏配了 collectionBehavior。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        // 让毛玻璃材质透出：窗口本体透明、圆角，但标题栏给一层**不透明深色底**，
        // 使左上角红黄绿三点落在清晰的「标题栏条」上，而不是半透明叠在摄像头画面上（需求：不入侵画面）。
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.title = "HandMark"
        window.appearance = NSAppearance(named: .vibrantDark)

        super.init()
        window.delegate = self

        // 窗口背景改用毛玻璃材质（Dark HUD vibrancy），不再是不透明灰块。
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: totalH))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.autoresizingMask = [.width, .height]

        // 预览视图置于按钮区之上。
        view.frame = NSRect(x: 0, y: btnH, width: w, height: previewH)
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)

        // 底部浮岛式按钮区：清除笔迹 / 隐藏预览（翻页按钮 V4.1 已隐藏，翻页改由手势完成）。
        buttonBar = buildButtonBar(in: effect, width: w, height: btnH)

        window.contentView = effect

        // 捕获红黄绿三点原始位置作为基线，再统一右移 8px（落在标题栏最外层、不入侵画面）。
        captureTrafficLights()
        reassertTrafficLights()
        // 接管黄灯（最小化）与绿灯（全屏预览含手势线）的默认行为。
        bindTrafficLights()
    }

    /// 底部按钮区容器（全屏预览模式下整体隐藏，让画面铺满整个窗口）。
    private var buttonBar: NSView? = nil
    /// 全屏预览前保存的窗口与预览视图原尺寸（精确还原，避免标题栏/圆点错位、画面入侵文字）。
    private var savedWindowFrame: NSRect? = nil
    private var savedViewFrame: NSRect? = nil
    /// 初始化时捕获的红黄绿三点原始位置（作为水平偏移基线；垂直始终跟随系统定位）。
    private var initialTLFrames: [NSWindow.ButtonType: NSRect] = [:]
    private let trafficLightTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    // MARK: - 交通灯：黄灯=最小化，绿灯=全屏预览（含手势线）

    private func bindTrafficLights() {
        // 黄灯（第 2 个）：最小化 → 窗口消失，后台手势识别继续；菜单栏「显示 HandMark」可恢复。
        if let mini = window.standardWindowButton(.miniaturizeButton) {
            mini.target = self
            mini.action = #selector(minimizePanel(_:))
        }
        // 绿灯（第 3 个）：放大 → 全屏显示完整预览（含手势识别线 / 骨架 / 状态）；再点还原。
        if let zoom = window.standardWindowButton(.zoomButton) {
            zoom.target = self
            zoom.action = #selector(toggleFullPreview(_:))
        }
    }

    /// 黄灯：最小化（窗口消失，识别在后台继续；菜单栏「显示 HandMark」可恢复）。
    @objc func minimizePanel(_ sender: Any?) {
        savedWindowFrame = nil
        savedViewFrame = nil
        window.orderOut(nil)
        gTracker?.previewWanted = false
        log("🟡 预览已最小化（后台手势仍在运行；菜单栏「显示 HandMark」可恢复）")
    }

    /// 绿灯：全屏预览（含手势识别线、骨架、笔刷胶囊、状态条）/ 还原。
    @objc func toggleFullPreview(_ sender: Any?) {
        if savedWindowFrame == nil { enterFullPreview() } else { exitFullPreview() }
    }

    /// 进入全屏预览：记录原窗口与预览视图尺寸，隐藏按钮区，窗口铺满当前屏幕。
    private func enterFullPreview() {
        guard savedWindowFrame == nil,
              let screen = window.screen ?? NSScreen.main else { return }
        savedWindowFrame = window.frame
        savedViewFrame = view.frame
        buttonBar?.isHidden = true
        view.cameraOnly = false
        window.setFrame(screen.visibleFrame, display: true, animate: true)
        if let cv = window.contentView { view.frame = cv.bounds }
        reassertTrafficLights()
        view.needsDisplay = true
        log("🟢 已全屏预览（含手势识别线，再点绿灯还原）")
    }

    /// 退出全屏预览：精确还原原窗口尺寸与预览视图布局（避免标题栏/圆点错位、画面入侵文字）。
    private func exitFullPreview() {
        guard let f = savedWindowFrame, let vf = savedViewFrame else { return }
        savedWindowFrame = nil
        savedViewFrame = nil
        window.setFrame(f, display: true, animate: true)
        view.frame = vf
        view.cameraOnly = false
        buttonBar?.isHidden = false
        reassertTrafficLights()
        view.needsDisplay = true
        log("🟢 已还原常规尺寸")
    }

    /// 初始化时捕获红黄绿三点的原始位置（仅作水平偏移基线，垂直始终交给系统定位）。
    private func captureTrafficLights() {
        initialTLFrames.removeAll()
        for t in trafficLightTypes {
            if let b = window.standardWindowButton(t) { initialTLFrames[t] = b.frame }
        }
    }

    /// 把标题栏左上角红黄绿三点整体右移 8px（落在标题栏最外层、不入侵画面）。
    /// 每次窗口尺寸变化（全屏/还原）后都重新执行，避免系统重新布局导致圆点错位。
    private func reassertTrafficLights() {
        for t in trafficLightTypes {
            guard let b = window.standardWindowButton(t), let base = initialTLFrames[t] else { continue }
            var f = b.frame
            f.origin.x = base.origin.x + 8
            b.setFrameOrigin(f.origin)
        }
    }

    /// 构建底部按钮区（容器视图，便于放大模式下整体隐藏）：清除笔迹 / 隐藏预览。
    /// 返回容器本身；V4.1 起翻页按钮不再显示（翻页统一由双指挥动手势完成）。
    @discardableResult
    private func buildButtonBar(in parent: NSView, width w: CGFloat, height h: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bar.autoresizingMask = [.width]
        parent.addSubview(bar)

        // 单行布局（父视图左下原点）：清除笔迹 / 隐藏预览，左右各一个。
        let topY: CGFloat = h - 10 - 30   // 按钮 y（距顶 10）

        // —— 清除笔迹（trash）、隐藏预览（eye.slash），图标 + 完整文字 ——
        let clearBtn = makeIconButton(symbol: "trash", fallback: "清除笔迹",
                                      accessibility: "清除笔迹",
                                      action: #selector(PanelActions.clear(_:)), primary: false)
        clearBtn.title = "清除笔迹"
        clearBtn.imagePosition = .imageLeading
        clearBtn.frame = NSRect(x: 12, y: topY, width: 132, height: 30)
        let hideBtn = makeIconButton(symbol: "eye.slash", fallback: "隐藏预览",
                                     accessibility: "隐藏预览",
                                     action: #selector(PanelActions.togglePreview(_:)), primary: false)
        hideBtn.title = "隐藏预览"
        hideBtn.imagePosition = .imageLeading
        hideBtn.frame = NSRect(x: w - 12 - 132, y: topY, width: 132, height: 30)
        bar.addSubview(clearBtn)
        bar.addSubview(hideBtn)

        // 下排翻页按钮（DEV_PPT_TEST_BUTTONS）：V4.1 默认关闭，手势翻页已可用。
        // 需要独立验证翻页链路时把它改回 true 即可，不影响手势路径。
        if DEV_PPT_TEST_BUTTONS {
            let botY: CGFloat = 10            // 下排按钮 y（距底 10）
            let btnW: CGFloat = 120, gap: CGFloat = 12
            let totalW = btnW * 2 + gap
            let startX = (w - totalW) / 2
            let prevBtn = makeIconButton(symbol: "chevron.left", fallback: "上一页",
                                         accessibility: "上一页",
                                         action: #selector(PanelActions.devPrevSlide(_:)), primary: true)
            prevBtn.title = "上一页"
            prevBtn.imagePosition = .imageLeading
            prevBtn.frame = NSRect(x: startX, y: botY, width: btnW, height: 32)
            let nextBtn = makeIconButton(symbol: "chevron.right", fallback: "下一页",
                                         accessibility: "下一页",
                                         action: #selector(PanelActions.devNextSlide(_:)), primary: true)
            nextBtn.title = "下一页"
            nextBtn.imagePosition = .imageTrailing
            nextBtn.frame = NSRect(x: startX + btnW + gap, y: botY, width: btnW, height: 32)
            bar.addSubview(prevBtn)
            bar.addSubview(nextBtn)
        }
        return bar
    }

    /// 统一的按钮工厂：优先用 SF Symbol，老系统取不到时回退文字。primary=核心动作（更强调）。
    private func makeIconButton(symbol: String, fallback: String, accessibility: String,
                                action: Selector, primary: Bool) -> NSButton {
        let btn = NSButton(title: "", target: actions, action: action)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) {
            let cfg = NSImage.SymbolConfiguration(pointSize: primary ? 13 : 14,
                                                  weight: primary ? .semibold : .regular)
            btn.image = img.withSymbolConfiguration(cfg)
            btn.imagePosition = .imageOnly
        } else {
            btn.title = fallback
        }
        btn.bezelStyle = primary ? .rounded : .texturedRounded
        btn.isBordered = true
        btn.setButtonType(.momentaryPushIn)
        btn.toolTip = accessibility
        if primary { btn.keyEquivalent = "" }   // 不抢回车，避免非 key 窗口歧义
        return btn
    }

    var isVisible: Bool { window.isVisible }
    /// 已刷新到预览窗口的帧数（用于验证画面是否在跑）
    private(set) var appliedFrames = 0
    private(set) var lastImageSize = CGSize.zero

    // 显示：窗口置前并恢复预览图生成。
    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        gTracker?.previewWanted = true
    }
    // 隐藏：隐藏整个窗口并停预览图生成（后台识别/绘画继续）
    func hide() { window.orderOut(nil); gTracker?.previewWanted = false }
    func toggle() { isVisible ? hide() : show() }

    // 交通灯红点关闭 = 退出整个应用（真机需求：点左上角关闭直接退出程序，停止摄像头与后台任务）。
    // 注：隐藏控制窗口但保留后台绘画的能力仍可通过「隐藏预览」按钮达成；菜单栏另有「退出 HandMark」。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    /// 由主摄像头回调驱动（主线程调用）
    func apply(_ frame: HandFrame, status: PreviewStatus? = nil, brush: BrushSelection? = nil) {
        guard isVisible else { return }   // 隐藏时省掉渲染开销
        view.handFrame = frame
        if let status { view.status = status }
        if let brush { view.brush = brush }
        appliedFrames += 1
        if let image = frame.image { lastImageSize = CGSize(width: image.width, height: image.height) }
        view.needsDisplay = true
    }

    func setStatus(_ status: PreviewStatus) {
        view.status = status
        view.needsDisplay = true
        // 摄像头异常时即便窗口被隐藏也要弹出，明确提示原因
        switch status {
        case .noPermission, .noDevice, .error:
            if !isVisible { show() }
        default:
            break
        }
    }
}
// gPreview 保留变量名，类型改为合并后的 PreviewWindowController，captureOutput 等调用点不变
private var gPreview: PreviewWindowController?
// 菜单栏状态项：强引用持有避免释放
private var gStatusItem: NSStatusItem?
private var gStatusActions: StatusItemActions?

// MARK: - 菜单栏（NSStatusItem）动作
// NSMenuItem.target 是 weak，需全局强引用（gStatusActions）持有。
final class StatusItemActions: NSObject {
    weak var previewWindow: PreviewWindowController?
    init(previewWindow: PreviewWindowController?) {
        self.previewWindow = previewWindow
    }
    // 显示 HandMark 预览窗口：重新显示窗口并恢复预览图生成
    @objc func showPreviewWindow(_ sender: Any?) {
        previewWindow?.show()
    }
    // 退出 HandMark：真正停止摄像头会话与后台任务
    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    // V4.0：开始固定 ROI 校准（提示会出现在屏幕顶部，不弹窗、不抢焦点）
    @objc func startCalibration(_ sender: Any?) {
        gTracker?.startCalibration()
    }
    // V4.0：丢弃标定结果，回到「整幅画面 → 全屏」的 Legacy 映射
    @objc func resetCalibration(_ sender: Any?) {
        gTracker?.resetCalibration()
    }
    // 启用手势翻页开关：切换全局 gesturePageEnabled；关闭时仅停手势翻页，
    // 不影响摄像头/绘画/其他手势（协调器据此把翻页状态机停在 idle）。
    @objc func toggleGesturePage(_ sender: NSMenuItem) {
        gesturePageEnabled.toggle()
        sender.state = gesturePageEnabled ? .on : .off
        log("🖐 手势翻页开关：\(gesturePageEnabled ? "已启用" : "已关闭")")
    }
}

/// 创建菜单栏状态项（图标 + 两项菜单：显示 / 退出）
func makeStatusItem(previewWindow: PreviewWindowController) -> NSStatusItem {
    let actions = StatusItemActions(previewWindow: previewWindow)
    gStatusActions = actions   // NSMenuItem.target 是 weak，必须持有

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    applyMenuBarIcon(to: item.button)

    let menu = NSMenu()
    let showItem = NSMenuItem(title: "显示 HandMark 窗口",
                              action: #selector(StatusItemActions.showPreviewWindow(_:)), keyEquivalent: "")
    showItem.target = actions
    let pageItem = NSMenuItem(title: "启用手势翻页",
                              action: #selector(StatusItemActions.toggleGesturePage(_:)),
                              keyEquivalent: "")
    pageItem.target = actions
    pageItem.state = gesturePageEnabled ? .on : .off
    let quitItem = NSMenuItem(title: "退出 HandMark",
                              action: #selector(StatusItemActions.quit(_:)), keyEquivalent: "q")
    quitItem.target = actions
    let calibItem = NSMenuItem(title: "校准活动区域（4 步）",
                               action: #selector(StatusItemActions.startCalibration(_:)),
                               keyEquivalent: "")
    calibItem.target = actions
    let resetItem = NSMenuItem(title: "重置为全画面映射",
                               action: #selector(StatusItemActions.resetCalibration(_:)),
                               keyEquivalent: "")
    resetItem.target = actions
    menu.addItem(showItem)
    menu.addItem(pageItem)
    menu.addItem(calibItem)
    menu.addItem(resetItem)
    menu.addItem(.separator())
    menu.addItem(quitItem)
    item.menu = menu
    return item
}

/// 按系统当前外观（浅色/深色）为菜单栏状态项设置对应图标：
/// - 深色菜单栏 → MenuBarIconDark.png（navy 底 + 白手势）
/// - 浅色菜单栏 → MenuBarIconLight.png（浅底 + navy 手势）
/// 图标由设计稿导出、圆角四角已置为透明，故直接以彩色图显示（不作 template）。
private func applyMenuBarIcon(to button: NSStatusBarButton?) {
    guard let button = button else { return }
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let name = isDark ? "MenuBarIconDark" : "MenuBarIconLight"
    if let url = Bundle.main.url(forResource: name, withExtension: "png"),
       let img = NSImage(contentsOf: url) {
        img.size = NSSize(width: 20, height: 20)
        img.isTemplate = false
        button.image = img
        button.title = ""
    } else {
        button.title = "✋"
    }
    button.toolTip = "HandMark"
}

/// 系统浅色/深色外观切换时，刷新菜单栏图标。
private func observeAppearanceForMenuBarIcon() {
    NotificationCenter.default.addObserver(
        forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
        object: nil, queue: .main) { [weak gStatusItem] _ in
        applyMenuBarIcon(to: gStatusItem?.button)
    }
}

// MARK: - 固定 ROI 标定结果的持久化
// 存 JSON 文件而不是 UserDefaults：本程序以可执行目标运行，不依赖 Info.plist 的 bundle id，
// 路径：优先走系统目录 API，沙盒（App Store 版）会自动解析到容器内，非沙盒版即 ~/Library/...
//（旧实现硬编码 NSHomeDirectory()，在 App Store 沙盒版下会被拒绝写入 → 日志与标定全丢）。
final class ROIStore {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
        let dir = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("HandMark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("roi.json")
    }()

    static func load() -> MappingROI? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MappingROI.self, from: data)
    }

    @discardableResult
    static func save(_ roi: MappingROI) -> Bool {
        guard let data = try? JSONEncoder().encode(roi) else { return false }
        do {
            try data.write(to: fileURL)
            return true
        } catch {
            log("❌ ROI 保存失败：\(error.localizedDescription)")
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 摄像头 + Vision 手部追踪
// 必须持有强引用：AVCaptureVideoDataOutput 的 delegate 是 weak，且 Timer 用到了 self
private var gTracker: HandTracker?
private var gPanelActions: PanelActions?
// V2.0：透明覆盖层（激光光点绘制）与翻页键盘事件发送器的全局引用。
private weak var gOverlay: OverlayView?
private let gPageFlipper = PageFlipper()
// PPT 翻页默认机制：AppleScript 控制「正在放映」的 PowerPoint（不依赖键盘焦点、不切前台窗口）。
// CGEvent（gPageFlipper）暂时保留，但默认关闭自动回退：权限/放映/脚本错误各自返回并记录，不静默兜底。
// 双演示软件统一控制器（PowerPoint + WPS）。测试按钮经此调用；暂不接入手势。
private let gPresentation = PresentationController()
private let gSystemVolume = SystemVolumeController()

// 开发期临时开关：在预览面板上显示「上一页 / 下一页」按钮，直接调用演示控制服务，
// 不经过任何手势识别（阶段 A 独立验证）。
//
// V4.1：双指挥动翻页已实测可用且稳定，按用户要求**隐藏面板上的翻页按钮**，
// 翻页统一由手势完成；下方 devPrevSlide/devNextSlide 方法保留（仍可供调试/快捷键复用）。
let DEV_PPT_TEST_BUTTONS = false

// 调试 HUD 总开关：开启时状态条显示第二行原始参数（捏合距离/掌宽/置信度）并画 ROI/调试覆盖层；
// 关闭时走「精简优雅」呈现——状态条只留一行带状态圆点的简短文案，不显示调参数字（正式观感）。
// 需要实机标定时临时改回 true 即可，数据链路本身不受影响。
let SHOW_DEBUG_HUD = false

// MARK: - PPT 翻页：系统方向键事件发送器（CGEvent）
// 向当前前台演示应用发送 ← / → 方向键。需「辅助功能」权限；无权限时不假装成功，只记录失败。
final class PageFlipper {
    /// 左方向键 keycode = 123，右方向键 = 124（macOS 虚拟键码）。
    private let leftKey: CGKeyCode = 123
    private let rightKey: CGKeyCode = 124

    /// 当前是否具备发送按键事件所需的辅助功能权限（只读，不弹窗）。
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 发送一次方向键（按下+抬起）。返回是否成功发送（无权限或事件创建失败则 false）。
    @discardableResult
    func flip(_ direction: PageDirection) -> Bool {
        guard hasAccessibilityPermission else {
            log("⚠️ 翻页失败：缺少辅助功能权限（系统设置 > 隐私与安全性 > 辅助功能，勾选 HandMark）")
            return false
        }
        let key = (direction == .left) ? leftKey : rightKey
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else {
            log("⚠️ 翻页失败：无法创建键盘事件")
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("⌨️ 翻页：\(direction == .left ? "← 上一页" : "→ 下一页")（事件已发送）")
        return true
    }
}

final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let state: DrawState
    private let update: () -> Void
    private let screenSize: CGSize
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "handmark.camera", qos: .userInteractive)
    private let ciContext = CIContext()
    // MARK: - V4.0：坐标映射 / 指针滤波 / 固定 ROI 校准
    private lazy var mapper = PointerMapper(mode: MAPPING_MODE,
                                            roi: ROIStore.load(),
                                            mirrorX: MIRROR_X,
                                            flipY: FLIP_Y,
                                            screenSize: screenSize)
    private lazy var oneEuro = OneEuroFilter2D(config: OneEuroConfig(
        minCutoff: ONE_EURO_MIN_CUTOFF,
        beta: ONE_EURO_BETA,
        dCutoff: ONE_EURO_D_CUTOFF,
        maxDeltaT: ONE_EURO_MAX_DELTA_T))
    private var legacyEMA = LegacyEMAFilter2D(alpha: EMA_ALPHA)
    private var calibrator = ROICalibrator(minSamplesPerCorner: 8)
    private var calibrationStepStart: TimeInterval = 0
    /// 食指尖连续不可用的起始时间；nil 表示当前指尖可用（追踪正常）。
    private var tipGapSince: TimeInterval? = nil
    private var trackingLostCount = 0     // 追踪中断次数（用于日志与验收）
    private var trackingSealCount = 0     // 因中断而封存笔画的次数
    private var filterResetCount = 0      // 滤波器重锚次数
    // MARK: 逐帧抖动 / 静止窗口测量（验收 §10.C，全部在 videoQueue 内更新）
    private var jitterRaw: [CGPoint] = []
    private var jitterFiltered: [CGPoint] = []
    private var jitterPalm: [Double] = []     // 同步记录掌宽：用于评估「远近变化是否造成映射增益漂移」（阶段 4）
    private var jitterWindowStart: TimeInterval? = nil
    private var staticWindowCount = 0     // 判定为「手静止」的窗口数
    private var staticDriftSum = 0.0      // 静止窗口内滤波后漂移量累计（px）
    private var staticDriftMax = 0.0
    private var lastFrameJitterRaw = 0.0  // 最近一秒：原始坐标的平均帧间位移（px/帧）
    private var lastFrameJitterFiltered = 0.0

    private var smoothed: CGPoint?       // 光点/落笔坐标 EMA（同源）
    // 仅用于日志验证
    private var frameCount = 0
    private var handSeen = false
    private var lastDist = 0.0
    private var lastTip = CGPoint.zero
    /// 预览窗口是否需要画面帧（主线程设置，隐藏后置 false 以省开销）
    var previewWanted = true
    // 手势优先级协调器（来自 HandMarkCore 的纯逻辑协调器，聚合捏合 + 六→握拳清屏，时间显式注入）。
    // 阶段4 以此替换阶段1 单独调用的 PinchStateMachine；捏合相位经 coordinator.pinch.phase 读取，
    // 清屏相位经 coordinator.clear.phase 读取（用于日志/预览）。
    private var coordinator: GesturePriorityCoordinator = {
        var c = GesturePriorityCoordinator()
        c.laserEnabled = LASER_GESTURE_ENABLED   // V2.1：激光手势已废除（光点改为指尖常驻）
        return c
    }()
    // 手势参数：由顶部现有可调常量映射构造，保证与现有捏合行为一致；
    // clear 取 ClearConfig() 默认值（几何阈值 extHi/extLo/fistCompact 留阶段5 实机标定）。
    // releaseConfirmMs 为 V1.1 新增的松开去抖窗（PinchConfig 默认值，现有为单帧立即结束）。
    private let config = GestureConfig(
        pinch: PinchConfig(
            pinchOn: PINCH_ON,
            pinchOff: PINCH_OFF,
            pinchConfirmMs: PINCH_CONFIRM_MS,
            minConfidence: MIN_CONFIDENCE,
            lowConfToleranceMs: LOW_CONF_TOLERANCE_MS,
            emaAlpha: EMA_ALPHA
        ),
        clear: ClearConfig(),
        knob: KnobConfig(confirmMs: KNOB_CONFIRM_MS,
                         triggerDegrees: KNOB_TRIGGER_DEGREES,
                         emaAlpha: KNOB_ANGLE_EMA_ALPHA,
                         maxFrameDeltaDegrees: KNOB_MAX_FRAME_DELTA_DEG,
                         jitterDeadZoneDegrees: KNOB_JITTER_DEADZONE_DEG,
                         lossToleranceMs: KNOB_LOSS_TOLERANCE_MS,
                         reopenReleaseMs: KNOB_REOPEN_RELEASE_MS),
        volume: VolumeGestureConfig(confirmMs: VOLUME_CONFIRM_MS, cooldownMs: VOLUME_COOLDOWN_MS)
    )
    private var lastDistPx = 0.0
    private var lastPalmScale = 0.0
    private var lastTipConfidence: Double = 0
    /// V4.0：当前笔尖锚点的置信度（用于调试覆盖层与追踪可信度判定）。
    private var lastAnchorConfidence: Double = 0
    private var lastWritten: CGPoint?   // 最近写入轨迹的点（用于诊断末段跳变）
    private var prevWritten: CGPoint?
    private var palmScaleSmoothed: Double = 0    // 手掌尺度的平滑值（抗抖动）
    private var palmOutlierFrames = 0           // 连续「尺度突变」帧数（用于解锁，见下方注释）
    private var lastKnucklePx = 0.0             // 本帧掌宽原始值（indexMCP↔littleMCP，诊断用）
    private var lastPalmLenPx = 0.0             // 本帧掌长原始值（wrist↔middleMCP，诊断用）
    private var lastPoseDebug = PoseDebug(thumb: 0, index: 0, middle: 0, ring: 0, little: 0, fistSpread: 0)  // 最近一帧五指伸直比+握拳收拢度（诊断/标定）
    private var lastFistDiag: FistDiag? = nil   // 最近一帧握拳判定的逐项诊断（实机标定用）
    private var lastKnobDiag: KnobDiag? = nil   // 最近一帧五指旋钮判定的逐项诊断（实机标定用）
    private var lastPalmBasePx = 0.0            // 掌长基准（腕↔中指掌指关节）像素
    private var lastPalmAngleDeg = 0.0          // 掌心朝向角（度，已统一到屏幕坐标；正=顺时针）
    private var lastKnuckleAngleDeg = 0.0       // 对照角（食指掌指关节→小指掌指关节），诊断旋转灵敏度
    private var lastFingerLenPx = [0.0, 0.0, 0.0, 0.0]  // 食/中/无/小 指尖↔指根 像素距离
    // 注：LASER_GESTURE_ENABLED=false 时激光恒不激活，以下字段仅用于开关重新打开后的进出日志。
    private var laserWasActive = false          // 上一帧激光是否激活（用于进出激光的一次性日志）
    private var lastClearPhase: ClearPhase = .idle   // 上一帧清屏相位（用于清屏流程的一次性日志）

    init(state: DrawState, update: @escaping () -> Void, screenSize: CGSize) {
        self.state = state
        self.update = update
        self.screenSize = screenSize
    }

    static func start(state: DrawState, update: @escaping () -> Void, screenSize: CGSize) {
        let tracker = HandTracker(state: state, update: update, screenSize: screenSize)
        gTracker = tracker   // 持有，避免被释放
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            tracker.configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    log("摄像头权限已授予")
                    tracker.configureAndRun()
                } else {
                    log("❌ 摄像头权限被拒绝，请在 系统设置 > 隐私与安全性 > 摄像头 中授权")
                    DispatchQueue.main.async { gPreview?.setStatus(.noPermission) }
                }
            }
        default:
            log("❌ 摄像头权限被拒绝，请在 系统设置 > 隐私与安全性 > 摄像头 中授权")
            DispatchQueue.main.async { gPreview?.setStatus(.noPermission) }
        }
    }

    /// 启动时如实报告映射模式与标定状态：没有 ROI 就明说在用 Legacy，不假装已启用 ROI。
    private func logMappingStatus() {
        let requested = MAPPING_MODE == .fixedROI ? "FixedROI" : "Legacy"
        let effective = mapper.effectiveMode == .fixedROI ? "FixedROI" : "Legacy"
        let filter = POINTER_FILTER_MODE == .oneEuro ? "1€Filter" : "LegacyEMA"
        let anchor = TIP_ANCHOR_MODE == .indexTip ? "食指尖" : "捏合中点"
        log(String(format: "🗺 映射=%@(请求 %@) 增益=%.0fx%.0f 滤波=%@ 笔尖=%@ 屏幕=%.0fx%.0f",
                   effective, requested, mapper.gainX, mapper.gainY, filter, anchor,
                   screenSize.width, screenSize.height))
        if let roi = mapper.roi {
            if mapper.effectiveMode == .fixedROI {
                log(String(format: "🗺 已加载 ROI[左%.3f 右%.3f 上%.3f 下%.3f]（标定于 %.0fx%.0f，%@）",
                           roi.minX, roi.maxX, roi.minY, roi.maxY,
                           roi.screenWidth, roi.screenHeight,
                           roi.mirrorX == MIRROR_X && roi.flipY == FLIP_Y ? "方向一致" : "方向不一致→已回退"))
            } else if let reason = roi.invalidReason {
                log("⚠️ ROI 已加载但不可用：\(reason)，当前使用 Legacy 全画面映射")
            }
        } else {
            log("🗺 尚未标定 ROI：使用 Legacy 全画面映射。菜单栏 ✋ → 「校准活动区域（4 步）」可标定")
        }
    }

    private func configureAndRun() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            log("❌ 未找到摄像头设备")
            DispatchQueue.main.async { gPreview?.setStatus(.noDevice) }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else {
                log("❌ 无法添加摄像头输入")
                DispatchQueue.main.async { gPreview?.setStatus(.error("无法添加摄像头输入")) }
                return
            }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else {
                log("❌ 无法添加视频输出")
                DispatchQueue.main.async { gPreview?.setStatus(.error("无法添加视频输出")) }
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            log("✅ 摄像头已启动，开始手部追踪")
            logMappingStatus()
            DispatchQueue.main.async {
                gPreview?.setStatus(.cameraOnNoHand)
                self.startHeartbeat()
            }
        } catch {
            log("❌ 摄像头初始化失败: \(error.localizedDescription)")
            DispatchQueue.main.async { gPreview?.setStatus(.error(error.localizedDescription)) }
        }
    }
}

extension HandTracker {
    // 预览画面：复用本帧的 CVPixelBuffer，半分辨率足够小窗口显示
    private func makePreviewImage(_ pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}

// MARK: - 固定 ROI 校准流程（V4.0）
//
// 交互设计：菜单栏点「校准活动区域」开始 → 屏幕顶部常驻提示每一步该把手移到哪 →
// 每个角先静置 1.2s 再采集 1.0s（取中位数抗抖）→ 自动进入下一步 → 四步完成后校验并保存。
//
// 注意：要求用户把手移到的是**自己舒适活动范围的四个角**，而不是屏幕四角 ——
// 在 Legacy 映射下要指到屏幕四角就必须把手伸到画面边缘，那正是本方案要消除的问题。
extension HandTracker {

    /// 重置指针滤波器（手部丢失/恢复、长时间中断后调用，避免平滑跨越产生长线）。
    /// 评估一个 1 秒窗口的逐帧抖动；若原始坐标几乎没动，则该窗口的滤波后漂移就是静止漂移。
    ///
    /// 判据：原始坐标包围盒对角线 < STATIC_WINDOW_PX 视为「手静止」。用**原始**而非滤波后
    /// 判定，避免滤波器把移动抹平后自我认定「静止」（会系统性低估漂移）。
    private func evaluateJitterWindow() {
        defer {
            jitterRaw.removeAll(keepingCapacity: true)
            jitterFiltered.removeAll(keepingCapacity: true)
            jitterPalm.removeAll(keepingCapacity: true)
            jitterWindowStart = nil
        }
        let n = jitterRaw.count
        guard n >= STATIC_MIN_FRAMES else { return }

        func bbox(_ pts: [CGPoint]) -> Double {
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            for p in pts {
                minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
            }
            return hypot(maxX - minX, maxY - minY)
        }
        func meanStep(_ pts: [CGPoint]) -> Double {
            guard pts.count >= 2 else { return 0 }
            var s = 0.0
            for i in 1..<pts.count { s += hypot(Double(pts[i].x - pts[i - 1].x), Double(pts[i].y - pts[i - 1].y)) }
            return s / Double(pts.count - 1)
        }

        let rawBox = bbox(jitterRaw)
        let filtBox = bbox(jitterFiltered)
        lastFrameJitterRaw = meanStep(jitterRaw)
        lastFrameJitterFiltered = meanStep(jitterFiltered)

        guard rawBox < STATIC_WINDOW_PX else { return }   // 手在动，不判定静止漂移
        staticWindowCount += 1
        staticDriftSum += filtBox
        staticDriftMax = max(staticDriftMax, filtBox)
        // 阶段 4 判据：静止窗口内掌宽若大幅变化而屏幕坐标几乎不动，说明「远近变化→增益漂移」
        // 并不显著，掌宽归一化就没有必要（反而会把掌宽的 30% 噪声注入坐标）。
        let palmMin = jitterPalm.min() ?? 0
        let palmMax = jitterPalm.max() ?? 0
        let palmVar = palmMin > 1 ? (palmMax - palmMin) / palmMin * 100 : 0
        // 只在静止窗口写日志：这是「静止悬停 3 秒」验收项的可复现数据。
        log(String(format: "⏸ 静止窗口 %.1fs/%d帧：原始抖动框=%.1fpx 滤波后漂移=%.1fpx 帧间位移 原始=%.2f→滤波=%.2fpx 掌宽变化=%.1f%%(% .0f-% .0fpx)",
                  JITTER_WINDOW_SEC, n, rawBox, filtBox, lastFrameJitterRaw, lastFrameJitterFiltered,
                  palmVar, palmMin, palmMax))
    }

    private func resetPointerFilter() {
        oneEuro.reset()
        legacyEMA.reset()
        filterResetCount += 1
    }

    func startCalibration() {
        calibrator = ROICalibrator(minSamplesPerCorner: 8)
        calibrator.start()
        calibrationStepStart = CACurrentMediaTime()
        log("🎯 开始固定 ROI 校准：4 步，每步静置 \(ROI_CALIB_SETTLE_SEC)s 后采集 \(ROI_CALIB_COLLECT_SEC)s")
        DispatchQueue.main.async { gOverlay?.showPrompt(ROICalibrationCorner.topLeft.prompt) }
    }

    /// 丢弃标定结果，回到「整幅画面 → 全屏」的 Legacy 映射。
    func resetCalibration() {
        calibrator.abort()
        mapper.roi = nil
        mapper.mode = .legacy
        ROIStore.clear()
        log("↩️ 已重置为 Legacy 全画面映射（删除 \(ROIStore.fileURL.path)）")
        DispatchQueue.main.async {
            gOverlay?.hidePrompt()
            gOverlay?.showFeedback("已重置为全画面映射")
        }
    }

    /// 校准状态机：由每一帧驱动（时间在 I/O 层注入，纯逻辑不取时间）。
    private func stepCalibration(now: TimeInterval, display: DisplayPoint?, tipTrusted: Bool) {
        guard let corner = calibrator.corner else { return }
        let elapsed = now - calibrationStepStart

        if elapsed < ROI_CALIB_SETTLE_SEC {
            return                                   // 静置期：只显示提示，不采样
        }
        if elapsed < ROI_CALIB_SETTLE_SEC + ROI_CALIB_COLLECT_SEC {
            // 采集期：关键点不可信的帧不采样（需求 5.3：不得输出不可信坐标）
            if let d = display, tipTrusted { calibrator.addSample(d) }
            return
        }

        guard calibrator.commitCurrentCorner() else {
            log("❌ 校准中止：\(corner.shortName) 有效样本仅 \(calibrator.currentSampleCount) 帧（需 ≥8），沿用旧映射")
            DispatchQueue.main.async {
                gOverlay?.hidePrompt()
                gOverlay?.showFeedback("校准失败：未稳定识别到手，已沿用旧映射")
            }
            calibrator.abort()
            return
        }

        if let next = calibrator.corner {
            calibrationStepStart = now
            log("🎯 校准 \(corner.shortName) 已记录，下一步：\(next.shortName)")
            DispatchQueue.main.async { gOverlay?.showPrompt(next.prompt) }
        } else {
            finishCalibration()
        }
    }

    private func finishCalibration() {
        guard let roi = calibrator.buildROI(mirrorX: MIRROR_X, flipY: FLIP_Y,
                                            screenWidth: Double(screenSize.width),
                                            screenHeight: Double(screenSize.height)) else {
            let pts = calibrator.collected.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }
            log("❌ 校准失败：标定区域无效（四个角=\(pts.joined(separator: " "))），沿用旧映射")
            DispatchQueue.main.async {
                gOverlay?.hidePrompt()
                gOverlay?.showFeedback("校准失败：手部移动幅度太小，请重来")
            }
            calibrator.abort()
            return
        }
        mapper.roi = roi
        mapper.mode = .fixedROI
        let saved = ROIStore.save(roi)
        calibrator.abort()
        log(String(format: "✅ 校准完成 ROI[左%.3f 右%.3f 上%.3f 下%.3f]，增益 %.0fx%.0f（Legacy 为 %.0fx%.0f），保存\(saved ? "成功" : "失败")",
                   roi.minX, roi.maxX, roi.minY, roi.maxY,
                   mapper.gainX, mapper.gainY,
                   Double(screenSize.width), Double(screenSize.height)))
        DispatchQueue.main.async {
            gOverlay?.hidePrompt()
            gOverlay?.showFeedback("校准完成：已启用活动区域映射")
        }
    }

    /// 心跳与调试覆盖层共用的映射/滤波状态描述。
    private var mappingDebugText: String {
        let mode = mapper.effectiveMode == .fixedROI ? "ROI" : "Legacy"
        let filter = POINTER_FILTER_MODE == .oneEuro ? "1€" : "EMA"
        let tracking = tipGapSince == nil ? "正常" : "中断"
        var s = String(format: "映射=%@ 增益=%.0fx%.0f 滤波=%@ 追踪=%@ 笔尖=%.0f%% ",
                       mode, mapper.gainX, mapper.gainY, filter, tracking,
                       lastAnchorConfidence * 100)
        if let roi = mapper.roi, mapper.effectiveMode == .fixedROI {
            s += String(format: "ROI[%.2f-%.2f, %.2f-%.2f] ", roi.minX, roi.maxX, roi.minY, roi.maxY)
        } else {
            s += "ROI[未标定] "
        }
        s += String(format: "指尖=(%.0f,%.0f) ", lastTip.x, lastTip.y)
        return s
    }
}

extension HandTracker {
    // 每 1 秒输出一次识别状态（含握拳逐项诊断），便于实机标定与验证
    private func startHeartbeat() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            log("心跳: 已处理帧=\(self.frameCount) 手部=\(self.handSeen ? "已识别" : "未识别") "
                + "捏合距离=\(String(format: "%.3f", self.lastDist)) "
                + "原始距离=\(String(format: "%.0f", self.lastDistPx))px "
                + "掌宽=\(String(format: "%.0f", self.lastPalmScale))px"
                + "(掌宽原始=\(String(format: "%.0f", self.lastKnucklePx)) 掌长原始=\(String(format: "%.0f", self.lastPalmLenPx))) "
                + "置信度=\(String(format: "%.2f", self.lastTipConfidence)) "
                + "状态=\(self.phaseName) "
                + "清屏=\(self.clearPhaseName) "
                + "激光手势=\(LASER_GESTURE_ENABLED ? "启用" : "已废除") 翻页=\(self.pagePhaseName) "
                + "旋钮=\(self.knobPhaseName) 音量=\(self.volumePhaseName) "
                + "捏合挂起=\(self.suspendReasonText) "
                + String(format: "掌心角=%.0f°/对照%.0f° 累计=%+.0f°(原始%+.0f°) 笔刷[%@/%@] ", self.lastPalmAngleDeg,
                         self.lastKnuckleAngleDeg,
                         self.coordinator.knob.accumulatedDegrees,
                         self.coordinator.knob.rawAccumulatedDegrees,
                         self.state.brushSnapshot().size.displayName,
                         self.state.brushSnapshot().color.displayName)
                + self.knobDiagText
                + String(format: "伸直比[拇%.2f 食%.2f 中%.2f 无%.2f 小%.2f] 收拢=%.2f ",
                         self.lastPoseDebug.thumb, self.lastPoseDebug.index, self.lastPoseDebug.middle,
                         self.lastPoseDebug.ring, self.lastPoseDebug.little, self.lastPoseDebug.fistSpread)
                + self.fistDiagText
                + String(format: "掌长=%.0fpx 指长px[食%.0f 中%.0f 无%.0f 小%.0f] ",
                         self.lastPalmBasePx, self.lastFingerLenPx[0], self.lastFingerLenPx[1],
                         self.lastFingerLenPx[2], self.lastFingerLenPx[3])
                + self.mappingDebugText
                + String(format: "丢失=%d 封存=%d 重锚=%d ", self.trackingLostCount,
                         self.trackingSealCount, self.filterResetCount)
                + String(format: "帧抖动[原始%.2f→滤波%.2f px/帧] ", self.lastFrameJitterRaw,
                         self.lastFrameJitterFiltered)
                + String(format: "静止窗口=%d 平均漂移=%.1fpx 最大=%.1fpx ",
                         self.staticWindowCount,
                         self.staticWindowCount > 0 ? self.staticDriftSum / Double(self.staticWindowCount) : 0,
                         self.staticDriftMax)
                + "指尖屏幕坐标=(\(Int(self.lastTip.x)), \(Int(self.lastTip.y))) "
                + "预览窗口=\(gPreview?.isVisible == true ? "显示" : "隐藏") "
                + "预览帧=\(gPreview?.appliedFrames ?? 0)"
                + "(\(Int(gPreview?.lastImageSize.width ?? 0))x\(Int(gPreview?.lastImageSize.height ?? 0)))")
        }
    }

    /// 握拳判定的逐项诊断文本（实机标定用：哪一项卡住了，一眼可见）。
    private var fistDiagText: String {
        guard let d = lastFistDiag else { return "握拳[无手] " }
        func s(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "缺失" }
        return String(format: "握拳[弯曲度 食%@ 中%@ 无%@ 小%@ | 可见%d 蜷曲%d 伸直%d | "
                      + "收拢=%@ 掌置信=%.2f | 蜷曲%@ 收拢%@ 可靠%@ → %@] ",
                      s(d.curl[0]), s(d.curl[1]), s(d.curl[2]), s(d.curl[3]),
                      d.validCount, d.curledCount, d.straightCount,
                      s(d.spread), d.palmConfidence,
                      d.fourCurled ? "√" : "×", d.compact ? "√" : "×", d.reliable ? "√" : "×",
                      d.matched ? "命中" : "未命中")
    }

    /// 五指旋钮判定的逐项诊断文本（哪一项卡住导致进不了旋钮模式，一眼可见）。
    private var knobDiagText: String {
        guard let d = lastKnobDiag else { return "旋钮[无手] " }
        func s(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "缺失" }
        return String(format: "旋钮[四指伸直%d/4 弯曲度 食%@ 中%@ 无%@ 小%@ | "
                      + "拇伸%@(%@/直%.2f) 张开%@(%.2f) 可靠%@(掌%.2f 指%.2f) → %@] ",
                      d.straightCount, s(d.curl[0]), s(d.curl[1]), s(d.curl[2]), s(d.curl[3]),
                      d.thumbExtended ? "√" : "×", s(d.thumbCurl), d.thumbStraightness,
                      d.pinchOpen ? "√" : "×", d.pinchGap,
                      d.reliable ? "√" : "×", d.palmConfidence, d.minFingerConfidence,
                      d.matched ? "命中" : "未命中")
    }

    private var phaseName: String {
        switch coordinator.pinch.phase {
        case .idle: return "空闲"
        case .candidate: return "候选"
        case .drawing: return "绘画中"
        case .releaseCandidate: return "绘画中(去抖)"
        }
    }

    /// 激光状态机相位名（心跳/调试用）。
    private var laserPhaseName: String {
        switch coordinator.laser.phase {
        case .idle: return "关"
        case .candidate: return "候选"
        case .active: return "指示中"
        }
    }

    /// 翻页状态机相位名（心跳/调试用）。
    private var pagePhaseName: String {
        switch coordinator.page.phase {
        case .idle: return "关"
        case .armed: return "待挥动"
        case .cooldown: return "冷却"
        case .waitReset: return "锁定"
        }
    }

    private var knobPhaseName: String {
        switch coordinator.knob.phase {
        case .idle: return "关"
        case .candidate: return "候选"
        case .active: return "调节中"
        case .consumed: return "已切档(待收手重开)"
        }
    }

    private var volumePhaseName: String {
        switch coordinator.volume.phase {
        case .idle: return "关"
        case .candidate(let direction): return direction == .up ? "加候选" : "减候选"
        case .latched(let direction): return direction == .up ? "加锁存" : "减锁存"
        }
    }

    /// 本帧「捏合被哪个高优先级手势挂起」（none 表示未被挂起）。
    /// 与协调器口径一致，仅用于诊断，不参与裁决。
    private var suspendReasonText: String {
        var r: [String] = []
        switch coordinator.clear.phase {
        case .sixArmed, .fistCandidate, .clearing, .cooldown: r.append("清屏")
        case .idle, .sixCandidate: break
        }
        if coordinator.laser.phase == .active { r.append("激光") }
        if coordinator.page.phase == .armed { r.append("翻页") }
        if coordinator.knob.isBusy { r.append("旋钮") }
        if coordinator.volume.isBusy { r.append("音量") }
        return r.isEmpty ? "无" : r.joined(separator: "+")
    }

    /// 清屏相位变化的一次性日志。
    ///
    /// 「六→握拳」是两步手势，任一步没过都表现为「清屏用不了」但没有任何线索。
    /// 这里把每一步的进入/放弃都打出来（含失败瞬间的握拳逐项诊断），
    /// 实测时看日志即可定位卡在「六没就绪」还是「握拳没成立」。
    private func logClearPhaseIfChanged() {
        let p = coordinator.clear.phase
        defer { lastClearPhase = p }
        guard p != lastClearPhase else { return }
        switch p {
        case .idle:
            // 只有从「已就绪/确认中」被放弃时才提示，避免每帧刷屏。
            switch lastClearPhase {
            case .sixArmed, .fistCandidate:
                log("⌛ 清屏取消：「六」就绪后 \(Int(config.clear.sixToFistTimeoutMs))ms 内没握成拳（\(fistDiagText)）")
            case .cooldown:
                break
            default:
                break
            }
        case .sixCandidate:
            break   // 一帧即过，不刷屏
        case .sixArmed:
            log("🤙 清屏：检测到「六」，请握拳保持 \(Int(config.clear.fistConfirmMs))ms 清空笔迹"
                + "（\(Int(config.clear.sixToFistTimeoutMs))ms 内有效）")
        case .fistCandidate:
            log("✊ 清屏：握拳识别中，保持 \(Int(config.clear.fistConfirmMs))ms 即清空")
        case .clearing:
            break   // 由下方 🧹 日志记录
        case .cooldown:
            break
        }
    }

    /// 清屏状态机相位名（用于心跳日志/调试，便于观测六→握拳组合清屏推进）。
    private var clearPhaseName: String {
        switch coordinator.clear.phase {
        case .idle: return "清屏空闲"
        case .sixCandidate: return "六候选"
        case .sixArmed: return "六就绪"
        case .fistCandidate: return "握拳候选"
        case .clearing: return "清屏中"
        case .cooldown: return "冷却中"
        }
    }

    @objc func captureOutput(_ output: AVCaptureOutput,
                             didOutput sampleBuffer: CMSampleBuffer,
                             from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCount += 1
        // 预览画面直接用本帧数据（不另开摄像头）；窗口隐藏时不生成，省开销
        let previewImage = previewWanted ? makePreviewImage(pb) : nil

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return }

        // 掌部骨架（wrist + 各指 MCP）是握拳时最稳的参照：只要它可用就算「有手」。
        // 旧逻辑要求 indexTip 与 thumbTip 都必须存在，而握拳时这两点常被遮挡，
        // 整帧被判成「未识别」→ 清屏状态机永远拿不到握拳帧，这是握拳识别不到的主因之一。
        guard let obs = request.results?.first,
              let pts = try? obs.recognizedPoints(.all),
              isPalmSkeletonUsable(pts) else {
            handleNoHand(previewImage)
            return
        }

        let indexTip = pts[.indexTip]
        let thumbTip = pts[.thumbTip]

        if !handSeen {
            handSeen = true
            log("✅ 检测到手部，正在追踪食指指尖")
        }

        let rawW = Double(CVPixelBufferGetWidth(pb))
        let rawH = Double(CVPixelBufferGetHeight(pb))

        // 手掌尺度（掌宽）用于归一化，避免受手离摄像头远近影响
        let palmScale = computePalmScale(pts, rawW: rawW, rawH: rawH)
        lastPalmScale = palmScale

        // 掌长与各指「指尖↔指根」像素距离（诊断用：判断 curl 判据量级是否合理）
        func px(_ a: VNHumanHandPoseObservation.JointName,
                _ b: VNHumanHandPoseObservation.JointName) -> Double {
            guard let pa = pts[a], let pb = pts[b] else { return -1 }
            return hypot((pa.location.x - pb.location.x) * rawW,
                         (pa.location.y - pb.location.y) * rawH)
        }
        lastPalmBasePx = px(.wrist, .middleMCP)
        lastFingerLenPx = [px(.indexTip, .indexMCP), px(.middleTip, .middleMCP),
                           px(.ringTip, .ringMCP), px(.littleTip, .littleMCP)]

        // 捏合距离：像素距离 → 手掌尺度归一化（指尖缺失时沿用上一帧，不产生虚假距离）
        var distPx = lastDistPx
        var tipConf: Float = 0
        if let it = indexTip, let tt = thumbTip, usable(it), usable(tt) {
            let dxPx = (it.location.x - tt.location.x) * rawW
            let dyPx = (it.location.y - tt.location.y) * rawH
            distPx = hypot(dxPx, dyPx)
            tipConf = min(it.confidence, tt.confidence)
        }
        let dist = palmScale > 1 ? distPx / palmScale : distPx / rawW
        lastDist = dist
        lastDistPx = distPx
        lastTipConfidence = Double(tipConf)

        // === ① 先推进协调器（内部先清屏后捏合）===
        // I1：pinchDistanceNorm / FingerFeature 坐标均用原始归一化坐标，严禁喂 EMA 后的屏幕坐标。
        // 时间只在此 I/O 层取真实时间注入，纯逻辑内部不取时间。tipReliable 口径由协调器内部统一处理。
        let now = CACurrentMediaTime()
        let pinchPhaseBefore = coordinator.pinch.phase   // 用于诊断「捏合候选被抢占」
        let m = buildHandMetrics(pts, rawW: rawW, rawH: rawH,
                                 palmScale: palmScale, pinchDistanceNorm: dist,
                                 pinchDistancePx: distPx)
        lastPoseDebug = poseDebug(m)
        lastFistDiag = fistDiagnostics(m)
        lastKnobDiag = knobDiagnostics(m, minConfidence: Float(MIN_CONFIDENCE))
        // 双指翻页手形的逐项诊断：回答「手识别到了，为什么双指手形没命中」。
        lastPageDiag = pageDiagnostics(m, minConfidence: Float(MIN_CONFIDENCE))
        if gesturePageEnabled, let d = lastPageDiag, d.matched != lastPageMatched {
            lastPageMatched = d.matched
            log(d.matched
                ? "✌️ 双指手形命中（\(d.summary)）"
                : "🔍 双指手形未命中：\(d.summary)｜" +
                  "curl 食\(fmtNum(d.curl[0])) 中\(fmtNum(d.curl[1])) " +
                  "无\(fmtNum(d.curl[2])) 小\(fmtNum(d.curl[3]))｜" +
                  "ratio 食\(fmtNum(lastPageDiag?.ratio[0])) 中\(fmtNum(lastPageDiag?.ratio[1]))｜" +
                  "捏合距 \(fmtNum(d.pinchGap))｜掌部置信 \(fmtNum(Double(d.palmConfidence)))｜可靠 \(d.reliable)")
        }
        lastPalmAngleDeg = m.hasPalmAngle ? m.palmAngle * 180 / .pi : 0
        // 对照角：掌宽向量（食指掌指关节→小指掌指关节）。与掌心角同源映射，
        // 用于实机判断「旋转时哪个角更灵敏」——两者应同步变化。
        if let im = pts[.indexMCP], let lm = pts[.littleMCP], usable(im), usable(lm) {
            let kdx = MIRROR_X ? -(Double(lm.location.x - im.location.x))
                               :  (Double(lm.location.x - im.location.x))
            let kdy = FLIP_Y ? (Double(lm.location.y - im.location.y))
                             : -(Double(lm.location.y - im.location.y))
            lastKnuckleAngleDeg = atan2(kdy, kdx) * 180 / .pi
        }
        // 激光光点取中指尖、翻页参考点取食指尖（原始归一化坐标，与 HandMetrics 口径一致）。
        let midTipPt = pts[.middleTip]?.location ?? .zero
        let hasMidTip = usable(pts[.middleTip])
        let refPt = pts[.indexTip]?.location ?? .zero
        let hasRef = usable(pts[.indexTip])
        coordinator.pageEnabled = gesturePageEnabled
        let decision = coordinator.step(m,
                                        midTip: midTipPt, hasMidTip: hasMidTip,
                                        refPoint: refPt, hasRef: hasRef,
                                        now: now, config: config)
        // 翻页手势识别态变化日志（实机标定用：确认「双指手形」是否被识别、以及翻页冷却）。
        let pagePhaseNow = coordinator.page.phase
        if pagePhaseNow != lastPagePhase {
            switch pagePhaseNow {
            case .armed:    log("✌️ 已识别双指翻页手形（开始跟踪挥动，请水平挥动）")
            case .cooldown: log("📄 翻页已触发，冷却中（约 800ms 内不再翻）")
            case .waitReset: log("🔒 已翻一页，请先收手/解除✌️ 才能翻下一页（防回摆误翻）")
            case .idle:
                if lastPagePhase == .armed || lastPagePhase == .cooldown || lastPagePhase == .waitReset {
                    log("↩️ 退出翻页手形（手移出画面或手形改变）")
                }
            }
            lastPagePhase = pagePhaseNow
        }
        // 注：tipReliable 已由协调器内部据 FingerFeature.minConfidence 自洽判定，
        // 指尖缺失时 minConfidence 自然为 0，无需在此另喂状态机。
        logClearPhaseIfChanged()

        // 诊断：捏合「候选计时中」被高优先级手势打回 idle（表现为起笔困难/时断时续）。
        if pinchPhaseBefore == .candidate, coordinator.pinch.phase == .idle,
           suspendReasonText != "无", dist < PINCH_ON {
            log("⚠️ 捏合候选被【\(suspendReasonText)】打断（d=\(String(format: "%.3f", dist))）")
        }

        // 绘画坐标（V4.0）：Vision 归一化 → 笔尖锚点 → 映射 → 滤波 → 追踪中断判定。
        //
        // 说明：指针（红色光点）与落笔**共用**同一份滤波结果，不做二次滤波，
        // 避免出现「光点在一处、笔迹在另一处」以及重复平滑带来的额外拖尾。
        //
        // ① 笔尖锚点（Vision 归一化坐标）
        var anchor: CGPoint? = nil
        var anchorConfidence: Float = 0
        switch TIP_ANCHOR_MODE {
        case .indexTip:
            if let it = indexTip, usable(it) {
                anchor = CGPoint(x: CGFloat(it.location.x), y: CGFloat(it.location.y))
                anchorConfidence = it.confidence
            }
        case .pinchMidpoint:
            // 候选实验：捏合时真正的「笔尖」是拇指与食指的接触点，取两点中点可平均掉单点噪声。
            if let it = indexTip, let tt = thumbTip, usable(it), usable(tt) {
                anchor = CGPoint(x: (it.location.x + tt.location.x) / 2,
                                 y: (it.location.y + tt.location.y) / 2)
                anchorConfidence = min(it.confidence, tt.confidence)
            }
        }

        // ② 校准流程优先：校准期间只采集原始（未滤波）显示坐标，且不允许落笔
        let calibrating = calibrator.isRunning
        if calibrating {
            let display = anchor.map {
                mapper.displayPoint(visionX: Double($0.x), visionY: Double($0.y))
            }
            stepCalibration(now: now,
                            display: display,
                            tipTrusted: anchor != nil && anchorConfidence >= MIN_CONFIDENCE)
        }

        // ③ 追踪中断判定：指尖不可用时开始计时，超过阈值即封存笔画并重置滤波器，
        //    保证手在别处重新出现时不会把两段笔迹连成一条线（需求 7.1.3 / 6.2）。
        if anchor == nil {
            if tipGapSince == nil { tipGapSince = now }
            let gapMs = (now - (tipGapSince ?? now)) * 1000
            if gapMs >= TRACKING_SEAL_MS, !state.isSealed {
                state.markTrackingLost()
                trackingSealCount += 1
                log("⚠️ 追踪中断 \(Int(gapMs))ms：已封存当前笔画（恢复后将另起一笔）")
            }
            if gapMs >= TRACKING_RESET_MS { resetPointerFilter() }
        } else if let gapStart = tipGapSince {
            let gapMs = (now - gapStart) * 1000
            tipGapSince = nil
            trackingLostCount += 1
            resetPointerFilter()
            log("👀 指尖恢复（中断 \(Int(gapMs))ms，滤波器已重锚）")
        }

        // ④ 映射：Legacy 直接铺满全屏；ROI 只把标定区域放大到全屏（越界一律钳制）
        let rawScreen: CGPoint? = anchor.map {
            mapper.map(visionX: Double($0.x), visionY: Double($0.y))
        }

        var pScreen = smoothed ?? lastTip
        if let raw = rawScreen {
            pScreen = (POINTER_FILTER_MODE == .oneEuro)
                ? oneEuro.filter(raw, timestamp: now)
                : legacyEMA.filter(raw, timestamp: now)
        }
        // 注：指尖不可用时 pScreen 保持上一帧位置（光点冻结），不写入笔画。
        let pSmoothed = pScreen
        smoothed = pSmoothed
        lastTip = pSmoothed
        lastAnchorConfidence = Double(anchorConfidence)

        // ⑤ 逐帧抖动采样：只在有原始坐标时累积（指尖不可用期间不计入）
        if let raw = rawScreen {
            jitterRaw.append(raw)
            jitterFiltered.append(pSmoothed)
            jitterPalm.append(lastPalmScale)
            if jitterWindowStart == nil { jitterWindowStart = now }
            if let ws = jitterWindowStart, now - ws >= JITTER_WINDOW_SEC {
                evaluateJitterWindow()
            }
        }

        // 校准期间不落笔：避免用户把手移到四个角的过程中意外画上笔迹。
        let outcome: PinchOutcome = calibrating ? .none : decision.pinchOutcome
        if calibrating { state.sealStroke() }

        // === ② 按 outcome 落笔（begin 新建不追加；append 追加；end/none 不追加）===
        switch outcome {
        case .begin:
            state.beginStroke(at: pSmoothed)   // 每次捏合都新建一条笔画，不与上一笔连接
            lastWritten = pSmoothed
            prevWritten = nil
            log("✏️ 开始绘画（确认 \(Int(PINCH_CONFIRM_MS))ms，d=\(String(format: "%.3f", dist))）起点=(\(Int(pSmoothed.x)), \(Int(pSmoothed.y)))")
        case .append:
            // 落笔点直接用光点坐标 pSmoothed（与红点同源，"光点在哪笔落哪"，最大限度跟手）。
            // 不再做第二道低通（二次平滑会叠加滞后、拖慢笔尖）；顺滑交给「渲染层贝塞尔平滑」实现——
            // 渲染平滑不引入任何输入滞后。仅保留一个很小的死区，滤掉手"停住"时的静止抖动。
            let dp = pSmoothed
            let moved = lastWritten.map { hypot(dp.x - $0.x, dp.y - $0.y) } ?? .greatestFiniteMagnitude
            let jumpy = moved > DRAW_MAX_STEP && lastTipConfidence < DRAW_JUMP_MAX_CONF
            if moved >= DRAW_MIN_STEP, !jumpy {
                state.appendPoint(dp)
                prevWritten = lastWritten
                lastWritten = dp
            } else if jumpy {
                // 异常跳变（多为指尖识别抖动/瞬时丢失）：只跳过本帧，不断笔、不连线
                log("⚠️ 跳过异常跳变点（位移=\(String(format: "%.0f", moved))px，置信度=\(String(format: "%.2f", lastTipConfidence))）")
            }
        case .end:
            let tail = lastWritten.flatMap { lw in prevWritten.map { hypot(lw.x - $0.x, lw.y - $0.y) } } ?? 0
            // 结束原因诊断：真松开（距离越阈）/ 指尖置信度持续不足 / 其他（被抢占等）。
            let reason = dist > PINCH_OFF ? "真松开"
                       : (lastTipConfidence < Double(MIN_CONFIDENCE) ? "置信度不足" : "其他")
            log("⏹ 停止绘画（\(reason) d=\(String(format: "%.3f", dist)) 原始=\(String(format: "%.0f", distPx))px "
                + "掌宽=\(String(format: "%.0f", palmScale))px 置信度=\(String(format: "%.2f", lastTipConfidence)) "
                + "笔画数=\(state.strokesSnapshot().count) "
                + "末段位移=\(String(format: "%.1f", tail))px）")
            state.endStroke()
            lastWritten = nil
            prevWritten = nil
        case .none:
            break
        }

        // === ③ 六→握拳组合清屏：在 videoQueue 下先封存当前笔画（禁追加）再清全部（I2 同队列 + NSLock）===
        // 协调器在 performClear 帧已把 pinchOutcome 置 .none，故不会同帧又落笔。
        if decision.clearOutcome == .performClear {
            lastWritten = nil
            prevWritten = nil
            state.clearAll()   // 作用于真实 OverlayView 对应的 DrawState（与 begin/append 同队列，线程安全）
            log("🧹 六→握拳清屏，清空笔迹")
        }

        // === ④ 激光：V2.1 起手势已废除，本帧不做任何光点驱动 ===
        // 屏幕上的红色光点由 OverlayView.refresh() 依据「食指指尖」常驻更新（与落笔坐标同源），
        // 看到手即显示、手消失即隐藏，不再需要「四指伸出+拇指收回」手势触发，
        // 也因此不再参与优先级抢占（翻页与绘画不会被激光挂起）。
        //（协调器侧由 coordinator.laserEnabled = LASER_GESTURE_ENABLED 关闭，状态机恒不激活。）

        // === ⑤ PPT 翻页（第三优先级）：复用已验证可靠的 gPresentation（WPS 定向投递 postToPid + activate）===
        // 要求（需求第一步）：手势模块只调用现有翻页控制器的对应方法，不自行创建 CGEvent / 获取 WPS PID。
        // 方向依据需求文档：向左挥(.left) → 下一页；向右挥(.right) → 上一页。
        // 若实机方向相反（取决于摄像头镜像/坐标系），交换下方两行 nextSlide/previousSlide 即可。
        if case .flip(let dir) = decision.pageOutcome {
            let result = (dir == .left)
                ? gPresentation.nextSlide()      // 向左挥 → 下一页
                : gPresentation.previousSlide()  // 向右挥 → 上一页
            lastPageFlipDir = dir
            lastPageFlipResult = result
            if result == .eventPosted {
                log("📄 手势翻页：已发送\(dir == .left ? "下一页" : "上一页")指令（eventPosted ≠ 翻页成功，请目视确认 WPS）")
            } else {
                log("📄 手势翻页未执行：\(result.logMessage)")
            }
        }

        // === ⑥ 五指旋钮（独占期间不落笔，协调器已挂起捏合）===
        switch decision.knobOutcome {
        case .entered:
            log("🎛 进入旋钮模式（顺时针切粗细 / 逆时针切颜色）")
        case .rotate(.clockwise):
            let level = state.cycleBrushSizeClockwise()
            let message = "笔刷：\(level.displayName)"
            log("🎛 顺时针 → \(message) (\(level.width)px)")
            DispatchQueue.main.async { gOverlay?.showFeedback(message) }
        case .rotate(.counterclockwise):
            let color = state.cycleBrushColorCounterclockwise()
            let message = "颜色：\(color.displayName)"
            log("🎛 逆时针 → \(message) (\(color.hex))")
            let swatch = nsColor(for: color)
            DispatchQueue.main.async { gOverlay?.showFeedback(message, swatch: swatch) }
        case .exited:
            log("🎛 退出旋钮模式，恢复绘画")
        case .none:
            break
        }

        // === ⑦ 拇指上下音量（每次确认只调一档）===
        if case .adjust(let direction) = decision.volumeOutcome {
            let result = gSystemVolume.adjustOneStep(direction)
            switch result {
            case .success(let change):
                let arrow = direction == .up ? "↑" : "↓"
                let message = "音量 \(arrow) \(change.percent)%"
                log("🔊 \(message)（本次实际变化=\(change.changed ? "是" : "已达上下限")，"
                    + "调节前静音=\(change.wasMuted ? "是" : "否")）")
                DispatchQueue.main.async { gOverlay?.showFeedback(message) }
            case .failure(let error):
                // 不伪造音量已改变：只在日志与提示中如实说明失败原因。
                log("⚠️ 音量调节失败：\(error.description)")
                DispatchQueue.main.async { gOverlay?.showFeedback("音量不可用：\(error.description)") }
            }
        }

        let currentPhase = coordinator.pinch.phase
        let drawingLike = currentPhase == .drawing || currentPhase == .releaseCandidate
        let previewPhase = decision.previewPhase
        DispatchQueue.main.async {
            self.state.setFinger(pSmoothed)
            self.state.setPinching(drawingLike)
            self.update()
            var hf = HandFrame(image: previewImage, joints: pts)
            hf.pinchDistance = dist
            hf.pinchDistancePx = distPx
            hf.palmScale = palmScale
            hf.phase = currentPhase
            hf.candidateElapsed = 0
            hf.tipConfidence = Double(tipConf)
            // 阶段4（任务 5.8）：透传协调器合成的 previewPhase，经 PreviewStatus.from 映射，
            // 使预览能显示清屏候选/正在清屏等状态。
            hf.previewPhase = previewPhase
            hf.roi = self.mapper.effectiveMode == .fixedROI ? self.mapper.roi : nil
            hf.debugInfo = self.mappingDebugText
            let status = pageGestureStatus(previewPhase: previewPhase)
            gPreview?.apply(hf, status: status, brush: self.state.brushSnapshot())
        }
    }

    /// 关键点是否真实可用：存在且置信度非零、坐标不是原点（Vision 对未检测到的点给 (0,0)）。
    private func usable(_ p: VNRecognizedPoint?) -> Bool {
        guard let p = p else { return false }
        return p.confidence > 0.01 && (p.location.x > 0.001 || p.location.y > 0.001)
    }

    /// 掌部骨架（腕关节 + 至少 3 个掌指关节）是否可用。
    /// 握拳时蜷曲的手指指尖常不可见，但掌部骨架基本都在，用它判定「手是否存在」。
    private func isPalmSkeletonUsable(_ pts: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard usable(pts[.wrist]) else { return false }
        let mcps: [VNHumanHandPoseObservation.JointName] =
            [.thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        return mcps.filter { usable(pts[$0]) }.count >= 3
    }

    /// 掌部骨架置信度：腕关节与各 MCP 的「第二低」置信度（握拳可靠性的判据）。
    ///
    /// 旧实现取 6 个关节的**最低**值，只要 thumbCMC 或 littleMCP 中任意一个被遮挡
    /// （握拳时很常见），整帧就被判成不可靠 → 握拳永远进不了清屏流程。
    /// 改成丢弃最差的**一个**关节、取次低值：仍能拦住「骨架整体不可信」的帧，
    /// 但容忍单点抖动/遮挡（实测可靠帧占比明显提升）。
    private func palmSkeletonConfidence(_ pts: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) -> Float {
        var confs: [Float] = []
        confs.reserveCapacity(6)
        for name in [VNHumanHandPoseObservation.JointName.wrist, .thumbCMC, .indexMCP,
                     .middleMCP, .ringMCP, .littleMCP] {
            confs.append(pts[name]?.confidence ?? 0)
        }
        guard !confs.isEmpty else { return 0 }
        confs.sort()
        // 只有一个关节时无从丢弃，直接用它本身。
        return confs.count >= 2 ? confs[1] : confs[0]
    }

    /// 未检测到手（或掌部骨架不可用）：复位状态机、结束笔画、预览显示「未识别到手」。
    private func handleNoHand(_ previewImage: CGImage?) {
        handSeen = false
        smoothed = nil
        // 手部丢失期间不积累抖动样本，避免「丢失前 + 恢复后」被拼进同一个统计窗口。
        jitterRaw.removeAll(keepingCapacity: true)
        jitterFiltered.removeAll(keepingCapacity: true)
        jitterPalm.removeAll(keepingCapacity: true)
        jitterWindowStart = nil
        let now = CACurrentMediaTime()
        // 构造 hasHand=false 的空 HandMetrics，让清屏状态机在手部丢失时被正确复位（候选取消回 idle）。
        let emptyFinger = FingerFeature(tip: .zero, dip: .zero, pip: .zero, mcp: .zero,
                                        minConfidence: 0, hasTip: false, hasMcp: false)
        let emptyNoHand = HandMetrics(thumb: emptyFinger, index: emptyFinger, middle: emptyFinger,
                                      ring: emptyFinger, little: emptyFinger,
                                      wrist: .zero,
                                      palmScale: 0,
                                      pinchDistanceNorm: lastDist,
                                      hasHand: false,
                                      palmConfidence: 0)
        let decision = coordinator.step(emptyNoHand,
                                        midTip: .zero, hasMidTip: false,
                                        refPoint: .zero, hasRef: false,
                                        now: now, config: config)
        if decision.pinchOutcome == .end {
            let tail = lastWritten.flatMap { lw in prevWritten.map { hypot(lw.x - $0.x, lw.y - $0.y) } } ?? 0
            log("⏹ 手部关键点丢失，立即结束笔画（笔画数=\(state.strokesSnapshot().count)，"
                + "末段位移=\(String(format: "%.1f", tail))px）")
        }
        lastWritten = nil
        prevWritten = nil
        lastFistDiag = nil
        lastKnobDiag = nil
        lastPageDiag = nil       // 手部丢失时清空双指诊断，状态条回落到「未识别到手」
        lastPageMatched = false
        DispatchQueue.main.async {
            self.state.setFinger(nil)
            self.state.setPinching(false)
            self.update()
            var hf = HandFrame(image: previewImage)
            hf.pinchDistance = self.lastDist
            gPreview?.apply(hf, status: .cameraOnNoHand)
        }
    }

    /// 从 Vision 关键点构造 HandMarkCore 的纯值类型 HandMetrics（供协调器判定）。
    ///
    /// 不变量 I1：FingerFeature 的 tip/dip/pip/mcp 与 wrist 一律使用 Vision **原始**归一化坐标
    /// （`location`，0...1，左下原点），**不做镜像、不做 EMA**；分类层内部用 wrist↔middle.mcp 的
    /// 归一化距离（palmNorm）自洽归一，故坐标必须是原始 location，严禁喂屏幕坐标。
    ///
    /// - `palmScale` / `pinchDistanceNorm` 直接透传调用方已算好的像素掌宽与原始归一化捏合距离（I1）。
    /// - 缺失关键点以 .zero 兜底，并使该指 minConfidence 自然偏低（缺失关节置信度视为 0），
    ///   从而 reliable 偏低、不致误触发清屏。
    private func buildHandMetrics(_ pts: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                                  rawW: Double, rawH: Double,
                                  palmScale: Double,
                                  pinchDistanceNorm: Double,
                                  pinchDistancePx: Double = 0) -> HandMetrics {
        // 取某关键点的原始归一化坐标（缺失返回 .zero）。
        func loc(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint {
            pts[name]?.location ?? .zero
        }
        // 取某关键点置信度（缺失视为 0，使含缺失关节的手指 minConfidence 偏低）。
        func conf(_ name: VNHumanHandPoseObservation.JointName) -> Float {
            pts[name]?.confidence ?? 0
        }
        // 用四关节名构造一根手指特征：坐标取原始 location，minConfidence 取四关节置信度最小值。
        // hasTip / hasMcp 标记该关节是否真实可用——缺失关节的坐标是 (0,0)，
        // 若参与距离计算会把收拢度/弯曲度污染成毫无意义的值（实测把收拢度放大到 1.11 卡死握拳）。
        func finger(tip: VNHumanHandPoseObservation.JointName,
                    dip: VNHumanHandPoseObservation.JointName,
                    pip: VNHumanHandPoseObservation.JointName,
                    mcp: VNHumanHandPoseObservation.JointName) -> FingerFeature {
            let minConf = min(conf(tip), conf(dip), conf(pip), conf(mcp))
            return FingerFeature(tip: loc(tip), dip: loc(dip), pip: loc(pip), mcp: loc(mcp),
                                 minConfidence: minConf,
                                 hasTip: usable(pts[tip]), hasMcp: usable(pts[mcp]))
        }

        // 拇指无标准 DIP/PIP/MCP 命名：用 IP 近似 dip、MP 近似 pip、CMC 近似 mcp。
        let thumb  = finger(tip: .thumbTip,  dip: .thumbIP,   pip: .thumbMP,   mcp: .thumbCMC)
        let index  = finger(tip: .indexTip,  dip: .indexDIP,  pip: .indexPIP,  mcp: .indexMCP)
        let middle = finger(tip: .middleTip, dip: .middleDIP, pip: .middlePIP, mcp: .middleMCP)
        let ring   = finger(tip: .ringTip,   dip: .ringDIP,   pip: .ringPIP,   mcp: .ringMCP)
        let little = finger(tip: .littleTip, dip: .littleDIP, pip: .littlePIP, mcp: .littleMCP)

        // 旋钮朝向统一到用户实际看到的屏幕坐标：预览/覆盖层若镜像 x 或翻转 y，
        // 这里同步应用相同映射。屏幕坐标 y 向下，因此 atan2 的正方向即用户看到的顺时针。
        let hasPalmAngle = usable(pts[.wrist]) && usable(pts[.middleMCP])
        var palmAngle = 0.0
        if hasPalmAngle {
            let rawDX = Double(middle.mcp.x - loc(.wrist).x)
            let rawDY = Double(middle.mcp.y - loc(.wrist).y)
            let displayDX = MIRROR_X ? -rawDX : rawDX
            let displayDY = FLIP_Y ? rawDY : -rawDY
            palmAngle = atan2(displayDY, displayDX)
        }

        return HandMetrics(thumb: thumb, index: index, middle: middle, ring: ring, little: little,
                           wrist: loc(.wrist),
                           palmScale: palmScale,
                           pinchDistanceNorm: pinchDistanceNorm,
                           pinchDistancePx: pinchDistancePx,
                           hasHand: true,
                           palmConfidence: palmSkeletonConfidence(pts),
                           palmAngle: palmAngle,
                           hasPalmAngle: hasPalmAngle)
    }

    /// 手掌尺度：优先掌宽（食指掌指关节↔小指掌指关节），退化到掌长（手腕↔中指掌指关节）。
    /// 单帧尺度会被手指蜷缩/手掌旋转严重压缩，因此做「合理性检查 + 指数平滑」。
    private func computePalmScale(_ pts: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                                  rawW: Double, rawH: Double) -> Double {
        func pixelDist(_ a: VNRecognizedPoint?, _ b: VNRecognizedPoint?) -> Double? {
            guard let a = a, let b = b,
                  a.confidence > 0.5, b.confidence > 0.5 else { return nil }
            let dx = (a.location.x - b.location.x) * rawW
            let dy = (a.location.y - b.location.y) * rawH
            return hypot(dx, dy)
        }
        let knuckleWidth = pixelDist(pts[.indexMCP], pts[.littleMCP])   // 掌宽
        let palmLength = pixelDist(pts[.wrist], pts[.middleMCP])        // 掌长
        lastKnucklePx = knuckleWidth ?? 0
        lastPalmLenPx = palmLength ?? 0

        // 关键：投影压缩 / 手指蜷缩只会让「测得距离」变小，不会变大。
        // 因此掌宽与「掌长×0.85」取较大者，天然更接近真实掌心尺度：
        // 掌宽在手侧转/握拳时会塌到几十 px（实测曾塌到 51px），而掌长相对稳定。
        let altLen = (palmLength ?? 0) * 0.85                           // 掌长折算到掌宽量级
        var raw: Double = 0
        if let w = knuckleWidth, w > 1 {
            raw = (altLen > 1) ? max(w, altLen) : w
        } else if altLen > 1 {
            raw = altLen
        }

        guard raw > 1 else { return palmScaleSmoothed }                 // 本帧不可用：沿用历史值

        if palmScaleSmoothed <= 1 {
            palmScaleSmoothed = raw
            palmOutlierFrames = 0
        } else {
            let ratio = raw / palmScaleSmoothed
            if ratio < 0.75 || ratio > 1.33 {
                // 本帧尺度突变（多为遮挡/蜷缩）：换用另一个尺度，仍不合理则沿用历史值。
                let alt = (knuckleWidth ?? 0) > 1 && raw == knuckleWidth ? altLen : (knuckleWidth ?? 0)
                if alt > 1, abs(alt / palmScaleSmoothed - 1) < 0.33 {
                    raw = alt
                    palmOutlierFrames = 0
                } else {
                    // 防锁死：旧实现在这里直接沿用历史值，一旦历史值是塌陷的小值
                    // （如 51px），此后真实值永远被判为「突变」→ 尺度被永久锁死在 51px，
                    // 归一化捏合距离被放大 3~4 倍 → 表现为「捏合提前跳出、画线不连贯」。
                    // 连续不合理达到阈值即认为基准本身是错的，重新锚定为当前观测值。
                    palmOutlierFrames += 1
                    if palmOutlierFrames >= 8 {          // 约 8 帧（≈0.27s @30fps）
                        palmScaleSmoothed = raw
                        palmOutlierFrames = 0
                        return raw
                    }
                    raw = palmScaleSmoothed
                }
            } else {
                palmOutlierFrames = 0
            }
            palmScaleSmoothed += (raw - palmScaleSmoothed) * 0.15       // 平滑，避免尺度抖动放大距离
        }
        return palmScaleSmoothed
    }
}
// MARK: - 日志（同时输出到 stdout 与日志文件，便于任何启动方式下验证）
let logPath: String = {
    // 用系统目录 API 而非硬编码 NSHomeDirectory()：App Store（沙盒）版会自动落到容器内，
    // 非沙盒版仍是 ~/Library/Logs/HandMark.log，调试习惯不变。
    let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    let dir = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library"))
        .appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("HandMark.log").path
}()
func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    print(message)
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

// MARK: - 权限 / 身份诊断（只读）
// 证明「日志来自当前这个可执行文件」（路径 + bundleId + cdhash），并同时记录两类权限 API 的真实值。
// 纯读取，不请求、不修改任何权限（CGRequestPostEventAccess 不在此调用，避免诊断本身改变状态）。
func logPermissionAndIdentityDiagnostics() {
    // 1) 当前进程真正加载的可执行文件路径（区分 HandMark.app 与 .build/release/HandMark）。
    let exePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "未知"
    let bundleId = Bundle.main.bundleIdentifier ?? "nil（可能以裸二进制方式运行，无 bundle）"
    let bundlePath = Bundle.main.bundlePath
    log("🪪 身份诊断：可执行文件=\(exePath)")
    log("🪪 身份诊断：bundlePath=\(bundlePath) bundleId=\(bundleId) pid=\(ProcessInfo.processInfo.processIdentifier)")

    // 2) 当前进程的 cdhash（与 codesign -d 看到的应一致；用于确认 TCC 授权是否针对此 cdhash）。
    var codeRef: SecCode?
    if SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef {
        var staticRef: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let scode = staticRef {
            var info: CFDictionary?
            if SecCodeCopySigningInformation(scode, SecCSFlags(rawValue: kSecCSDynamicInformation), &info) == errSecSuccess,
               let dict = info as? [String: Any] {
                if let cdhashData = dict["cdhash"] as? Data {
                    let hex = cdhashData.map { String(format: "%02x", $0) }.joined()
                    log("🪪 身份诊断：运行进程 cdhash=\(hex)")
                } else {
                    log("🪪 身份诊断：未取到 cdhash（可能未签名或 ad-hoc 信息不完整）")
                }
            }
        }
    } else {
        log("🪪 身份诊断：SecCodeCopySelf 失败，无法读取运行进程签名信息")
    }

    // 3) 两类权限 API 的真实返回值（只读，不请求授权）。
    let ax = AXIsProcessTrusted()
    let postEvent = CGPreflightPostEventAccess()
    log("🔐 权限诊断（只读）：AXIsProcessTrusted()=\(ax)（辅助功能类别）")
    log("🔐 权限诊断（只读）：CGPreflightPostEventAccess()=\(postEvent)（发送合成键盘事件实际依赖此项）")
    log("🔐 权限诊断：若两者均为 false 且系统设置里已见 HandMark 勾选，多半是 ad-hoc cdhash 随重建变化、"
        + "TCC 授权记录对不上当前 cdhash。先移除旧条目重新授权验证，再决定是否需要稳定签名。")
}

// MARK: - 入口
setbuf(stdout, nil)   // 立即刷新日志，便于重定向验证
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不出现在 Dock、不抢焦点

guard let screenFrame = NSScreen.main?.frame else {
    fatalError("[HandMark] 未找到主屏幕")
}

let state = DrawState()
let overlay = OverlayView(frame: screenFrame, state: state)

let overlayWindow = OverlayWindow(
    contentRect: screenFrame,
    styleMask: .borderless,
    backing: .buffered, defer: false
)
overlayWindow.isOpaque = false
overlayWindow.backgroundColor = .clear
overlayWindow.hasShadow = false
overlayWindow.level = .screenSaver
overlayWindow.ignoresMouseEvents = true          // 鼠标完全穿透到下层应用
overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
overlayWindow.contentView = overlay
gOverlay = overlay   // V2.0：供激光光点绘制

let updateOnMain: () -> Void = { overlay.refresh() }

// 合并窗口：单一「HandMark」预览窗口（顶部预览 + 底部清除/隐藏按钮），复用同一路摄像头
let panelActions = PanelActions(state: state, update: updateOnMain)
gPanelActions = panelActions   // NSControl.target 是 weak，必须持有
let previewWindow = PreviewWindowController(screenFrame: screenFrame, actions: panelActions)
panelActions.previewWindow = previewWindow
gPreview = previewWindow

// 摄像头启动（含权限请求）
HandTracker.start(state: state, update: updateOnMain, screenSize: screenFrame.size)

// 菜单栏入口：显示 HandMark 窗口 / 退出 HandMark（保持 activationPolicy=.accessory）
gStatusItem = makeStatusItem(previewWindow: previewWindow)
observeAppearanceForMenuBarIcon()   // 系统浅/深色切换时自动换菜单栏图标

overlayWindow.orderFrontRegardless()
previewWindow.show()

log("✅ 透明覆盖窗口已启动，屏幕尺寸: \(Int(screenFrame.width))x\(Int(screenFrame.height))")
log("📄 日志文件：\(logPath)")
log("📐 标定文件：\(ROIStore.fileURL.path)")
log("版本：\(appVersionText)")
log("手势：捏合=绘画 / 仅食中伸出+水平挥=翻页 / 六→握拳=清屏；红色光点常驻跟随食指指尖（激光手势已废除）")
log("新增：五指张开=旋钮（顺时针切笔刷粗细 粗→中→细，逆时针切颜色 黄→蓝→黑→绿→白）；"
    + "拇指朝上/朝下=系统音量 ±\(VOLUME_STEP_PERCENT)%")
log("窗口内可清除笔迹/隐藏预览，菜单栏可显示/退出")

// ── 权限诊断（只读，不改签名/手势/绘画）───────────────────────────────────────
// 目的：证明日志确实来自「当前运行的这个可执行文件」，并同时记录两类权限 API 的真实返回值，
// 以区分失败发生在哪一类权限上（辅助功能 vs 事件合成）。
logPermissionAndIdentityDiagnostics()

// V2.0：翻页依赖系统方向键事件，需「辅助功能」权限。启动时提示当前状态（不弹窗、不假装成功）。
if gPageFlipper.hasAccessibilityPermission {
    log("✅ 辅助功能权限已授予，PPT 翻页可用")
} else {
    log("⚠️ 未获辅助功能权限：翻页手势会识别但无法发送方向键。")
    log("   请到 系统设置 > 隐私与安全性 > 辅助功能，勾选 HandMark（或启动它的终端），然后重启本应用。")
}
// V3.0：启动时确认系统音量是否真的可读写。不支持时如实说明，不在手势成功后伪造音量变化。
switch gSystemVolume.currentVolume() {
case .success(let value):
    let percent = Int((Double(value) * 100).rounded())
    log("✅ 系统音量可用（公开 Core Audio API），当前 \(percent)%")
case .failure(let error):
    log("⚠️ 系统音量不可用：\(error.description)。拇指音量手势将识别但不改变音量，并提示失败原因。")
}

app.run()

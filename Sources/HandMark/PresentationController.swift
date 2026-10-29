//
//  PresentationController.swift
//  HandMark
//
//  双演示软件统一翻页控制器：Microsoft PowerPoint（AppleScript）+ WPS 演示（定向键盘事件）。
//
//  设计要点（对应任务要求）：
//  - 统一接口 PresentationController：发现运行中的目标、选择当前放映目标、提供上一页/下一页/诊断。
//  - 两种软件用**各自独立**的适配器隔离，互不复用对方的控制对象模型：
//      · PowerPointAdapter：委托已验证语法的 PowerPointController（AppleScript）。
//      · WPSAdapter：CGEvent.postToPid **定向**发送方向键到 WPS 进程（WPS 无 AppleScript 字典）。
//  - 结果状态严格区分，且 **eventPosted ≠ 翻页成功**：WPS 无可编程的放映状态/翻页校验手段，
//    事件提交成功只记录为「已提交，待用户目视确认」，绝不记为「翻页成功」。
//  - 不做无提示的方式回退；不修改手势/绘制/摄像头/现有 PageFlipper。
//
//  本机已确认（非猜测）：
//  - WPS 安装在 /Applications/wpsoffice.app，bundle id = com.kingsoft.wpsoffice.mac，
//    无 AppleScript 字典（sdef 返回 -192）→ 只能走键盘事件。
//  - Microsoft PowerPoint 未安装 → 其适配器只能做静态检查/编译验证，不能声称实机通过。
//
//  仅 import Foundation / AppKit / CoreGraphics。无网络 / MCP / 后端依赖。
//

import Foundation
import AppKit
import CoreGraphics
#if canImport(HandMarkCore)
import HandMarkCore
#endif

// MARK: - 统一结果状态

/// 一次翻页/控制调用的统一结果。各状态含义见任务 §3。
enum PresentationResult: Equatable, Error {
    /// 目标应用未运行。
    case targetNotRunning
    /// 有多个可控目标且无法确定当前放映目标（需用户明确）。
    case targetAmbiguous
    /// 缺少所需权限（PowerPoint=Automation 自动化；WPS=辅助功能 Accessibility / 事件合成访问）。
    case permissionDenied
    /// 事件已提交，但**尚未**验证幻灯片是否真的变化（WPS 键盘事件的最好结果）。
    case eventPosted
    /// PowerPoint 的 AppleScript 执行失败（含原始错误号/消息）。
    case scriptFailed(code: Int, message: String)
    /// PowerPoint 在运行但未进入放映（无放映窗口）。
    case notPresenting
    /// 当前环境不支持该控制方式（如目标无任何可用控制通道）。
    case unsupported(reason: String)

    var logMessage: String {
        switch self {
        case .targetNotRunning: return "目标应用未运行"
        case .targetAmbiguous:  return "存在多个可控目标，无法确定当前放映目标"
        case .permissionDenied: return "缺少所需权限"
        case .eventPosted:      return "事件已提交（尚未验证幻灯片是否变化，请目视确认）"
        case .scriptFailed(let c, let m): return "AppleScript 执行失败（错误 \(c)）：\(m)"
        case .notPresenting:    return "目标未进入放映状态"
        case .unsupported(let r): return "当前环境不支持该控制方式：\(r)"
        }
    }
}

enum PageDir { case next, prev }

/// 翻页控制目标的可读状态（不真正翻页，仅供 UI 状态显示）。
enum PageTargetStatus { case ready, noTarget, noPermission }

// MARK: - 适配器协议

/// 一种演示软件的控制适配器。
protocol PresentationAdapter: AnyObject {
    var target: PresentationTarget { get }
    /// 目标进程是否在运行（本地查询，不发任何事件）。
    var isRunning: Bool { get }
    /// 运行中的进程（用于日志：名称/bundleId/pid/前台）。nil 表示未运行。
    var runningApp: NSRunningApplication? { get }
    /// 目标是否当前位于前台（用于「两个都在跑」时选当前放映的那个）。
    var isFrontmost: Bool { get }
    /// 控制方式名称（日志用）。
    var methodName: String { get }
    /// 只读探测是否可控（不翻页）。
    func canControl() -> PresentationResult
    /// 翻页一次。
    func navigate(_ dir: PageDir) -> PresentationResult
}

/// 可识别的目标软件。
enum PresentationTarget: String {
    case powerPoint = "Microsoft PowerPoint"
    case wps = "WPS 演示"

    var bundleId: String {
        switch self {
        case .powerPoint: return "com.microsoft.Powerpoint"
        case .wps:        return "com.kingsoft.wpsoffice.mac"
        }
    }
}

// MARK: - PowerPoint 适配器（AppleScript，委托已验证的 PowerPointController）

final class PowerPointAdapter: PresentationAdapter {
    let target: PresentationTarget = .powerPoint
    private let controller = PowerPointController()

    var runningApp: NSRunningApplication? { HandMark_runningApp(bundleId: target.bundleId) }
    var isRunning: Bool { runningApp != nil }
    var isFrontmost: Bool { runningApp?.isActive ?? false }
    var methodName: String { "AppleScript / Apple Events" }

    func canControl() -> PresentationResult {
        return map(controller.canControlPowerPoint())
    }

    func navigate(_ dir: PageDir) -> PresentationResult {
        let r = (dir == .next) ? controller.nextSlide() : controller.previousSlide()
        return map(r)
    }

    /// 把 PowerPointController 的结果映射到统一结果。
    private func map(_ r: PPTControlResult) -> PresentationResult {
        switch r {
        case .ok:                       return .eventPosted  // PPT 虽由脚本确认接受，但统一口径仍让用户目视确认
        case .notRunning:               return .targetNotRunning
        case .automationDenied:         return .permissionDenied
        case .notPresenting:            return .notPresenting
        case .cannotConnect(let c, let m): return .scriptFailed(code: c, message: m)
        case .scriptError(let c, let m):   return .scriptFailed(code: c, message: m)
        }
    }
}

// MARK: - WPS 适配器（CGEvent.postToPid 定向方向键）

/// WPS 演示无 AppleScript 字典 → 用 CGEvent 把方向键**定向投递到 WPS 进程**（postToPid），
/// 而不是走 HID 全局注入（避免打到 HandMark 自己的窗口）。
/// 投递逻辑与已验证可用的 WPSFlipTest 完全一致：先激活 WPS 到前台、用 nil 事件源、定向投递。
final class WPSAdapter: PresentationAdapter {
    let target: PresentationTarget = .wps
    /// 右方向键=下一页，左方向键=上一页（WPS 放映与 PowerPoint 一致；也兼容 PageDown/PageUp）。
    private let rightKey: CGKeyCode = 124
    private let leftKey: CGKeyCode = 123

    var runningApp: NSRunningApplication? { HandMark_findWPS() }
    var isRunning: Bool { runningApp != nil }
    var isFrontmost: Bool { runningApp?.isActive ?? false }
    var methodName: String { "CGEvent.postToPid 定向方向键（需「辅助功能」权限）" }

    /// 发送合成键盘事件（CGEvent.postToPid）所需的权限，本机会话实测由
    /// **辅助功能（Accessibility）** 管辖——`CGPreflightPostEventAccess()` 返回 true 的前提是
    /// 本进程已在「系统设置 > 隐私与安全性 > 辅助功能」中被勾选（与 WPSFlipTest 验证结论一致）。
    /// 注意：输入监控（Input Monitoring）管辖的是「监听」类事件（CGEvent tap / ListenEvent），
    /// 与这里「发送」合成事件不是同一类别，请勿混淆。
    private var hasPostEventAccess: Bool { CGPreflightPostEventAccess() }

    /// 打印权限 API 的真实返回值，便于区分到底哪一类权限缺失（诊断用，不改变发送逻辑）。
    func logPermissionDiagnostics() {
        let ax = AXIsProcessTrusted()
        let preflight = CGPreflightPostEventAccess()
        log("🔐 WPS 权限诊断：CGPreflightPostEventAccess()=\(preflight)（发送合成键盘事件实际依赖此项，" +
            "对应「隐私与安全性 > 辅助功能」）；AXIsProcessTrusted()=\(ax)（辅助功能，另一类别，仅参考）")
    }

    func canControl() -> PresentationResult {
        guard runningApp != nil else { return .targetNotRunning }
        logPermissionDiagnostics()
        guard hasPostEventAccess else {
            // 首次缺权限时主动触发系统授权请求（可能弹出「辅助功能」授权提示）。不伪造成功、不静默切换。
            let requested = CGRequestPostEventAccess()
            log("🔐 WPS canControl：无事件合成访问权限 → 已调用 CGRequestPostEventAccess()，返回=\(requested)。" +
                "请在 系统设置 > 隐私与安全性 > 辅助功能 中勾选 HandMark 后重试。")
            return .permissionDenied
        }
        // WPS 没有可编程的放映状态查询手段 → 无法在 canControl 阶段确认是否正在放映。
        // 这里只能确认「进程在 + 有权限」，是否放映交由用户目视。
        return .eventPosted
    }

    func navigate(_ dir: PageDir) -> PresentationResult {
        guard let app = runningApp else { return .targetNotRunning }
        let pid = app.processIdentifier
        logPermissionDiagnostics()
        guard hasPostEventAccess else {
            let requested = CGRequestPostEventAccess()
            log("🔐 WPS navigate：无事件合成访问权限 → 已调用 CGRequestPostEventAccess()，返回=\(requested)。" +
                "请在 系统设置 > 隐私与安全性 > 辅助功能 中勾选 HandMark 后重试。")
            return .permissionDenied
        }

        // 与 WPSFlipTest 一致：投递前先把 WPS 激活到前台（含失败重试），
        // 确保全屏放映窗口确实收到方向键（否则事件可能被其他窗口吞掉）。
        activateAndConfirm(app)

        let key = (dir == .next) ? rightKey : leftKey
        // 与已验证可用的 WPSFlipTest 保持一致：用 nil 事件源（不绑定会话状态），实测更稳。
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            return .unsupported(reason: "无法创建 CGEvent 键盘事件")
        }
        // 关键：postToPid 把事件**定向**投递给 WPS 进程，而非全局 HID 注入。
        down.postToPid(pid)
        up.postToPid(pid)
        // 只能确认「事件已提交到 WPS 进程」——不能据此断言幻灯片已变化（WPS 无可编程校验）。
        return .eventPosted
    }

    /// 投递前激活 WPS 到前台（与 WPSFlipTest 一致：activate + 短暂等待 + 失败重试），
    /// 确保全屏放映窗口确实收到方向键。
    private func activateAndConfirm(_ app: NSRunningApplication) {
        app.activate()
        usleep(200_000)
        if let fm = NSWorkspace.shared.frontmostApplication,
           fm.processIdentifier != app.processIdentifier {
            log("🎯 WPS 未在前台，重试激活…")
            app.activate()
            usleep(200_000)
        }
    }
}

// MARK: - WPS 进程发现（与 WPSFlipTest 成功经验一致）

/// WPS 主程序 Bundle ID（精确匹配优先，避免命中帮助/辅助进程）。
private let WPS_PRIMARY_BUNDLE_IDS = ["com.kingsoft.wpsoffice.mac", "com.kingsoft.wpsoffice"]

/// 定位 WPS 进程：
/// 1) 精确 Bundle ID 优先（排除帮助/辅助进程）；
/// 2) 多进程时优先正在放映的前台进程；
/// 3) 宽松匹配 kingsoft/wps 作为兜底。
/// 与已验证可用的 WPSFlipTest 的 findWPS() 行为一致。
private func HandMark_findWPS() -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications

    let exact = apps.filter { WPS_PRIMARY_BUNDLE_IDS.contains($0.bundleIdentifier ?? "") }
    if !exact.isEmpty {
        if let front = exact.first(where: { $0.isActive }) { return front }
        return exact.first
    }

    let loose = apps.filter {
        let bid = ($0.bundleIdentifier ?? "").lowercased()
        let name = ($0.localizedName ?? "").lowercased()
        return bid.contains("kingsoft") || bid.contains("wps") ||
               name.contains("wps") || name.contains("wpsoffice")
    }
    if !loose.isEmpty {
        if let front = loose.first(where: { $0.isActive }) { return front }
        return loose.first
    }
    return nil
}

// 注：Swift 顶层 `runningApp` 与适配器里的属性同名会产生歧义，这里用一个带前缀的自由函数。
private func HandMark_runningApp(bundleId: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
}

// MARK: - 统一控制器

final class PresentationController {
    private let powerPoint = PowerPointAdapter()
    private let wps = WPSAdapter()
    private var adapters: [PresentationAdapter] { [powerPoint, wps] }

    /// 发送合成键盘事件（向 WPS / PowerPoint 定向投递）所需的权限，只读探测、不弹窗。
    /// 对应「系统设置 > 隐私与安全性 > 辅助功能」，与 WPSAdapter 实际翻页所依赖的
    /// `CGPreflightPostEventAccess()` 语义一致（区别于另一类别的 AXIsProcessTrusted）。
    /// 供启动日志 / UI 提示统一引用，替代已移除的 PageFlipper 探针。
    var hasPostEventAccess: Bool { CGPreflightPostEventAccess() }

    /// 发现当前运行中的目标，并打印诊断（名称/bundleId/pid/前台）。
    @discardableResult
    func detectTargets() -> [PresentationAdapter] {
        logFullRunningDiagnostics()
        let running = adapters.filter { $0.isRunning }
        if running.isEmpty {
            log("🔎 目标发现：没有正在运行的演示软件（PowerPoint / WPS 均未运行）")
        } else {
            for a in running {
                let app = a.runningApp
                log("🔎 目标发现：\(a.target.rawValue) bundleId=\(a.target.bundleId) " +
                    "pid=\(app?.processIdentifier ?? -1) 前台=\(a.isFrontmost ? "是" : "否") 控制方式=\(a.methodName)")
            }
        }
        return running
    }

    /// 选择当前要控制的目标：只有一个就用它；多个时选前台那个；都不在前台则无法确定。
    private func chooseTarget() -> Result<PresentationAdapter, PresentationResult> {
        let running = adapters.filter { $0.isRunning }
        switch running.count {
        case 0:
            return .failure(.targetNotRunning)
        case 1:
            return .success(running[0])
        default:
            let frontmost = running.filter { $0.isFrontmost }
            if frontmost.count == 1 {
                log("🔎 目标选择：多个演示软件在运行，选前台应用 \(frontmost[0].target.rawValue)")
                return .success(frontmost[0])
            }
            log("🔎 目标选择：多个演示软件在运行且无法确定前台放映目标 → targetAmbiguous")
            return .failure(.targetAmbiguous)
        }
    }

    func canControlTarget() -> PresentationResult {
        switch chooseTarget() {
        case .failure(let r): return r
        case .success(let a): return a.canControl()
        }
    }

    /// 只读探测翻页目标状态（供 UI 状态显示，不真正翻页、不弹权限请求）。
    /// - 无运行中的演示软件 → .noTarget
    /// - 有目标但缺少辅助功能权限（WPS 定向投递所需，本机实际场景）→ .noPermission
    /// - 其余 → .ready
    func targetStatus() -> PageTargetStatus {
        switch chooseTarget() {
        case .failure(.targetNotRunning):
            return .noTarget
        case .failure:
            return .ready   // 多目标等异常态，翻页时再决定
        case .success:
            // CGPreflightPostEventAccess 为只读探测，不会触发授权弹窗（区别于 canControl 内的 CGRequestPostEventAccess）。
            return CGPreflightPostEventAccess() ? .ready : .noPermission
        }
    }

    func nextSlide() -> PresentationResult { navigate(.next) }
    func previousSlide() -> PresentationResult { navigate(.prev) }

    private func navigate(_ dir: PageDir) -> PresentationResult {
        let dirText = (dir == .next) ? "下一页" : "上一页"
        switch chooseTarget() {
        case .failure(let r):
            log("🛑 翻页（\(dirText)）未执行：\(r.logMessage)")
            return r
        case .success(let a):
            let app = a.runningApp
            let result = a.navigate(dir)
            // 统一日志：目标应用 / bundleId / pid / 控制方式 / 方向 / 结果。
            log("🎯 翻页请求 目标=\(a.target.rawValue) bundleId=\(a.target.bundleId) " +
                "pid=\(app?.processIdentifier ?? -1) 方式=\(a.methodName) 方向=\(dirText) → \(result)（\(result.logMessage)）")
            if result == .eventPosted {
                log("👁 请目视确认幻灯片是否真的\(dirText)了（eventPosted 不等于翻页成功）")
            }
            return result
        }
    }

    /// 打印所有疑似演示软件的进程（诊断用，不拦截）。
    private func logFullRunningDiagnostics() {
        let apps = NSWorkspace.shared.runningApplications
        let hits = apps.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            return name.contains("powerpoint") || name.contains("wps") ||
                   bid.contains("powerpoint") || bid.contains("kingsoft") || bid.contains("wps")
        }
        if hits.isEmpty {
            log("🔎 运行诊断：未发现 PowerPoint / WPS 相关进程")
            return
        }
        for app in hits {
            log("🔎 运行诊断：名称=\(app.localizedName ?? "nil") " +
                "bundleId=\(app.bundleIdentifier ?? "nil") pid=\(app.processIdentifier) " +
                "前台=\(app.isActive ? "是" : "否")")
        }
    }
}

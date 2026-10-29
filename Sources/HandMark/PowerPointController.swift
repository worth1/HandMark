//
//  PowerPointController.swift
//  HandMark
//
//  通过 AppleScript / Apple Events 控制「正在放映」的 Microsoft PowerPoint 翻页。
//
//  设计依据（任务要求）：
//  - 默认机制：AppleScript。不依赖 HandMark 窗口是否持有键盘焦点；不切换前台窗口。
//  - 针对**当前放映窗口**执行：`slide show window 1` 仅在放映时存在，
//    `go to next/previous slide` 作用于其 `slide show view`（普通编辑视图不受影响）。
//    语法以 PowerPoint 脚本字典与社区实证为准（go to slide 只在普通视图有效，故不使用）。
//  - 明确区分并分别处理：未运行 / 运行但无法连接 / Automation 未授权 / 未放映 / 脚本/对象模型失败。
//  - 失败绝不静默：记录原始 AppleScript 错误码与消息，不把所有异常都归为「未运行」。
//  - 不自动回退到键盘模拟（CGEvent 仅手动备选）。
//
//  关键修订（阶段 A 第一次实测失败的根因）：
//  原实现在发 AppleScript 之前，先用 `NSWorkspace` 按「应用显示名/硬编码 bundle id」做一道
//  运行判断，判断为 false 就直接返回「未运行」——这把真实错误（比如 bundle id 大小写不符、
//  本地化名称不同、或其实是 Automation 未授权）全部误报成「PowerPoint 未运行」。
//  现在改为：**不拦截**，始终让 AppleScript 真正执行，用其**原始错误码**来区分各种失败；
//  `NSWorkspace` 的查询只用于**诊断日志**，不再作为是否发送 Apple Event 的硬门槛。
//
//  仅 import Foundation / AppKit（NSAppleScript）。不引入任何网络 / MCP / 后端依赖。
//

import Foundation
import AppKit
import HandMarkCore

/// PowerPoint 当前可控状态 / 一次翻页调用的结果。
enum PPTControlResult: Equatable {
    /// 成功执行（翻页命令已被 PowerPoint 接受）。
    case ok
    /// PowerPoint 未运行（由 AppleScript 错误码判定：-600 procNotFound / -1728 等）。
    case notRunning
    /// PowerPoint 在运行，但 AppleScript 无法连接 / 应用拒绝事件（非权限类连接失败）。
    case cannotConnect(code: Int, message: String)
    /// Automation 权限未授权（-1743 / -1744）。
    case automationDenied
    /// PowerPoint 在运行，但当前没有处于放映（无 slide show window）。
    case notPresenting
    /// AppleScript 语法 / 对象模型调用失败（含原始错误号与描述）。
    case scriptError(code: Int, message: String)

    /// 面向用户/日志的中文说明。
    var logMessage: String {
        switch self {
        case .ok:
            return "翻页命令执行成功"
        case .notRunning:
            return "PowerPoint 未运行：请先打开 PPT"
        case .cannotConnect(let code, let message):
            return "PowerPoint 在运行但 AppleScript 无法连接（错误 \(code)）：\(message)"
        case .automationDenied:
            return "Automation 权限未授权：系统设置 > 隐私与安全性 > 自动化 > HandMark，勾选「Microsoft PowerPoint」后重试"
        case .notPresenting:
            return "PowerPoint 未进入放映：请先开始幻灯片放映（放映状态下才有可翻页的窗口）"
        case .scriptError(let code, let message):
            return "AppleScript 执行失败（错误 \(code)）：\(message)"
        }
    }

    /// 是否为「可翻页」状态。
    var isControllable: Bool { self == .ok }
}

/// 控制正在放映的 PowerPoint 的服务（AppleScript 默认机制）。
///
/// 线程说明：`NSAppleScript` 需在主线程执行。本服务的所有公开方法都假定在主线程调用
/// （现有翻页裁决发生在 `captureOutput` 的主线程回调里，满足该约束）。
final class PowerPointController {

    /// PowerPoint 的应用名（AppleScript 以此定位；比 bundle id 更贴合脚本字典用法）。
    private let appName = "Microsoft PowerPoint"

    // MARK: - 公开接口

    /// 下一页（放映中）。返回结构化结果，调用方据此记录「命令执行成功/失败」。
    @discardableResult
    func nextSlide() -> PPTControlResult {
        return navigate(next: true)
    }

    /// 上一页（放映中）。
    @discardableResult
    func previousSlide() -> PPTControlResult {
        return navigate(next: false)
    }

    /// 状态检查：当前是否可以控制 PowerPoint 翻页（运行 + 放映 + 已授权）。
    /// 会实际向 PowerPoint 发 Apple Event（可能触发/命中 Automation 授权），并打印诊断日志。
    func canControlPowerPoint() -> PPTControlResult {
        logRunningDiagnostics()
        let script = """
        tell application "\(appName)"
            try
                return (count of slide show windows) as string
            on error errMsg number errNum
                return "ERR:" & errNum & ":" & errMsg
            end try
        end tell
        """
        let outcome = run(script)
        switch outcome {
        case .failure(let failure):
            log("🔎 canControlPowerPoint：\(failure.result.logMessage)")
            return failure.result
        case .success(let value):
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(v), n >= 1 {
                log("🔎 canControlPowerPoint：可控（放映窗口数=\(n)）")
                return .ok
            }
            log("🔎 canControlPowerPoint：\(PPTControlResult.notPresenting.logMessage)（放映窗口数=\(v)）")
            return .notPresenting
        }
    }

    // MARK: - 诊断

    /// 打印当前所有疑似 PowerPoint 的进程（名称 / bundleId / PID）。仅用于诊断，不做任何拦截。
    private func logRunningDiagnostics() {
        let apps = NSWorkspace.shared.runningApplications
        let candidates = apps.filter { app in
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            return name.contains("powerpoint") || bid.contains("powerpoint")
        }
        if candidates.isEmpty {
            log("🔎 运行诊断：未发现名称/bundleId 含 powerpoint 的进程（注意：这不作为翻页拦截依据）")
        } else {
            for app in candidates {
                let name = app.localizedName ?? "nil"
                let bid = app.bundleIdentifier ?? "nil"
                let active = app.isActive ? "前台" : "后台"
                log("🔎 运行诊断：匹配到 PowerPoint 进程 名称=\(name) bundleId=\(bid) pid=\(app.processIdentifier) 状态=\(active)")
            }
        }
    }

    // MARK: - 内部

    /// 执行翻页：始终真正发送 AppleScript，由其**原始错误码**区分失败类型；不做本地运行拦截。
    private func navigate(next: Bool) -> PPTControlResult {
        logRunningDiagnostics()

        // 关键：针对**当前放映窗口**（slide show window 1）的放映视图执行。
        // 命令语法修订（修 -2741）：放映视图是 `go to next/previous slide` 命令的**直接宾语**，
        // 必须用 `tell <view> to go to next slide`，而**不能**写成
        // `go to next slide slide show view of ...`——后者会被解析器当作「命令后跟多余标识符」，
        // 报 -2741（expected parameter name but found identifier）。
        // 依据 PowerPoint 脚本字典与社区实证：放映窗口可响应 go to next/previous slide；
        // go to slide / slide / current show position 在放映窗口不可用（故不使用）。
        let command = next ? "go to next slide" : "go to previous slide"
        let script = """
        tell application "\(appName)"
            try
                if (count of slide show windows) is 0 then
                    return "NOTSHOW"
                end if
                tell slide show view of slide show window 1 to \(command)
                return "OK"
            on error errMsg number errNum
                return "ERR:" & errNum & ":" & errMsg
            end try
        end tell
        """

        let outcome = run(script)
        let label = next ? "下一页" : "上一页"
        switch outcome {
        case .failure(let failure):
            log("🛑 翻页命令执行失败（\(label)）：\(failure.result.logMessage)")
            return failure.result
        case .success(let value):
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v == "OK" {
                log("✅ \(label)：\(PPTControlResult.ok.logMessage)")
                return .ok
            }
            if v == "NOTSHOW" {
                log("🛑 翻页命令执行失败（\(label)）：\(PPTControlResult.notPresenting.logMessage)")
                return .notPresenting
            }
            let result = PPTControlResult.scriptError(code: 0, message: "未知脚本返回：\(v)")
            log("🛑 翻页命令执行失败（\(label)）：\(result.logMessage)")
            return result
        }
    }

    /// 运行一段 AppleScript，把执行层错误与脚本内业务错误都归一化成 `PPTControlResult`。
    ///
    /// 始终记录**原始错误码与消息**（不丢失信息），再按错误码分类：
    /// - -1743 / -1744：Automation 未授权。
    /// - -600（procNotFound）/ -1728 常见于「应用未运行 / 对象不存在」：此处 -600 判为未运行。
    /// - -1708 / -1721 等：语法 / 对象模型调用失败。
    /// - 其余执行层错误：运行但无法连接（cannotConnect），保留原始码。
    private func run(_ source: String) -> Result<String, PPTControlResultFailure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.init(result: .scriptError(code: -1, message: "无法创建 AppleScript 对象")))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "未知错误"
            // 原始错误始终记录，便于定位（不被下面的归类掩盖）。
            log("🧩 AppleScript 执行层错误：errorNumber=\(code) errorMessage=\(message)")
            return .failure(.init(result: classify(code: code, message: message)))
        }

        // 脚本正常返回：取字符串值（我们所有脚本都 return 字符串）。
        let value = descriptor.stringValue ?? "\(descriptor.int32Value)"
        // 脚本内 try/on error 捕获的业务错误以 ERR:num:msg 回传，这里同样记录原始码再分类。
        if value.hasPrefix("ERR:") {
            let parts = value.dropFirst(4).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let code = Int(parts.first ?? "0") ?? 0
            let msg = parts.count > 1 ? String(parts[1]) : "未知错误"
            log("🧩 AppleScript 脚本内错误：errNum=\(code) errMsg=\(msg)")
            return .failure(.init(result: classify(code: code, message: msg)))
        }
        return .success(value)
    }

    /// 把 AppleScript 错误码归类为结构化结果（原始码/消息已在调用处记录）。
    private func classify(code: Int, message: String) -> PPTControlResult {
        switch code {
        case -1743, -1744:
            return .automationDenied
        case -600, -609:
            // -600 procNotFound / -609 connectionInvalid：应用未运行。
            return .notRunning
        case -1708, -1721, -1700, -10000, -2741, -2740:
            // 事件不被处理 / 参数不符 / 强制转换失败 / Apple event 处理失败 /
            // -2741 -2740 AppleScript 解析（语法）错误：统归语法或对象模型问题，保留原始码。
            return .scriptError(code: code, message: message)
        default:
            // 其余执行层错误：应用在但无法连接（保留原始码，不冒充「未运行」）。
            return .cannotConnect(code: code, message: message)
        }
    }
}

/// 包装器：让 `run` 的失败分支携带一个 `PPTControlResult`。
private struct PPTControlResultFailure: Error {
    let result: PPTControlResult
}

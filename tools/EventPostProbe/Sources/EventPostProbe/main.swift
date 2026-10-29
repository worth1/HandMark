//
//  EventPostProbe — 事件合成（发送按键）权限诊断程序（独立于 HandMark）
//
//  本轮唯一目标：弄清「事件合成访问（CGPreflightPostEventAccess）」为什么拿不到。
//  因此本程序**不发送任何按键、不触达 WPS、不做任何自动化发键**。
//  只做两件事：
//    1) 身份与权限只读诊断（启动即打印）。
//    2) 一个手动按钮触发 CGRequestPostEventAccess()，记录调用前后状态与是否观察到系统提示。
//
//  权限语义（依据已安装 SDK 的 CoreGraphics/CGEvent.h 原注释，可本机核对）：
//    - CGPreflightPostEventAccess()  = 「event synthesizing access」（发送/合成事件）——发键真正所需。
//    - CGPreflightListenEventAccess()= 「event listening access」（= Input Monitoring 输入监控）——仅对照。
//    - AXIsProcessTrusted()          = Accessibility（辅助功能）——另一类别，仅对照。
//
//  仅 import AppKit / CoreGraphics / Security。无网络、无第三方依赖。
//

import AppKit
import CoreGraphics
import Security

// MARK: - 日志（窗口内文本 + stdout）

final class ProbeLog {
    static let shared = ProbeLog()
    weak var textView: NSTextView?
    func line(_ s: String) {
        let msg = "\(Date()) \(s)"
        print(msg)
        DispatchQueue.main.async {
            guard let tv = self.textView else { return }
            tv.string += msg + "\n"
            tv.scrollToEndOfDocument(nil)
        }
    }
}
func plog(_ s: String) { ProbeLog.shared.line(s) }

// MARK: - 身份诊断（修正 cdhash 歧义）

/// 读取本进程签名信息，明确区分「未签名 / adhoc / 有 Team」而不是「没取到 cdhash 就当未签名」。
func logIdentity() {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "未知"
    let bid = Bundle.main.bundleIdentifier ?? "nil（可能以裸二进制运行，无 bundle）"
    let pid = ProcessInfo.processInfo.processIdentifier
    plog("🪪 可执行文件=\(exe)")
    plog("🪪 bundleId=\(bid) pid=\(pid)")

    var codeRef: SecCode?
    let selfStatus = SecCodeCopySelf([], &codeRef)
    guard selfStatus == errSecSuccess, let code = codeRef else {
        plog("🪪 签名：SecCodeCopySelf 失败（OSStatus=\(selfStatus)）——无法判定签名状态")
        return
    }
    var staticRef: SecStaticCode?
    let stStatus = SecCodeCopyStaticCode(code, [], &staticRef)
    guard stStatus == errSecSuccess, let scode = staticRef else {
        plog("🪪 签名：SecCodeCopyStaticCode 失败（OSStatus=\(stStatus)）")
        return
    }

    // kSecCSSigningInformation 取签名类别（含 flags / teamid）；kSecCSDynamicInformation 取 cdhash。
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
    let infoStatus = SecCodeCopySigningInformation(scode, flags, &info)
    guard infoStatus == errSecSuccess, let dict = info as? [String: Any] else {
        plog("🪪 签名：SecCodeCopySigningInformation 失败（OSStatus=\(infoStatus)）")
        return
    }

    // 1) 是否签名 + 签名类型。用 CodeSignature flags 判定 adhoc，而非靠 cdhash 是否存在。
    //    kSecCodeSignatureAdhoc = 0x2；无签名字典则判为未签名。
    if let csFlags = dict[kSecCodeInfoFlags as String] as? UInt32 {
        let isAdhoc = (csFlags & 0x2) != 0
        plog("🪪 签名类型：\(isAdhoc ? "ad-hoc（0x2 置位）" : "非 ad-hoc")（CodeSignature flags=0x\(String(csFlags, radix: 16))）")
    } else if dict[kSecCodeInfoIdentifier as String] == nil {
        plog("🪪 签名类型：未签名（无签名标识/flags）")
    } else {
        plog("🪪 签名类型：已签名（未读到 flags，类型未细分）")
    }

    // 2) Team ID（ad-hoc 通常为 nil；这是已证实事实，不是推断）。
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    plog("🪪 TeamIdentifier=\(team ?? "nil（未设置，ad-hoc 签名的正常现象）")")

    // 3) 签名内 identifier。
    if let ident = dict[kSecCodeInfoIdentifier as String] as? String {
        plog("🪪 签名 identifier=\(ident)")
    }

    // 4) cdhash：有就打印；没有**不**等于未签名（上面已用 flags/identifier 判定签名状态）。
    if let cd = dict[kSecCodeInfoUnique as String] as? Data {
        plog("🪪 CDHash=\(cd.map { String(format: "%02x", $0) }.joined())")
    } else if let cdhashes = dict["cdhashes"] as? [Data], let first = cdhashes.first {
        plog("🪪 CDHash=\(first.map { String(format: "%02x", $0) }.joined())")
    } else {
        plog("🪪 CDHash：本次未从签名信息取到（注意：这不代表未签名，签名状态以上面的『签名类型』为准）")
    }
}

// MARK: - 权限只读诊断

func logPreflight(_ tag: String = "") {
    let post = CGPreflightPostEventAccess()
    let listen = CGPreflightListenEventAccess()
    let ax = AXIsProcessTrusted()
    let prefix = tag.isEmpty ? "" : "[\(tag)] "
    plog("🔐 \(prefix)CGPreflightPostEventAccess()=\(post)   ← 发送/合成按键真正所需（本轮关注）")
    plog("🔐 \(prefix)CGPreflightListenEventAccess()=\(listen)  ← 事件监听 = Input Monitoring（仅对照）")
    plog("🔐 \(prefix)AXIsProcessTrusted()=\(ax)              ← Accessibility 辅助功能（仅对照）")
}

// MARK: - UI

final class Probe: NSObject {
    @objc func onReadonly(_ s: Any?) {
        plog("—— 只读复查权限 ——")
        logIdentity()
        logPreflight("只读")
    }

    @objc func onRequest(_ s: Any?) {
        plog("—— 手动触发 CGRequestPostEventAccess() ——")
        plog("➊ 调用前状态：")
        logPreflight("前")
        plog("➋ 现在调用 CGRequestPostEventAccess()（可能弹系统提示，也可能不弹——以观察为准）…")
        let r = CGRequestPostEventAccess()
        plog("➌ 返回值=\(r)")
        plog("   语义：true=当前已具备事件合成访问；false=当前不具备。**false 不等于用户点了拒绝**，"
            + "也可能是系统未弹窗/已记录过/身份对不上授权记录。")
        plog("➍ 调用后状态：")
        logPreflight("后")
        plog("👉 请在屏幕上观察：是否出现了系统授权对话框？把观察结果连同以上日志反馈给我。")
    }
}

let probe = Probe()
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
win.title = "EventPostProbe — 事件合成权限诊断（不发送按键）"
win.center()

let content = NSView(frame: win.contentView!.bounds)
content.autoresizingMask = [.width, .height]

func mkButton(_ title: String, _ action: Selector, x: CGFloat, w: CGFloat) -> NSButton {
    let b = NSButton(title: title, target: probe, action: action)
    b.frame = NSRect(x: x, y: 420, width: w, height: 30)
    b.bezelStyle = .rounded
    return b
}
content.addSubview(mkButton("① 只读复查权限", #selector(Probe.onReadonly(_:)), x: 12, w: 180))
content.addSubview(mkButton("② 请求事件合成权限 (Request)", #selector(Probe.onRequest(_:)), x: 200, w: 280))

let scroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 736, height: 398))
scroll.hasVerticalScroller = true
scroll.autoresizingMask = [.width, .height]
let tv = NSTextView(frame: scroll.bounds)
tv.isEditable = false
tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
tv.autoresizingMask = [.width, .height]
scroll.documentView = tv
content.addSubview(scroll)
ProbeLog.shared.textView = tv

win.contentView = content
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

plog("=== EventPostProbe 启动（本轮不发送任何按键、不触达 WPS）===")
plog("目标：确认事件合成访问 CGPreflightPostEventAccess 为何拿不到。")
logIdentity()
logPreflight("启动")
plog("用法：先看启动时的 🔐 三行；点 ② 请求一次并观察是否弹窗；再点 ① 复查是否变化。")

app.run()

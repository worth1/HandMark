// ProbeCLI — 与 EventPostProbe「只读复查权限」按钮等价的命令行版本。
// 仅调用三个只读 API 并打印，不发送按键、不触达 WPS、不请求权限。
// 必须与探针使用同一 bundle id 与同一证书签名，TCC 才能对得上代码身份。
import AppKit
import CoreGraphics
import Security

func logIdentity() {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "未知"
    let bid = Bundle.main.bundleIdentifier ?? "nil"
    let pid = ProcessInfo.processInfo.processIdentifier
    print("🪪 可执行文件=\(exe)")
    print("🪪 bundleId=\(bid) pid=\(pid)")
    var codeRef: SecCode?
    guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else {
        print("🪪 签名：SecCodeCopySelf 失败"); return
    }
    var staticRef: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let scode = staticRef else {
        print("🪪 签名：SecCodeCopyStaticCode 失败"); return
    }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation)
    guard SecCodeCopySigningInformation(scode, flags, &info) == errSecSuccess,
          let dict = info as? [String: Any] else {
        print("🪪 签名：SecCodeCopySigningInformation 失败"); return
    }
    if let csFlags = dict[kSecCodeInfoFlags as String] as? UInt32 {
        let isAdhoc = (csFlags & 0x2) != 0
        print("🪪 签名类型：\(isAdhoc ? "ad-hoc（0x2 置位）" : "非 ad-hoc")（flags=0x\(String(csFlags, radix: 16))）")
    }
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    print("🪪 TeamIdentifier=\(team ?? "nil")")
    if let ident = dict[kSecCodeInfoIdentifier as String] as? String {
        print("🪪 签名 identifier=\(ident)")
    }
    if let cd = dict[kSecCodeInfoUnique as String] as? Data {
        print("🪪 CDHash=\(cd.map { String(format: "%02x", $0) }.joined())")
    }
}

func logPreflight(_ tag: String) {
    let post = CGPreflightPostEventAccess()
    let listen = CGPreflightListenEventAccess()
    let ax = AXIsProcessTrusted()
    let prefix = tag.isEmpty ? "" : "[\(tag)] "
    print("🔐 \(prefix)CGPreflightPostEventAccess()=\(post)   ← 发送/合成按键真正所需")
    print("🔐 \(prefix)CGPreflightListenEventAccess()=\(listen)  ← 事件监听 = Input Monitoring（对照）")
    print("🔐 \(prefix)AXIsProcessTrusted()=\(ax)              ← Accessibility 辅助功能（对照）")
}

print("=== ProbeCLI 只读复查（不发送任何按键、不触达 WPS）===")
logIdentity()
logPreflight("只读")

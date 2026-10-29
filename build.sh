#!/bin/bash
# HandMark 构建脚本：编译 Release 版本并打包为 HandMark.app
#
# ── 签名策略（按优先级自动选择）────────────────────────────────────────────
#   1) Developer ID Application  —— 正式对外分发渠道（配合公证可过 Gatekeeper）。
#   2) Apple Development         —— 本机开发调试。
#   3) ad-hoc (--sign -)         —— 兜底。
#
#   为什么尽量用 1/2 而不用 ad-hoc：TCC（辅助功能 / 摄像头 / 输入监控）的授权记录
#   对 ad-hoc 签名是绑定 **CDHash** 的，每次重建二进制都会变 → 旧的授权条目失效，
#   表现为「系统设置里已勾 HandMark，代码里 CGPreflightPostEventAccess() 仍为 false」，
#   必须删掉旧条目重加。用固定证书签名后，TCC 匹配的是「证书 + Bundle ID」，
#   重建不再丢授权。
#
#   显式指定身份（二选一）：
#     SIGN_IDENTITY="Developer ID Application: xxx (TEAM)" ./build.sh
#     ./build.sh "Developer ID Application: xxx (TEAM)"
#
# ── 上架 Mac App Store 请用 package_appstore.sh ──────────────────────────
#   App Store 强制 App Sandbox（HandMark.entitlements），会禁止向 WPS 投递 CGEvent，
#   与翻页功能互斥；本脚本的直发渠道用 HandMark-Direct.entitlements（无沙盒）。
set -e
cd "$(dirname "$0")"

# ── 选择签名身份 ─────────────────────────────────────────────────────────
SIGN_IDENTITY_REQ="${SIGN_IDENTITY:-${1:-}}"
pick_identity() {
    # 从 security find-identity 输出里按关键字取出第一个证书名（引号内文本）
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 "$1" \
        | sed -E 's/^.*"([^"]+)".*$/\1/'
}

if [ -n "$SIGN_IDENTITY_REQ" ]; then
    SIGN_ID="$SIGN_IDENTITY_REQ"
    SIGN_KIND="explicit"
else
    SIGN_ID="$(pick_identity 'Developer ID Application')"
    SIGN_KIND="developer-id"
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID="$(pick_identity 'Apple Development')"
        SIGN_KIND="apple-development"
    fi
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID="-"
        SIGN_KIND="adhoc"
    fi
fi

echo ">>> 编译中..."
# 本环境（WorkBuddy 沙箱下的 SwiftPM）需要禁用 SwiftPM 自带沙箱；本机正常运行无影响。
swift build -c release --disable-sandbox 2>/dev/null || swift build -c release

APP_DIR="HandMark.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/HandMark "$APP_DIR/Contents/MacOS/HandMark"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# 应用图标：assets/icon.png → 多尺寸 .icns
if [ -f assets/icon.png ]; then
    echo ">>> 生成图标..."
    ICONSET=$(mktemp -d)/icon.iconset
    mkdir -p "$ICONSET"
    SQUARE=$(mktemp -d)/icon_square.png
    sips -c 1212 1212 assets/icon.png --out "$SQUARE" >/dev/null 2>&1 || cp assets/icon.png "$SQUARE"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$SQUARE" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        sips -z $((sz * 2)) $((sz * 2)) "$SQUARE" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 菜单栏图标（深色/浅色各一套，由 main.swift 按系统外观切换）
if [ -d assets/menubar ]; then
    cp assets/menubar/*.png "$APP_DIR/Contents/Resources/"
fi

# ── 签名 ─────────────────────────────────────────────────────────────────
ENTITLEMENTS="HandMark-Direct.entitlements"   # 直发渠道：无 App Sandbox（沙盒会禁掉翻页）
[ -f "$ENTITLEMENTS" ] || ENTITLEMENTS=""

sign_with() {   # $1 = 身份, 其余 = 附加参数
    local id="$1"; shift
    if [ -n "$ENTITLEMENTS" ]; then
        codesign --force --deep --sign "$id" --entitlements "$ENTITLEMENTS" "$@" "$APP_DIR" 2>/dev/null
    else
        codesign --force --deep --sign "$id" "$@" "$APP_DIR" 2>/dev/null
    fi
}

# 不带 entitlements 的裸签名（某些证书/profile 不接受 camera、apple-events 等受限权限时的回退）
sign_plain() {
    local id="$1"; shift
    codesign --force --deep --sign "$id" "$@" "$APP_DIR" 2>/dev/null
}

SIGN_OK=0
case "$SIGN_KIND" in
    developer-id)
        # 正式分发：Hardened Runtime + 时间戳（时间戳需联网；离线时退化为不带时间戳）
        if sign_with "$SIGN_ID" --options runtime --timestamp || sign_with "$SIGN_ID" --options runtime; then
            SIGN_OK=1
        fi
        ;;
    apple-development)
        # Apple Development 不支持 --timestamp；带 entitlements 失败时退化为裸签名
        if sign_with "$SIGN_ID" || sign_plain "$SIGN_ID"; then
            SIGN_OK=1
        fi
        ;;
    adhoc)
        if sign_with "-"; then SIGN_OK=1; fi
        ;;
    explicit)
        if sign_with "$SIGN_ID" --options runtime || sign_with "$SIGN_ID"; then
            SIGN_OK=1
        fi
        ;;
esac

# 上述任一路径失败（例如指定的证书不在钥匙串里）→ 回退 ad-hoc，保证本地一定能跑。
if [ "$SIGN_OK" -ne 1 ]; then
    echo ">>> 警告：使用「$SIGN_ID」签名失败，回退 ad-hoc 签名（TCC 授权会在下次重建后失效）"
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
fi

echo ">>> 构建完成：$PWD/$APP_DIR"
echo ">>> 签名身份：$(codesign -dvv "$APP_DIR" 2>&1 | grep -m1 '^Authority' | sed 's/^Authority=//')"
echo ">>> Team ID ：$(codesign -dvv "$APP_DIR" 2>&1 | grep -m1 'TeamIdentifier' | sed 's/^TeamIdentifier=//')"
if [ "$SIGN_KIND" = "adhoc" ]; then
    echo ">>> 提示：当前为 ad-hoc 签名，重建后需在「系统设置 > 隐私与安全性 > 辅助功能/摄像头」"
    echo "          删除旧的 HandMark 条目并重新勾选。安装 Developer ID 证书后重跑本脚本可一劳永逸。"
fi
echo ">>> 启动方式：open $PWD/$APP_DIR"

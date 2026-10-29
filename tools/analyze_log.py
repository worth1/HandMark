#!/usr/bin/env python3
# HandMark 日志分析工具（可复现的基线 / 优化后测量）
#
# 用法：
#   python3 tools/analyze_log.py                     # 分析最近一次启动之后（默认）
#   python3 tools/analyze_log.py --all               # 分析整个日志（跨会话聚合）
#   python3 tools/analyze_log.py --list              # 列出所有启动分段（用于挑选基线/对比区间）
#   python3 tools/analyze_log.py --startup 1         # 分析倒数第 2 次启动之后（0=最近一次）
#   python3 tools/analyze_log.py --screen 1512x982   # 手动指定屏幕尺寸
#   python3 tools/analyze_log.py --json              # 机器可读输出（便于做 A/B 表格）
#
# 输出：
#   1. 映射模式 / 滤波模式 / 增益 / ROI 边界（实验配置，需求 §9）
#   2. 指尖覆盖率 / 舒适区宽度 / 屏幕外圈占比
#   3. 逐帧抖动与「静止窗口」统计（真正的静止漂移，不是 1Hz 采样代理值）
#   4. 掌宽/掌长测量稳定性 + 静止窗口内掌宽变化（阶段 4 掌宽归一化可行性）
#   5. 追踪事件统计（丢失 / 封存 / 重锚）
#
# 重要说明（避免误读）：
#   - 「覆盖率」统计的是**手实际停留过的位置分布**，不等于**物理可达范围**。
#     要证明「够不到边缘」必须做有目的的九宫格/四角实测，不能靠自然使用日志推断。
#   - 「静止窗口」由应用逐帧判定：一个 1 秒窗口内**原始**坐标包围盒 < 30px 才算静止，
#     此时**滤波后**坐标的包围盒即为静止漂移量。旧版本日志没有该行，会显示「无数据」。
#   - 所有未使用真实摄像头的结论必须标记为「未实测」。
import argparse
import json
import math
import os
import re
import sys

DEFAULT_LOG = os.path.expanduser("~/Library/Logs/HandMark.log")
START_MARK = "透明覆盖窗口已启动"
HEARTBEAT = "心跳:"
HAND_SEEN = "手部=已识别"
TIP_RE = re.compile(r"指尖屏幕坐标=\((-?\d+), (-?\d+)\)")
PALM_RE = re.compile(r"掌宽原始=([\d.]+) 掌长原始=([\d.]+)")
GAIN_RE = re.compile(r"映射=(\S+) 增益=([\d.]+)x([\d.]+) 滤波=(\S+) 追踪=(\S+)")
LOST_RE = re.compile(r"丢失=(\d+) 封存=(\d+) 重锚=(\d+)")
MAPPING_RE = re.compile(r"🗺 映射=(\S+)\(请求 (\S+)\)")
ROI_RE = re.compile(r"已加载 ROI\[左([\d.]+) 右([\d.]+) 上([\d.]+) 下([\d.]+)\]")
STATIC_RE = re.compile(
    r"⏸ 静止窗口 ([\d.]+)s/(\d+)帧：原始抖动框=([\d.]+)px 滤波后漂移=([\d.]+)px "
    r"帧间位移 原始=([\d.]+)→滤波=([\d.]+)px(?: 掌宽变化=([\d.]+)%)?")
JITTER_RE = re.compile(r"帧抖动\[原始([\d.]+)→滤波([\d.]+) px/帧\]")
SCREEN_RE = re.compile(r"屏幕尺寸: (\d+)x(\d+)")


def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    idx = min(len(s) - 1, int(len(s) * p))
    return s[idx]


def startup_indices(lines):
    return [i for i, l in enumerate(lines) if START_MARK in l]


def analyze(lines, start, w, h):
    segment = lines[start:]
    out = {"line_start": start + 1, "lines": len(segment), "screen": [w, h]}

    # 屏幕尺寸
    for l in segment:
        m = SCREEN_RE.search(l)
        if m:
            w, h = int(m.group(1)), int(m.group(2))
            out["screen"] = [w, h]
            break

    tips, palm_w, palm_l = [], [], []
    modes, filters, gains = set(), set(), set()
    lost = seal = reset = 0
    jitter_raw, jitter_filt = [], []
    static = []
    for l in segment:
        m = STATIC_RE.search(l)
        if m:
            static.append({
                "sec": float(m.group(1)), "frames": int(m.group(2)),
                "raw_box": float(m.group(3)), "drift": float(m.group(4)),
                "step_raw": float(m.group(5)), "step_filt": float(m.group(6)),
                "palm_var": float(m.group(7)) if m.group(7) else None,
            })
            continue
        if HEARTBEAT not in l:
            continue
        g = GAIN_RE.search(l)
        if g:
            modes.add(g.group(1)); filters.add(g.group(4))
            gains.add("%sx%s" % (g.group(2), g.group(3)))
        m = LOST_RE.search(l)
        if m:
            lost, seal, reset = int(m.group(1)), int(m.group(2)), int(m.group(3))
        j = JITTER_RE.search(l)
        if j:
            jitter_raw.append(float(j.group(1))); jitter_filt.append(float(j.group(2)))
        if HAND_SEEN in l:
            t = TIP_RE.search(l)
            if t:
                tips.append((int(t.group(1)), int(t.group(2))))
            p = PALM_RE.search(l)
            if p:
                pw, pl = float(p.group(1)), float(p.group(2))
                if pw > 0: palm_w.append(pw)
                if pl > 0: palm_l.append(pl)

    out["config"] = {}
    for l in segment:
        m = MAPPING_RE.search(l)
        if m:
            out["config"]["mapping_effective"] = m.group(1)
            out["config"]["mapping_requested"] = m.group(2)
            break
    for l in segment:
        m = ROI_RE.search(l)
        if m:
            out["config"]["roi"] = [float(x) for x in m.groups()]
            break
    out["modes"] = sorted(modes)
    out["filters"] = sorted(filters)
    out["gains"] = sorted(gains)
    out["tracking"] = {"lost": lost, "sealed": seal, "reset": reset}

    cov = {}
    if tips:
        xs = [p[0] for p in tips]; ys = [p[1] for p in tips]
        mx, my = w * 0.08, h * 0.08
        edge = sum(1 for x, y in tips if x < mx or x > w - mx or y < my or y > h - my)
        d = [math.hypot(tips[i][0] - tips[i - 1][0], tips[i][1] - tips[i - 1][1])
             for i in range(1, len(tips))]
        cov = {
            "samples": len(tips),
            "x_pct": [100 * pct(xs, p) / w for p in (0.0, .05, .95, 1.0)],
            "y_pct": [100 * pct(ys, p) / h for p in (0.0, .05, .95, 1.0)],
            "comfort_x_pct": 100 * (pct(xs, .95) - pct(xs, .05)) / w,
            "comfort_y_pct": 100 * (pct(ys, .95) - pct(ys, .05)) / h,
            "edge_ratio": 100 * edge / len(tips),
            "hb_step_p10": pct(d, .10),
        }
    out["coverage"] = cov

    jitter = {}
    if jitter_raw:
        jitter["frames_mean_step_raw"] = sum(jitter_raw) / len(jitter_raw)
        jitter["frames_mean_step_filtered"] = sum(jitter_filt) / len(jitter_filt)
        jitter["windows"] = len(jitter_raw)
    if static:
        drifts = [s["drift"] for s in static]
        pv = [s["palm_var"] for s in static if s["palm_var"] is not None]
        jitter["static_windows"] = len(static)
        jitter["static_drift_mean"] = sum(drifts) / len(drifts)
        jitter["static_drift_max"] = max(drifts)
        jitter["static_drift_p90"] = pct(drifts, .90)
        jitter["static_raw_box_mean"] = sum(s["raw_box"] for s in static) / len(static)
        if pv:
            jitter["palm_var_mean_pct"] = sum(pv) / len(pv)
            jitter["palm_var_max_pct"] = max(pv)
    out["jitter"] = jitter

    palm = {}
    for name, arr in (("palm_width_px", palm_w), ("palm_length_px", palm_l)):
        if len(arr) < 2:
            palm[name] = {"samples": len(arr)}
            continue
        m = sum(arr) / len(arr)
        sd = math.sqrt(sum((v - m) ** 2 for v in arr) / len(arr))
        palm[name] = {"samples": len(arr), "mean": m, "sd": sd,
                      "cv_pct": 100 * sd / m if m else 0, "min": min(arr), "max": max(arr)}
    out["palm"] = palm
    return out


def print_report(r, args):
    print("== HandMark 日志分析 ==")
    print("日志：%s" % args.log)
    print("分析区间：第 %d 行起，共 %d 行  屏幕：%dx%d（点）"
          % (r["line_start"], r["lines"], r["screen"][0], r["screen"][1]))
    print()
    print("-- 实验配置（需求 §9）--")
    cfg = r["config"]
    if cfg:
        print("启动映射：%s（请求 %s）" % (cfg.get("mapping_effective", "旧版本"),
                                    cfg.get("mapping_requested", "旧版本")))
        if "roi" in cfg:
            print("已加载 ROI：左%.2f 右%.2f 上%.2f 下%.2f" % tuple(cfg["roi"]))
    print("心跳映射模式：%s" % (", ".join(r["modes"]) or "无（旧版本日志）"))
    print("心跳滤波模式：%s" % (", ".join(r["filters"]) or "无（旧版本日志）"))
    print("映射增益：%s" % (", ".join(r["gains"]) or "无（旧版本日志）"))
    t = r["tracking"]
    print("追踪事件累计：丢失=%d 封存=%d 重锚=%d" % (t["lost"], t["sealed"], t["reset"]))
    print()

    print("-- 指尖覆盖（实际停留分布，非物理可达范围）--")
    c = r["coverage"]
    if c:
        print("有效样本：%d" % c["samples"])
        print("X: min=%.1f%% p5=%.1f%% p95=%.1f%% max=%.1f%%" % tuple(c["x_pct"]))
        print("Y: min=%.1f%% p5=%.1f%% p95=%.1f%% max=%.1f%%" % tuple(c["y_pct"]))
        print("舒适区（p5~p95）宽度：X %.1f%%  Y %.1f%%" % (c["comfort_x_pct"], c["comfort_y_pct"]))
        print("落在屏幕外圈 8%% 边距的样本：%.1f%%" % c["edge_ratio"])
        print("相邻心跳(1s)位移 p10=%.1f px（代理指标，含真实移动）" % c["hb_step_p10"])
    else:
        print("无数据")
    print()

    print("-- 逐帧抖动与静止漂移 --")
    j = r["jitter"]
    if j:
        if "frames_mean_step_raw" in j:
            print("帧间位移均值：原始=%.2f → 滤波=%.2f px/帧（%d 个 1s 窗口）"
                  % (j["frames_mean_step_raw"], j["frames_mean_step_filtered"], j["windows"]))
        if "static_windows" in j:
            print("静止窗口：%d 个（原始抖动框均值 %.1fpx）"
                  % (j["static_windows"], j["static_raw_box_mean"]))
            print("静止漂移：均值=%.1fpx p90=%.1fpx 最大=%.1fpx"
                  % (j["static_drift_mean"], j["static_drift_p90"], j["static_drift_max"]))
        else:
            print("静止窗口：0（本次区间内手未静止，或为旧版本日志）")
    else:
        print("无数据（旧版本日志没有逐帧抖动字段）")
    print()

    print("-- 掌宽/掌长稳定性（阶段 4 可行性）--")
    for name in ("palm_width_px", "palm_length_px"):
        d = r["palm"].get(name, {})
        if d.get("samples", 0) < 2:
            print("%s：样本不足（%d）" % (name, d.get("samples", 0)))
            continue
        print("%s：样本=%d 均值=%.1fpx 标准差=%.1fpx 变异系数=%.1f%% 范围=%.0f~%.0f"
              % (name, d["samples"], d["mean"], d["sd"], d["cv_pct"], d["min"], d["max"]))
    if j.get("palm_var_mean_pct") is not None:
        print("静止窗口内掌宽变化：均值=%.1f%% 最大=%.1f%%（手未动时掌宽是否仍在波动）"
              % (j["palm_var_mean_pct"], j["palm_var_max_pct"]))
    print()
    print("== 提醒 ==")
    print("1. 覆盖率/舒适区来自自然使用日志，只能作为参考；九宫格实测才能证明可达性。")
    print("2. 静止漂移由应用逐帧判定（原始框<30px/秒），旧版本日志无此字段。")
    print("3. 所有未使用真实摄像头的结论必须标记为「未实测」。")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--all", action="store_true", help="分析整个日志")
    ap.add_argument("--list", action="store_true", help="列出所有启动分段")
    ap.add_argument("--startup", type=int, default=0, help="0=最近一次启动，1=倒数第二次…")
    ap.add_argument("--screen", default=None, help="屏幕尺寸，形如 1512x982")
    ap.add_argument("--json", action="store_true", help="输出 JSON（便于 A/B 对比脚本消费）")
    args = ap.parse_args()

    if not os.path.exists(args.log):
        print("日志文件不存在：%s" % args.log)
        return 1
    with open(args.log, encoding="utf-8", errors="ignore") as f:
        lines = f.read().splitlines()

    idxs = startup_indices(lines)
    if args.list:
        print("共 %d 次启动（时间取自「透明覆盖窗口已启动」行）" % len(idxs))
        for k, i in enumerate(reversed(idxs)):
            n = len(idxs) - 1 - k
            stamp = lines[i][:25]
            print("  --startup %-2d  第%-7d行  %s" % (n, i + 1, stamp))
        return 0

    w, h = 1512, 982
    if args.screen:
        w, h = (int(x) for x in args.screen.split("x"))
    start = 0
    if not args.all:
        if not idxs:
            print("日志中没有启动标记，按全部分析")
        else:
            k = min(args.startup, len(idxs) - 1)
            start = idxs[len(idxs) - 1 - k]

    r = analyze(lines, start, w, h)
    if args.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    else:
        print_report(r, args)
    return 0


if __name__ == "__main__":
    sys.exit(main())

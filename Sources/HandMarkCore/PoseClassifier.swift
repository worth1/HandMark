//
//  PoseClassifier.swift
//  HandMarkCore
//
//  V1.1 姿势分类层（纯函数）—— fingerExtension / classifySix / classifyFist。
//  真机反馈修订版：改用「手指伸直比」判据，对手型/朝向/摄像头距离更鲁棒，
//  并放宽清屏姿势的置信度门限（握拳时蜷曲手指的 Vision 置信度天然偏低）。
//
//  只 import Foundation 与 CoreGraphics，严禁 import AVFoundation / AppKit / Vision。
//
//  ── 判据：手指伸直比 straightenRatio ───────────────────────────────────────
//  对每根手指，定义 ratio = dist(tip, wrist) / dist(mcp, wrist)：
//   - 手指伸直时，指尖明显比指根(MCP)离手腕更远 → ratio 较大（通常 > ~1.3）。
//   - 手指弯曲/蜷曲时，指尖回收，甚至比指根更靠近手腕 → ratio 较小（通常 < ~1.1）。
//  该比值不依赖像素 palmScale，也不受手整体大小/远近影响（分子分母同尺度相约）。
//  用两个阈值形成区间：ratio >= STRAIGHT_HI 判为「伸直」，ratio <= CURL_LO 判为「弯曲」。
//
//  握拳收拢度 fistSpread = 五指指尖两两最大距离 / dist(wrist, middleMCP)（掌心基准，归一化）。
//  收拢时该值小。
//

import Foundation
import CoreGraphics

// MARK: - 判据阈值（可调；真机标定入口）

/// 伸直比 >= 此值判为「伸直」。
public let STRAIGHT_HI = 1.35
/// 伸直比 <= 此值判为「弯曲」。
public let CURL_LO = 1.15
/// 握拳收拢度（**四根长指**有效指尖的两两最大距离 / 掌长）< 此值判为「收拢」。
///
/// 注意：拇指**不参与**收拢度计算。握拳时拇指绕在四指外侧或前方，其指尖位置与
/// 「四指是否收拢」无关，把它算进最大跨度会把收拢度顶到 1.9~3.0（实测），
/// 使真握拳被判成「未收拢」——这是「六能识别、握拳却识别不到」的直接原因之一。
public let FIST_SPREAD_MAX = 1.3
/// 握拳「蜷曲」判据中允许的伸直比上限。
///
/// 蜷曲要求同时满足：curl 小（指尖贴回指根）**且** 指尖不比指根更远离手腕。
/// 后者原用 `CURL_LO`（1.15）卡死，实测真握拳时该比值常在 1.15~1.35（手掌侧转、
/// 投影压缩会把 `dist(mcp,wrist)` 压小而放大比值），导致明明握紧了却判不出蜷曲。
/// 放宽到 `STRAIGHT_HI`（1.35）后：真握拳（1.15~1.35）纳入，捏合绘画的半握手型
/// （实测 1.41~1.64）仍被排除，区分度保留。
public let FIST_CURL_STRAIGHTEN_MAX = STRAIGHT_HI
/// 清屏姿势判定的「掌部骨架」置信度门限。
///
/// 注意：这里判的是 wrist + 各指 MCP 的最低置信度，**不是指尖置信度**。
/// 握拳时蜷曲手指的指尖/DIP 被遮挡，置信度天然极低（实测 0.0~0.2），
/// 若拿指尖置信度当门限，握拳永远会被判为「不可靠」而拒绝清屏。
public let CLEAR_MIN_CONFIDENCE: Float = 0.15
/// 单指弯曲度 curl = dist(tip, mcp) / 掌长，低于此值判为「蜷曲」。
/// 蜷曲时指尖回收到指根附近（实测约 0.2~0.4），伸直时约 0.7~1.1。
public let CURL_MAX = 0.62
/// 单指弯曲度高于此值判为「伸直」（与 CURL_MAX 形成滞回区间）。
///
/// 注意：这是**食指/中指的基准阈值**。curl = dist(tip,mcp) / 掌长 与手指自身长度成正比，
/// 无名指尤其是小指天然更短，实测五指张开时「食0.90 中0.97 无0.94 小0.66」——
/// 小指永远够不到 0.70，导致「五指全伸」判定恒不成立（旋钮进不去）。
/// 因此按手指分档缩放，见 `curlScale(_:)`。
public let STRAIGHT_MIN = 0.70
/// 各手指相对基准阈值的缩放系数（真实手部几何标定）。
///
/// 实测同一只手五指张开时的 curl：食 0.90 / 中 0.97 / 无 0.94 / 小 0.66。
/// 以食、中为 1.0，无名指约 0.88、小指约 0.78 的量级给出余量，
/// 蜷曲时各指 curl 实测约 0.2~0.4，仍明显低于缩放后的 CURL_MAX（0.55 / 0.48），不会误判。
public func curlScale(_ kind: FingerKind) -> Double {
    switch kind {
    case .thumb:  return 0.60    // 拇指关节链短，量级不同，仅用于放宽
    case .index:  return 1.00
    case .middle: return 1.00
    case .ring:   return 0.88
    case .little: return 0.78
    }
}

/// 手指标识：curl 判据需要按指分档，否则短指（小指）永远判不出「伸直」。
public enum FingerKind {
    case thumb, index, middle, ring, little
}
/// 激光 / 翻页手形要求的「拇指-食指张开度」下限（归一化捏合距离）。
///
/// 捏合绘画时四根长指往往仍然伸直（实测：捏合帧弯曲度 食0.71 中0.73 无0.63 小0.50），
/// 单看「四指伸直」无法区分「激光手形」与「捏合绘画」——这是激光抢占画笔的主因。
/// 二者的本质差别是拇指尖↔食指尖的距离：捏合时极小（实测 0.08~0.16），
/// 激光/翻页手形时食指是伸出去的、距离明显更大（实测 > 0.8）。
/// 因此激光与翻页判定一律要求该距离不低于本阈值（取绘画松笔阈值 0.35 同量级）。
public let POSE_MIN_PINCH_GAP = 0.35

// MARK: - 翻页手形专用阈值（实机标定入口）
//
// 「仅食+中伸直」用通用伸直判据（STRAIGHT_MIN=0.70 / STRAIGHT_HI=1.35）实测过于苛刻：
// 伸直判据要求 curl 与 straightenRatio **同时**达标，而手只要稍微侧转/前推，
// 透视压缩就会让 curl 掉到 0.7 以下或 ratio 掉到 1.35 以下，表现为「手识别到了、
// 双指手形却永远不命中」。翻页只需与「五指全伸（激光/旋钮）」「全蜷（握拳）」
// 「捏合绘画」区分，区分度远大于余量，故单独放宽一档。
/// 翻页「伸直」的 curl 下限（通用值 0.70 → 0.58 → 0.48）。
///
/// 0.58 在水平挥动时偏严：中指随手掌侧转/前推会自然微屈，curl 落到 0.52 左右即被
/// 误判为「未伸直」，导致双指手形在挥动中掉线、翻页手势中途中断（表现「挥了不翻」）。
/// 放宽到 0.48 仅接纳自然微屈，仍能可靠区分「手枪/捏合」等中指明显蜷曲的手形
/// （其 curl 明显低于 0.4，与 0.48 之间有清晰空档）。
public let PAGE_STRAIGHT_CURL_MIN = 0.48
/// 翻页「伸直」的 straightenRatio 下限（通用值 1.35 → 1.28）。
public let PAGE_STRAIGHT_RATIO_MIN = 1.28
/// 翻页手形的拇指-食指张开度下限（通用值 0.35 → 0.25）。
///
/// 做 V/剪刀手时拇指通常压在蜷曲的无名指与小指上，拇指尖↔食指尖距离天然偏小；
/// 与「捏合绘画」的区分主要由协调器的 pinchEngaged 挂起负责，此处只做粗筛。
public let PAGE_MIN_PINCH_GAP = 0.25

// MARK: - 内部几何工具

@inline(__always)
private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
}

/// 手指伸直比：dist(tip,wrist) / dist(mcp,wrist)。mcp 退化时返回 0（保守判为弯曲）。
@inline(__always)
public func straightenRatio(_ f: FingerFeature, wrist: CGPoint) -> Double {
    let base = dist(f.mcp, wrist)
    guard base > 1e-6 else { return 0 }
    return dist(f.tip, wrist) / base
}

/// 兼容旧签名：伸展度（保留供其他代码/测试引用）。此处等价于伸直比。
public func fingerExtension(_ f: FingerFeature, palmScale: Double, wrist: CGPoint) -> Double {
    return straightenRatio(f, wrist: wrist)
}

@inline(__always)
private func clearReliable(_ m: HandMetrics, minConfidence: Float) -> Bool {
    // 清屏可靠性改用「掌部骨架」置信度：握拳时蜷曲手指的指尖/DIP 置信度天然极低，
    // 拿指尖置信度当门限会让握拳永远不可靠（这正是握拳识别不到的主因之一）。
    guard m.hasHand else { return false }
    return m.palmConfidence >= minConfidence
}

@inline(__always)
private func minFiveConfidence(_ m: HandMetrics) -> Float {
    min(m.thumb.minConfidence, m.index.minConfidence, m.middle.minConfidence,
        m.ring.minConfidence, m.little.minConfidence)
}

// MARK: - 掌部基准与单指弯曲度

/// 掌长基准 = dist(wrist, middleMCP)。握拳时该距离仍稳定（MCP 不受蜷曲遮挡影响）。
@inline(__always)
public func palmBase(_ m: HandMetrics) -> Double {
    return dist(m.wrist, m.middle.mcp)
}

/// 单指弯曲度：dist(tip, mcp) / 掌长。指尖或指根缺失时返回 nil（不得参与判定）。
///
/// 相比 `straightenRatio`（tip↔wrist / mcp↔wrist），本判据：
/// - 蜷曲与伸直的区分度更大（0.2~0.4 vs 0.7~1.1，中间留有明显空档）；
/// - 不依赖 wrist 与 mcp 的相对位置，手掌旋转/侧手时更稳；
/// - 缺失点直接返回 nil，不会把 (0,0) 当成真实坐标污染结果。
@inline(__always)
public func curlRatio(_ f: FingerFeature, palmBase base: Double) -> Double? {
    guard f.hasTip, f.hasMcp, base > 1e-6 else { return nil }
    return dist(f.tip, f.mcp) / base
}

/// 只收集「有效长指指尖」（食/中/无名/小）的坐标（缺失指尖一律排除，避免 (0,0) 污染）。
///
/// **刻意不含拇指**：握拳时拇指绕在四指外侧/前方，与「四指是否收拢」无关，
/// 计入会显著抬高最大跨度（实测 1.9~3.0），把真握拳误判为「未收拢」。
@inline(__always)
private func validLongTips(_ m: HandMetrics) -> [CGPoint] {
    var tips: [CGPoint] = []
    if m.index.hasTip  { tips.append(m.index.tip) }
    if m.middle.hasTip { tips.append(m.middle.tip) }
    if m.ring.hasTip   { tips.append(m.ring.tip) }
    if m.little.hasTip { tips.append(m.little.tip) }
    return tips
}

/// 兼容旧签名：只收集「有效指尖」——现只返回四根长指指尖（不含拇指）。
@inline(__always)
private func validTips(_ m: HandMetrics) -> [CGPoint] {
    return validLongTips(m)
}

@inline(__always)
private func maxPairDistance(_ tips: [CGPoint]) -> Double {
    var maxPair = 0.0
    for i in 0..<tips.count { for j in (i+1)..<tips.count { maxPair = max(maxPair, dist(tips[i], tips[j])) } }
    return maxPair
}

/// 收拢度：长指有效指尖两两最大距离 / 掌长。有效长指指尖不足 2 个时返回 nil（无法可靠衡量）。
@inline(__always)
private func fistSpread(_ m: HandMetrics) -> Double? {
    let tips = validLongTips(m)
    let base = palmBase(m)
    guard tips.count >= 2, base > 1e-6 else { return nil }
    return maxPairDistance(tips) / base
}

// MARK: - 诊断（供 UI/日志实机标定）

/// 一帧五指伸直比 + 握拳收拢度，便于日志打印与实机标定阈值。
public struct PoseDebug: Equatable {
    public var thumb: Double, index: Double, middle: Double, ring: Double, little: Double
    public var fistSpread: Double
    public init(thumb: Double, index: Double, middle: Double, ring: Double,
                little: Double, fistSpread: Double) {
        self.thumb = thumb; self.index = index; self.middle = middle
        self.ring = ring; self.little = little; self.fistSpread = fistSpread
    }
}

public func poseDebug(_ m: HandMetrics) -> PoseDebug {
    let w = m.wrist
    let base = palmBase(m)
    let maxPair = maxPairDistance(validLongTips(m))
    let spread = base > 1e-6 ? maxPair / base : 0
    return PoseDebug(thumb: straightenRatio(m.thumb, wrist: w),
                     index: straightenRatio(m.index, wrist: w),
                     middle: straightenRatio(m.middle, wrist: w),
                     ring: straightenRatio(m.ring, wrist: w),
                     little: straightenRatio(m.little, wrist: w),
                     fistSpread: spread)
}

// MARK: - 握拳诊断（实机标定用）

/// 握拳判定的逐项诊断，用于日志与预览窗实机标定。
public struct FistDiag: Equatable {
    /// 各长指（食/中/无/小）的弯曲度（dist(tip,mcp)/掌长），缺失为 nil。
    public var curl: [Double?]
    /// 有效长指数（tip 与 mcp 均可用）。
    public var validCount: Int
    /// 判定为蜷曲的长指数。
    public var curledCount: Int
    /// 判定为伸直的长指数。
    public var straightCount: Int
    /// 收拢度（有效指尖两两最大距离/掌长），无法衡量时为 nil。
    public var spread: Double?
    /// 掌部骨架置信度。
    public var palmConfidence: Float
    public var fourCurled: Bool      // 四根长指均蜷曲
    public var compact: Bool         // 指尖收拢
    public var reliable: Bool        // 掌部骨架可靠
    public var matched: Bool         // 最终命中

    public init(curl: [Double?], validCount: Int, curledCount: Int, straightCount: Int,
                spread: Double?, palmConfidence: Float,
                fourCurled: Bool, compact: Bool, reliable: Bool, matched: Bool) {
        self.curl = curl
        self.validCount = validCount
        self.curledCount = curledCount
        self.straightCount = straightCount
        self.spread = spread
        self.palmConfidence = palmConfidence
        self.fourCurled = fourCurled
        self.compact = compact
        self.reliable = reliable
        self.matched = matched
    }
}

public func fistDiagnostics(_ m: HandMetrics, minConfidence: Float = CLEAR_MIN_CONFIDENCE) -> FistDiag {
    let base = palmBase(m)
    let kinds: [FingerKind] = [.index, .middle, .ring, .little]
    let longs = [m.index, m.middle, m.ring, m.little]
    let curls = longs.map { curlRatio($0, palmBase: base) }
    var curled = 0, straight = 0, valid = 0
    for (i, f) in longs.enumerated() {
        guard let c = curls[i], f.hasTip, f.hasMcp else { continue }
        valid += 1
        // 双判据：既要「指尖贴近指根」（curl 小），也要「指尖不比指根更远离手腕」
        // （straightenRatio <= CURL_LO）。只用一个判据时，捏合绘画的半握手型会被
        // 误判成握拳（实测：捏合时 curl 0.43~0.64 已够小，但伸直比 1.41~1.64 明显是伸直）。
        let st = straightenRatio(f, wrist: m.wrist)
        if c < CURL_MAX * curlScale(kinds[i]) && st <= FIST_CURL_STRAIGHTEN_MAX { curled += 1 }
        else if c > STRAIGHT_MIN * curlScale(kinds[i]) && st >= STRAIGHT_HI { straight += 1 }
    }
    let spread = fistSpread(m)
    // 四根长指中：不允许任何一根是伸直的，且「可判定的长指」里绝大多数（至多允许一根
    // 因遮挡/模糊不可判定）必须是蜷曲的。握拳时指尖常被遮挡，若苛求四根全可见会漏判；
    // 只剩 1 根可判定时（valid==1）不再要求凑够 2 根，否则紧握拳反而判不出。
    let fourCurled = straight == 0 && curled >= min(2, valid) && curled >= valid - 1
    let compact = spread.map { $0 < FIST_SPREAD_MAX } ?? false
    let reliable = clearReliable(m, minConfidence: minConfidence)
    return FistDiag(curl: curls, validCount: valid, curledCount: curled, straightCount: straight,
                    spread: spread, palmConfidence: m.palmConfidence,
                    fourCurled: fourCurled, compact: compact, reliable: reliable,
                    matched: fourCurled && compact && reliable)
}

// MARK: - 六 / 握拳分类

/// 「六」：拇指伸直 + 小指伸直 + 食/中/无名弯曲。
/// config 参数保留以兼容旧签名；实际阈值用本文件的 STRAIGHT_HI / CURL_LO。
public func classifySix(_ m: HandMetrics, minConfidence: Float, config: ClearConfig) -> PoseMatch {
    let reliable = clearReliable(m, minConfidence: CLEAR_MIN_CONFIDENCE)
    let w = m.wrist
    let thumb  = straightenRatio(m.thumb,  wrist: w)
    let index  = straightenRatio(m.index,  wrist: w)
    let middle = straightenRatio(m.middle, wrist: w)
    let ring   = straightenRatio(m.ring,   wrist: w)
    let little = straightenRatio(m.little, wrist: w)

    let matched =
        thumb  >= STRAIGHT_HI &&
        little >= STRAIGHT_HI &&
        index  <= CURL_LO &&
        middle <= CURL_LO &&
        ring   <= CURL_LO

    return PoseMatch(matched: matched && reliable,
                     confidence: minFiveConfidence(m),
                     reliable: reliable)
}

/// 「握拳」：四根长指均蜷曲 + 指尖收拢 + 掌部骨架可靠。
///
/// 判据为什么要换成 curlRatio（dist(tip,mcp)/掌长）而不是原来的 straightenRatio：
/// 1. 原判据要求 `thumb < STRAIGHT_HI`，而拇指 mcp 用的是 thumbCMC（紧贴手腕），
///    分母极小会把比值放大，使拇指在握拳时也可能被判成「伸直」，直接卡死握拳。
/// 2. 原判据对缺失关键点不设防：小指/无名指缺失时 tip 被填成 (0,0)，
///    算出的收拢度被放大到 1.11（实测），刚好卡在阈值 1.1 之上 → 永不收拢。
/// 3. 原 `clearReliable` 用「五指中至少 4 指的指尖置信度 >= 门限」，而握拳时蜷曲手指
///    的指尖/DIP 置信度天然极低（实测 0.0~0.2）→ 可靠性恒为 false → 握拳永不命中。
///
/// 现判据全部改用掌部骨架（wrist + MCP）做参照：握拳时它们依然可见且稳定。
public func classifyFist(_ m: HandMetrics, minConfidence: Float, config: ClearConfig) -> PoseMatch {
    let d = fistDiagnostics(m, minConfidence: minConfidence)
    return PoseMatch(matched: d.matched,
                     confidence: m.palmConfidence,
                     reliable: d.reliable)
}

// MARK: - V2.0 激光 / 翻页手形分类

/// 单指是否「伸直」：curl 判据优先（dist(tip,mcp)/掌长 > 按指缩放后的 STRAIGHT_MIN），
/// 且伸直比 straightenRatio >= STRAIGHT_HI 作为方向校验。缺失关键点判为不伸直。
@inline(__always)
private func isStraight(_ f: FingerFeature, palmBase base: Double, wrist: CGPoint,
                        kind: FingerKind = .middle) -> Bool {
    guard let c = curlRatio(f, palmBase: base) else { return false }
    return c > STRAIGHT_MIN * curlScale(kind) && straightenRatio(f, wrist: wrist) >= STRAIGHT_HI
}

/// 单指是否「弯曲」：curl < 按指缩放后的 CURL_MAX 且伸直比 <= CURL_LO。
/// 缺失关键点保守判为「非伸直」（按弯曲处理）。
@inline(__always)
private func isCurled(_ f: FingerFeature, palmBase base: Double, wrist: CGPoint,
                      kind: FingerKind = .middle) -> Bool {
    guard let c = curlRatio(f, palmBase: base) else { return true }
    return c < CURL_MAX * curlScale(kind) && straightenRatio(f, wrist: wrist) <= CURL_LO
}

/// 拇指与食指是否「张开」（非捏合）。
///
/// 指尖缺失时返回 true（不由本条否决手形），避免在遮挡场景下误杀激光/翻页；
/// 真正区分捏合与激光的兜底由协调器的「捏合进行中则挂起激光/翻页」负责。
@inline(__always)
private func pinchOpen(_ m: HandMetrics, minGap: Double) -> Bool {
    guard m.thumb.hasTip, m.index.hasTip else { return true }
    return m.pinchDistanceNorm >= minGap
}

/// 「激光」手形：拇指弯曲 + 食/中/无名/小指均伸直（四指伸出、拇指收回）。
/// 激光光点取中指指尖，故中指必须可靠伸出。
public func classifyLaser(_ m: HandMetrics, minConfidence: Float,
                          minPinchGap: Double = POSE_MIN_PINCH_GAP) -> PoseMatch {
    let base = palmBase(m)
    let w = m.wrist
    let reliable = m.hasHand && m.palmConfidence >= minConfidence && m.middle.hasTip
    let thumbCurled = isCurled(m.thumb, palmBase: base, wrist: w, kind: .thumb)
    let fourStraight =
        isStraight(m.index,  palmBase: base, wrist: w, kind: .index) &&
        isStraight(m.middle, palmBase: base, wrist: w, kind: .middle) &&
        isStraight(m.ring,   palmBase: base, wrist: w, kind: .ring) &&
        isStraight(m.little, palmBase: base, wrist: w, kind: .little)
    // 关键：必须「非捏合」。捏合绘画时四指也可能被判为伸直，若无此条会被误判成激光并抢占画笔。
    let notPinching = pinchOpen(m, minGap: minPinchGap)
    return PoseMatch(matched: thumbCurled && fourStraight && notPinching && reliable,
                     confidence: m.palmConfidence,
                     reliable: reliable)
}

// MARK: - 翻页手形诊断（实机标定用）

/// 翻页手形判定的逐项诊断。用于回答「手识别到了，为什么双指手形没命中」——
/// 把每一根手指的判定结果与实测数值暴露出来，避免只能靠猜调阈值。
public struct PageDiag: Equatable {
    /// 食指 / 中指是否判为伸直（翻页手形要求两者都成立）。
    public var indexStraight: Bool
    public var middleStraight: Bool
    /// 无名指 / 小指是否判为「未伸直」（翻页手形要求两者都**不**伸直）。
    ///
    /// 用「未伸直」而非严格「蜷曲」：真实 V 手势下无名指/小指弯曲但指尖可能仍在
    /// 指根外侧一点，其 straightenRatio 常达 1.2~1.4，严格蜷曲判据（<=1.15）会把
    /// 正确的手势判掉；而「未伸直」仍能与「五指全伸」（激光/旋钮）清晰区分。
    public var ringNotStraight: Bool
    public var littleNotStraight: Bool
    /// 拇指-食指是否张开（粗筛，用于排除捏合绘画）。
    public var pinchOpen: Bool
    /// 关键点是否完整可靠。
    public var reliable: Bool
    /// 食/中/无/小四指的弯曲度 curl（dist(tip,mcp)/掌长），缺失为 nil。
    public var curl: [Double?]
    /// 食/中/无/小四指的伸直比 straightenRatio（dist(tip,wrist)/dist(mcp,wrist)）。
    public var ratio: [Double]
    /// 归一化捏合距离（拇指尖↔食指尖）。
    public var pinchGap: Double
    /// 掌部骨架置信度。
    public var palmConfidence: Float
    /// 最终是否命中。
    public var matched: Bool

    public init(indexStraight: Bool, middleStraight: Bool,
                ringNotStraight: Bool, littleNotStraight: Bool,
                pinchOpen: Bool, reliable: Bool,
                curl: [Double?], ratio: [Double],
                pinchGap: Double, palmConfidence: Float, matched: Bool) {
        self.indexStraight = indexStraight
        self.middleStraight = middleStraight
        self.ringNotStraight = ringNotStraight
        self.littleNotStraight = littleNotStraight
        self.pinchOpen = pinchOpen
        self.reliable = reliable
        self.curl = curl
        self.ratio = ratio
        self.pinchGap = pinchGap
        self.palmConfidence = palmConfidence
        self.matched = matched
    }

    /// 一句话摘要，供 UI 状态条显示（如「食✓ 中✗ 无✓ 小✓」）。
    public var summary: String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        return "食\(mark(indexStraight)) 中\(mark(middleStraight)) " +
               "无\(mark(ringNotStraight)) 小\(mark(littleNotStraight))"
    }
}

/// 翻页手形的「伸直」判据（专用放宽阈值）。
@inline(__always)
private func isStraightPage(_ f: FingerFeature, palmBase base: Double, wrist: CGPoint,
                            kind: FingerKind) -> Bool {
    guard let c = curlRatio(f, palmBase: base) else { return false }
    return c > PAGE_STRAIGHT_CURL_MIN * curlScale(kind) &&
           straightenRatio(f, wrist: wrist) >= PAGE_STRAIGHT_RATIO_MIN
}

/// 逐项诊断翻页手形（实机标定用：哪一项卡住一眼可见）。
public func pageDiagnostics(_ m: HandMetrics, minConfidence: Float,
                            minPinchGap: Double = PAGE_MIN_PINCH_GAP) -> PageDiag {
    let base = palmBase(m)
    let w = m.wrist
    let reliable = m.hasHand && m.palmConfidence >= minConfidence &&
                   m.index.hasTip && m.middle.hasTip
    let longs: [FingerFeature] = [m.index, m.middle, m.ring, m.little]
    let kinds: [FingerKind] = [.index, .middle, .ring, .little]
    let curls = longs.map { curlRatio($0, palmBase: base) }
    let ratios = longs.map { straightenRatio($0, wrist: w) }
    let straight = zip(longs, kinds).map { isStraightPage($0.0, palmBase: base, wrist: w, kind: $0.1) }

    let indexStraight = straight[0]
    let middleStraight = straight[1]
    // 无名指/小指：只要求「未伸直」，不要求严格蜷曲（理由见 PageDiag.ringNotStraight 注释）。
    let ringNotStraight = !straight[2]
    let littleNotStraight = !straight[3]
    let open = pinchOpen(m, minGap: minPinchGap)
    let matched = indexStraight && middleStraight && ringNotStraight &&
                  littleNotStraight && open && reliable
    return PageDiag(indexStraight: indexStraight, middleStraight: middleStraight,
                    ringNotStraight: ringNotStraight, littleNotStraight: littleNotStraight,
                    pinchOpen: open, reliable: reliable,
                    curl: curls, ratio: ratios,
                    pinchGap: m.pinchDistanceNorm, palmConfidence: m.palmConfidence,
                    matched: matched)
}

/// 「翻页」手形：仅食指 + 中指伸直，无名指与小指未伸直（剪刀/V 手形）。
///
/// 拇指按需求文档「不作为必要条件」（可自然伸出或弯曲），不参与判定；
/// 与捏合绘画的冲突由 `pinchOpen` 粗筛 + 协调器「捏合上手则挂起翻页」双层兜底。
public func classifyPage(_ m: HandMetrics, minConfidence: Float,
                         minPinchGap: Double = PAGE_MIN_PINCH_GAP) -> PoseMatch {
    let d = pageDiagnostics(m, minConfidence: minConfidence, minPinchGap: minPinchGap)
    return PoseMatch(matched: d.matched,
                     confidence: m.palmConfidence,
                     reliable: d.reliable)
}

// MARK: - V3.0 五指旋钮 / 拇指音量手形

/// 控制类手势使用的严格可靠性：五根指尖与指根都必须真实可用，且掌部骨架可靠。
/// 与握拳清屏不同，旋钮和音量不允许用缺失点做宽松推断，宁可不触发也不能误操作。
@inline(__always)
private func controlPoseReliable(_ m: HandMetrics, minConfidence: Float) -> Bool {
    // 控制手势的置信度底线比绘画更低（0.10）：真正的防线是「四指全伸 / 四指全蜷」
    // 这组互斥几何，而不是置信度。实测夜间摄像头下五指最低置信度会掉到 0.14~0.15，
    // 若沿用绘画门限 0.15，张开手掌会频繁被判不可靠而进不了旋钮模式。
    let floor: Float = min(minConfidence, 0.10)
    let fingers = [m.thumb, m.index, m.middle, m.ring, m.little]
    return m.hasHand && m.palmConfidence >= minConfidence &&
           fingers.allSatisfy { $0.hasTip && $0.hasMcp && $0.minConfidence >= floor }
}

/// 拇指没有与长指完全同构的关节，使用「指尖到 CMC 的展开长度 + 关节链直线度」双判据。
/// 不使用 tip 相对 wrist 的远近，因为拇指朝下时 tip 本来就可能靠近或越过 wrist。
@inline(__always)
private func isThumbExtendedForControl(_ m: HandMetrics) -> Bool {
    let base = palmBase(m)
    guard let curl = curlRatio(m.thumb, palmBase: base), base > 1e-6 else { return false }
    let chainLength = dist(m.thumb.tip, m.thumb.dip) +
                      dist(m.thumb.dip, m.thumb.pip) +
                      dist(m.thumb.pip, m.thumb.mcp)
    let directLength = dist(m.thumb.tip, m.thumb.mcp)
    let straightness = chainLength > 1e-6 ? directLength / chainLength : 0
    // 实测：五指张开时拇指 curl 只有 0.27~1.12（Vision 的 thumbCMC 定位噪声大，
    // 且拇指平面外旋转会压缩投影长度），按 0.42 卡会把张开的手判成「拇指未伸」，
    // 于是旋钮永远进不去。真正的区分力来自「四指全伸 / 四指全蜷」这一组互斥几何，
    // 拇指判据只做粗筛：关节链要直（≥0.72），指尖别缩回掌心（≥0.20）即可。
    return curl >= 0.20 && straightness >= 0.72
}

/// 五指旋钮进入手形：五指全部伸展、拇指与食指分开、关键点完整可靠。
public func classifyKnob(_ m: HandMetrics, minConfidence: Float,
                         minPinchGap: Double = POSE_MIN_PINCH_GAP) -> PoseMatch {
    let d = knobDiagnostics(m, minConfidence: minConfidence, minPinchGap: minPinchGap)
    return PoseMatch(matched: d.matched,
                     confidence: minFiveConfidence(m),
                     reliable: d.reliable)
}

/// 五指旋钮逐项诊断（实机标定用：哪一项卡住导致进不了旋钮模式，一眼可见）。
public struct KnobDiag: Equatable {
    /// 四根长指中判定为「伸直」的根数（需要全部 4 根）。
    public var straightCount: Int
    /// 四根长指各自的弯曲度（dist(tip,mcp)/掌长），缺失为 nil。
    public var curl: [Double?]
    /// 拇指是否判定为伸展。
    public var thumbExtended: Bool
    /// 拇指展开度（curl）与末节直线度，诊断用。
    public var thumbCurl: Double?
    public var thumbStraightness: Double
    /// 拇指-食指是否张开（非捏合）。
    public var pinchOpen: Bool
    /// 归一化捏合距离。
    public var pinchGap: Double
    /// 关键点是否完整可靠。
    public var reliable: Bool
    /// 掌部骨架置信度 / 五指最低置信度。
    public var palmConfidence: Float
    public var minFingerConfidence: Float
    public var matched: Bool

    public init(straightCount: Int, curl: [Double?], thumbExtended: Bool,
                thumbCurl: Double?, thumbStraightness: Double,
                pinchOpen: Bool, pinchGap: Double, reliable: Bool,
                palmConfidence: Float, minFingerConfidence: Float, matched: Bool) {
        self.straightCount = straightCount
        self.curl = curl
        self.thumbExtended = thumbExtended
        self.thumbCurl = thumbCurl
        self.thumbStraightness = thumbStraightness
        self.pinchOpen = pinchOpen
        self.pinchGap = pinchGap
        self.reliable = reliable
        self.palmConfidence = palmConfidence
        self.minFingerConfidence = minFingerConfidence
        self.matched = matched
    }
}

public func knobDiagnostics(_ m: HandMetrics, minConfidence: Float,
                            minPinchGap: Double = POSE_MIN_PINCH_GAP) -> KnobDiag {
    let base = palmBase(m)
    let w = m.wrist
    let reliable = controlPoseReliable(m, minConfidence: minConfidence)

    let longs: [FingerFeature] = [m.index, m.middle, m.ring, m.little]
    let kinds: [FingerKind] = [.index, .middle, .ring, .little]
    let curls = longs.map { curlRatio($0, palmBase: base) }
    let straightCount = zip(longs, kinds).filter {
        isStraight($0.0, palmBase: base, wrist: w, kind: $0.1)
    }.count

    let thumbCurl = curlRatio(m.thumb, palmBase: base)
    let chainLength = dist(m.thumb.tip, m.thumb.dip) +
                      dist(m.thumb.dip, m.thumb.pip) +
                      dist(m.thumb.pip, m.thumb.mcp)
    let directLength = dist(m.thumb.tip, m.thumb.mcp)
    let straightness = chainLength > 1e-6 ? directLength / chainLength : 0
    let thumbExtended = isThumbExtendedForControl(m)

    let open = pinchOpen(m, minGap: minPinchGap)
    let matched = thumbExtended && straightCount == 4 && open && reliable
    return KnobDiag(straightCount: straightCount, curl: curls, thumbExtended: thumbExtended,
                    thumbCurl: thumbCurl, thumbStraightness: straightness,
                    pinchOpen: open, pinchGap: m.pinchDistanceNorm, reliable: reliable,
                    palmConfidence: m.palmConfidence,
                    minFingerConfidence: minFiveConfidence(m),
                    matched: matched)
}

/// 旋钮「保持」判据（仅在已激活后用于维持）：不苛求五指全伸，
/// 只要求掌部骨架可靠、掌心角可用，且食/中指未蜷回。
///
/// 旋转手掌时手指会互相遮挡（尤其无名指/小指），若每帧都要求完整五指手形，
/// 用户一转就掉出 active（实测：进入旋钮后同一秒即退出，从未触发过切换）。
public func classifyKnobHold(_ m: HandMetrics, minConfidence: Float,
                             minPinchGap: Double = POSE_MIN_PINCH_GAP) -> PoseMatch {
    let base = palmBase(m)
    let w = m.wrist
    let reliable = m.hasHand && m.palmConfidence >= minConfidence &&
                   m.index.hasTip && m.index.hasMcp && m.middle.hasTip && m.middle.hasMcp
    let stillOpen = isStraight(m.index, palmBase: base, wrist: w, kind: .index) ||
                    isStraight(m.middle, palmBase: base, wrist: w, kind: .middle)
    // 一旦捏合上手（拇指-食指靠近）必须立刻退出，把操作权交还绘画。
    let notPinching = pinchOpen(m, minGap: minPinchGap)
    return PoseMatch(matched: reliable && stillOpen && notPinching,
                     confidence: m.palmConfidence,
                     reliable: reliable)
}

/// 拇指音量方向。方向按 Vision 统一原始坐标定义：y 增大为画面向上。
/// 水平镜像只改变 x，不会反转上下；左右手也不改变 distal thumb vector 的 y 符号。
public func classifyThumbVolume(_ m: HandMetrics,
                                direction: VolumeGestureDirection,
                                minConfidence: Float) -> PoseMatch {
    let base = palmBase(m)
    let w = m.wrist
    let reliable = controlPoseReliable(m, minConfidence: minConfidence)
    let longs: [FingerFeature] = [m.index, m.middle, m.ring, m.little]
    let kinds: [FingerKind] = [.index, .middle, .ring, .little]
    let fourCurled = zip(longs, kinds).allSatisfy {
        isCurled($0.0, palmBase: base, wrist: w, kind: $0.1)
    }

    // 以拇指末节（IP -> tip）判方向，并要求明显以竖直分量为主。
    // 不能只比较 tip 与 wrist，否则手掌整体位置/左右手/镜像容易污染判定。
    let dx = Double(m.thumb.tip.x - m.thumb.dip.x)
    let dy = Double(m.thumb.tip.y - m.thumb.dip.y)
    let distalLength = hypot(dx, dy)
    let verticalEnough = distalLength > max(1e-6, base * 0.10) && abs(dy) >= abs(dx) * 1.15
    let directionMatched = direction == .up ? dy > 0 : dy < 0
    let matched = reliable && isThumbExtendedForControl(m) && fourCurled &&
                  verticalEnough && directionMatched
    return PoseMatch(matched: matched,
                     confidence: minFiveConfidence(m),
                     reliable: reliable)
}

//
//  GesturePriorityCoordinator.swift
//  HandMarkCore
//
//  所有手势的唯一动作裁决入口。清屏、激光、翻页、旋钮、音量与绘画按状态互斥，
//  同一帧最多产生一个外部功能动作。
//

import Foundation
import CoreGraphics

public struct GesturePriorityCoordinator {
    public var pinch = PinchStateMachine()
    public var clear = ClearGestureStateMachine()
    public var laser = LaserStateMachine()
    public var page = PageSwipeStateMachine()
    public var knob = KnobGestureStateMachine()
    public var volume = VolumeGestureStateMachine()

    /// V2.1 默认由应用关闭，关闭后激光手势不分类、不占用优先级。
    public var laserEnabled: Bool = true
    /// 是否启用「双指挥动翻页」手势（由 UI 开关控制）。关闭时翻页手形不参与判定，状态机停在 idle。
    public var pageEnabled: Bool = true

    public init() {}

    public mutating func step(_ m: HandMetrics,
                              midTip: CGPoint,
                              hasMidTip: Bool,
                              refPoint: CGPoint,
                              hasRef: Bool,
                              now: TimeInterval,
                              config: GestureConfig) -> CoordinatorDecision {
        let minConf = config.pinch.minConfidence

        // 姿势分类统一在协调器内完成，I/O 层不得绕开协调器直接执行动作。
        let six = classifySix(m, minConfidence: minConf, config: config.clear)
        let fist = classifyFist(m, minConfidence: minConf, config: config.clear)
        let laserPose = laserEnabled
            ? classifyLaser(m, minConfidence: minConf)
            : PoseMatch(matched: false, confidence: 0, reliable: false)
        let pagePose = classifyPage(m, minConfidence: minConf)
        // 开关关闭时不喂手形 → 翻页状态机恒 idle，轨迹自然清空（满足「关闭后残留手势不触发」）。
        let effectivePagePose = pageEnabled ? pagePose : PoseMatch(matched: false, confidence: 0, reliable: false)
        let knobPose = classifyKnob(m, minConfidence: minConf)
        // 已激活后改用「保持」判据：旋转中手指互相遮挡是常态，
        // 若每帧都要求完整五指手形，用户一转就掉出 active，永远触发不了切换。
        // 已切档（.consumed）期间同样用宽松判据，否则回程旋转可能把手形判丢而提前退出。
        let knobPoseForStep = knob.isEngaged ? classifyKnobHold(m, minConfidence: minConf) : knobPose
        let volumeUpPose = classifyThumbVolume(m, direction: .up, minConfidence: minConf)
        let volumeDownPose = classifyThumbVolume(m, direction: .down, minConfidence: minConf)

        let drawing = pinch.phase == .drawing || pinch.phase == .releaseCandidate
        // 捏合一旦上手，后续控制手势不得抢占，避免重现起笔困难/中途断笔。
        let pinchEngaged = pinch.phase != .idle

        // 1. 清屏最高优先级。
        let clearOutcome = clear.step(six: six, fist: fist, drawing: drawing,
                                      handPresent: m.hasHand, now: now, config: config.clear)
        let clearLocked = isClearLocked(clear.phase)

        // 2. 保留的激光状态机（应用默认关闭）。
        let laserOutcome = laser.step(laser: laserPose, midTip: midTip, hasMidTip: hasMidTip,
                                      suspended: !laserEnabled || clearLocked || pinchEngaged,
                                      handPresent: m.hasHand, now: now, config: config.laser)
        let laserActive = laserEnabled && laser.phase == .active

        // 3. PPT 翻页。已激活的旋钮/音量保持独占；绘画上手时同样不得翻页。
        let controlAlreadyBusy = knob.isActive || volume.isBusy
        let pageOutcome = page.step(page: effectivePagePose, refPoint: refPoint, hasRef: hasRef,
                                    suspended: clearLocked || laserActive || pinchEngaged || controlAlreadyBusy,
                                    handPresent: m.hasHand, now: now, config: config.page)
        let pageBusy = page.phase == .armed || pageOutcome != .none

        // 4. 五指旋钮。真正落笔时不得进入；翻页或音量手势处理中同样不得进入。
        //    注意：这里刻意不用 pinchEngaged（捏合状态机非 idle）——捏合「候选计时中」时
        //    手形仍是张开的，旋钮手形本身要求五指全伸且拇指-食指张开（≥0.35），
        //    与捏合天然互斥；若把 candidate 也算作占用，五指张开会被捏合候选永久挂起，
        //    表现为「张开手掌转半天也进不了旋钮模式」。
        let knobOutcome = knob.step(knob: knobPoseForStep,
                                    palmAngle: m.palmAngle,
                                    hasPalmAngle: m.hasPalmAngle,
                                    suspended: clearLocked || laserActive || drawing || pageBusy || volume.isBusy,
                                    handPresent: m.hasHand,
                                    now: now,
                                    config: config.knob)
        let knobBusy = knob.isBusy

        // 5. 拇指音量。与旋钮互斥，且不得在绘画/翻页/清屏期间触发。
        let volumeOutcome = volume.step(up: volumeUpPose,
                                        down: volumeDownPose,
                                        suspended: clearLocked || laserActive || pinchEngaged || pageBusy || knobBusy,
                                        handPresent: m.hasHand,
                                        now: now,
                                        config: config.volume)
        let volumeBusy = volume.isBusy

        // 6. 绘画：任何更高优先级状态占用时暂停。
        let suspendPinch = clearLocked || laserActive || pageBusy || knobBusy || volumeBusy
        let tipReliable = m.index.hasTip && m.thumb.hasTip &&
                          min(m.index.minConfidence, m.thumb.minConfidence) >= minConf
        var pinchOutcome = pinch.step(distNorm: m.pinchDistanceNorm,
                                      distPx: m.pinchDistancePx,
                                      tipReliable: tipReliable,
                                      handPresent: m.hasHand,
                                      suspended: suspendPinch,
                                      now: now,
                                      config: config.pinch)
        if clearOutcome == .performClear { pinchOutcome = .none }

        let previewPhase = composePreviewPhase(m: m, laserActive: laserActive)
        return CoordinatorDecision(pinchOutcome: pinchOutcome,
                                   clearOutcome: clearOutcome,
                                   previewPhase: previewPhase,
                                   laserOutcome: laserOutcome,
                                   pageOutcome: pageOutcome,
                                   knobOutcome: knobOutcome,
                                   volumeOutcome: volumeOutcome)
    }

    private func isClearLocked(_ phase: ClearPhase) -> Bool {
        switch phase {
        case .sixArmed, .fistCandidate, .clearing, .cooldown: return true
        case .idle, .sixCandidate: return false
        }
    }

    private func composePreviewPhase(m: HandMetrics, laserActive: Bool) -> PreviewPhase {
        guard m.hasHand else { return .idleHand }

        switch clear.phase {
        case .sixCandidate: return .sixCandidate
        case .sixArmed: return .sixArmed
        case .fistCandidate: return .fistCandidate
        case .clearing: return .clearing
        case .cooldown: return .cooldown
        case .idle: break
        }

        if laserEnabled {
            switch laser.phase {
            case .candidate: return .laserCandidate
            case .active: return .laserActive
            case .idle: break
            }
        }

        switch page.phase {
        case .armed: return .pageArmed
        case .cooldown, .waitReset: return .pageCooldown
        case .idle: break
        }

        switch knob.phase {
        case .candidate: return .knobCandidate
        case .active: return .knobActive
        case .consumed: return .knobConsumed
        case .idle: break
        }

        switch volume.phase {
        case .candidate: return .volumeCandidate
        case .latched: return .volumeLatched
        case .idle: break
        }

        switch pinch.phase {
        case .drawing, .releaseCandidate: return .drawing
        case .candidate: return .pinchCandidate
        case .idle: return .idleHand
        }
    }
}

//  ChatMotionTokens.swift
//  agentGui
//
//  统一动效令牌 — ChatView 体系内所有动效参数的单一来源。
//  使用方式: ChatMotion.enterSpring / ChatMotion.scrollToBottom 等。

import SwiftUI

enum ChatMotion {

    // MARK: - 入场

    /// 消息块、卡片的弹性入场动画（spring）
    static let enterSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// 标准入场持续时长（用于非 spring 的 easeOut 入场）
    static let enterDuration: TimeInterval = 0.25

    // MARK: - 退场

    /// 标准退场持续时长
    static let exitDuration: TimeInterval = 0.18

    /// 纯透明度退场 Transition
    static let exitOpacity: AnyTransition = .opacity

    // MARK: - 流式内容

    /// streaming delta 文本追加动画
    static let streamingAppend = Animation.easeOut(duration: 0.12)

    // MARK: - 滚动

    /// 滚动到底部的平滑动画
    static let scrollToBottom = Animation.easeOut(duration: 0.22)

    // MARK: - 交互反馈

    /// hover 缩放比例（用于可交互元素）
    static let hoverScale: CGFloat = 1.02

    /// 按下缩放比例
    static let pressScale: CGFloat = 0.97

    /// hover 状态切换弹性动画
    static let hoverSpring = Animation.spring(response: 0.28, dampingFraction: 0.76)

    // MARK: - 复合 Transition（无法通过 Animation 单独表达的）

    /// Hover Actions Bar 进出场：向上淡入 / 淡出
    static let hoverActionsTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -2)),
        removal: .opacity
    )

    /// Theater State Change — 卡片列表结构性变更（权限请求、toolCall 变更）
    static let theaterStateChange = Animation.easeInOut(duration: 0.24)

    /// 顶部 Banner 进出场（只读横幅、通知横幅）
    static let bannerTransition: AnyTransition = .opacity.combined(
        with: .scale(scale: 0.98, anchor: .top)
    )
}

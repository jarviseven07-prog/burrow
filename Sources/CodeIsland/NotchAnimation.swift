import SwiftUI

enum NotchAnimation {
    /// 展开面板：微弹，有少许回弹感
    static var open: Animation {
        .spring(response: NotchAnimationMetrics.openResponse, dampingFraction: NotchAnimationMetrics.openDamping)
    }
    /// 收起面板：临界阻尼，无过冲（防止 NotchPanelShape 底边露出刘海）
    static var close: Animation {
        .spring(response: NotchAnimationMetrics.closeResponse, dampingFraction: NotchAnimationMetrics.closeDamping)
    }
    /// 通知弹出：快速弹跳，用于 completion/approval 自动展开
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    /// 微交互：hover 状态变化、按钮高亮等
    static let micro = Animation.easeOut(duration: 0.12)
    /// Hover 预备段：全量展开的延迟计时期间，先给一个轻量的"我看到你了"反馈
    static let hoverPrehover = Animation.easeOut(duration: NotchHoverInteraction.prehoverAnimationDuration)
}

// MARK: - Blur + Fade transition

private struct BlurFadeModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        // No compositingGroup here: macOS 26 renders compositingGroup + blur
        // (even with radius 0 in the identity state) transparent until a forced
        // re-composition, which made the approval card invisible except on hover
        // (issue #100).
        content
            .blur(radius: active ? 5 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    /// Blur out + fade — smoother than plain opacity for notch content switches.
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(active: true),
            identity: BlurFadeModifier(active: false)
        )
    }
}


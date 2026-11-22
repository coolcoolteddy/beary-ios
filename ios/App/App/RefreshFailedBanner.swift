import UIKit

/// 「未能刷新 · 重试」常驻横条：私信会话列表／广场／好友／时间线四页共用。
/// 外观与各页旧自写版一致：底色 = bg 上叠 12% 语义红（不透明复合色，深浅模式
/// 各自按当前 trait 混合，与旧“red 0.12 透在 bg 上”的观感一致；覆盖式须不透明，
/// 否则列表内容会透过半透明条显出来）＋「未能刷新」14pt ink＋「重试」14 semibold ink。
/// 各页自留：顶约束（钉在哪）与重试回调（重拉哪）；最小高 44 由本条自己定。
final class RefreshFailedBanner: UIView {
    /// 重试点按时调用，各页接自己的重拉（load／refreshAllInternal／reloadTimeline）。
    var onRetry: (() -> Void)?

    /// 条当前是否在屏（时间线吸顶头让位用）。
    var isBannerVisible: Bool { !isHidden }

    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    /// - Parameter retryAccessibilityHint: 重试钮的无障碍提示，各页写自己的重拉对象
    ///   （如“重新拉取会话列表，不改变当前列表位置”）。
    init(retryAccessibilityHint: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor { trait in
            let base = BearyColors.bg.resolvedColor(with: trait)
            let tint = BearyColors.red.resolvedColor(with: trait)
            var baseR: CGFloat = 0, baseG: CGFloat = 0, baseB: CGFloat = 0, baseA: CGFloat = 0
            var tintR: CGFloat = 0, tintG: CGFloat = 0, tintB: CGFloat = 0, tintA: CGFloat = 0
            base.getRed(&baseR, green: &baseG, blue: &baseB, alpha: &baseA)
            tint.getRed(&tintR, green: &tintG, blue: &tintB, alpha: &tintA)
            let a: CGFloat = 0.12
            return UIColor(red: tintR * a + baseR * (1 - a),
                           green: tintG * a + baseG * (1 - a),
                           blue: tintB * a + baseB * (1 - a),
                           alpha: 1)
        }
        isHidden = true
        alpha = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = BearyColors.ink
        messageLabel.text = "未能刷新"
        addSubview(messageLabel)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.accessibilityLabel = "重试"
        retryButton.accessibilityHint = retryAccessibilityHint
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 显隐：覆盖式只淡入淡出（私信会话列表／好友旧口径）；`animated: false` 时直设终值
    /// （广场／时间线旧口径：瞬时显隐，表顶约束由各页自己切换）。
    /// 收起动画被新显隐打断时 completion 的 finished 为 false，不藏条，防新显的条
    /// 被旧收起动画的 completion 误藏。
    func setVisible(_ visible: Bool, animated: Bool = true) {
        if visible {
            isHidden = false
            guard animated, BearyMotion.animated(true) else {
                alpha = 1
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.alpha = 1
            })
        } else {
            guard animated, BearyMotion.animated(true) else {
                alpha = 0
                isHidden = true
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.alpha = 0
            }, completion: { finished in
                if finished {
                    self.isHidden = true
                }
            })
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

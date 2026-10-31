import UIKit

// ===== BearyStateView 统一状态视图（B 批）=====
// 空态 / 加载态 / 错误重试态 / 未登录引导态共用一处组件，后续各页接入时只换本视图，
// 不动各页自身的显隐逻辑（本批示范接入见 BearyTrashViewController 的失败态）。
// 结构（竖向居中栈）：图标圆（54 圈：橙 18% 底 + 1pt 25% 橙圈，选人 sheet 空态圆同款；
// 无图标时整行隐藏）＋标题（15 粗体 ink）＋副文案（12.5 gray，多行居中）＋
// 动作钮（BearyButton，默认 secondaryOutline 紧凑 36/18；调用方可传其他工厂样式）。
// 加载态：图标圆内改转圈（官方 icon_refresh 20pt，2026-10-30 全 App 统一，
// 不再用 UIActivityIndicatorView medium 圈）；加载时动作钮隐藏。
// 边框重刷：动作钮边框是 CGColor，赋值时固化——traitCollectionDidChange 内重赋
// （钮自身也会重刷；本视图再兜底一层，空态按钮边框深浅切换不跟随的问题不再复发）。
// 调用：configure(...) 一次配齐；无标题/副文案/动作时对应行自动隐藏；动作走闭包 onAction。
// 宽度说明：本视图自身无固定宽，放在 center 对齐的栈内时宽由内容决定；长副文案
// 需调用方另给宽度约束，否则多行文案只按内容宽换行。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyStateKind {
    case empty
    case loading
    case error
    case login
}

final class BearyStateView: UIView {

    private let stack = UIStackView()
    private let iconCircle = UIView()
    private let iconView = UIImageView()
    private let spinner = BearyRefreshIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var actionButton: BearyButton = BearyButton(style: .secondaryOutline(.compact))
    private var actionButtonStyle: BearyButtonStyle = .secondaryOutline(.compact)
    private var actionHeightConstraint: NSLayoutConstraint?
    private var actionHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.build()
    }

    private func build() {
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        iconCircle.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
        iconCircle.layer.borderWidth = 1
        iconCircle.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
        iconCircle.layer.cornerRadius = 27
        iconCircle.layer.masksToBounds = true
        iconCircle.translatesAutoresizingMaskIntoConstraints = false

        iconView.tintColor = BearyColors.orange
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        spinner.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = UIFont.systemFont(ofSize: 12.5)
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.lineBreakMode = .byCharWrapping
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.bearyAddPressFeedback()

        stack.addArrangedSubview(iconCircle)
        iconCircle.addSubview(iconView)
        iconCircle.addSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(actionButton)
        stack.setCustomSpacing(4, after: titleLabel)

        let heightConstraint = actionButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height)
        heightConstraint.isActive = true
        self.actionHeightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconCircle.widthAnchor.constraint(equalToConstant: 54),
            iconCircle.heightAnchor.constraint(equalToConstant: 54),
            iconView.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25),
            spinner.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    /// 一次配齐。kind 只决定加载转圈与否（loading 时图标换转圈、动作钮隐藏）；
    /// 其余行一律按参数有无显隐：iconName 为 nil 则图标圆整行隐藏，actionTitle 为 nil
    /// 则动作钮隐藏；actionStyle 变化时动作钮按新样式重建（工厂钮样式在 init 后不可换）。
    func configure(kind: BearyStateKind, title: String?, subtitle: String?, iconName: String?, actionTitle: String?, actionStyle: BearyButtonStyle = .secondaryOutline(.compact), onAction: (() -> Void)? = nil) {
        let isLoading = (kind == .loading)
        if let name = iconName, isLoading == false {
            iconCircle.isHidden = false
            iconView.isHidden = false
            spinner.isHidden = true
            spinner.stopSpinning()
            iconView.image = BearyIconImages.image(named: name, pointSize: 25)
        } else if isLoading {
            iconCircle.isHidden = false
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startSpinning()
        } else {
            iconCircle.isHidden = true
            iconView.isHidden = true
            spinner.isHidden = true
            spinner.stopSpinning()
        }
        titleLabel.text = title
        titleLabel.isHidden = (title == nil)
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle == nil)
        self.actionHandler = onAction
        if let actionTitle = actionTitle, isLoading == false {
            if actionStyle != self.actionButtonStyle {
                self.rebuildActionButton(style: actionStyle)
            }
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
            self.actionHeightConstraint?.constant = actionStyle.height
        } else {
            actionButton.isHidden = true
            self.actionHandler = nil
        }
    }

    /// 工厂钮样式在 init 后不可换：样式变化时拆旧建新，约束/动作/按压反馈随新钮重挂。
    private func rebuildActionButton(style: BearyButtonStyle) {
        let wasHidden = actionButton.isHidden
        stack.removeArrangedSubview(actionButton)
        actionButton.removeFromSuperview()
        self.actionHeightConstraint = nil
        let button = BearyButton(style: style)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        button.isHidden = wasHidden
        stack.addArrangedSubview(button)
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: style.height)
        heightConstraint.isActive = true
        self.actionButton = button
        self.actionButtonStyle = style
        self.actionHeightConstraint = heightConstraint
    }

    @objc private func actionTapped() {
        self.actionHandler?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            // CGColor 只在赋值时解析一次：深浅切换时重赋图标圆圈与动作钮边框，
            // 空态按钮边框不再停留在旧主题色（钮自身 trait 处理之外再兜底一层）。
            self.iconCircle.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
            self.actionButton.refreshChrome()
        }
    }
}

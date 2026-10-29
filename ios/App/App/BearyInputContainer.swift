import UIKit

// ===== 审计 P2-14：共享输入容器 =====
// 登录页与邀请页此前各写一份 makeFieldContainer（faint 底、圆角 12、
// 左右 14 内边距、48 高，逐字重复），本组件收敛为一处：统一背景 /
// 边框 / 内边距 / 聚焦态 / 错误态，内部仍是调用方传入的原生
// UITextField / UITextView（不换自定义输入控件，文案与校验逻辑不动）。
// 边框色是 CGColor、赋值时固化：traitCollectionDidChange 内按
// BearyButton.refreshChrome 范式重赋，背景色走动态色自动跟随。
// 聚焦监听走 begin/end editing 通知，不占调用方的 delegate 与
// editingChanged target（验证码 / 邀请码的 delegate 校验原样保留）。
// 错误态 isError 供字段级错误调用方使用；现有错误口径仍是
// messageLabel / fieldErrorLabel 行级提示，本批不把登录与邀请的
// 行级错误改成字段红边（校验逻辑与错误文案均不动）。

final class BearyInputContainer: UIView {
    private let content: UIView
    private let normalBorderColor: UIColor
    private var contentEditingFocused = false

    /// 错误态：红边优先于聚焦蓝边；复位后回到聚焦 / 常态。
    var isError = false {
        didSet { refreshBorder() }
    }

    /// - content: 原生 UITextField / UITextView（调用方继续持有引用，
    ///   字体 / 占位 / 键盘 / delegate / target 一律原样）。
    /// - insets: 内容相对容器的内边距；登录 / 邀请单行框为左右 14、上下 0。
    /// - cornerRadius: 默认 12（登录 / 邀请原值）。
    /// - fixedHeight: 单行框传 48；多行框不传、由调用方约束定高。
    /// - borderColor: 常态边框色，默认 line；需 ink 20% 等口径时调用方传入。
    init(content: UIView, insets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14), cornerRadius: CGFloat = 12, fixedHeight: CGFloat? = nil, borderColor: UIColor = BearyColors.line) {
        self.content = content
        self.normalBorderColor = borderColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BearyColors.faint
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1
        layer.masksToBounds = true
        refreshBorder()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var constraints = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ]
        if let fixedHeight = fixedHeight {
            constraints.append(heightAnchor.constraint(equalToConstant: fixedHeight))
        }
        NSLayoutConstraint.activate(constraints)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(editingBegan), name: UITextField.textDidBeginEditingNotification, object: content)
        center.addObserver(self, selector: #selector(editingEnded), name: UITextField.textDidEndEditingNotification, object: content)
        center.addObserver(self, selector: #selector(editingBegan), name: UITextView.textDidBeginEditingNotification, object: content)
        center.addObserver(self, selector: #selector(editingEnded), name: UITextView.textDidEndEditingNotification, object: content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func editingBegan() {
        contentEditingFocused = true
        refreshBorder()
    }

    @objc private func editingEnded() {
        contentEditingFocused = false
        refreshBorder()
    }

    private func refreshBorder() {
        if isError {
            layer.borderColor = BearyColors.red.cgColor
        } else if contentEditingFocused {
            layer.borderColor = BearyColors.blue.cgColor
        } else {
            layer.borderColor = normalBorderColor.cgColor
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshBorder()
        }
    }
}

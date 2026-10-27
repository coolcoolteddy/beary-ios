import UIKit

// ===== 批一占位页 =====
// 消息 / 时间线 / 我 / 搜索 / 邀请 / 登录 / 个人主页在批一里先以此占位：
// 只有一行居中说明文案，不接任何接口、不画复杂 UI。
// 批二 / 批三逐页替换为真实现时，容器按页删对应 case，不改接线。
// W11：标题不再是死参——标题与说明同时画出（标题 17 semibold 墨色在上、说明 15 灰色在下）；
// 容器侧他人主页回退已改走“用户不存在，请重试”空态（见 SceneDelegate.ensurePlaceholder）。
// L19（已被 E2 取代）：文案组曾按内容区（顶栏底至胶囊顶）居中，随布局重算；
// E2：空态与加载态统一放可视区中心往上 30pt，本页文案组固定 centerY -30。

final class BearyPlaceholderViewController: UIViewController {
    private let titleText: String
    private let message: String
    private var centerYConstraint: NSLayoutConstraint?

    init(title: String, message: String = "正在做原生版") {
        self.titleText = title
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.gray
        // 长文案也要收进屏内换行居中：只定中心时超长文本会横向溢出屏幕。
        label.numberOfLines = 0
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [titleLabel, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let centerY = stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centerYConstraint = centerY
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerY,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // E2：空态与加载态统一放可视区中心往上 30pt——本占位页文案组固定 -30，
        // 取代 L19 按内容区（顶栏底至胶囊顶）算的变量偏移（安全区变化时不再重算）。
        if centerYConstraint?.constant != -30 {
            centerYConstraint?.constant = -30
        }
    }
}

import UIKit

// ===== 批一占位页 =====
// 消息 / 时间线 / 我 / 搜索 / 邀请 / 登录 / 个人主页在批一里先以此占位：
// 只有一行居中说明文案，不接任何接口、不画复杂 UI。
// 批二 / 批三逐页替换为真实现时，容器按页删对应 case，不改接线。

final class BearyPlaceholderViewController: UIViewController {
    private let message: String

    init(title: String, message: String = "正在做原生版") {
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
        let label = UILabel()
        label.text = message
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.gray
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

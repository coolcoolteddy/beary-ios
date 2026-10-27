import UIKit

// ===== 批一占位页 =====
// 消息 / 时间线 / 我 / 搜索 / 邀请 / 登录 / 个人主页在批一里先以此占位：
// 只有一行居中说明文案，不接任何接口、不画复杂 UI。
// 批二 / 批三逐页替换为真实现时，容器按页删对应 case，不改接线。
// W11：标题不再是死参——标题与说明同时画出（标题 17 semibold 墨色在上、说明 15 灰色在下）；
// 容器侧他人主页回退已改走“用户不存在，请重试”空态（见 SceneDelegate.ensurePlaceholder）。
// L19：文案组按内容区（顶栏底至胶囊顶）居中——页 view 顶已是顶栏底，底直通容器底，
// 故 centerY 偏移取 -(安全区底 + 胶囊 50 + 底距 12) / 2，随布局重算。

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
        // L19：内容区底 = 容器底 - (安全区底 + 胶囊 62)，内容区中心相对页中心的上移量即其一半。
        // 顶栏透度批：页顶已改 view.top（页高变大），内容区顶仍为顶栏底——旧公式只含安全区底，
        // 是按旧页高（顶 = 安全区顶 + 60/0）推的；新页高下须把安全区顶也计入，否则文案中心上移安全区顶/2。
        // 本占位页为居中内容、不在顶栏下方，故只改此居中偏移，不加顶部内边距。
        let offset = (view.safeAreaInsets.top - view.safeAreaInsets.bottom - 62) / 2
        if centerYConstraint?.constant != offset {
            centerYConstraint?.constant = offset
        }
    }
}

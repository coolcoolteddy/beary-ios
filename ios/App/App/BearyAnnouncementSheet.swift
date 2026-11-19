import UIKit

// ===== App 公告底 sheet（2026-11-08）=====
// 走系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）。
// 内容就是 admin 里写的那段原文，不自动拼 Release 说明。单“知道了”按钮。
// 字号走规范语义入口：标题 sheet 档 15 bold（smallActionFont），
// 正文 15 regular（smallBodyFont）；按钮走 BearyButton 工厂（常规 16 semibold）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyAnnouncementSheet {

    /// 从 presenter 弹出公告底 sheet（presenter 即 chrome 容器）。
    static func show(from presenter: UIViewController, announcement: BearyAnnouncement) {
        let sheet = BearyAnnouncementSheetViewController(announcement: announcement)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyAnnouncementSheetViewController: UIViewController, BearySystemSheetSizing {

    private let announcement: BearyAnnouncement

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let buttonStack = UIStackView()

    init(announcement: BearyAnnouncement) {
        self.announcement = announcement
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = announcement.title
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        view.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.text = announcement.content
        bodyLabel.font = BearyDynamicType.smallBodyFont()
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.numberOfLines = 0
        view.addSubview(bodyLabel)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        let button = BearyButton(style: .primaryPill(.ink))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("知道了", for: .normal)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(button)
        button.heightAnchor.constraint(equalToConstant: button.style.height).isActive = true
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 16）：系统抓手
            // 占顶区，标题位置不动；一律不要 ×，标题右缘放回内容边 -16。
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }
}

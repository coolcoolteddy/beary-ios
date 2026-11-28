import UIKit

// ===== App 公告底 sheet（2026-11-08）=====
// 走系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）。
// 内容就是 admin 里写的那段原文，不自动拼 Release 说明。单“知道了”按钮。
// 滚动结构照抄 BearyInputSheet：标题＋正文走 UIScrollView＋内容容器，
// “知道了”按钮组固定在底部；内容短时 sheet 高跟内容走，内容长时容器按 0.88
// 封顶、正文在滚动区内纵向滚动、按钮组贴底不动。
// 字号走规范语义入口：标题 sheet 档 15 bold（smallActionFont），
// 正文 15 regular（smallBodyFont）；按钮走 BearyButton 工厂（常规 16 semibold）。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyAnnouncementSheet {

    /// 从 presenter 弹出公告底 sheet（presenter 即 chrome 容器）。
    static func show(from presenter: UIViewController, announcement: BearyAnnouncement) {
        let sheet = BearyAnnouncementSheetViewController(announcement: announcement)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyAnnouncementSheetViewController: UIViewController, BearySystemSheetSizing {

    private let announcement: BearyAnnouncement

    private let scrollView = UIScrollView()
    private let scrollContentView = UIView()
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
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        // 内容区滚动容器：标题→正文挂内容容器内纵向滚动，
        // 按钮组留在 view 上固定底部（BearyInputSheet 同款）。
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContentView)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = announcement.title
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        scrollContentView.addSubview(titleLabel)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.text = announcement.content
        bodyLabel.font = BearyDynamicType.smallBodyFont()
        bodyLabel.textColor = BearyColors.gray
        bodyLabel.numberOfLines = 0
        scrollContentView.addSubview(bodyLabel)

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

        // 滚动区底边贴按钮组顶边（999：容器封顶后 sheet 帧被压短时先断这条，
        // 按钮组仍贴底可见，滚动区塌到 0 高，不动按钮高）。
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor)
        scrollBottom.priority = UILayoutPriority(rawValue: 999)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollBottom,

            scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 16）：系统抓手
            // 占顶区，标题位置不动；一律不要 ×，标题右缘放回内容边 -16。
            titleLabel.topAnchor.constraint(equalTo: scrollContentView.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
            titleLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            bodyLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
            bodyLabel.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -16),

            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -BearySystemSheet.contentBottomPadding),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    /// 滚动区无固有高，整体系 fitting 算不出高：改为滚动内容高（已含内容底
    /// 16 留白）＋按钮组高＋底边 8＋安全区底边分别相加；与改前总高一致，
    /// 封顶 0.88 仍由容器做，超高时正文在滚动区内纵向滚动、按钮组贴底不动。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let contentHeight = scrollContentView.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let buttonsHeight = buttonStack.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let height = ceil(contentHeight) + ceil(buttonsHeight) + BearySystemSheet.contentBottomPadding + view.safeAreaInsets.bottom + extraBottomInset
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

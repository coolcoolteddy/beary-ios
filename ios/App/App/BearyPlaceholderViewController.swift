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

// ===== 审计 N1：原生新手教程 =====
// 6 页内容取自网页版 beary.html 的 TUT_PAGES（只读来源，未改网页端一字）：
// 第 1 页欢迎（网页原标题为空，原生同样不画标题，改画欢迎头：logo 32 +
// 「欢迎来到 beary」19/700）、第 2 页 7 天私密、第 3 页 15 分钟修改、
// 第 4 页点赞/回应/收藏/分享、第 5 页消息与主页、第 6 页小工具。
// 文案仅做删冗精简，规则意思与网页版一致；第 2–6 页顶有网页 .tut-big
// 同款大图标圆（74 圆 faint 底 + 36 墨图标：mail/clock/heart/bell/compass）。
// 字号行高按网页 .tut-box：标题 18、正文 15/行高 1.7/最小高 96。
// 约定：无参 init()，由容器 lane 全屏模态弹出；本类不接任何菜单或启动逻辑。
// 关闭或完成都会把 UserDefaults beary_tutorial_seen_v1 置为 true，
// 供容器 lane 做首次启动自动弹出判断；isModalInPresentation 防止手势
// 下滑绕过关闭/完成路径导致该标记漏写。

final class BearyTutorialViewController: UIViewController, UIScrollViewDelegate {
    static let tutorialSeenKey = "beary_tutorial_seen_v1"

    private struct TutorialPage {
        let title: String
        let body: String
        // 网页 TUT_PAGES 的 icon 字段（第 1 页为空、走欢迎头不画大图标圆；
        // bell 复用 xcassets 已有 IconBell 资产——经像素核查与官方 beary-bell
        // 同款，不重复建资产；compass 为新增 icon_compass 资产，路径取官方
        // beary-compass 原稿，非自创、非 SF 符号）。
        let iconName: String?
        let isWelcome: Bool
    }

    private let pages: [TutorialPage] = [
        TutorialPage(
            title: "",
            body: "这里是一个安静的日记角落：写下今天，先私密保存七天，送达后由你决定是否公开——给每篇日记一点沉淀的时间。下面五页是这里的简单规则。",
            iconName: nil,
            isWelcome: true
        ),
        TutorialPage(
            title: "日记先私密 7 天",
            body: "每篇日记发布后不会立刻公开，而是先私密保存 7 天，在时间线里能看到离送达还剩多久。送达后，它只属于你自己；想公开时，在自己的日记上点「公开」，确认后进入倒计时，期间可以取消，到期后公开且不能撤回删除。",
            iconName: "icon_mail",
            isWelcome: false
        ),
        TutorialPage(
            title: "15 分钟内可修改",
            body: "刚发布写错了也不怕：15 分钟内可以编辑内容，整个私密期内都能删除。超过 15 分钟内容就会锁定，公开之后也不能再删改，所以发布前可以多检查一遍。",
            iconName: "icon_clock",
            isWelcome: false
        ),
        TutorialPage(
            title: "点赞、回应、收藏与分享",
            body: "这里没有文字评论区。看到喜欢的日记，可以点个赞，也可以贴小熊回应——喜欢哪种就贴哪种，可以同时留下好几只回应，再点一次就能摘下。还能收藏起来慢慢看（收藏列表只有你能看到），或者把单篇日记的链接分享给朋友。",
            iconName: "icon_heart",
            isWelcome: false
        ),
        TutorialPage(
            title: "消息与你的主页",
            body: "有人点赞、收藏或回应了你的日记，「消息」里都会收到提醒：新消息会带一个蓝点，点开就标为已读。我们写给你的信是橙色信封，重要的事都在里面。系统消息会合并成一张卡片，点开就能看全部。每个人都有一个公开主页 teddyhn.com/beary/@你的用户名，可以把链接分享出去。准备好了就点 +，写下你的第一篇日记吧。",
            iconName: "IconBell",
            isWelcome: false
        ),
        TutorialPage(
            title: "顺手的小工具",
            body: "写到一半也没关系：草稿会自动保存到这台设备，在编辑器工具栏点「草稿」就能接着写。发布时可以选一颗今天的心情，它会和日记一起出现。想写给某位朋友，就在发布前选一位收信人，对方要等送达那天才能打开。时间线顶部有日历和连续天数，写得越勤，小火苗越旺。想找以前的日记或朋友，点顶栏的放大镜搜一搜。",
            iconName: "icon_compass",
            isWelcome: false
        ),
    ]

    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private let closeButton = BearyHit44Button(type: .system)
    private let nextButton = UIButton(type: .system)
    private var pageViews: [UIView] = []
    private var currentPage = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        isModalInPresentation = true

        closeButton.setTitle("关闭", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        closeButton.setTitleColor(BearyColors.gray, for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        for page in pages {
            let container = UIView()
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 16
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            if page.isWelcome {
                // 网页 #tutWelcome：logo 高 32（.tut-logo，深色版资产自动反白，
                // 与网页 [data-theme="dark"] .tut-logo invert(1) 同效果）+
                // 「欢迎来到 beary」19/700（.tut-hi），间距 logo 下 10、hi 下 14。
                var welcomeLogoView: UIView?
                if let logoImage = UIImage(named: "LogoHorizontal") {
                    let logoView = UIImageView(image: logoImage)
                    logoView.translatesAutoresizingMaskIntoConstraints = false
                    logoView.contentMode = .scaleAspectFit
                    stack.addArrangedSubview(logoView)
                    let aspect = logoImage.size.height > 0 ? logoImage.size.width / logoImage.size.height : 1
                    NSLayoutConstraint.activate([
                        logoView.heightAnchor.constraint(equalToConstant: 32),
                        logoView.widthAnchor.constraint(equalToConstant: 32 * aspect),
                    ])
                    welcomeLogoView = logoView
                }
                let hiLabel = UILabel()
                hiLabel.text = "欢迎来到 beary"
                hiLabel.font = UIFont.boldSystemFont(ofSize: 19)
                hiLabel.textColor = BearyColors.ink
                hiLabel.textAlignment = .center
                hiLabel.numberOfLines = 0
                stack.addArrangedSubview(hiLabel)
                if let welcomeLogoView = welcomeLogoView {
                    stack.setCustomSpacing(10, after: welcomeLogoView)
                }
                stack.setCustomSpacing(14, after: hiLabel)
            } else if let iconName = page.iconName {
                // 网页 .tut-big：74 圆 faint 底 + 36 墨图标，圆下间距 16。
                let bigCircle = UIView()
                bigCircle.translatesAutoresizingMaskIntoConstraints = false
                bigCircle.backgroundColor = BearyColors.faint
                bigCircle.layer.cornerRadius = 37
                bigCircle.layer.masksToBounds = true
                let iconView = UIImageView()
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.image = BearyIconImages.image(named: iconName, pointSize: 36)
                iconView.tintColor = BearyColors.ink
                iconView.contentMode = .scaleAspectFit
                bigCircle.addSubview(iconView)
                NSLayoutConstraint.activate([
                    bigCircle.widthAnchor.constraint(equalToConstant: 74),
                    bigCircle.heightAnchor.constraint(equalToConstant: 74),
                    iconView.centerXAnchor.constraint(equalTo: bigCircle.centerXAnchor),
                    iconView.centerYAnchor.constraint(equalTo: bigCircle.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: 36),
                    iconView.heightAnchor.constraint(equalToConstant: 36),
                ])
                stack.addArrangedSubview(bigCircle)
            }
            if !page.title.isEmpty {
                let titleLabel = UILabel()
                titleLabel.text = page.title
                titleLabel.font = UIFont.boldSystemFont(ofSize: 18)
                titleLabel.textColor = BearyColors.ink
                titleLabel.textAlignment = .center
                titleLabel.numberOfLines = 0
                stack.addArrangedSubview(titleLabel)
                // 网页 .tut-box h3 下间距 8（默认栈距 16 只用于大图标圆→标题）。
                stack.setCustomSpacing(8, after: titleLabel)
            }
            let bodyLabel = UILabel()
            // 网页 .tut-box p：15 灰、行高 1.7、最小高 96——正文块高度固定后
            // 换页不再因各页文案长短浮动（标题/图标块本身各页固定高）。
            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.alignment = .center
            bodyParagraph.lineHeightMultiple = 1.7
            bodyLabel.attributedText = NSAttributedString(string: page.body, attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: BearyColors.gray,
                .paragraphStyle: bodyParagraph,
            ])
            bodyLabel.textAlignment = .center
            bodyLabel.numberOfLines = 0
            stack.addArrangedSubview(bodyLabel)
            bodyLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            ])
            scrollView.addSubview(container)
            pageViews.append(container)
        }

        pageControl.numberOfPages = pages.count
        pageControl.currentPage = 0
        pageControl.currentPageIndicatorTintColor = BearyColors.orange
        pageControl.pageIndicatorTintColor = BearyColors.line
        pageControl.addTarget(self, action: #selector(pageControlChanged), for: .valueChanged)
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageControl)

        nextButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        nextButton.setTitleColor(.white, for: .normal)
        nextButton.backgroundColor = BearyColors.orange
        nextButton.layer.cornerRadius = 22
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextButton)
        updateChrome()

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -16),
            nextButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nextButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -158),
            nextButton.widthAnchor.constraint(equalToConstant: 200),
            nextButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 页容器用 frame 布局（与站内图片分页查看同款做法），内层 stack 走约束：
        // 滚动区顶在关闭按钮下方、底在页码指示上方，旋转后按当前页复位偏移。
        let top = view.safeAreaInsets.top + 56
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 116
        let width = view.bounds.width
        let height = max(bottom - top, 0)
        scrollView.frame = CGRect(x: 0, y: top, width: width, height: height)
        for (index, pageView) in pageViews.enumerated() {
            pageView.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        scrollView.contentSize = CGSize(width: width * CGFloat(pageViews.count), height: height)
        scrollView.contentOffset = CGPoint(x: CGFloat(currentPage) * width, y: 0)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / width))
        guard page >= 0 && page < pages.count && page != currentPage else { return }
        currentPage = page
        updateChrome()
    }

    @objc private func pageControlChanged() {
        scrollToPage(pageControl.currentPage, animated: true)
    }

    @objc private func nextTapped() {
        if currentPage >= pages.count - 1 {
            finish()
        } else {
            scrollToPage(currentPage + 1, animated: true)
        }
    }

    @objc private func closeTapped() {
        finish()
    }

    private func scrollToPage(_ page: Int, animated: Bool) {
        guard page >= 0 && page < pages.count else { return }
        currentPage = page
        updateChrome()
        scrollView.setContentOffset(CGPoint(x: CGFloat(page) * scrollView.bounds.width, y: 0), animated: animated)
    }

    private func updateChrome() {
        pageControl.currentPage = currentPage
        let title = currentPage >= pages.count - 1 ? "开始使用" : (currentPage == 0 ? "开始了解" : "下一步")
        nextButton.setTitle(title, for: .normal)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: BearyTutorialViewController.tutorialSeenKey)
        dismiss(animated: true, completion: nil)
    }
}

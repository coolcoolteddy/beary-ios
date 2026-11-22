import UIKit

// ===== Plus 来源明细独立页 =====
// 口径（2026-11-22 Li 定）：Plus 页内的来源明细内联区块挪出，Plus 页底部
// 只留一个「来源明细」按钮，点进本页。本页即来源明细的全部内容——状态行、
// 发放记录行、加载／空态／失败态与重试，文案与行格式跟内联版一致；数据走
// 与 Plus 页同一份 fetchPlusDetail／sharedLoad（A2）。
// 全屏页，左上角左箭头返回（导航按钮规矩）。

final class BearyPlusGrantsViewController: UIViewController {

    /// A2：Plus 页的共享加载结果（同会话在途结果共用）；为 nil 时本页自己拉一次。
    private var sharedLoad: BearySharedLoad<BearyPlusDetailResponse>?

    init(sharedLoad: BearySharedLoad<BearyPlusDetailResponse>? = nil) {
        self.sharedLoad = sharedLoad
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "来源明细"
        return labelValue
    }()

    private let scrollView: UIScrollView = {
        let scrollValue = UIScrollView()
        scrollValue.translatesAutoresizingMaskIntoConstraints = false
        scrollValue.delaysContentTouches = false
        return scrollValue
    }()

    private let contentStack: UIStackView = {
        let stackValue = UIStackView()
        stackValue.translatesAutoresizingMaskIntoConstraints = false
        stackValue.axis = .vertical
        stackValue.spacing = 0
        stackValue.alignment = .fill
        return stackValue
    }()

    private var plusDetail: BearyPlusDetailResponse?
    private var grantsLoadFailed = false
    private var isRetryingGrants = false
    private var grantsRetryGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        renderGrantsSection()
        loadGrantsSection()

        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -52),
            scrollView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentNarrowLeading,
            contentNarrowTrailing,
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentNarrowWidth,
        ])
    }

    // MARK: - 内容列（Plus 页同款两分支互斥）
    /// 宽 ≤820：现行全宽约束原样；宽 ≥821：600 居中。两组只激活一组，
    /// 切换在 viewDidLayoutSubviews 里整组开关，状态不变不开关，避免布局循环。
    private lazy var contentNarrowLeading: NSLayoutConstraint = contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor)
    private lazy var contentNarrowTrailing: NSLayoutConstraint = contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
    private lazy var contentNarrowWidth: NSLayoutConstraint = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
    private lazy var contentWideWidth: NSLayoutConstraint = contentStack.widthAnchor.constraint(equalToConstant: 600)
    private lazy var contentWideCenterX: NSLayoutConstraint = contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
    private var contentIsWide = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 仅 iPad 且宽 ≥821 用 600 居中，其余用现行全宽；切换时重算一次。
        let wantWide = BearyDesktop.isWide(view.bounds.width)
        if wantWide != contentIsWide {
            contentIsWide = wantWide
            contentNarrowLeading.isActive = !wantWide
            contentNarrowTrailing.isActive = !wantWide
            contentNarrowWidth.isActive = !wantWide
            contentWideWidth.isActive = wantWide
            contentWideCenterX.isActive = wantWide
        }
    }

    // MARK: - 来源明细（自 Plus 页内联版整段挪出，行格式与文案不动；
    // 内联版的「来源明细」区头不搬——本页顶栏标题即“来源明细”）
    private func loadGrantsSection() {
        if let sharedLoad = sharedLoad {
            // A2：接 Plus 页同会话在途结果——在途则等同一份回包，已取到
            // 则直接用缓存；失败则走失败态。回包已在主线程（见 loader）。
            sharedLoad.load { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let detail):
                    self.plusDetail = detail
                    self.grantsLoadFailed = false
                case .failure:
                    self.grantsLoadFailed = true
                }
                self.renderGrantsSection()
            }
        } else {
            BearyAPI.shared.fetchPlusDetail { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let detail):
                        self.plusDetail = detail
                        self.grantsLoadFailed = false
                    case .failure(let error):
                        if case .cancelled = error { return }
                        self.grantsLoadFailed = true
                    }
                    self.renderGrantsSection()
                }
            }
        }
    }

    /// 设置页 fillPlusDetail 同款状态文案。
    private static func grantsStatusText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if detail.permanent == true { return "Plus 会员 · 永久" }
        if let effective = detail.effectiveUntil, effective > now {
            return "Plus 会员 · 至 " + BearyAccountText.dateString(ms: effective)
        }
        return "普通用户"
    }

    /// 来源明细页同款专属会员文案。
    private static func grantsPersonalText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let personal = detail.personalUntil ?? 0
        let freeUntil = detail.freeUntil ?? 0
        if detail.permanent == true { return "永久会员" }
        if personal > now {
            var text = "至 " + BearyAccountText.dateString(ms: personal)
            if freeUntil > 0 && personal > freeUntil {
                text += " · 限免结束后保留 \((personal - freeUntil) / 86400000) 天"
            } else if freeUntil > now {
                text += " · 与限免期重叠"
            }
            return text
        }
        return "暂无（好友注册并绑定邀请码，双方各得 +30 天）"
    }

    /// 内测限免行文案（旧设置页 Plus 组同款）。
    private static func grantsFreeText(detail: BearyPlusDetailResponse) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let freeUntil = detail.freeUntil ?? 0
        if freeUntil > now {
            return "全体内测用户免费 · 至 " + BearyAccountText.dateString(ms: freeUntil)
        }
        return "已结束 · " + BearyAccountText.dateString(ms: freeUntil) + " 到期"
    }

    private func renderGrantsSection() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if plusDetail == nil && !grantsLoadFailed {
            // 拉取进行中：先显加载行，不闪空态（回包后重绘）。
            let spinner = BearyRefreshIconView()
            spinner.image = BearyIconImages.image(named: "icon_refresh", pointSize: 20)
            spinner.startSpinning()
            let loadingLabel = UILabel()
            loadingLabel.translatesAutoresizingMaskIntoConstraints = false
            loadingLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            loadingLabel.adjustsFontForContentSizeCategory = true
            loadingLabel.textColor = BearyColors.gray
            loadingLabel.text = "加载中…"
            let loadingRow = UIStackView(arrangedSubviews: [spinner, loadingLabel])
            loadingRow.axis = .horizontal
            loadingRow.spacing = 8
            loadingRow.alignment = .center
            contentStack.addArrangedSubview(grantsRowWrap(content: loadingRow, isLast: true))
        } else if grantsLoadFailed {
            let failedLabel = UILabel()
            failedLabel.translatesAutoresizingMaskIntoConstraints = false
            failedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            failedLabel.adjustsFontForContentSizeCategory = true
            failedLabel.textColor = BearyColors.gray
            failedLabel.text = "加载失败"
            let retryButton = BearyButton.retryInline()
            retryButton.addTarget(self, action: #selector(grantsRetryTapped), for: .touchUpInside)
            retryButton.bearyAddPressFeedback()
            let failedStack = UIStackView(arrangedSubviews: [failedLabel, retryButton])
            failedStack.axis = .vertical
            failedStack.spacing = 8
            failedStack.alignment = .leading
            contentStack.addArrangedSubview(grantsRowWrap(content: failedStack, isLast: true))
        } else if let detail = plusDetail {
            var contents: [UIView] = []
            contents.append(grantsStatusContent(title: "当前状态", detail: Self.grantsStatusText(detail: detail)))
            contents.append(grantsStatusContent(title: "专属会员", detail: Self.grantsPersonalText(detail: detail)))
            if (detail.freeUntil ?? 0) > 0 {
                contents.append(grantsStatusContent(title: "内测限免", detail: Self.grantsFreeText(detail: detail)))
            }
            let grants = detail.grants ?? []
            if grants.isEmpty {
                let emptyLabel = UILabel()
                emptyLabel.translatesAutoresizingMaskIntoConstraints = false
                emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
                emptyLabel.adjustsFontForContentSizeCategory = true
                emptyLabel.textColor = BearyColors.gray
                emptyLabel.numberOfLines = 0
                emptyLabel.text = "暂无发放记录"
                contents.append(emptyLabel)
            } else {
                for grant in grants {
                    let nameLabel = UILabel()
                    nameLabel.translatesAutoresizingMaskIntoConstraints = false
                    nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
                    nameLabel.adjustsFontForContentSizeCategory = true
                    nameLabel.textColor = BearyColors.ink
                    nameLabel.numberOfLines = 0
                    nameLabel.text = BearyAccountText.grantSourceName(grant.source)
                    let detailLabel = UILabel()
                    detailLabel.translatesAutoresizingMaskIntoConstraints = false
                    detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                    detailLabel.adjustsFontForContentSizeCategory = true
                    detailLabel.textColor = BearyColors.gray
                    detailLabel.numberOfLines = 0
                    detailLabel.text = BearyAccountText.dateString(ms: grant.createdAt) + " · " + BearyAccountText.grantValueText(days: grant.days)
                    let rowStack = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
                    rowStack.axis = .vertical
                    rowStack.spacing = 4
                    contents.append(rowStack)
                }
            }
            for (index, content) in contents.enumerated() {
                contentStack.addArrangedSubview(grantsRowWrap(content: content, isLast: index == contents.count - 1))
            }
        }
    }

    /// 状态行内容（标题 15 墨左、文案 14 灰右，内联版同款）。
    private func grantsStatusContent(title: String, detail: String) -> UIView {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        titleLabel.text = title
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .right
        detailLabel.text = detail
        let row = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    /// 来源明细行包容器（与 benefitRow 同款：顶细线、上下各 14、左右 16，
    /// 末行补底细线）。
    private func grantsRowWrap(content: UIView, isLast: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let topLine = hairline()
        row.addSubview(topLine)
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        var constraints: [NSLayoutConstraint] = [
            topLine.topAnchor.constraint(equalTo: row.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ]
        if isLast {
            let bottomLine = hairline()
            row.addSubview(bottomLine)
            constraints.append(contentsOf: [
                bottomLine.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bottomLine.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                bottomLine.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = BearyColors.line
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return line
    }

    @objc private func grantsRetryTapped() {
        // 109：同会员来源明细页——在途重试直接忽略，先 render 加载态，
        // 回包后恢复。
        guard !isRetryingGrants else { return }
        isRetryingGrants = true
        grantsRetryGeneration += 1
        let gen = grantsRetryGeneration
        plusDetail = nil
        grantsLoadFailed = false
        renderGrantsSection()
        BearyAPI.shared.fetchPlusDetail { [weak self] result in
            DispatchQueue.main.async {
                // 先解锁再判代次：成功/失败/过期回包一律解锁，不留死锁。
                self?.isRetryingGrants = false
                guard let self = self, self.grantsRetryGeneration == gen else { return }
                switch result {
                case .success(let detail):
                    self.plusDetail = detail
                    self.grantsLoadFailed = false
                case .failure:
                    self.grantsLoadFailed = true
                }
                self.renderGrantsSection()
            }
        }
    }

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

import UIKit

// ===== 盲盒交换入口行（广场顶部与时间线顶部共用同一视图类）=====
// 视觉：surface 底 + 1px line 边框 + 圆角 14（与预览页“盲盒交换”入口行同款信息层级，
// 不复用预览的虚线演示样式）；图标 28pt；标题 15 semibold；计数与副文案 12/13 灰字。
// 计数联动：本视图监听 .bearyBlindBoxDidChange，任一入口开盒/撤回后两处同时刷新；
// 进页时宿主再调一次 refresh()（缓存镜像 + 跨日重置，不额外发请求，服务端刷新由流程页做）。
// 已换态：整行变灰（alpha 0.6 + 计数灰字）但仍可点——点按进流程页看今日收到篇与撤回
// 入口；“变灰”指视觉置灰，不是禁用，否则撤回入口无处可去。游客态：行可见，副文案
// 为“登录后可交换”，点按进流程页的登录提示（不直接弹登录门，与宿主 onRequireLogin
// 的通用门保持分工：流程页内登录成功后直接回到盲盒流程）。

final class BearyBlindBoxEntryView: UIView {

    var onTap: (() -> Void)?

    private let iconView = UIImageView()
    private let pendingChip = UILabel()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = BearyColors.line.cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = BearyColors.orange

        // 待补标注：新图标未注册时暂代图旁挂虚线 chip（预览页「待补」chip 同款口径）。
        pendingChip.translatesAutoresizingMaskIntoConstraints = false
        pendingChip.text = "待补"
        pendingChip.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        pendingChip.textColor = BearyColors.orange
        pendingChip.textAlignment = .center
        pendingChip.layer.cornerRadius = 8
        pendingChip.layer.borderWidth = 1
        pendingChip.layer.borderColor = BearyColors.orange.cgColor
        pendingChip.clipsToBounds = true
        pendingChip.isHidden = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "盲盒交换"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        // 挤压口径：标题行里计数与箭头永不被压——计数抱紧且抗压 required，
        // 标题抗压低于计数（不够宽时标题截断），副标题换行承担宽度收缩。
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = BearyColors.gray
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.numberOfLines = 0

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.contentMode = .scaleAspectFit
        chevronView.tintColor = BearyColors.gray
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        if let chevron = BearyIconImages.image(named: "icon_chevron_right", pointSize: 16) {
            chevronView.image = chevron
        }

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        // 文本列先收缩：不够宽时副标题换行（已 numberOfLines=0），不压计数与箭头。
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let iconStack = UIStackView(arrangedSubviews: [iconView, pendingChip])
        iconStack.axis = .vertical
        iconStack.spacing = 2
        iconStack.alignment = .center
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        iconStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconStack.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconStack, textStack, chevronView])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let tapButton = BearyHit44Button(type: .custom)
        tapButton.translatesAutoresizingMaskIntoConstraints = false
        tapButton.accessibilityLabel = "盲盒交换"
        tapButton.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        tapButton.bearyAddPressFeedback()
        addSubview(tapButton)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            pendingChip.widthAnchor.constraint(equalToConstant: 30),
            pendingChip.heightAnchor.constraint(equalToConstant: 16),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
            tapButton.topAnchor.constraint(equalTo: topAnchor),
            tapButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            tapButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            tapButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(handleStateChanged), name: .bearyBlindBoxDidChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleStateChanged() {
        refresh()
    }

    @objc private func tapped() {
        onTap?()
    }

    /// 刷新计数与副文案（只读本地镜像，不发请求）。
    func refresh() {
        let (icon, isPlaceholder) = BlindBoxIcons.blindBox(pointSize: 28)
        iconView.image = icon
        pendingChip.isHidden = !isPlaceholder
        if SessionManager.shared.isLoggedIn == false {
            countLabel.text = "今日 0/1"
            subtitleLabel.text = "登录后可交换 · 放一篇旧公开日记，换一篇别人的旧日记"
            alpha = 1
            return
        }
        let used = BlindBoxState.shared.usedToday
        countLabel.text = BlindBoxState.shared.countText()
        if used {
            subtitleLabel.text = "今日已换，来看看收到的日记"
            alpha = 0.6
        } else {
            subtitleLabel.text = "放一篇旧公开日记，换一篇别人的旧日记"
            alpha = 1
        }
    }
}

import UIKit

// ===== 设置页 ID 卡（2026-11-19 七组版）：注册时弹出的可翻转 ID 卡 =====
// 翻转核心复用 #1879 注册引导的 BearyIDCardView（0.55s 弹簧、透视
// m34=-1/1200、isFlipping 连点守卫、窄屏重建），不重写一套；
// #1879 专属的 BearyOnboardingPalette 与 UIFont.onboardingSerif 在 main 上
// 不存在，改走 BearyColors 与系统衬线（设置页账号名走衬线，见规范 §3）。
// 正面干净纯白、只有头像＋昵称；背面分段放注册时间、账号所在地、
// 用户名更改（几次＋上次更改时间）、ID。无“编辑资料”按钮（改资料入口
// 在我的页）、无会员行（会员在 Plus 卡）、无同步状态行。
// 数据一律真值：账号所在地／用户名更改次数与上次更改时间来自 /me 新字段
// （服务端 diff，加在 /me 上）；未下发时显示“–”，绝不编造、绝不写死
// 预览里的示例值（中国、4 次、上次更改 2026年9月）。

/// 设置页 ID 卡背面数据（由设置页 fillIdCard 组装，全部可选、缺值显“–”）。
struct BearySettingsIDCardData {
    var displayName: String
    var avatar: String?
    /// 注册时间（毫秒时间戳，来自 /me created_at）。
    var createdAt: Int?
    /// 账号所在地（来自 /me account_region，服务端取最近一次登录的地区）。
    var accountRegion: String?
    /// 用户名更改次数（来自 /me handle_change_count）。
    var handleChangeCount: Int?
    /// 用户名上次更改时间（毫秒时间戳，来自 /me handle_changed_at）。
    var handleChangedAt: Int?
    /// ID 行文本（serial_id／@handle／数字 id 回退，绝不编造）。
    var idText: String
}

final class BearySettingsIDCardView: UIView {

    private(set) var isShowingBack = false

    private let flipContainer = UIView()
    private let frontView = UIView()
    private let backView = UIView()
    private var isFlipping = false
    private var configuredData: BearySettingsIDCardData?

    private let avatarContainer = UIView()
    private let avatarImageView = UIImageView()
    private let avatarInitialLabel = UILabel()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.borderColor = BearyColors.line.cgColor
        clipsToBounds = true
        backgroundColor = BearyColors.surface1
        flipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flipContainer)
        NSLayoutConstraint.activate([
            flipContainer.topAnchor.constraint(equalTo: topAnchor),
            flipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            flipContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            flipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 176),
        ])
        frontView.translatesAutoresizingMaskIntoConstraints = false
        frontView.backgroundColor = BearyColors.surface1
        frontView.layer.isDoubleSided = false
        flipContainer.addSubview(frontView)
        backView.translatesAutoresizingMaskIntoConstraints = false
        backView.backgroundColor = BearyColors.surface1
        backView.layer.isDoubleSided = false
        // 背面预旋转 180°：容器转 180° 后背面正对观众。
        backView.layer.transform = CATransform3DMakeRotation(CGFloat.pi, 0, 1, 0)
        flipContainer.addSubview(backView)
        NSLayoutConstraint.activate([
            frontView.topAnchor.constraint(equalTo: flipContainer.topAnchor),
            frontView.leadingAnchor.constraint(equalTo: flipContainer.leadingAnchor),
            frontView.trailingAnchor.constraint(equalTo: flipContainer.trailingAnchor),
            frontView.bottomAnchor.constraint(equalTo: flipContainer.bottomAnchor),
            backView.topAnchor.constraint(equalTo: flipContainer.topAnchor),
            backView.leadingAnchor.constraint(equalTo: flipContainer.leadingAnchor),
            backView.trailingAnchor.constraint(equalTo: flipContainer.trailingAnchor),
            backView.bottomAnchor.constraint(equalTo: flipContainer.bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        addGestureRecognizer(tap)
        bearyAddRowPressFeedback()
        isAccessibilityElement = true
        accessibilityLabel = "我的 ID 卡，点按翻转查看背面"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func cardTapped() {
        flip(animated: true)
    }

    /// 点卡片绕 Y 轴 0.55s 弹簧翻转；减动效时直接换面。
    func flip(animated: Bool) {
        guard !isFlipping else { return }
        isShowingBack.toggle()
        let target: CGFloat = isShowingBack ? CGFloat.pi : 0
        let applyTransform = {
            var transform = CATransform3DIdentity
            transform.m34 = -1.0 / 1200.0
            transform = CATransform3DRotate(transform, target, 0, 1, 0)
            self.flipContainer.layer.transform = transform
        }
        if animated && BearyMotion.animated(true) {
            isFlipping = true
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: applyTransform, completion: { [weak self] _ in
                self?.isFlipping = false
            })
        } else {
            applyTransform()
        }
    }

    func configure(data: BearySettingsIDCardData) {
        configuredData = data
        buildFront(data: data)
        buildBack(data: data)
    }

    // MARK: - 正面（干净纯白：头像＋昵称）

    private func buildFront(data: BearySettingsIDCardData) {
        frontView.subviews.forEach { $0.removeFromSuperview() }
        avatarContainer.translatesAutoresizingMaskIntoConstraints = false
        avatarContainer.backgroundColor = BearyColors.surface2
        avatarContainer.layer.cornerRadius = 32
        avatarContainer.clipsToBounds = true
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarInitialLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarInitialLabel.font = BearyDynamicType.avatarInitialFont()
        avatarInitialLabel.adjustsFontForContentSizeCategory = true
        avatarInitialLabel.textColor = BearyColors.ink
        avatarInitialLabel.textAlignment = .center
        avatarInitialLabel.text = String(data.displayName.prefix(1))
        avatarContainer.addSubview(avatarImageView)
        avatarContainer.addSubview(avatarInitialLabel)
        NSLayoutConstraint.activate([
            avatarContainer.widthAnchor.constraint(equalToConstant: 64),
            avatarContainer.heightAnchor.constraint(equalToConstant: 64),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
        ])
        // 头像与编辑页同法：/me 下发的 avatar 是 data:image;base64，直接解码；
        // 否则走头像 URL 加载，失败回显首字母兜底。
        avatarImageView.image = nil
        if let avatar = data.avatar, !avatar.isEmpty, avatar.hasPrefix("data:"),
           let commaIndex = avatar.firstIndex(of: ","),
           let avatarData = Data(base64Encoded: String(avatar[avatar.index(after: commaIndex)...])),
           let avatarImage = UIImage(data: avatarData) {
            avatarImageView.image = avatarImage
            avatarInitialLabel.isHidden = true
        } else if let avatar = data.avatar, !avatar.isEmpty {
            avatarInitialLabel.isHidden = true
            avatarImageView.bearySetImage(url: BearyImageURLs.avatarURL(avatar)) { [weak self] _ in
                self?.avatarInitialLabel.isHidden = false
            }
        } else {
            avatarInitialLabel.isHidden = false
        }
        // 设置页账号名走衬线（规范 §3 衬线克制版 11 处之一）。
        nameLabel.font = BearyDynamicType.heroNameFont()
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 1
        nameLabel.text = data.displayName
        let stack = UIStackView(arrangedSubviews: [avatarContainer, nameLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        frontView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: frontView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: frontView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: frontView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: frontView.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - 背面（分段：注册时间／账号所在地／用户名更改／ID）

    private func buildBack(data: BearySettingsIDCardData) {
        backView.subviews.forEach { $0.removeFromSuperview() }
        let createdText = BearyAccountText.dateString(ms: data.createdAt)
        let regionText = (data.accountRegion ?? "").isEmpty ? "–" : data.accountRegion!
        let handleText: String
        if let count = data.handleChangeCount {
            if let last = data.handleChangedAt, last > 0 {
                handleText = "\(count) 次 · 上次更改 \(BearyAccountText.dateString(ms: last))"
            } else {
                handleText = "\(count) 次"
            }
        } else {
            handleText = "–"
        }
        let rows: [(title: String, value: String, mono: Bool)] = [
            ("注册时间", createdText, false),
            ("账号所在地", regionText, false),
            ("用户名更改", handleText, false),
            ("ID", data.idText, true),
        ]
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .fill
        backView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: backView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: backView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: backView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: backView.bottomAnchor, constant: -16),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                NSLayoutConstraint.activate([separator.heightAnchor.constraint(equalToConstant: 1)])
                stack.addArrangedSubview(separator)
            }
            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = BearyColors.gray
            titleLabel.text = row.title
            titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let valueLabel = UILabel()
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            if row.mono {
                valueLabel.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
            } else {
                valueLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            }
            valueLabel.adjustsFontForContentSizeCategory = true
            valueLabel.textColor = BearyColors.ink
            valueLabel.textAlignment = .right
            valueLabel.numberOfLines = 1
            valueLabel.text = row.value
            if row.mono {
                valueLabel.attributedText = NSAttributedString(string: row.value, attributes: [.kern: 2, .font: valueLabel.font as Any])
            }
            let rowStack = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
            rowStack.axis = .horizontal
            rowStack.spacing = 12
            rowStack.alignment = .center
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(rowStack)
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                rowStack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 7),
                rowStack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                rowStack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                rowStack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -7),
            ])
            stack.addArrangedSubview(wrap)
        }
    }
}

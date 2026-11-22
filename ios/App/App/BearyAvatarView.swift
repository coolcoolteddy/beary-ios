import UIKit

// MARK: - BearyAvatarView：头像统一组件（C3 抽取，fix/avatar-shared-migration 参数化）
//
// 搬运来源（main 现行同款四处，视觉一字不动）：好友行 BearyFriendCell、
// 会话行 BearyDMConversationCell、搜索用户行 makeUserRow、设置页拉黑行
// BearyBlockedUserCell。规格：默认 44×44 圆角 22；无图/失败时首字母占位——
// 17pt bold（cappedFont）、BearyColors.orange 字、orange 14% 底；失败时
// 44×44 icon_refresh 20pt（ink 色）重试钮居中压在头像上，仅失败态可见。
// 颜色不改：首字母仍走 BearyColors.orange，不等新 token 值、不顺带修 V1。
// 加载口径取四处主 configure 的交集：BearyImageLoader.loadDetailed 下采样
// 到 44×scale，回调凭代次 + URL 双重校验（复用/换行后才到的旧回包丢弃）。
// 重试复用同一条 load 路径（与主 configure 同口径）。与 main 现行重试的
// 差别、与未合入 #679 的关系，见本文件末尾注释与 PR 描述，合入时复核。
// 调用方只给外框约束，内部三层贴满/居中；复用前调 reset()。
// 动效：无新增动效；按压反馈走既有 bearyAddPressFeedback（transform 系）。
// 本组件只进 App target：测试 target 不用它，且它的依赖
// BearyIconImages / BearyImageLoader 不在 BearyCoreTests 内（与 BearyStateView
// 同款 App-only 前例），故不进测试 target Sources。
//
// 直径参数（fix/avatar-shared-migration）：三处旧实现全不是 44pt，
// 故加 init(diameter:)——圆角／下采样／占位字号／重试钮／图标尺寸随直径走，
// 各处保持现有尺寸（通知栈与通知 cell 42、ID 卡 36/46），不悄悄统一成 44。
// 无参 BearyAvatarView() 仍走 44 默认。类别图标槽（通知卡面/系统行用）：
// showCategoryIcon + setCategoryColors，见末尾行为差别第 6 项。

final class BearyAvatarView: UIView {

    /// 头像直径（默认 44；通知栈/通知 cell 42、ID 卡 36/46，见 init(diameter:)）。
    private var diameter: CGFloat = 44

    private let imageView = UIImageView()
    private let fallbackLabel = UILabel()
    /// 类别图标槽（通知卡面/系统行）：19pt（按直径等比）居中图标，不加载头像。
    private let iconView = UIImageView()
    private var retryWidthConstraint: NSLayoutConstraint?
    private var retryHeightConstraint: NSLayoutConstraint?
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    private lazy var retryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        // 新交互面口径：关掉系统默认高亮压暗（FAB 同款），按压反馈只走
        // bearyAddPressFeedback 的 transform 缩放＋轻震，不叠加压暗。
        button.adjustsImageWhenHighlighted = false
        button.accessibilityLabel = "重试"
        button.accessibilityHint = "重新加载头像"
        button.isHidden = true
        button.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    private var loadTask: URLSessionDataTask?
    private var currentURL: URL?
    private var generation = 0
    private var fallbackName = "beary 用户"
    /// #679 三重校验的第三重：当前行代表的用户 id（configure 记录、reset 清零）。
    /// 仅好友/会话两处传，搜索与设置页不传（沿用旧口径）。
    private var ownerID: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = diameter / 2
        clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = diameter / 2
        imageView.layer.masksToBounds = true
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17))
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textColor = BearyColors.ink // 2026-11-04 黑白灰：回退头像改浅灰底墨字，与选人器回退圈同口径（取代 #707 留橙口径）
        fallbackLabel.backgroundColor = BearyColors.surface2
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = diameter / 2
        fallbackLabel.layer.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = true
        addSubview(imageView)
        addSubview(fallbackLabel)
        addSubview(iconView)
        addSubview(retryButton)
        retryWidthConstraint = retryButton.widthAnchor.constraint(equalToConstant: diameter)
        retryHeightConstraint = retryButton.heightAnchor.constraint(equalToConstant: diameter)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: diameter * 19 / 42)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: diameter * 19 / 42)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallbackLabel.topAnchor.constraint(equalTo: topAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        retryWidthConstraint?.isActive = true
        retryHeightConstraint?.isActive = true
        iconWidthConstraint?.isActive = true
        iconHeightConstraint?.isActive = true
    }

    /// 非 44pt 的头像位用这个构造器（通知栈/通知 cell 42、ID 卡 36/46）：
    /// 圆角／下采样／占位字号／重试钮／图标尺寸随直径走，布局尺寸保持调用方现行值。
    convenience init(diameter: CGFloat) {
        self.init(frame: .zero)
        self.diameter = diameter
        applyDiameter()
    }

    /// 直径定下来后重算全部随直径走的尺寸（圆角、占位字号、重试钮、图标）。
    private func applyDiameter() {
        let radius = diameter / 2
        layer.cornerRadius = radius
        imageView.layer.cornerRadius = radius
        fallbackLabel.layer.cornerRadius = radius
        fallbackLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17 * diameter / 44))
        retryWidthConstraint?.constant = diameter
        retryHeightConstraint?.constant = diameter
        let iconSize = diameter * 19 / 42
        iconWidthConstraint?.constant = iconSize
        iconHeightConstraint?.constant = iconSize
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 复用/重建前调用：取消在途任务、代次 +1 作废旧回包、清图藏重试钮、清类别图标。
    func reset() {
        cancelLoad()
        imageView.image = nil
        retryButton.isHidden = true
        iconView.image = nil
        iconView.isHidden = true
        backgroundColor = .clear
    }

    /// 只取消在途加载并作废旧回包（不碰图层显隐与底色），供 showCategoryIcon 用。
    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        currentURL = nil
        ownerID = nil
    }

    /// 类别图标模式（通知卡面/系统行）：头像位改画居中图标，不加载头像；
    /// 底色与图标色由 setCategoryColors 定，不在此处清底色（调用方先定色后亮图标也成立）。
    func showCategoryIcon(_ image: UIImage?) {
        cancelLoad()
        imageView.image = nil
        retryButton.isHidden = true
        imageView.isHidden = true
        fallbackLabel.isHidden = true
        iconView.image = image
        iconView.isHidden = image == nil
    }

    /// 类别图标的底色与图标色（通知 cell 的 applyCardCategoryColors 定口径）。
    func setCategoryColors(backgroundColor: UIColor, tintColor: UIColor) {
        self.backgroundColor = backgroundColor
        iconView.tintColor = tintColor
    }

    /// displayName 为空时回落“beary 用户”（#696 全站统一口径）；
    /// avatarURL 为 nil 时直接显首字母占位，不建加载任务。
    func configure(displayName: String, avatarURL: URL?, ownerID: Int? = nil) {
        iconView.image = nil
        iconView.isHidden = true
        backgroundColor = .clear
        let name = displayName.isEmpty ? "beary 用户" : displayName
        fallbackName = name
        self.ownerID = ownerID
        retryButton.isHidden = true
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        currentURL = nil
        guard let url = avatarURL else {
            imageView.isHidden = true
            fallbackLabel.isHidden = false
            fallbackLabel.text = String(name.prefix(1)).uppercased()
            return
        }
        // 换绑定先显首字母占位：清掉旧位图，加载期间不留上一任头像；
        // 成功回包再切头像（load 成功分支），失败留占位＋重试钮（与重试路径同口径）。
        imageView.image = nil
        imageView.isHidden = true
        fallbackLabel.isHidden = false
        fallbackLabel.text = String(name.prefix(1)).uppercased()
        currentURL = url
        load(url: url, displayName: name)
    }

    private func load(url: URL, displayName: String) {
        loadTask?.cancel()
        let capturedGeneration = generation
        let capturedOwnerID = ownerID
        // 头像框直径 diameter：下采样到 diameter×scale 解码，不整图全解码进内存。
        loadTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: diameter * UIScreen.main.scale) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, capturedGeneration == self.generation, self.currentURL == url, capturedOwnerID == self.ownerID else { return }
                switch result {
                case .success(let image):
                    self.imageView.image = image
                    self.imageView.isHidden = false
                    self.fallbackLabel.isHidden = true
                    self.retryButton.isHidden = true
                case .failure:
                    // 失败不再留空白圆圈：回首字母占位＋点按重试（好友/会话原口径）。
                    self.imageView.isHidden = true
                    self.fallbackLabel.isHidden = false
                    self.fallbackLabel.text = String(displayName.prefix(1)).uppercased()
                    self.retryButton.isHidden = false
                }
            }
        }
    }

    /// 栈内重试透传用：点落在可见重试钮内时返回重试钮，否则返回 nil
    ///（头像区其余点仍交给栈的整区点按钮，不拦截展开/收起）。
    func retryButtonHit(at point: CGPoint, from view: UIView) -> UIView? {
        guard !retryButton.isHidden else { return nil }
        let local = convert(point, from: view)
        return retryButton.frame.contains(local) ? retryButton : nil
    }

    @objc private func retryTapped() {
        guard let url = currentURL else { return }
        retryButton.isHidden = true
        // 重试等待期间保留首字母占位：imageView 保持隐藏、fallbackLabel
        // 保持显示，成功回包再切头像，失败回包只恢复重试钮。
        load(url: url, displayName: fallbackName)
    }
}

// MARK: - 抽取时的行为差别（合入时复核，勿当“纯搬运”默认已等价）
//
// 1. main 现行重试（好友/会话 loadAvatar）：loadDetailed 不传下采样尺寸、
//    回包只校验 self，不校验代次/URL。组件重试复用主 load 路径，故重试现
//    带下采样 + 代次/URL 校验——比 main 旧重试更严，不是原样搬运；但与
//    主 configure 口径一致，且方向与 #679 相同。
// 2. #679 已合入 main：好友/会话重试带“代表用户 id”三重校验 + 下采样。
//    并解时已选“组件加 ownerID 参数”：configure(ownerID:) 记录、reset 清零，
//    load 回包校验代次 + URL + ownerID 三重，调用点好友传 user.id、会话传 peer?.id；
//    搜索与设置页不传（沿用旧口径）。
// 3. 搜索旧失败态：BearySearchImageRetry 只亮重试钮，不切首字母占位
//    （失败时仍是空圆圈 + 重试钮）。搜索改走组件后，失败态与好友/会话
//    一致：首字母占位 + 重试钮。属统一行为的可见变化，已在 PR 描述中列出。
// 4. 设置页拉黑行旧失败态：失败回调只处理成功分支，失败时留空白头像、
//    无重试钮、无占位。拉黑行改走组件后，失败态同为首字母占位 + 重试钮。
//    另：设置页内另有 64pt 主头像（ink 28）与 36pt 切换账号行（ink 15、
//    faint 底），均非本组件所述 44/orange  copy，本支不动。
// 5. fix/avatar-shared-migration：通知头像栈（42pt）旧失败态是“留首字母
//    占位、无重试钮”，改走组件后失败态统一为首字母占位＋重试钮；重试钮
//    42×42 压在圆内，栈整区点按钮会盖住它，栈重写 hitTest 让重试钮点按透传。
// 6. fix/avatar-shared-migration：通知 cell 互动行（42pt）旧失败态是“藏
//    首字母占位、只亮重试图标”，改走组件后统一为首字母占位＋重试钮；
//    类别图标（卡面/系统行）改走组件图标槽 showCategoryIcon，底色/图标色
//    仍由 cell 的 applyCardCategoryColors 定；无图行仍只显首字母占位、
//    不亮重试（configure avatarURL=nil 口径不变）。
// 7. fix/avatar-shared-migration：ID 卡（36/46pt）旧实现 URLSession 直取，
//    无缓存/下采样/代次校验、失败直接无图；改走组件后走 BearyImageLoader
//    缓存＋下采样＋代次校验，失败态为首字母占位＋重试钮。占位形态变了：
//    旧 blueSoft 底＋person.fill glyph 改为首字母占位（surface2 底墨字）。
//    名字取 data.nickname；卡面数据无用户 id，ownerID 不传（与搜索/设置页同口径）。
// 8. 直径参数化：init(diameter:) 只改尺寸口径，不改布局尺寸——通知两处
//    保持 42、ID 卡保持 36/46；无参 BearyAvatarView() 仍是 44 默认。

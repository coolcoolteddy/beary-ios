import UIKit

// MARK: - BearyAvatarView：44pt 头像统一组件（C3 抽取）
//
// 搬运来源（main 现行同款四处，视觉一字不动）：好友行 BearyFriendCell、
// 会话行 BearyDMConversationCell、搜索用户行 makeUserRow、设置页拉黑行
// BearyBlockedUserCell。规格：44×44 圆角 22；无图/失败时首字母占位——
// 17pt bold（cappedFont）、BearyColors.orange 字、orange 14% 底；失败时
// 44×44 icon_refresh 20pt（ink 色）重试钮居中压在头像上，仅失败态可见。
// 颜色不改：首字母仍走 BearyColors.orange，不等新 token 值、不顺带修 V1。
// 加载口径取四处主 configure 的交集：BearyImageLoader.loadDetailed 下采样
// 到 44×scale，回调凭代次 + URL 双重校验（复用/换行后才到的旧回包丢弃）。
// 重试复用同一条 load 路径（与主 configure 同口径）。与 main 现行重试的
// 差别、与未合入 #679 的关系，见本文件末尾注释与 PR 描述，合入时复核。
// 调用方只给外框 44×44 约束，内部三层贴满/居中；复用前调 reset()。
// 动效：无新增动效；按压反馈走既有 bearyAddPressFeedback（transform 系）。
// 本组件只进 App target：测试 target 不用它，且它的依赖
// BearyIconImages / BearyImageLoader 不在 BearyCoreTests 内（与 BearyStateView
// 同款 App-only 前例），故不进测试 target Sources。

final class BearyAvatarView: UIView {

    private let imageView = UIImageView()
    private let fallbackLabel = UILabel()

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
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 22
        imageView.layer.masksToBounds = true
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17))
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textColor = BearyColors.ink // 2026-11-04 黑白灰：回退头像改浅灰底墨字，与选人器回退圈同口径（取代 #707 留橙口径）
        fallbackLabel.backgroundColor = BearyColors.surface2
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = 22
        fallbackLabel.layer.masksToBounds = true
        addSubview(imageView)
        addSubview(fallbackLabel)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallbackLabel.topAnchor.constraint(equalTo: topAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 44),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 复用/重建前调用：取消在途任务、代次 +1 作废旧回包、清图藏重试钮。
    func reset() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
        currentURL = nil
        ownerID = nil
        imageView.image = nil
        retryButton.isHidden = true
    }

    /// displayName 为空时回落“beary 用户”（#696 全站统一口径）；
    /// avatarURL 为 nil 时直接显首字母占位，不建加载任务。
    func configure(displayName: String, avatarURL: URL?, ownerID: Int? = nil) {
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
        // 头像框 44pt：下采样到 44×scale 解码，不整图全解码进内存。
        loadTask = BearyImageLoader.shared.loadDetailed(url: url, downsampleToWidth: 44 * UIScreen.main.scale) { [weak self] result in
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

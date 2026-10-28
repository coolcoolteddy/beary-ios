import UIKit

// ===== BearyDiaryCardCell 共享日记卡片（B 批卡片合并）=====
// 首页 BearyFeedCell 与个人主页 BearyProfileEntryCell 的合并体，两页共用一处
// 实现。两页卡片骨架相同（头像 40 + 右列：写给行 / 标题行 / 正文 / 折叠 /
// 引用卡 / 图片条 216 / 操作行 / 回应行 / 底线 2），但互动架构与若干视觉
// 本就不同，合并时以 cardMode 区分，不擅自统一：
//  - 标题行对齐（Li 2026-10-27 定：两页统一 .firstBaseline，按文字基线对齐）。
//  - 互动架构：feed 模式 cell 内直发 API（点赞/收藏/回应，成功失败路径
//    就地同步）；profile 模式 cell 只转发回调（onLike/onBookmark/onEmoteTap
//    等），API 与就地同步归控制器（syncInteraction(entry:interactionDisabled:)）。
//  - 视觉分歧点（各保各的）：正文字号 feed 16 / profile 15；0 赞时 feed
//    显示“0”、profile 隐藏数字位；未赞色 feed 爱心 ink + 计数灰、profile
//    爱心与计数同灰；取消赞预态 feed ink / profile 灰；写给行字号 feed
//    12 粗体 / profile 13 常规；心情行间距 feed 3 / profile 4；操作行
//    feed 带公开行 pubStack、profile 同款（A-2 补齐）；折叠 feed 实测溢出（300 字 +
//    实测超 6 行）/ profile 只计 300 字；图片槽底色 feed line / profile faint。
//  - 统一项：回应流一律 Feed 流式换行 BearyEmoteFlowView（profile 单行横滑
//    emoteScrollView 废弃）；图片失败重试一律 Feed 口径（头像/主图均有重试钮，
//    profile 主图槽位补重试）；引用卡一律共享 BearyQuoteCardView（profile
//    圆角 12→8、补左侧线，内边距与字号不动）；回应 chip 一律 BearyEmoteChipView
//    （自带 trait 重刷边框）；操作行一律 BearyActionStackView（point 透传，
//    Hit44 热区不再被 22pt 高的操作行截掉）；回应 chip 点击层与 + 钮一律
//    BearyHit44Button（视觉尺寸不变，只扩热区）。
// 必须保留的既有成果：94 包主图 9 槽位复用（两页都走槽位，复用即取消在途
// 下载）；#67 互动就地同步（两套 syncInteraction 均保留，成功与失败路径不再
// reload 换 cell）；#70 Profile 引用缩略图池化（已下沉到 BearyQuoteCardView
// 内置 thumbPool）；69 批天气 Lottie 管控（本 cell 只用静态天气图标，不碰
// 播放器）、点赞先行反馈口径与 pre-unlike/收藏先行例外（只搬运、不改语义）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

/// 卡片模式：feed = 首页（广场 + 今日送达），profile = 个人主页（三页签）。
/// cell 实例一生只属于一张表，mode 在创建时定死，不中途切换。
enum BearyDiaryCardMode {
    case feed
    case profile
}

// MARK: - E1-5：本文件内图标重绘缓存（原首页文件内私有，现共享给两页 cell 与引用卡）

/// BearyIconImages 每次调用都重绘一次 PNG；卡片内的调用全部经此缓存，
/// key = 名字 + 尺寸（template 图与 tint 无关，深浅模式共用同一缓存图）。
enum BearyFeedIconCache {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        let key = "\(name)#\(pointSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let made = BearyIconImages.image(named: name, pointSize: pointSize) else { return nil }
        cache.setObject(made, forKey: key)
        return made
    }
}

// MARK: - 图片失败重试（清单第 13 项首页部分：主卡图片 + 头像；合并后两页同款）

/// 纯图标重试钮（用户定形态就是图标，不要文字按钮）：28pt bg 色圆盘 + icon_refresh。
/// 只由失败回调显示；点按先藏、重载成功后保持隐藏、再失败则重新出现。
/// 加载中与成功态不碰——成功路径不回调，图标自然不会出现。
final class BearyFeedRetryButton: UIButton {
    weak var targetImageView: UIImageView?
    var retryURL: URL?
    // B 组：帧 28 时 point 外扩至 44（头像帧另改 44 后本扩不生效，图片重试仍靠它）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx: CGFloat = bounds.width < 44 ? (44 - bounds.width) / 2 : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

func bearyFeedRetryButton(target: Any?, action: Selector) -> BearyFeedRetryButton {
    let btn = BearyFeedRetryButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(BearyFeedIconCache.image(named: "icon_refresh", pointSize: 20), for: .normal)
    btn.tintColor = BearyColors.gray
    btn.backgroundColor = BearyColors.bg
    btn.layer.cornerRadius = 14
    btn.clipsToBounds = true
    btn.isHidden = true
    btn.accessibilityLabel = "重新加载图片"
    btn.addTarget(target, action: action, for: .touchUpInside)
    btn.bearyAddPressFeedback()
    return btn
}

/// 经 bearySetImage 的 onFailure 钩子加载：失败（取消除外，复用取消不算失败）时亮重试图标。
func bearyFeedLoadImage(into imageView: UIImageView, url: URL?, retryButton: BearyFeedRetryButton, downsampleToWidth: CGFloat? = nil) {
    retryButton.targetImageView = imageView
    retryButton.retryURL = url
    retryButton.isHidden = true
    imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: downsampleToWidth, onFailure: { [weak retryButton] _ in
        retryButton?.isHidden = false
    })
}

func bearyFeedPerformRetry(_ button: BearyFeedRetryButton) {
    guard let imageView = button.targetImageView, let url = button.retryURL else { return }
    button.isHidden = true
    // 80 包 B3-2：重试时图框已布局，按实测框宽下采样（未布局时传 nil 走原路）。
    let retryDownsample = imageView.bounds.width > 0 ? imageView.bounds.width * UIScreen.main.scale : nil
    imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: retryDownsample, onFailure: { [weak button] _ in
        button?.isHidden = false
    })
}

// MARK: - 操作行透传栈（A 批小修：actionStack 命中截断）

/// 普通 UIStackView、无高度约束、高度由 22pt 级子视图撑开时，子视图的
/// BearyHit44Button 扩后热区（上下各 11pt）会超出栈 bounds 而被截掉；
/// 本栈重写 point(inside:)：点落在栈内照常，落在外时只当它命中了某个
/// UIButton 子孙的扩后热区才放行（视觉尺寸与布局一字不动，只扩热区）。
final class BearyActionStackView: UIStackView {

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) {
            return true
        }
        for sub in arrangedSubviews {
            if self.hitExpandedButton(in: sub, point: point) {
                return true
            }
        }
        return false
    }

    /// 追加 1（B 法）：重叠带命中优先级——收藏/分享的 44pt 扩后热区在两钮之间
    /// 重叠（个人主页约 7pt、首页约 3pt），UIKit 默认按子视图逆序命中，重叠带
    /// 一律落到右侧钮；此处多钮同时命中时按视觉中心最近者胜（重叠带中线分流），
    /// 单钮命中时走默认路径，spacer、公开行等其他视图行为一字不动。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        var claimants: [UIButton] = []
        collectClaimingButtons(in: self, point: point, event: event, into: &claimants)
        if claimants.count >= 2 {
            var best: UIButton?
            var bestDistance: CGFloat = .greatestFiniteMagnitude
            for button in claimants {
                let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self)
                let distance = abs(center.x - point.x)
                if distance < bestDistance {
                    bestDistance = distance
                    best = button
                }
            }
            return best
        }
        return super.hitTest(point, with: event)
    }

    /// 递归收集扩后热区命中该点的 UIButton 子孙（隐藏/不可交互/透明者不算，
    /// 与 UIKit hitTest 的可达条件一致；isEnabled 不参与判定，禁用钮仍占位吞点，
    /// 与现行行为一致）。
    private func collectClaimingButtons(in view: UIView, point: CGPoint, event: UIEvent?, into out: inout [UIButton]) {
        for sub in view.subviews {
            guard sub.isHidden == false, sub.alpha >= 0.01, sub.isUserInteractionEnabled else { continue }
            if let button = sub as? UIButton {
                let local = sub.convert(point, from: self)
                if button.point(inside: local, with: event) {
                    out.append(button)
                }
            }
            collectClaimingButtons(in: sub, point: point, event: event, into: &out)
        }
    }

    private func hitExpandedButton(in view: UIView, point: CGPoint) -> Bool {
        if view.isHidden {
            return false
        }
        if let button = view as? UIButton {
            let local = view.convert(point, from: self)
            if button.point(inside: local, with: nil) {
                return true
            }
        }
        for sub in view.subviews {
            if self.hitExpandedButton(in: sub, point: point) {
                return true
            }
        }
        return false
    }
}

// MARK: - 回应 chip（A 批小修：边框深浅切换不跟随）

/// 两页原 chip 都是 UIView 容器 + 内层横排（播放器 24 + 计数）+ 透明点击层；
/// 本组件收敛为一处，并自带 traitCollectionDidChange 重刷边框（CGColor
/// 赋值时固化，不重赋即停留在旧主题色）——个人主页 chip 边框深浅切换不
/// 跟随的问题由此根治，cell 侧不再另起一套遍历重刷（二选一，只此一套）。
/// 点击层为 BearyHit44Button（视觉仍为整 chip 尺寸，只扩热区）；mine 态：
/// 底色 hov、边框 ink、计数 ink 粗体；非 mine：底色 faint、边框 line、计数 gray。
final class BearyEmoteChipView: UIView {

    private let row = UIStackView()
    private let countLabel = UILabel()
    private var emotePlayer: BearyEmoteView?
    private var mineFlag = false
    /// 透明点击层：cell 侧挂 target、写 tag、控 enabled；热区由父类扩到 44。
    let overlayButton = BearyHit44Button(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 16
        layer.borderWidth = 1
        clipsToBounds = true
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(countLabel)
        addSubview(row)
        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlayButton)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            overlayButton.topAnchor.constraint(equalTo: topAnchor),
            overlayButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        self.applyChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 胶囊形兜底：圆角恒取高的一半，任何高度下都是胶囊（32 高时即 16，与旧值一致）；
    /// 即使某路残留 transform 使 bounds 翻倍，显示圆角仍为显示高的一半。
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.height > 0 {
            layer.cornerRadius = bounds.height / 2
        }
    }
    /// 池化渲染：样式/计数/tag 由调用方随后写 overlayButton；key 不变且已在播时
    /// 不重播（每次渲染都 play() 会从 0 帧重画描线）、停播时恢复播放；key 变了
    /// 才换播放器；不重建容器与约束。
    func render(key: String, count: Int, mine: Bool) {
        mineFlag = mine
        countLabel.font = UIFont.systemFont(ofSize: 12, weight: mine ? .bold : .regular)
        countLabel.textColor = mine ? BearyColors.ink : BearyColors.gray
        countLabel.text = "\(count)"
        if let current = emotePlayer, current.emoteKey == key {
            if current.isPlayingNow == false {
                current.play()
            }
        } else {
            emotePlayer?.stop()
            emotePlayer?.removeFromSuperview()
            let next = BearyEmoteView(key: key, animated: true)
            next.translatesAutoresizingMaskIntoConstraints = false
            row.insertArrangedSubview(next, at: 0)
            NSLayoutConstraint.activate([
                next.widthAnchor.constraint(equalToConstant: 24),
                next.heightAnchor.constraint(equalToConstant: 24),
            ])
            emotePlayer = next
        }
        self.applyChrome()
    }

    var player: BearyEmoteView? {
        return emotePlayer
    }

    func stopPlayer() {
        emotePlayer?.stop()
    }

    private func applyChrome() {
        backgroundColor = mineFlag ? BearyColors.hov : BearyColors.faint
        layer.borderColor = (mineFlag ? BearyColors.ink : BearyColors.line).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            self.applyChrome()
        }
    }
}

// MARK: - 虚线 + 钮：34px 圆圈、CAShapeLayer 虚线边框、灰色加号（网页 .emote-add 口径）

/// 首页原 BearyFeedDashedAddButton，合并时父类由 UIButton 换为
/// BearyHit44Button（视觉 34×34 不变，热区扩到 44）；虚线描边仍自带 trait 重刷。
final class BearyDiaryCardDashedAddButton: BearyHit44Button {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1
        dashedLayer.lineDashPattern = [4, 3]
        updateStrokeColor()
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStrokeColor() {
        dashedLayer.strokeColor = BearyColors.line.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColor()
    }
}

// MARK: - 日记卡片 cell（首页 F1–F13 ＋个人主页列表行合并体）

class BearyDiaryCardCell: UITableViewCell {

    let cardMode: BearyDiaryCardMode

    // MARK: 首页模式回调（cell 内直发 API，成功失败经此回传控制器）

    /// 点图片条时触发（传图片下标，控制器开图片查看器；不再进详情）。
    var onImageTapped: ((Int) -> Void)?
    /// 引用卡点按：data-pub=1 时传引用 id（控制器经容器走 gotoEntry 等价）。
    var onQuoteSelected: ((String) -> Void)?
    /// 引用卡点按：非 gone、data-pub!=1 时控制器弹 toast（本回调只转发）。
    var onQuoteNotPublic: (() -> Void)?
    /// 点赞/收藏成功后回传（控制器用 applyInteraction 同步模型并刷新该行）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?) -> Void)?
    /// 回应成功后回传聚合 emotes（控制器走现有 applyInteraction 只刷该行）。
    var onEmoteChanged: ((String, [EmoteCount]?) -> Void)?
    /// 回应行 + 号被点时转发（控制器弹出统一回应 Sheet）。
    var onEmoteAddRequested: (() -> Void)?
    var onRequireLogin: (() -> Void)?
    var onActionFailed: (() -> Void)?
    /// 回应失败后回传（控制器弹 toast；点赞/收藏失败仍走 onActionFailed 的 alert，不混用）。
    var onEmoteFailed: (() -> Void)?
    var onShareRequested: ((Entry) -> Void)?
    var onPublishTapped: (() -> Void)?
    var onPublishCancelTapped: (() -> Void)?
    /// 点头像或作者名：打开作者主页。
    var onAuthorTapped: (() -> Void)?
    /// C6 卡片上下文菜单：编辑/删除转发给控制器（容器接线到编辑器与删除确认流程）；
    /// 首页与个人主页两模式共用同一对回调（分享/收藏走 cell 内已有按钮路径）。
    var onContextMenuEdit: (() -> Void)?
    var onContextMenuDelete: (() -> Void)?
    /// 折叠切换 / 引用异步落位后，行高需重算时通知控制器 reloadRows（.none，无动画）。
    var onNeedsRowReload: (() -> Void)?
    /// L21（91 包）：仅展开/收起路径用——控制器改走 performBatchUpdates 平滑伸缩，
    /// 正文 0.22s 交叉淡入在 cell 内做；引用异步落位仍走 onNeedsRowReload。
    var onNeedsFoldAnimation: (() -> Void)?

    // MARK: 个人主页模式回调（cell 只转发，API 归控制器）

    var onLike: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onShare: (() -> Void)?
    var onEmoteTap: ((String) -> Void)?
    var onEmoteAdd: (() -> Void)?
    /// A1（个人主页模式）：非公开卡片点“+”时转发——控制器弹“公开后才能回应”
    /// toast，不打开选择器；chip 本身已禁用，点按无事件，故提示只能挂在“+”钮上。
    var onEmoteAddNotPublic: (() -> Void)?
    var onQuoteTap: (() -> Void)?
    var onFoldToggle: (() -> Void)?
    /// N7 主页图片灯箱：图片条点按回调（keys=本条图 key，index=点按位置），
    /// VC 侧复用独立文件内的 BearyEntryImageViewerViewController 全屏弹出（时间线同款）。
    var onTapImages: (([String], Int) -> Void)?

    /// 折叠展开态按条目持久化（首页模式；滚动复用、整表刷新都不收起），与网页 __foldOpen 同口径。
    static var expandedEntryIds: Set<String> = []
    /// 引用单篇缓存（首页模式 F11）：quoteId -> 拉到的整条 Entry；失败集合避免滚动时反复重拉；
    /// 下拉刷新时由 resetQuoteFetchState 清空，失败引用在刷新后可重试。
    static var quoteCache: [String: Entry] = [:]
    static var quoteFailedIds: Set<String> = []
    static var quoteLoadingIds: Set<String> = []

    static func resetQuoteFetchState() {
        quoteCache = [:]
        quoteFailedIds = []
        quoteLoadingIds = []
    }

    private var currentEntry: Entry?
    /// 就地同步用条目 id（首页 currentEntryIdValue 与个人主页 cellEntryId 合并为一处；
    /// 个人主页控制器以 cellEntryId 读取，故本属性为 internal，不再是原同文件 fileprivate）。
    var cellEntryId: String?
    private var currentImageKeys: [String] = []
    private var isExpanded = false
    private var isLikeBusy = false
    private var isBookmarkBusy = false
    /// 跟手批：按下已给过先行反馈（轻震/预取消赞），抬起确认时不再重播。
    private var likePressPreviewActive = false
    /// 点赞钮显式宽约束：见 updateLikeButton / applyLikeButtonState 的宽度算法。
    private var likeButtonWidthConstraint: NSLayoutConstraint?
    /// 折叠溢出判定缓存（首页模式 nil = 未测）：300 字以上且实测超 6 行才溢出。
    private var foldOverflow: Bool?
    /// 80 包 B12：折叠实测缓存（entryId + 宽度 + 字号 16 + 字数 + 文本哈希），跨复用
    /// 命中，文本/宽度变化即换键；超 200 条清库防无界增长。
    private var foldOverflowCache: [String: Bool] = [:]
    /// 回应行当前快照（按 count 降序；chip 点选按下标取 key；成功后由服务端聚合覆盖）。
    private var currentEmoteList: [EmoteCount] = []
    /// 个人主页模式 chip key 快照（与 currentEmoteList 同序，点选按下标取 key）。
    private var chipKeys: [String] = []
    /// 80 包 B4-1：回应胶囊池——chip 容器留池复用，只在 key 变化时换播放器。
    private var emoteChipPool: [BearyEmoteChipView] = []
    private var isEmoteBusy = false
    /// 回应先行反馈在途态（首页模式，点赞/收藏同款口径）：点选后 chip 行立即按
    /// 先行值重绘、API 在后台跑，成功对齐服务端值、失败回滚。旧 E3-3 pending
    /// 半透明视觉随先行反馈废止（先行 chip 全量显示，不再 0.6 置灰）。
    private var emoteFlightKey: String?
    private var emoteFlightAdded = false
    private var emoteFlightOriginal: [EmoteCount]?
    private var emoteFlightServerEmotes: [EmoteCount]?
    private var emoteFlightFailed = false
    private var emoteFlightUnauthorized = false
    private var emoteFlightAPIDone = false
    /// 摘下在途：退场动画播完前回包到达时先记结果、不抢动画中的 chip。
    private var emoteFlightRemovalStaged = false
    /// 表情 sheet 选中锁（首页模式）：选定后 140ms 内再选直接丢弃（网页 emotePickLock 同口径）。
    private var emotePickLocked = false
    /// 引用卡点按态：gone/locked 不动作；加载失败点按重试；其余按 isPublic 分流。
    private var quoteTapId: String?
    private var quoteTapIsPublic: Bool?
    private var quoteTapGoneOrLocked = false
    private var quoteTapLoadFailed = false
    private var emoteRowHeightConstraint: NSLayoutConstraint?
    private var rightStackTopConstraint: NSLayoutConstraint?
    /// L21（91 包，个人主页模式）：本卡正文是否超过 300 字（折叠按钮是否适用），
    /// configure 时记下，供 setFoldDisplay 就地切换显示用，不再每次重算。
    private var foldApplies = false
    /// 就地同步用已显示态（个人主页模式；configure 写入、syncInteraction 维护）：
    /// 点赞数、收藏态、回应行显示签名，供判等与失败复原用，不另建模型副本。
    private var cellLikedByMe = false
    private var cellLikeCount = 0
    private var cellBookmarkedByMe = false
    private var cellEmoteSignature = ""
    /// 个人主页模式互动禁用态（控制器 busy 集合现算后传入，渲染与同步共用）。
    private var profileDisabled = false
    private var authorTapInstalled = false

    // MARK: 左列头像（F4：无图时背后首字母圆透出；合并后两页同款容器 + 重试钮）

    private let avatarContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        return v
    }()

    private let avatarInitialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()

    private let avatarImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 20
        v.backgroundColor = BearyColors.line.withAlphaComponent(0)
        return v
    }()

    /// 头像失败重试钮（清单第 13 项）：放 avatarContainer 内（avatarImageView 的兄弟层，
    /// 不拦截作者点按手势；隐藏时不占交互），失败时亮、点按重载头像。
    private lazy var avatarRetryButton: BearyFeedRetryButton = {
        return bearyFeedRetryButton(target: self, action: #selector(feedRetryTapped(_:)))
    }()

    // MARK: 右列

    private let recipientIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_mail", pointSize: 13)
        v.tintColor = BearyColors.orange
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let recipientLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var recipientRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [recipientIconView, recipientLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = self.cardMode == .feed ? 5 : 4
        st.alignment = .center
        return st
    }()

    private let nameLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()

    private let badgeImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let crownImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        // I4：与编辑器口径统一——只走 crown 资产，缺失即隐藏，不留灰色 crown.fill 回退。
        if let crown = UIImage(named: "crown") {
            v.image = crown
        }
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private let weatherImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()

    private var moodEmoteView: BearyEmoteView?
    /// E3：落点行天气 Lottie 覆盖层（仅 gotoEntry 落点行创建；其他行恒为 nil，
    /// 天气标只显示底层 wx 静态图）。停播时摘层即回到静态图，不改静态图本身。
    private var weatherEmoteView: BearyEmoteView?

    private let moodLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var moodStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [moodLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = self.cardMode == .feed ? 3 : 4
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private lazy var titleStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameLabel, badgeImageView, crownImageView, titleSpacerLabel, timeLabel, weatherImageView, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        // 标题行对齐（Li 2026-10-27 定：两页统一按文字基线对齐）：feed 与
        // profile 均为 .firstBaseline（网页口径 display:flex;align-items:baseline，
        // 16.5 名与 14 时间、天气、心情按基线对齐）。
        st.alignment = .firstBaseline
        st.distribution = .fill
        return st
    }()

    /// 标题行弹性垫片：横向 hugging/compression 均为最低（1），独吞标题行全部
    /// 剩余宽度，使徽章/皇冠紧贴名字、日期留在右缘；空间不足时垫片先缩到 0，
    /// 再由名字（defaultLow）截断。空 UILabel 自带基线，不破坏 firstBaseline 对齐。
    private let titleSpacerLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    /// R4 App：日记标题行（非作者行 titleStack）。16.5pt 粗体，走
    /// BearyDynamicType.cardTitleFont()（scaledFont）+ adjustsFontForContentSizeCategory；
    /// 单行截断（与作者名行既有 1 行口径一致，不另发明文案）；空标题时
    /// isHidden，stack 不为其留高度、不留空行（见 updateEntryTitle）。
    private let entryTitleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        lb.lineBreakMode = .byTruncatingTail
        lb.isHidden = true
        return lb
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.diaryBodyFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        // P3-3：长串断行——超长无空格 token 按字符断行，不溢出；字号行高不动。
        lb.lineBreakMode = .byCharWrapping
        return lb
    }()

    private lazy var foldButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.tintColor = BearyColors.gray
        btn.setImage(BearyFeedIconCache.image(named: "icon_chevron_down", pointSize: 14), for: .normal)
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        btn.contentHorizontalAlignment = .left
        // 首页口径带内边距（4/2/4/2），个人主页口径无内边距，各保各的。
        if self.cardMode == .feed {
            btn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        }
        btn.isHidden = true
        btn.addTarget(self, action: #selector(foldButtonTapped), for: .touchUpInside)
        btn.bearyAddPressHaptic()
        return btn
    }()

    private let quoteView = BearyQuoteCardView()

    private let imagesScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private let imagesStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private lazy var likeButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.contentEdgeInsets = UIEdgeInsets.zero
        btn.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        btn.addTarget(self, action: #selector(likeButtonTapped), for: .touchUpInside)
        btn.addTarget(self, action: #selector(iconTouchDown(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(iconTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // 跟手批：按下即预览、抬起在外/滚动取消即复原（API 只在抬起确认时发）。
        btn.addTarget(self, action: #selector(likePressDown), for: .touchDown)
        btn.addTarget(self, action: #selector(likePressCancelled), for: [.touchUpOutside, .touchCancel])
        return btn
    }()

    private lazy var bookmarkButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(bookmarkButtonTapped), for: .touchUpInside)
        // W6：原 iconTouchDown 只缩 .84，改通用按压（缩 .84 + .light），点赞钮不动（已有 likePressDown）。
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var shareButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
        btn.tintColor = BearyColors.gray
        btn.addTarget(self, action: #selector(shareButtonTapped), for: .touchUpInside)
        // W6：同收藏钮，改通用按压（缩 .84 + .light）。
        btn.bearyAddPressFeedback()
        return btn
    }()

    // MARK: 回应行（网页 .emote-row 口径：chip + 行末 + 钮，自动换行；两页统一流式）

    private let emoteFlowView: BearyEmoteFlowView = {
        let v = BearyEmoteFlowView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// 首页模式 + 钮：虚线 34 圆圈（原 BearyFeedDashedAddButton，父类已换 Hit44）。
    private var feedAddButton: BearyDiaryCardDashedAddButton?
    /// 个人主页模式 + 钮：与首页同款虚线 34 圆圈（原实心 32 圆钮已随本修统一删除）。
    private var profileAddButton: BearyDiaryCardDashedAddButton?

    /// D2：公开行视图（首页模式；网页 pubActionInnerHtml 口径；渲染见 refreshPubRow）。
    private let pubCountdownLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private lazy var publishButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        btn.setTitle("公开", for: .normal)
        btn.setTitleColor(BearyColors.ink, for: .normal)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // 网页 .obtn 口径：高 44、圆角 22（Q1 按钮高/pill 圆角统一；此前高 40、圆角 20）。
        btn.layer.cornerRadius = 22
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        btn.layer.borderWidth = 1
        btn.layer.borderColor = BearyColors.line.cgColor
        btn.addTarget(self, action: #selector(publishTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var publishCancelButton: UIButton = {
        let btn = BearyHit44Button(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        btn.setTitle("取消", for: .normal)
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        btn.addTarget(self, action: #selector(publishCancelTapped), for: .touchUpInside)
        btn.bearyAddPressFeedback()
        return btn
    }()

    private lazy var pubStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [pubCountdownLabel, publishButton, publishCancelButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private lazy var actionStack: BearyActionStackView = {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let st = BearyActionStackView(arrangedSubviews: [likeButton, spacer, bookmarkButton, shareButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 16
        st.alignment = .center
        return st
    }()

    private lazy var rightStack: UIStackView = {
        quoteView.translatesAutoresizingMaskIntoConstraints = false
        let st = UIStackView(arrangedSubviews: [recipientRow, titleStack, entryTitleLabel, contentLabel, foldButton, quoteView, imagesScrollView, actionStack, emoteFlowView])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        // 首页口径 spacing 0 + 逐行 customSpacing；个人主页口径 spacing 10 + 部分 customSpacing。
        st.spacing = self.cardMode == .feed ? 0 : 10
        return st
    }()

    private let separatorView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    private var imageHeightConstraint: NSLayoutConstraint?
    private var separatorTopGap: CGFloat {
        // 底线距右列：首页 12（右列底 -14 减线高 2）、个人主页 14，各保各的。
        return cardMode == .feed ? 12 : 14
    }

    /// 94 包：图片槽位复用——9 只槽位在 init 时一次建好挂进 imagesStack
    /// （条目图片上限 9 张），configure 只改图/宽/显隐，prepareForReuse
    /// 只取消在途加载并隐藏，不再每次销毁重建 UIImageView。合并后首页也走
    /// 槽位（原首页每 configure 新建一批视图）；每槽位带 Feed 口径重试钮
    /// （个人主页原槽位无重试，合并后补齐，池化保留）。
    private var imageSlots: [UIImageView] = []
    private var imageSlotWidthConstraints: [NSLayoutConstraint] = []
    private var imageSlotRetryButtons: [BearyFeedRetryButton] = []

    private func makeImageSlots() {
        guard imageSlots.isEmpty else { return }
        for index in 0..<9 {
            let slot = UIImageView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            // 槽底色各保各的：首页 line、个人主页 faint。
            slot.backgroundColor = cardMode == .feed ? BearyColors.line : BearyColors.faint
            slot.contentMode = .scaleAspectFill
            slot.clipsToBounds = true
            slot.layer.cornerRadius = 12
            slot.isUserInteractionEnabled = true
            slot.tag = index
            slot.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            slot.isHidden = true
            imagesStack.addArrangedSubview(slot)
            let widthConstraint = slot.widthAnchor.constraint(equalToConstant: 280)
            imageSlotWidthConstraints.append(widthConstraint)
            NSLayoutConstraint.activate([
                widthConstraint,
                slot.heightAnchor.constraint(equalToConstant: 216),
            ])
            let retry = bearyFeedRetryButton(target: self, action: #selector(feedRetryTapped(_:)))
            slot.addSubview(retry)
            NSLayoutConstraint.activate([
                retry.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                retry.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                retry.widthAnchor.constraint(equalToConstant: 28),
                retry.heightAnchor.constraint(equalToConstant: 28),
            ])
            imageSlotRetryButtons.append(retry)
            imageSlots.append(slot)
        }
    }

    init(style: UITableViewCell.CellStyle, reuseIdentifier: String?, mode: BearyDiaryCardMode) {
        self.cardMode = mode
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.build()
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        // 仅作兜底（两页 VC 一律走带 mode 的创建，不依赖本初始化）；
        // 默认 feed，与原 BearyFeedCell 的默认行为一致。
        self.cardMode = .feed
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        // 写给行字号各保各的：首页 12 粗体、个人主页 13 常规；文案同为“写给你的”。
        recipientLabel.font = cardMode == .feed ? UIFont.boldSystemFont(ofSize: 12) : UIFont.systemFont(ofSize: 13)
        recipientLabel.text = "写给你的"
        // 首页皇冠带网页 drop-shadow（0 1px 1px 黑 30%），个人主页无阴影。
        if cardMode == .feed {
            crownImageView.layer.shadowColor = UIColor.black.cgColor
            crownImageView.layer.shadowOpacity = 0.30
            crownImageView.layer.shadowOffset = CGSize(width: 0, height: 1)
            crownImageView.layer.shadowRadius = 1
        }
        // 引用卡点按分流：首页 gone/locked 不动作、加载失败重试、公开/未公开分流；
        // 个人主页 gone 卡也透传（allowGoneTap），控制器弹提示。
        quoteView.allowGoneTap = (cardMode == .profile)
        quoteView.onTapped = { [weak self] in self?.quoteViewTapped() }
        quoteView.onRetryTapped = { [weak self] in self?.retryQuoteFetch() }
        avatarContainer.addSubview(avatarInitialLabel)
        avatarContainer.addSubview(avatarImageView)
        avatarContainer.addSubview(avatarRetryButton)
        contentView.addSubview(avatarContainer)
        contentView.addSubview(rightStack)
        imagesScrollView.addSubview(imagesStack)
        contentView.addSubview(separatorView)
        // C6 卡片上下文菜单：UIContextMenuInteraction 挂 contentView（原位浮起
        // 整卡预览 + 系统毛玻璃 UIMenu），取代 Q9 长按手势 + actionSheet；
        // 按钮/图片/引用/头像上的长按排除见文件末尾 contextMenuInteraction 代理
        // （头像/名字排除仅首页模式，个人主页模式各保各的，与旧口径一致）。
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
        // D2（首页/个人主页模式）：公开行插在点赞钮与 spacer 之间
        // （网页操作行：likeBtn + pubAction + spacer + bmBtn + shBtn）。
        if cardMode == .feed || cardMode == .profile {
            actionStack.insertArrangedSubview(pubStack, at: 1)
        }
        // F1（首页模式）：正文点击不导航——正文 label 自带空点按手势，把点按截住，
        // 使其不到达 tableView 的 didSelectRowAt（行其余区域点按仍进详情）。
        if cardMode == .feed {
            contentLabel.isUserInteractionEnabled = true
            contentLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(contentTapped)))
        }
        makeImageSlots()
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        badgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        weatherImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let imageHeight = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = imageHeight
        let likeWidth = likeButton.widthAnchor.constraint(equalToConstant: 22)
        likeWidth.isActive = true
        likeButtonWidthConstraint = likeWidth
        let emoteHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteRowHeightConstraint = emoteHeight
        let rightTop = rightStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)
        rightStackTopConstraint = rightTop
        var extraConstraints: [NSLayoutConstraint] = []
        if cardMode == .profile {
            // 个人主页口径：点赞高 22、收藏/分享 21×21（原 required 约束）。
            extraConstraints.append(likeButton.heightAnchor.constraint(equalToConstant: 22))
            extraConstraints.append(bookmarkButton.widthAnchor.constraint(equalToConstant: 21))
            extraConstraints.append(bookmarkButton.heightAnchor.constraint(equalToConstant: 21))
            extraConstraints.append(shareButton.widthAnchor.constraint(equalToConstant: 21))
            extraConstraints.append(shareButton.heightAnchor.constraint(equalToConstant: 21))
            extraConstraints.append(recipientIconView.widthAnchor.constraint(equalToConstant: 13))
            extraConstraints.append(recipientIconView.heightAnchor.constraint(equalToConstant: 13))
            extraConstraints.append(badgeImageView.widthAnchor.constraint(equalToConstant: 17))
            extraConstraints.append(badgeImageView.heightAnchor.constraint(equalToConstant: 17))
            extraConstraints.append(crownImageView.widthAnchor.constraint(equalToConstant: 19))
            extraConstraints.append(crownImageView.heightAnchor.constraint(equalToConstant: 19))
            extraConstraints.append(weatherImageView.widthAnchor.constraint(equalToConstant: 15))
            extraConstraints.append(weatherImageView.heightAnchor.constraint(equalToConstant: 15))
        } else {
            // 首页口径：收藏/分享带 2pt 内边距、无尺寸约束；标题行内可隐藏子视图
            // 的固定尺寸用 999 优先级，避免与 stack 的零尺寸约束冲突出警告。
            bookmarkButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            shareButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            let recipientIconHeight = recipientIconView.heightAnchor.constraint(equalToConstant: 13)
            recipientIconHeight.priority = UILayoutPriority(999)
            let badgeWidth = badgeImageView.widthAnchor.constraint(equalToConstant: 17)
            badgeWidth.priority = UILayoutPriority(999)
            let crownWidth = crownImageView.widthAnchor.constraint(equalToConstant: 19)
            crownWidth.priority = UILayoutPriority(999)
            let weatherWidth = weatherImageView.widthAnchor.constraint(equalToConstant: 15)
            weatherWidth.priority = UILayoutPriority(999)
            extraConstraints.append(recipientIconView.widthAnchor.constraint(equalToConstant: 13))
            extraConstraints.append(recipientIconHeight)
            extraConstraints.append(badgeWidth)
            extraConstraints.append(badgeImageView.heightAnchor.constraint(equalToConstant: 17))
            extraConstraints.append(crownWidth)
            extraConstraints.append(crownImageView.heightAnchor.constraint(equalToConstant: 19))
            extraConstraints.append(weatherWidth)
            extraConstraints.append(weatherImageView.heightAnchor.constraint(equalToConstant: 15))
        }
        NSLayoutConstraint.activate([
            avatarContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            avatarContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarContainer.widthAnchor.constraint(equalToConstant: 40),
            avatarContainer.heightAnchor.constraint(equalToConstant: 40),
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarImageView.topAnchor.constraint(equalTo: avatarContainer.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarContainer.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarContainer.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarContainer.bottomAnchor),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            rightTop,
            rightStack.leadingAnchor.constraint(equalTo: avatarContainer.trailingAnchor, constant: 12),
            rightStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            imageHeight,
            emoteHeight,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
            separatorView.topAnchor.constraint(equalTo: rightStack.bottomAnchor, constant: separatorTopGap),
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 2),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ] + extraConstraints)
        // imagesScrollView 的高度只由 imageHeightConstraint 驱动（216 有图 / 0 无图）。
        imageHeight.isActive = true
    }

    /// 正文点按（首页模式）：有意不做任何事（不导航、不折叠，折叠只走折叠钮）。
    @objc private func contentTapped() {
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 回应行高随 flow 实测走（两模式）；折叠判定以实测行宽为准，初次
        // configure 时 cell 宽可能尚未落位（用屏宽估算），布局落位后若溢出
        // 结论变了，在此纠正一次（结论稳定后不再变动，不会往复）。
        updateEmoteRowHeight()
        guard cardMode == .feed else { return }
        if currentEntry != nil, contentLabel.bounds.width > 0 {
            let overflow = measuredFoldOverflow(contentWidth: contentLabel.bounds.width)
            if overflow != foldOverflow {
                foldOverflow = overflow
                applyFoldVisibility(overflow: overflow)
                updateRightStackSpacing()
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 首页模式：心情与公开行边框需重刷（chip 边框已由 BearyEmoteChipView
        // 自带 trait 重刷，此处不再调 renderEmotes——两套并存已摘掉一套）。
        guard cardMode == .feed else { return }
        if currentEntry == nil { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodView()
            refreshPubRow()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onImageTapped = nil
        onQuoteSelected = nil
        onQuoteNotPublic = nil
        onInteractionChanged = nil
        onEmoteChanged = nil
        onEmoteAddRequested = nil
        onRequireLogin = nil
        onActionFailed = nil
        onShareRequested = nil
        onPublishTapped = nil
        onPublishCancelTapped = nil
        onAuthorTapped = nil
        onNeedsRowReload = nil
        onNeedsFoldAnimation = nil
        onContextMenuEdit = nil
        onContextMenuDelete = nil
        onLike = nil
        onBookmark = nil
        onShare = nil
        onEmoteTap = nil
        onEmoteAdd = nil
        onEmoteAddNotPublic = nil
        onQuoteTap = nil
        onFoldToggle = nil
        onTapImages = nil
        currentEntry = nil
        cellEntryId = nil
        currentImageKeys = []
        isExpanded = false
        isLikeBusy = false
        isBookmarkBusy = false
        likePressPreviewActive = false
        foldOverflow = nil
        foldApplies = false
        cellLikedByMe = false
        cellLikeCount = 0
        cellBookmarkedByMe = false
        cellEmoteSignature = ""
        profileDisabled = false
        // 80 包 A4：错峰改 cell.alpha/transform，对称复位。
        alpha = 1
        transform = .identity
        // 80 包 B4-1：池 chip 离树时先停其播放器，复用分支按 key 决定重播或重建。
        // 圆角长方形根治：chip-out 会把摘下 chip 缩到 0.5 后留池，复用时若不复位
        // transform，flow 按帧设 frame 会使 bounds 翻倍、固定 16 圆角显示成 8、
        // 内容缩半——截图第三只 chip 即此状；此处与 renderEmotes 复用处双重复位。
        for chip in emoteChipPool {
            chip.stopPlayer()
            chip.transform = .identity
            chip.alpha = 1
        }
        currentEmoteList = []
        chipKeys = []
        isEmoteBusy = false
        emoteFlightKey = nil
        emoteFlightAdded = false
        emoteFlightOriginal = nil
        emoteFlightServerEmotes = nil
        emoteFlightFailed = false
        emoteFlightUnauthorized = false
        emoteFlightAPIDone = false
        emoteFlightRemovalStaged = false
        emotePickLocked = false
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        emoteRowHeightConstraint?.constant = 0
        likeButton.setTitle(nil, for: .normal)
        pubStack.isHidden = true
        likeButtonWidthConstraint?.constant = 22
        likeButton.isEnabled = true
        bookmarkButton.isEnabled = true
        likeButton.imageView?.transform = .identity
        bookmarkButton.imageView?.transform = .identity
        avatarImageView.bearySetImage(url: nil, placeholder: nil)
        avatarInitialLabel.text = nil
        avatarRetryButton.isHidden = true
        avatarRetryButton.retryURL = nil
        recipientRow.isHidden = true
        recipientLabel.text = nil
        // 94 包：槽位复用——只取消在途加载并隐藏，不摘不销毁；重试钮同步隐藏。
        for (slotIndex, slot) in imageSlots.enumerated() {
            slot.bearySetImage(url: nil)
            slot.isHidden = true
            if slotIndex < imageSlotRetryButtons.count {
                imageSlotRetryButtons[slotIndex].isHidden = true
                imageSlotRetryButtons[slotIndex].retryURL = nil
            }
        }
        imagesScrollView.isHidden = true
        imageHeightConstraint?.constant = 0
        nameLabel.text = nil
        timeLabel.text = nil
        entryTitleLabel.text = nil
        entryTitleLabel.isHidden = true
        contentLabel.attributedText = nil
        contentLabel.text = nil
        foldButton.isHidden = true
        quoteView.clear()
        quoteView.isHidden = true
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        crownImageView.isHidden = true
        stopWeatherLottie()
        weatherImageView.image = nil
        weatherImageView.isHidden = true
        moodStack.isHidden = true
        moodEmoteView?.removeFromSuperview()
        moodEmoteView = nil
        moodLabel.text = nil
    }

    // MARK: - 文案与样式 helpers

    /// F3：时间一律 M月d日 H:mm（小时不补零，网页 fmtDate 口径；今天也不只显示 H:mm）。
    /// 80 包 B4-1：时间 formatter 静态复用（主线程 UI 路径使用，原每次调用新建）。
    private static let diaryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 H:mm"
        return f
    }()

    static func feedTimeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return diaryTimeFormatter.string(from: date)
    }

    /// F2：正文 16pt（首页）、行高 1.6（段落样式实现，非默认行高）。
    private func attributedBody(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        // P3-3：富文本段落样式会覆盖 label 的 lineBreakMode，此处同步按字符断行（字号行高不动）。
        paragraph.lineBreakMode = .byCharWrapping
        // C8 + R8 卡片内部分：正文字号一律走 scaledFont（feed 16 / profile 15，
        // 默认档点数不变，profile 15 此前未缩放、本批补齐）；contentLabel 侧
        // 已置 adjustsFontForContentSizeCategory，富文本字号在下次 configure
        // 时重解（C8 已知局限，本批不改）；装饰性小字不动。
        let bodyFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: fontSize))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: BearyColors.ink,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// R4 App：日记标题渲染（两路 configure 共用，模型 Entry.title 由 A4-App
    /// 已透传，本处只做渲染、不加模型字段）。空白/缺失标题时 text 清空且
    /// isHidden，stack 不留空行、不预留高度；卡片高度随内容。
    private func updateEntryTitle(_ rawTitle: String?) {
        let trimmed = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            entryTitleLabel.text = nil
            entryTitleLabel.isHidden = true
        } else {
            entryTitleLabel.text = trimmed
            entryTitleLabel.isHidden = false
        }
    }

    /// R9 A 卡片部分：只补无障碍标签，不改视觉与热区。点赞含状态与计数
    /// （“点赞，12”/“已点赞，12”，feed 0 赞亦为“点赞，0”）；收藏含状态
    /// （“收藏”/“已收藏”）；分享为功能标签“分享”。来源按模式取：feed 走
    /// currentEntry，profile 走 cellLikedByMe/cellLikeCount/cellBookmarkedByMe；
    /// profile 就地同步时 applyLike 与 applyProfileBookmark 先后各调一次，
    /// 末次调用时三项均为最新值。
    private func refreshActionAccessibility() {
        let liked: Bool
        let likeCount: Int
        let bookmarked: Bool
        if cardMode == .profile {
            liked = cellLikedByMe
            likeCount = cellLikeCount
            bookmarked = cellBookmarkedByMe
        } else {
            liked = currentEntry?.likedByMe ?? false
            likeCount = currentEntry?.likeCount ?? 0
            bookmarked = currentEntry?.bookmarkedByMe ?? false
        }
        likeButton.accessibilityLabel = "\(liked ? "已点赞" : "点赞")，\(likeCount)"
        bookmarkButton.accessibilityLabel = bookmarked ? "已收藏" : "收藏"
        shareButton.accessibilityLabel = "分享"
    }

    /// 网页口径：authorName = author_name || 'teddy'（空名时名显 teddy、头像字母为 T；
    /// 有名字时两者一致，此差异只在空名时出现）。个人主页口径空名 fallback 为“beary 用户”。
    private func displayAuthorName(_ rawName: String?) -> String {
        if let rawName = rawName, !rawName.isEmpty {
            return rawName
        }
        return cardMode == .feed ? "teddy" : "beary 用户"
    }

    /// F5：216 高按宽高比定宽（网页 stripW 同口径：0.55–2.22 倍高夹取，无尺寸老图默认 280）。
    private func stripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    private func updateRightStackSpacing() {
        if cardMode == .feed {
            // 写给行上边距 1：右列顶距 22，写给行可见时改为 23（其余行不变）。
            rightStackTopConstraint?.constant = recipientRow.isHidden ? 22 : 23
            rightStack.setCustomSpacing(3, after: recipientRow)
            rightStack.setCustomSpacing(4, after: titleStack)
            // R4 App：作者行→标题 4、标题→正文 4，均与原作者行→正文 4 一致；
            // 标题隐藏时其后间距置 0（无论 stack 按前一可见项还是按累计算间距，
            // 作者行→正文均为上行 4，不留空行高度）。
            rightStack.setCustomSpacing(entryTitleLabel.isHidden ? 0 : 4, after: entryTitleLabel)
            rightStack.setCustomSpacing(foldButton.isHidden ? 10 : 6, after: contentLabel)
            rightStack.setCustomSpacing(10, after: foldButton)
            rightStack.setCustomSpacing(10, after: quoteView)
            rightStack.setCustomSpacing(10, after: imagesScrollView)
            rightStack.setCustomSpacing(10, after: actionStack)
        } else {
            rightStackTopConstraint?.constant = 14
            rightStack.setCustomSpacing(4, after: recipientRow)
            rightStack.setCustomSpacing(4, after: titleStack)
            // R4 App：同 feed，作者行→标题 4、标题→正文 4；标题隐藏时其后间距置 0，
            // 作者行→正文仍为 4。
            rightStack.setCustomSpacing(entryTitleLabel.isHidden ? 0 : 4, after: entryTitleLabel)
            rightStack.setCustomSpacing(6, after: contentLabel)
            rightStack.setCustomSpacing(0, after: foldButton)
        }
    }

    /// 右列内容宽：头像列 20 + 40 + 间距 12，右 20，共 92。
    private func rightColumnWidthEstimate() -> CGFloat {
        let cellWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        return max(0, cellWidth - 92)
    }

    /// F9：心情 = 灰字 + 熊图 20px；无心情时整行隐藏。深浅变体由播放器内部切换。
    private func refreshMoodView() {
        guard let moodKey = currentEntry?.mood, let moodName = BearyText.moodNames[moodKey] else {
            moodStack.isHidden = true
            moodLabel.text = nil
            moodEmoteView?.removeFromSuperview()
            moodEmoteView = nil
            return
        }
        moodStack.isHidden = false
        moodLabel.text = moodName
        setMoodEmote(key: moodKey)
    }

    /// 卡片心情位：key 不变时复用播放器（深浅由其内部切换），key 变了才重建，尺寸仍为 20（宽约束 999 与原口径一致）。
    private func setMoodEmote(key: String) {
        if let current = moodEmoteView, current.emoteKey == key {
            return
        }
        moodEmoteView?.removeFromSuperview()
        let emoteView = BearyEmoteView(key: key, animated: false)
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        moodStack.insertArrangedSubview(emoteView, at: 0)
        let width = emoteView.widthAnchor.constraint(equalToConstant: 20)
        width.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            width,
            emoteView.heightAnchor.constraint(equalToConstant: 20),
        ])
        moodEmoteView = emoteView
    }

    /// E3：天气 key → Lottie 资源 key（编辑器选择器同款映射，唯 night 对应 moon）。
    private static func weatherLottieKey(for weatherKey: String) -> String {
        weatherKey == "night" ? "moon" : weatherKey
    }

    /// E3：gotoEntry 落点行天气标播 Lottie。仅落点控制器在定位落定后调用；
    /// 其他行从不调用，天气标保持底层 wx 静态图。覆盖层贴在 weatherImageView
    /// 上（编辑器选择器同款 BearyEmoteView + LottieWeather 资源；深浅切换与
    /// 减动效静态帧均由播放器内部口径处理，解析中/失败时回退 wx 静态图）。
    /// 已有同 key 覆盖层时只重播，不重建，避免落点重复调用时从头闪一下。
    func playWeatherLottie() {
        guard let weatherKey = currentEntry?.weather, !weatherKey.isEmpty, weatherImageView.isHidden == false else { return }
        if let current = weatherEmoteView, current.emoteKey == Self.weatherLottieKey(for: weatherKey) {
            current.play()
            return
        }
        stopWeatherLottie()
        let emoteView = BearyEmoteView(key: Self.weatherLottieKey(for: weatherKey), animated: true, fallbackImage: weatherImageView.image)
        emoteView.isUserInteractionEnabled = false
        emoteView.translatesAutoresizingMaskIntoConstraints = false
        weatherImageView.addSubview(emoteView)
        NSLayoutConstraint.activate([
            emoteView.leadingAnchor.constraint(equalTo: weatherImageView.leadingAnchor),
            emoteView.trailingAnchor.constraint(equalTo: weatherImageView.trailingAnchor),
            emoteView.topAnchor.constraint(equalTo: weatherImageView.topAnchor),
            emoteView.bottomAnchor.constraint(equalTo: weatherImageView.bottomAnchor),
        ])
        weatherEmoteView = emoteView
    }

    /// E3：停播落点天气 Lottie 并摘掉覆盖层，底层 wx 静态图即恢复。
    /// 复用、重配、滑出可视区（播放器离窗自停 + 复用/重配摘层）与新落点
    /// 盖掉旧落点时均走此路，不留错播与空转。
    func stopWeatherLottie() {
        weatherEmoteView?.stop()
        weatherEmoteView?.removeFromSuperview()
        weatherEmoteView = nil
    }

    @objc private func authorTapped() {
        onAuthorTapped?()
    }

    /// C6 上下文菜单：分享/收藏动作复用本 cell 已有的按钮路径
    /// shareButtonTapped/bookmarkButtonTapped（其内已按 cardMode 分流：
    /// 首页模式走 cell 内 API，个人主页模式走控制器回调），不新增服务端接口；
    /// 编辑/删除走 onContextMenuEdit/onContextMenuDelete。
    func shareFromCardMenu() {
        shareButtonTapped()
    }

    func bookmarkFromCardMenu() {
        bookmarkButtonTapped()
    }

    /// C6 菜单编辑资格：本人 + 私密 + 未过编辑期；Feed/Profile 载荷未必带
    /// editDeadline，缺失时仍出编辑项、由编辑器侧“已超过 15 分钟编辑期”拦截
    /// （与时间线滑动编辑“缺失即锁”的口径不同，见 PR 说明）。
    private func isCardMenuEditAvailable(entry: Entry) -> Bool {
        guard entry.isMine == true, entry.isPublic != true else { return false }
        if let deadline = entry.editDeadline {
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            return nowMs < deadline
        }
        return true
    }

    // MARK: - configure（首页模式）

    func configure(with entry: Entry) {
        stopWeatherLottie()
        currentEntry = entry
        cellEntryId = entry.id
        if let entryIdValue = entry.id {
            isExpanded = BearyDiaryCardCell.expandedEntryIds.contains(entryIdValue)
        } else {
            isExpanded = false
        }

        // F4：头像。无 URL 时 imageView 为空、背后首字母圆透出；有 URL 时照片盖住首字母。
        // 失败时 avatarRetryButton 亮重试图标（无 URL 不算失败，不亮）。
        let authorNameValue = displayAuthorName(entry.authorName)
        avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        if !authorTapInstalled {
            authorTapInstalled = true
            avatarImageView.isUserInteractionEnabled = true
            nameLabel.isUserInteractionEnabled = true
            avatarImageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
            nameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }
        bearyFeedLoadImage(into: avatarImageView, url: BearyImageURLs.avatarURL(entry.authorAvatar), retryButton: avatarRetryButton, downsampleToWidth: 40 * UIScreen.main.scale)

        // F12：写给标签只在当前用户就是收件人时显示“写给你的”（网页 renderPublic 同口径）；
        // 作者视角“写给 X”分支已删除——公开卡上作者本人不显示该行。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
            recipientLabel.text = "写给你的"
        } else {
            recipientRow.isHidden = true
            recipientLabel.text = nil
        }

        // F2/F13：名 16.5 粗体 + BETA 徽章图。Plus 皇冠按网页复刻：authorPlus==1 时显示
        //（清单 14 的首页取消显示已被“按网页复刻”覆盖；BETA 徽章不动）。
        // 无残留空位：crownImageView 是 titleStack 的 arrangedSubview，隐藏后 stack 自动
        // 将其尺寸压为 0，间距只算在可见项之间；19pt 宽约束是 999 优先级，不与压零冲突。
        nameLabel.text = authorNameValue
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        crownImageView.isHidden = (entry.authorPlus ?? 0) != 1 || crownImageView.image == nil

        // F3：时间。
        timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: entry.createdAt ?? 0)

        // F10：天气图标 15px（icon_wx_<weatherKey>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty {
            if let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
                weatherImageView.image = weatherImage
                weatherImageView.isHidden = false
            } else {
                weatherImageView.image = nil
                weatherImageView.isHidden = true
            }
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
        }

        // F9：心情。
        refreshMoodView()

        // R4 App：日记标题在作者行（titleStack）与正文之间，空标题不占位。
        updateEntryTitle(entry.title)

        // F6：正文折叠。
        updateContentAndFold()

        // F11：引用 lite 卡（见 configureQuoteFeed）。
        configureQuoteFeed(for: entry)

        // F5：图片条 216 高、按宽高比定宽、圆角 12、间距 8、横向滚动（94 包槽位复用）。
        renderImages(keys: entry.images ?? [], dims: entry.imgDims)

        // F7/F8：点赞、收藏、分享（按钮状态见 updateLikeButton / updateBookmarkButton；
        // 互动门控见 updateActionInteractivity，与详情 isPublic == true 一致）。
        updateLikeButton()
        updateBookmarkButton()
        updateActionInteractivity()
        refreshPubRow()
        // 回应行：操作行下方、行上边距 10（见 updateRightStackSpacing）。
        renderEmotes()
        updateRightStackSpacing()
    }

    // MARK: - configure（个人主页模式）

    func configure(entry: Entry, isExpanded: Bool, interactionDisabled: Bool) {
        stopWeatherLottie()
        // 跟手批：记下本卡赞态，供按下预览与取消复原用（configure 是唯一写入点）。
        currentEntry = entry
        cellEntryId = entry.id
        cellLikedByMe = entry.likedByMe ?? false
        cellLikeCount = entry.likeCount ?? 0
        cellBookmarkedByMe = entry.bookmarkedByMe ?? false
        profileDisabled = interactionDisabled
        self.isExpanded = isExpanded
        let authorNameValue = entry.authorName ?? "beary 用户"
        nameLabel.text = authorNameValue
        if let createdMs = entry.createdAt, createdMs > 0 {
            timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdMs)
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let avatarURLValue = BearyImageURLs.avatarURL(avatarPath) {
            avatarInitialLabel.isHidden = true
            // 合并后补齐：头像失败也有 Feed 口径重试钮（原个人主页只走普通加载，无重试）。
            bearyFeedLoadImage(into: avatarImageView, url: avatarURLValue, retryButton: avatarRetryButton, downsampleToWidth: 40 * UIScreen.main.scale)
        } else {
            avatarImageView.bearySetImage(url: nil)
            avatarRetryButton.isHidden = true
            avatarRetryButton.retryURL = nil
            avatarInitialLabel.isHidden = false
            avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        }
        // 写给标记：仅收件人是当前用户时显示（网页 renderPublic 同口径）。
        if let recipientIdValue = entry.recipientId, let meIdValue = SessionManager.shared.currentUser?.id, recipientIdValue == meIdValue {
            recipientRow.isHidden = false
        } else {
            recipientRow.isHidden = true
        }
        // 作者徽章（BETA 等，照常显示）；Plus 皇冠按 authorPlus 显示
        // （1:1 复刻，推翻清单 14；authorPlus 为 Int，0/缺失 = 不显示）。
        if let badgeKey = entry.authorBadge, !badgeKey.isEmpty, let badgeImage = BearyBadgeImages.image(for: badgeKey) {
            badgeImageView.image = badgeImage
            badgeImageView.isHidden = false
        } else {
            badgeImageView.image = nil
            badgeImageView.isHidden = true
        }
        rowCrownHiddenUpdate(entry: entry)
        // 天气图标（icon_wx_<key>，取不到图时隐藏、不留空）。
        if let weatherKey = entry.weather, !weatherKey.isEmpty, let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
            weatherImageView.image = weatherImage
            weatherImageView.isHidden = false
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
        }
        // 心情标签（表情 20 + 心情名；深浅变体由播放器内部切换）。
        if let moodKey = entry.mood, !moodKey.isEmpty, let moodName = BearyText.moodNames[moodKey] {
            setMoodEmote(key: moodKey)
            moodLabel.text = moodName
            moodStack.isHidden = false
        } else {
            moodEmoteView?.removeFromSuperview()
            moodEmoteView = nil
            moodLabel.text = nil
            moodStack.isHidden = true
        }
        // R4 App：日记标题在作者行（titleStack）与正文之间，空标题不占位。
        updateEntryTitle(entry.title)
        // 正文 + 300 字折叠（网页 renderPublic foldLong 口径；折叠态收起 6 行）。
        let bodyText = entry.content ?? ""
        contentLabel.attributedText = attributedBody(bodyText, fontSize: 15)
        foldApplies = bodyText.count > 300
        foldButton.isHidden = !foldApplies
        if foldApplies {
            setFoldDisplay(expanded: isExpanded, animated: false)
        } else {
            contentLabel.numberOfLines = 0
        }
        configureQuoteProfile(entry: entry)
        // 图片条 216 高、按宽高比定宽（原 stripW 口径；94 包槽位复用 + 合并后补重试）。
        renderImages(keys: entry.images ?? [], dims: entry.imgDims)
        // 点赞 / 收藏 / 分享（已赞、已收藏为橙色；忙时整行互动禁用）。
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 0 赞隐藏数字位，只剩爱心；非 0 按实测字宽给足整段标题宽。
        applyLikeButtonState(liked: entry.likedByMe ?? false, count: entry.likeCount ?? 0)
        applyProfileBookmarkState(bookmarked: entry.bookmarkedByMe ?? false)
        likeButton.isEnabled = !interactionDisabled
        bookmarkButton.isEnabled = !interactionDisabled
        shareButton.isEnabled = !interactionDisabled
        let publicOK = entry.isPublic == true
        shareButton.isHidden = publicOK == false
        renderEmotes()
        updateRightStackSpacing()
    }

    private func rowCrownHiddenUpdate(entry: Entry) {
        // 个人主页原口径：authorPlus==0 即隐藏；合并后补 Feed 的资产缺失守卫
        // （资产缺失时不再留 19pt 空盒，资产在时行为一字不动）。
        crownImageView.isHidden = (entry.authorPlus ?? 0) == 0 || crownImageView.image == nil
    }

    // MARK: - 图片条（94 包槽位复用，两页同款；失败重试 Feed 口径）

    private func renderImages(keys: [String], dims: [String: [Int]]?) {
        currentImageKeys = keys
        if imageSlots.isEmpty { makeImageSlots() }
        if keys.isEmpty {
            imagesScrollView.isHidden = true
            imageHeightConstraint?.constant = 0
            for (slotIndex, slot) in imageSlots.enumerated() {
                slot.bearySetImage(url: nil)
                slot.isHidden = true
                if slotIndex < imageSlotRetryButtons.count {
                    imageSlotRetryButtons[slotIndex].isHidden = true
                    imageSlotRetryButtons[slotIndex].retryURL = nil
                }
            }
            return
        }
        imagesScrollView.isHidden = false
        imageHeightConstraint?.constant = 216
        for (imageIndex, imageKey) in keys.enumerated() {
            let slot = imageSlots[imageIndex]
            slot.tag = imageIndex
            let strip = stripWidth(forKey: imageKey, dims: dims, height: 216)
            bearyFeedLoadImage(into: slot, url: BearyImageURLs.imageURL(key: imageKey, thumb: true), retryButton: imageSlotRetryButtons[imageIndex], downsampleToWidth: strip * UIScreen.main.scale)
            imageSlotWidthConstraints[imageIndex].constant = strip
            slot.isHidden = false
        }
        for (slotIndex, slot) in imageSlots.dropFirst(keys.count).enumerated() {
            slot.bearySetImage(url: nil)
            slot.isHidden = true
            let retryIndex = keys.count + slotIndex
            if retryIndex < imageSlotRetryButtons.count {
                imageSlotRetryButtons[retryIndex].isHidden = true
                imageSlotRetryButtons[retryIndex].retryURL = nil
            }
        }
    }

    /// 图片重试（头像与图片条共用）：先藏图标再重载，成功保持隐藏、再失败重新亮起。
    @objc private func feedRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    // MARK: - 折叠（首页实测溢出 / 个人主页 300 字门槛，各保各的）

    /// F5：按行判定折叠——先过 300 字门槛（网页 renderPublic foldLong 同口径），
    /// 再实测行数：≤6 行摘按钮（网页 pruneFolds 同口径；网页 .txt-fold 10.5em ÷ 1.6 行高 ≈ 6 行）。
    /// 行高取实测（16pt × 1.6 段落样式），不硬编码 24，避免字体度量偏差。
    private func measuredFoldOverflow(contentWidth: CGFloat) -> Bool {
        let fullText = currentEntry?.content ?? ""
        if fullText.isEmpty || fullText.count <= 300 || contentWidth <= 0 { return false }
        let foldCacheKey = "\(currentEntry?.id ?? "")|\(Int(contentWidth.rounded()))|16|\(fullText.count)|\(fullText.hashValue)"
        if let cached = foldOverflowCache[foldCacheKey] { return cached }
        let full = attributedBody(fullText, fontSize: 16)
        let fullHeight = full.boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let singleHeight = attributedBody("X", fontSize: 16).boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        if singleHeight <= 0 { return false }
        let lines = Int(ceil(fullHeight / singleHeight - 0.01))
        let overflow = lines > 6
        if foldOverflowCache.count > 200 { foldOverflowCache.removeAll() }
        foldOverflowCache[foldCacheKey] = overflow
        return overflow
    }

    /// M7：折叠箭头与编辑器附加栏同口径——0.2s 旋转动画；变换未变时不播（复用/重渲染不闪）。
    /// 折叠正文无透明度动画是刻意选择（与网页一致），不补。
    private func animateFoldArrow(expanded: Bool) {
        let target = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
        guard foldButton.imageView?.transform != target else { return }
        if UIAccessibility.isReduceMotionEnabled {
            foldButton.imageView?.transform = target
        } else {
            UIView.animate(withDuration: 0.2) { self.foldButton.imageView?.transform = target }
        }
    }

    private func applyFoldVisibility(overflow: Bool) {
        contentLabel.numberOfLines = isExpanded ? 0 : (overflow ? 6 : 0)
        if overflow {
            foldButton.isHidden = false
            foldButton.setTitle(isExpanded ? "收起" : "展开全文", for: .normal)
            animateFoldArrow(expanded: isExpanded)
        } else {
            foldButton.isHidden = true
        }
    }

    private func updateContentAndFold() {
        let fullText = currentEntry?.content ?? ""
        contentLabel.attributedText = attributedBody(fullText, fontSize: 16)
        let width = contentLabel.bounds.width > 0 ? contentLabel.bounds.width : rightColumnWidthEstimate()
        let overflow = measuredFoldOverflow(contentWidth: width)
        foldOverflow = overflow
        applyFoldVisibility(overflow: overflow)
    }

    /// L21（91 包，个人主页模式）：展开/收起显示切换（标题/箭头/行数三件与 configure 原口径一致）。
    /// animated 时正文 0.22s 交叉淡入，行高由控制器 performBatchUpdates 平滑伸缩。
    func setFoldDisplay(expanded: Bool, animated: Bool) {
        guard foldApplies else { return }
        let apply = {
            self.foldButton.setTitle(expanded ? "收起" : "展开全文", for: .normal)
            self.foldButton.imageView?.transform = expanded ? CGAffineTransform(rotationAngle: CGFloat.pi) : .identity
            self.contentLabel.numberOfLines = expanded ? 0 : 6
        }
        if animated {
            UIView.transition(with: contentLabel, duration: 0.22, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }
    }

    @objc private func foldButtonTapped() {
        if cardMode == .profile {
            onFoldToggle?()
            return
        }
        // F6：展开/收起平滑切换（91 包 L21，已推翻即时切换定版）：正文 0.22s 交叉淡入，
        // 行高由控制器 performBatchUpdates 平滑伸缩；引用异步落位仍走 onNeedsRowReload。
        guard let entryIdValue = cellEntryId else { return }
        if isExpanded {
            BearyDiaryCardCell.expandedEntryIds.remove(entryIdValue)
            isExpanded = false
        } else {
            BearyDiaryCardCell.expandedEntryIds.insert(entryIdValue)
            isExpanded = true
        }
        UIView.transition(with: contentLabel, duration: 0.22, options: .transitionCrossDissolve, animations: {
            self.updateContentAndFold()
        })
        updateRightStackSpacing()
        onNeedsFoldAnimation?()
    }

    // MARK: - 引用 lite 卡（首页异步 / 个人主页同步，各保各的；视图共享）

    /// 引用卡统一落点（首页模式）。服务端 attachQuotes 直传 gone/locked（Quote 模型已解码，
    /// F3 收尾）；字段非空时优先用字段判定，缺失时回退 is_public + 正文启发式：
    /// locked 态 is_public=false 且无正文；gone 态无 is_public 且无正文；
    /// 本人未公开则有正文 + is_public=false。
    /// - gone：gone 态 → “引用的日记已删除”（点按无动作）；
    /// - locked：锁定态 → “引用了一篇尚未公开的日记”（点按无动作）；
    /// - 正文非空：正常卡；未公开（本人视角）时带“投递中”pill；
    /// - 正文空且无字段：沿用旧启发式（未公开→锁定文案，其余→已删文案）。
    /// 缩略图门控（网页 quoteThumbsHtml）：仅 quote.is_public 或宿主本人时出。
    private func presentQuoteCard(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int?, isPublic: Bool?, gone: Bool?, locked: Bool?, quoteId: String?, hostIsMine: Bool) {
        quoteTapId = quoteId
        quoteTapIsPublic = isPublic
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        if gone == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            quoteView.isHidden = false
            return
        }
        if locked == true {
            quoteTapGoneOrLocked = true
            quoteView.showGone(message: "引用了一篇尚未公开的日记", iconName: "icon_lock")
            quoteView.isHidden = false
            return
        }
        if content.isEmpty {
            quoteTapGoneOrLocked = true
            if isPublic == false {
                quoteView.showGone(message: "引用了一篇尚未公开的日记", iconName: "icon_lock")
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            }
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: authorName,
            authorAvatar: authorAvatar,
            content: content,
            images: images,
            dims: dims,
            createdAt: createdAt,
            showDeliveringPill: isPublic == false,
            allowThumbs: isPublic == true || hostIsMine
        )
        quoteView.isHidden = false
    }

    /// F2：引用卡点按分流。首页模式（网页全局委托同口径）：gone/locked 不动作；
    /// 加载失败点按重试；data-pub=1 走容器 gotoEntry 等价；否则 toast。
    /// 个人主页模式：正常与 gone 卡都透传 onQuoteTap，控制器弹提示或打开目标。
    private func quoteViewTapped() {
        if cardMode == .profile {
            onQuoteTap?()
            return
        }
        if quoteTapGoneOrLocked { return }
        if quoteTapLoadFailed {
            retryQuoteFetch()
            return
        }
        guard let quoteIdValue = quoteTapId, !quoteIdValue.isEmpty else { return }
        if quoteTapIsPublic == true {
            onQuoteSelected?(quoteIdValue)
        } else {
            onQuoteNotPublic?()
        }
    }

    private func retryQuoteFetch() {
        guard let entryValue = currentEntry, let quoteIdValue = entryValue.quoteId, !quoteIdValue.isEmpty else { return }
        BearyDiaryCardCell.quoteFailedIds.remove(quoteIdValue)
        configureQuoteFeed(for: entryValue)
    }

    private func configureQuoteFeed(for entry: Entry) {
        quoteView.clear()
        quoteView.isHidden = true
        quoteTapId = nil
        quoteTapIsPublic = nil
        quoteTapGoneOrLocked = false
        quoteTapLoadFailed = false
        let hostIsMine = entry.isMine == true
        if let quoteValue = entry.quote {
            presentQuoteCard(
                authorName: displayAuthorName(quoteValue.authorName ?? entry.authorName),
                authorAvatar: quoteValue.authorAvatar ?? entry.authorAvatar,
                content: quoteValue.content ?? "",
                images: quoteValue.images ?? [],
                dims: quoteValue.imgDims,
                createdAt: quoteValue.createdAt,
                isPublic: quoteValue.isPublic,
                gone: quoteValue.gone,
                locked: quoteValue.locked,
                quoteId: quoteValue.id,
                hostIsMine: hostIsMine
            )
            return
        }
        guard let quoteIdValue = entry.quoteId, !quoteIdValue.isEmpty else { return }
        if let cachedEntry = BearyDiaryCardCell.quoteCache[quoteIdValue] {
            presentQuoteCard(
                authorName: displayAuthorName(cachedEntry.authorName),
                authorAvatar: cachedEntry.authorAvatar,
                content: cachedEntry.content ?? "",
                images: cachedEntry.images ?? [],
                dims: cachedEntry.imgDims,
                createdAt: cachedEntry.createdAt,
                isPublic: cachedEntry.isPublic,
                gone: nil,
                locked: nil,
                quoteId: quoteIdValue,
                hostIsMine: hostIsMine
            )
            return
        }
        // F3：拉取失败只记加载失败态，不再记“已删除”；卡片可点重试。
        if BearyDiaryCardCell.quoteFailedIds.contains(quoteIdValue) {
            quoteTapId = quoteIdValue
            quoteTapLoadFailed = true
            quoteView.showLoadFailed(message: "引用加载失败，重试")
            quoteView.isHidden = false
            return
        }
        if BearyDiaryCardCell.quoteLoadingIds.contains(quoteIdValue) { return }
        BearyDiaryCardCell.quoteLoadingIds.insert(quoteIdValue)
        let hostEntryIdValue = entry.id
        BearyAPI.shared.fetchEntry(id: quoteIdValue) { [weak self] result in
            DispatchQueue.main.async {
                BearyDiaryCardCell.quoteLoadingIds.remove(quoteIdValue)
                switch result {
                case .success(let fetchedEntry):
                    BearyDiaryCardCell.quoteCache[quoteIdValue] = fetchedEntry
                    guard let strongSelf = self, strongSelf.cellEntryId == hostEntryIdValue else { return }
                    strongSelf.presentQuoteCard(
                        authorName: strongSelf.displayAuthorName(fetchedEntry.authorName),
                        authorAvatar: fetchedEntry.authorAvatar,
                        content: fetchedEntry.content ?? "",
                        images: fetchedEntry.images ?? [],
                        dims: fetchedEntry.imgDims,
                        createdAt: fetchedEntry.createdAt,
                        isPublic: fetchedEntry.isPublic,
                        gone: nil,
                        locked: nil,
                        quoteId: quoteIdValue,
                        hostIsMine: hostIsMine
                    )
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                case .failure:
                    BearyDiaryCardCell.quoteFailedIds.insert(quoteIdValue)
                    guard let strongSelf = self, strongSelf.cellEntryId == hostEntryIdValue else { return }
                    strongSelf.quoteTapId = quoteIdValue
                    strongSelf.quoteTapLoadFailed = true
                    strongSelf.quoteView.showLoadFailed(message: "引用加载失败，重试")
                    strongSelf.quoteView.isHidden = false
                    strongSelf.updateRightStackSpacing()
                    strongSelf.onNeedsRowReload?()
                }
            }
        }
    }

    /// 引用卡（个人主页模式，同步）：服务端 Quote 模型无 gone/locked 字段，按返回形状推断
    /// （首页行同口径）：正文空 + 未公开 = 锁定；正文空 + 其他 = 已删除；正文非空 = 正常卡。
    /// 缩略图门控与网页 quoteThumbsHtml 同口径：公开或本人日记才出图。
    /// 正常卡不带“投递中”pill（个人主页原口径）；gone 卡点按透传控制器（allowGoneTap）。
    private func configureQuoteProfile(entry: Entry) {
        quoteView.clear()
        guard let quoteValue = entry.quote else {
            if let quoteId = entry.quoteId, !quoteId.isEmpty {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
                quoteView.isHidden = false
            } else {
                quoteView.isHidden = true
            }
            return
        }
        let quoteContent = quoteValue.content ?? ""
        if quoteContent.isEmpty {
            if quoteValue.isPublic == false {
                quoteView.showGone(message: "引用了一篇尚未公开的日记", iconName: "icon_lock")
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote")
            }
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: displayAuthorName(quoteValue.authorName),
            authorAvatar: quoteValue.authorAvatar,
            content: quoteContent,
            images: quoteValue.images ?? [],
            dims: quoteValue.imgDims,
            createdAt: quoteValue.createdAt,
            showDeliveringPill: false,
            allowThumbs: quoteValue.isPublic == true || entry.isMine == true
        )
        quoteView.isHidden = false
    }

    // MARK: - 点赞 / 收藏 / 公开行（两模式各保语义）

    private func updateLikeButton() {
        let liked = currentEntry?.likedByMe ?? false
        let countValue = currentEntry?.likeCount ?? 0
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22) ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        // 计数位宽度由显式约束定，不靠按钮固有宽：按钮固有宽不含标题边距，
        // 栈按固有宽给帧时标题框只剩边距差，数字会被裁成左半弧。
        // 网页口径：like-n 恒输出 like_count||0，0 赞也显示“0”（爱心 + 0）。
        let imageWidth = heartImage?.size.width ?? 22
        if countValue <= 0 {
            likeButton.setTitle("0", for: .normal)
            let zeroWidth = ceil(("0" as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + zeroWidth
        } else {
            let titleText = "\(countValue)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        // 网页口径：未赞时爱心描边跟随正文墨色（.like-btn 无基准色，即继承 ink），
        // 计数 span.like-n 才灰；点赞后爱心与计数同为橙。
        likeButton.tintColor = liked ? BearyColors.orange : BearyColors.ink
        likeButton.setTitleColor(liked ? BearyColors.orange : BearyColors.gray, for: .normal)
        likeButton.imageView?.transform = .identity
        refreshActionAccessibility()
    }

    /// 点赞钮渲染（个人主页模式；原 configure 内联块抽出，口径一字不动）：
    /// configure 与就地同步共用；同步侧先调它再播爆点，爆点不被 transform 复位打断。
    private func applyLikeButtonState(liked: Bool, count: Int) {
        let likedImageName = liked ? "icon_heart_fill" : "icon_heart"
        let likedImage = BearyFeedIconCache.image(named: likedImageName, pointSize: 22)
        likeButton.setImage(likedImage, for: .normal)
        let imageWidth = likedImage?.size.width ?? 22
        if count <= 0 {
            likeButton.setTitle(nil, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth
        } else {
            let titleText = "\(count)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        let likeColor = liked ? BearyColors.orange : BearyColors.gray
        likeButton.tintColor = likeColor
        likeButton.setTitleColor(likeColor, for: .normal)
        likeButton.imageView?.transform = .identity
        refreshActionAccessibility()
    }

    private func applyProfileBookmarkState(bookmarked: Bool) {
        let bookmarkImageName = bookmarked ? "icon_bookmark_fill" : "icon_bookmark"
        bookmarkButton.setImage(BearyFeedIconCache.image(named: bookmarkImageName, pointSize: 21), for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
        refreshActionAccessibility()
    }

    /// 取消点赞 pre-unlike（首页模式；网页 .pre-unlike 同款：心形缩 .8 + 填充先清），
    /// 失败由完成回调调 updateLikeButton 恢复。
    private func applyPreUnlike() {
        let outlineImage = BearyFeedIconCache.image(named: "icon_heart", pointSize: 22) ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(outlineImage, for: .normal)
        likeButton.tintColor = BearyColors.ink
        likeButton.setTitleColor(BearyColors.gray, for: .normal)
        BearyIconMotion.animateIconScale(on: likeButton, to: 0.8)
    }

    /// 取消赞预态（个人主页模式；首页 applyPreUnlike 同款，颜色按本页口径：未赞灰色）：
    /// 先换空心图 + 灰色 + 缩 .8，失败由控制器 reload 复原。
    private func applyCellPreUnlike() {
        likeButton.setImage(BearyFeedIconCache.image(named: "icon_heart", pointSize: 22), for: .normal)
        likeButton.tintColor = BearyColors.gray
        likeButton.setTitleColor(BearyColors.gray, for: .normal)
        BearyIconMotion.animateIconScale(on: likeButton, to: 0.8)
    }

    private func updateBookmarkButton() {
        let bookmarked = currentEntry?.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21) ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
        refreshActionAccessibility()
    }

    /// F7/F8（首页模式）：首页与详情互动门控统一为 isPublic == true 才可互动（详情同口径）。
    private func updateActionInteractivity() {
        let publicOK = currentEntry?.isPublic == true
        likeButton.isEnabled = publicOK && isLikeBusy == false
        bookmarkButton.isEnabled = publicOK && isBookmarkBusy == false
        likeButton.alpha = publicOK ? 1.0 : 0.4
        bookmarkButton.alpha = publicOK ? 1.0 : 0.4
        // 网页口径：shBtn 仅 is_public 时输出——非公开卡直接没有分享钮（不禁用占位）。
        shareButton.isHidden = publicOK == false
    }

    /// 拒绝动效（首页模式；网页 .deny shakeX .4s 同口径）：左右小幅抖动，reduced-motion 时跳过。
    private func playDenyShake(on button: UIButton) {
        // 拒绝震动不拿减动效门控：减动效只跳过视觉抖动，震动照常给。
        BearyHaptics.rejectionWarning()
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDenyShake")
    }

    /// D2：公开行渲染（首页/个人主页模式；网页 pubState / pubCountdownText 口径）。
    /// B 视觉文案：控制器 60 秒定时器对可见行调 refreshPublishRow 重算文案，
    /// 跨小时边界时“剩 N 小时”不再 stale；本函数自身仍是纯渲染，不持有定时器。
    func refreshPublishRow() {
        refreshPubRow()
    }
    private func refreshPubRow() {
        guard let entry = currentEntry, entry.isMine == true, entry.isPublic != true else {
            pubStack.isHidden = true
            return
        }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if let pend = entry.publishPendingUntil, pend > nowMs {
            let remainMs = pend - nowMs
            if remainMs >= 3600000 {
                pubCountdownLabel.text = "剩 \(Int(ceil(Double(remainMs) / 3600000.0))) 小时"
            } else {
                pubCountdownLabel.text = "剩不到 1 小时"
            }
            pubCountdownLabel.isHidden = false
            publishButton.isHidden = true
            publishCancelButton.isHidden = false
            publishButton.layer.borderColor = BearyColors.line.cgColor
            pubStack.isHidden = false
            return
        }
        if let publishAt = entry.publishAt, publishAt <= nowMs {
            pubCountdownLabel.isHidden = true
            publishButton.isHidden = false
            publishCancelButton.isHidden = true
            publishButton.layer.borderColor = BearyColors.line.cgColor
            pubStack.isHidden = false
            return
        }
        pubStack.isHidden = true
    }

    @objc private func publishTapped() {
        onPublishTapped?()
    }

    @objc private func publishCancelTapped() {
        onPublishCancelTapped?()
    }

    /// 互动就地同步（首页模式，卡顿批）：只改点赞/收藏/回应三处控件，不重建图片/
    /// 正文/引用、不重算行高。控制器同步（跨页回传）与自家回包共用：
    /// 与当前显示相等时跳过——自家回包不再打断正在播的点赞爆点与 chip-in；
    /// 回应先按已显示顺序合并回包（见 BearyEmoteOrder），再判等；
    /// 不可见行不调用（模型已由控制器改好，滑回显示时 configure 自然取新值）。
    func syncInteraction(entryId: String, likeCount: Int?, likedByMe: Bool?, bookmarkedByMe: Bool?, emotes: [EmoteCount]?) {
        guard cellEntryId == entryId else { return }
        var likeChanged = false
        if let v = likeCount, v != (currentEntry?.likeCount ?? 0) {
            currentEntry?.likeCount = v
            likeChanged = true
        }
        if let v = likedByMe, v != (currentEntry?.likedByMe ?? false) {
            currentEntry?.likedByMe = v
            likeChanged = true
        }
        if likeChanged { updateLikeButton() }
        var bookmarkChanged = false
        if let v = bookmarkedByMe, v != (currentEntry?.bookmarkedByMe ?? false) {
            currentEntry?.bookmarkedByMe = v
            bookmarkChanged = true
        }
        if bookmarkChanged { updateBookmarkButton() }
        if let server = emotes {
            let merged = BearyEmoteOrder.merged(previous: currentEntry?.emotes, server: server)
            if BearyEmoteOrder.signature(merged) != BearyEmoteOrder.signature(currentEntry?.emotes) {
                currentEntry?.emotes = merged
                renderEmotes()
            }
        }
    }

    /// 互动就地同步（个人主页模式，卡顿批）：只改点赞/收藏/回应三处与按钮启用态，
    /// 不重建图片/引用/正文、不重算行高。点赞/收藏恒按 entry 重绘
    /// （失败复原靠它把按下预览刷回原态）；回应只在显示签名变化时
    /// 重绘 chip 行（签名相等即跳过，避免无谓重启播放器）。
    /// 调用方保证先改模型再调本方法；行不可见时控制器不调（模型已改，
    /// 滑回显示时 configure 自然取新值）。
    func syncInteraction(entry: Entry, interactionDisabled: Bool, animatedEmoteLayout: Bool = false) {
        guard cellEntryId == entry.id else { return }
        currentEntry = entry
        cellLikedByMe = entry.likedByMe ?? false
        cellLikeCount = entry.likeCount ?? 0
        applyLikeButtonState(liked: cellLikedByMe, count: cellLikeCount)
        cellBookmarkedByMe = entry.bookmarkedByMe ?? false
        applyProfileBookmarkState(bookmarked: cellBookmarkedByMe)
        likeButton.isEnabled = !interactionDisabled
        bookmarkButton.isEnabled = !interactionDisabled
        shareButton.isEnabled = !interactionDisabled
        profileDisabled = interactionDisabled
        let candidate = BearyEmoteOrder.signature((entry.emotes ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }.filter { ($0.emote ?? "").isEmpty == false })
        if candidate != cellEmoteSignature {
            renderEmotes(animatedLayout: animatedEmoteLayout)
        } else {
            // A1：签名未变时就地同步也须走同一公开门控，否则会把
            // updateEmoteInteractivity 置灰/禁用的 chip 重新放行。
            updateEmoteInteractivity()
        }
    }

    /// 卡顿批：就地同步后直接对同 cell 补弹（不再 reload 换 cell）。
    func playBookmarkPop() {
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
    }

    /// 点赞成功爆点（Li 2026-10-27 新规格）：控制器回包就地同步后对同 cell 补播，
    /// 爱心回弹 + 液体爆点；取消点赞不调用。
    func playLikeBurst() {
        BearyIconMotion.playLikeBurst(on: likeButton)
    }

    // MARK: - 交互

    /// F1：点图进查看器（带下标）；正文点按已由 contentTapped 截住，不会走到行导航。
    /// 重试图标可见时点按只走重试，不进查看器（钮是槽位子视图，父层手势可能同收该点按）。
    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        if cardMode == .feed {
            if let iv = sender.view as? UIImageView,
               iv.subviews.contains(where: { ($0 as? BearyFeedRetryButton)?.isHidden == false }) {
                return
            }
            let index = sender.view?.tag ?? 0
            if index < 0 || index >= currentImageKeys.count { return }
            onImageTapped?(index)
            return
        }
        // N7 主页图片条点按：下标取自槽位 tag，keys 为 configure 存下的本条图 key；
        // 手势截获此次点按，行点按进详情（didSelectRowAt）不再触发（时间线／首页同款守卫）；
        // 卡片其他区域无手势，仍走 didSelectRowAt 进详情。
        let index = sender.view?.tag ?? 0
        guard index >= 0, index < currentImageKeys.count else { return }
        onTapImages?(currentImageKeys, index)
    }

    /// 按压反馈（两页同款 .84/.13s）。
    @objc private func iconTouchDown(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 0.84)
    }

    @objc private func iconTouchUp(_ sender: UIButton) {
        BearyIconMotion.animateIconScale(on: sender, to: 1)
    }

    /// 跟手批：按下即给先行反馈（轻震/预取消赞），手指的按压不等抬起；
    /// 首页模式守卫与 likeTapped 完全一致（公开、已登录、非忙碌、有 id），不满足不预览；
    /// 个人主页模式守卫为登录态（原口径）；API 仍只在抬起确认时发。
    @objc private func likePressDown() {
        if cardMode == .profile {
            guard SessionManager.shared.isLoggedIn else { return }
            if cellLikedByMe {
                applyCellPreUnlike()
            } else {
                // 描边已撤：按下只给轻震，按压缩放由 iconTouchDown 的 .84 给。
                BearyHaptics.likeTap()
            }
            likePressPreviewActive = true
            return
        }
        guard !isLikeBusy else { return }
        guard currentEntry?.isPublic == true else { return }
        guard SessionManager.shared.isLoggedIn else { return }
        guard let entryIdValue = cellEntryId, !entryIdValue.isEmpty else { return }
        if currentEntry?.likedByMe == true {
            applyPreUnlike()
        } else {
            // 描边已撤：按下只给轻震，按压缩放由 iconTouchDown 的 .84 给。
            BearyHaptics.likeTap()
        }
        likePressPreviewActive = true
    }

    /// 跟手批：抬起在外或滚动取消时复原按下预览（API 未发，状态一字未动）。
    @objc private func likePressCancelled() {
        guard likePressPreviewActive else { return }
        likePressPreviewActive = false
        if cardMode == .profile {
            if cellLikedByMe {
                likeButton.setImage(BearyFeedIconCache.image(named: "icon_heart_fill", pointSize: 22), for: .normal)
                likeButton.tintColor = BearyColors.orange
                likeButton.setTitleColor(BearyColors.orange, for: .normal)
            }
            likeButton.imageView?.transform = .identity
            return
        }
        guard !isLikeBusy else { return }
        updateLikeButton()
    }

    @objc private func likeButtonTapped() {
        if cardMode == .profile {
            // 按下没给过预览（极少数触摸直达抬起）才在这里补一次，避免与按下预览重复；
            // 预览本身不随抬起消失，留给控制器 API 回包后的同步复原。
            if likePressPreviewActive == false {
                likePressDown()
            }
            likePressPreviewActive = false
            onLike?()
            return
        }
        self.feedLikeTapped()
    }

    /// F8（首页模式）：点赞——Li 2026-10-27 定全量先行：抬起确认时立即填橙色、
    /// 计数 +1，不等服务端；回包后以服务端值为准对齐，成功补爆点（填充已先行，
    /// 不再重播填充淡入）；失败按原模型回滚 + 拒绝动效 + 通用提示。
    /// 取消点赞 pre-unlike 口径不变（只改视图，失败由回包复原）。
    private func feedLikeTapped() {
        // 按下已给过先行反馈时抬起不再重播（否则震动来两次）；
        // 守卫失败时把按下预览复原（按下与抬起之间状态几乎不可能变，纯防御）。
        let hadPressPreview = likePressPreviewActive
        likePressPreviewActive = false
        func restorePressPreview() {
            updateLikeButton()
        }
        guard let entryIdValue = cellEntryId, !entryIdValue.isEmpty else {
            if hadPressPreview { restorePressPreview() }
            return
        }
        if currentEntry?.isPublic != true {
            if hadPressPreview { restorePressPreview() }
            return
        }
        if SessionManager.shared.isLoggedIn == false {
            if hadPressPreview { restorePressPreview() }
            onRequireLogin?()
            return
        }
        if isLikeBusy {
            if hadPressPreview { restorePressPreview() }
            return
        }
        let currentlyLiked = currentEntry?.likedByMe ?? false
        let originalCount = currentEntry?.likeCount ?? 0
        if hadPressPreview == false {
            if currentlyLiked == false {
                BearyHaptics.likeTap()
            } else {
                applyPreUnlike()
            }
        }
        if currentlyLiked == false {
            // 点赞全量先行（Li 2026-10-27 定）：抬起确认时立即填橙色、计数 +1；
            // 模型同步改，updateLikeButton 按新模型渲染；回包成功对齐服务端值，
            // 失败按 originalCount / currentlyLiked 复原（见失败分支）。
            currentEntry?.likedByMe = true
            currentEntry?.likeCount = originalCount + 1
            updateLikeButton()
        }
        isLikeBusy = true
        // 方案一（Li 2026-10-28 定）：先行期间不禁用按钮，防重入只靠 isLikeBusy 守卫；
        // 若此处调 updateActionInteractivity，按钮禁用减淡会盖住刚写好的先行填色。
        BearyAPI.shared.toggleLike(id: entryIdValue, liked: currentlyLiked == false) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isLikeBusy = false
                BearyIconMotion.animateIconScale(on: strongSelf.likeButton, to: 1)
                strongSelf.updateActionInteractivity()
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? (currentlyLiked == false)
                    strongSelf.currentEntry?.likedByMe = newLiked
                    if let countValue = resp.count {
                        strongSelf.currentEntry?.likeCount = countValue
                    }
                    strongSelf.updateLikeButton()
                    if newLiked {
                        // 服务端确认的那一刻：爱心回弹 + 液体爆点；填充与计数已先行，
                        // 不再重播填充淡入（否则已填好的爱心会闪一次）；取消点赞不炸。
                        BearyIconMotion.playLikeBurst(on: strongSelf.likeButton)
                    }
                    strongSelf.onInteractionChanged?(entryIdValue, strongSelf.currentEntry?.likeCount, newLiked, nil)
                case .failure(let err):
                    // 失败回滚：先行填色与计数按原模型复原（取消点赞本就只改视图，
                    // 复原亦无害），再走既有失败路径（拒绝动效 + 通用提示），不另起一套。
                    strongSelf.currentEntry?.likedByMe = currentlyLiked
                    strongSelf.currentEntry?.likeCount = originalCount
                    strongSelf.updateLikeButton()
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.playDenyShake(on: strongSelf.likeButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    @objc private func bookmarkButtonTapped() {
        if cardMode == .profile {
            onBookmark?()
            return
        }
        self.feedBookmarkTapped()
    }

    /// F8（首页模式）：收藏先行切换、失败回滚 + 拒绝动效；先行期间不再半透明/禁用
    /// （方案一，Li 2026-10-28 定），防重入只靠 isBookmarkBusy 守卫；
    /// 成功后以服务端值为准并经控制器全副本同步。
    private func feedBookmarkTapped() {
        guard let entryIdValue = cellEntryId, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isBookmarkBusy { return }
        let currentlyBookmarked = currentEntry?.bookmarkedByMe ?? false
        let flipped = currentlyBookmarked == false
        currentEntry?.bookmarkedByMe = flipped
        updateBookmarkButton()
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
        isBookmarkBusy = true
        // 方案一：先行期间不压暗、不禁用，防重入只靠 isBookmarkBusy 守卫。
        BearyAPI.shared.toggleBookmark(id: entryIdValue) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.isBookmarkBusy = false
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? flipped
                    strongSelf.currentEntry?.bookmarkedByMe = newBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    strongSelf.onInteractionChanged?(entryIdValue, nil, nil, newBookmarked)
                case .failure(let err):
                    strongSelf.currentEntry?.bookmarkedByMe = currentlyBookmarked
                    strongSelf.updateBookmarkButton()
                    strongSelf.updateActionInteractivity()
                    if case .unauthorized = err {
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.playDenyShake(on: strongSelf.bookmarkButton)
                        strongSelf.onActionFailed?()
                    }
                }
            }
        }
    }

    @objc private func shareButtonTapped() {
        if cardMode == .profile {
            onShare?()
            return
        }
        // 分享用原生分享 sheet（控制器侧 present，payload 见 presentShareSheet）。
        if currentEntry?.isPublic != true { return }
        if let entryValue = currentEntry {
            onShareRequested?(entryValue)
        }
    }

    // MARK: - 回应行（网页 .emote-row 口径；两页统一流式换行）

    /// 回应行高（首页模式）：flow 实测换行高；行宽取 flow 实测宽，落位前用右列宽估算。
    private func updateEmoteRowHeight() {
        let width = emoteFlowView.bounds.width > 0 ? emoteFlowView.bounds.width : rightColumnWidthEstimate()
        let height = emoteFlowView.height(forWidth: width)
        if emoteRowHeightConstraint?.constant != height {
            emoteRowHeightConstraint?.constant = height
        }
    }

    /// F7：回应 chip 按 count 降序（网页 emoteChipsHtml 同口径）。按 key 取 chip（动画用）。
    /// 查 chipKeys（已建 chip 的紧凑 key 表，与 overlay tag 对齐），不用 currentEmoteList
    /// （空 key 项不建 chip，两表下标会错位）。
    private func chipView(forKey key: String) -> BearyEmoteChipView? {
        guard let index = chipKeys.firstIndex(where: { $0 == key }) else { return nil }
        for sub in emoteFlowView.subviews {
            guard let chip = sub as? BearyEmoteChipView, chip.overlayButton.tag == index else { continue }
            return chip
        }
        return nil
    }

    /// 贴上动效：chip-in 弹入 + 熊图 wiggle（详情页同款口径，网页 chipIn/emoteWiggle）；
    /// reduced-motion 时不动画。
    private func playChipIn(forKey key: String, completion: (() -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled { completion?(); return }
        emoteFlowView.layoutIfNeeded()
        guard let chip = chipView(forKey: key) else { completion?(); return }
        chip.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        chip.alpha = 0
        UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                chip.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                chip.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                chip.transform = .identity
                chip.alpha = 1
            }
        }, completion: { _ in completion?() })
        if let emoteView = chip.player {
            UIView.animateKeyframes(withDuration: 0.5, delay: 0, options: [], animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                    emoteView.transform = CGAffineTransform(rotationAngle: -0.1745).scaledBy(x: 1.3, y: 1.3)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.3) {
                    emoteView.transform = CGAffineTransform(rotationAngle: 0.1396).scaledBy(x: 1.15, y: 1.15)
                }
                UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                    emoteView.transform = .identity
                }
            }, completion: nil)
        }
    }

    /// 摘下动效：chip-out 缩没（网页 .chip-out .2s），只播动画、不重绘行；
    /// 离行与否由调用方在 completion 里决定（先行摘下：动画完再离行）。
    /// 减动效或 chip 已不在行时立即调 completion。
    func animateEmoteChipOut(key: String, completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            completion()
            return
        }
        guard let chip = chipView(forKey: key) else {
            completion()
            return
        }
        UIView.animate(withDuration: 0.2, animations: {
            chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            chip.alpha = 0
        }, completion: { _ in completion() })
    }

    /// 贴上动效外部入口（个人页控制器先行反馈用）：与 playChipIn 同款。
    func animateEmoteChipIn(key: String) {
        playChipIn(forKey: key)
    }

    /// 拒绝动效：摇指定 chip（找不到时摇 + 钮；失败回滚用）。
    func shakeEmoteChip(key: String) {
        if let chip = chipView(forKey: key) {
            playDenyShake(on: chip.overlayButton)
        } else {
            shakeEmoteAddButton()
        }
    }

    /// 拒绝动效：摇行末 + 钮（先行贴上失败回滚用）。
    func shakeEmoteAddButton() {
        for sub in emoteFlowView.subviews {
            if let button = sub as? BearyDiaryCardDashedAddButton {
                playDenyShake(on: button)
                return
            }
        }
    }

    /// 回应行统一渲染：count 降序（网页 emoteChipsHtml 同口径），mine 高亮，末尾常驻 + 按钮。
    /// 80 包 B4-1：胶囊池化——只把 chip 从 flow 摘下留池，不销毁；本轮未复用
    /// 的池 chip 不再上树（仍留池供下轮）；key 不变时重播播放器、key 变了才换播放器。
    /// animatedLayout：用户动作（先行贴/摘、回滚）时 + 钮与已存 chip 随新布局平滑移位
    /// （flow 帧动画，只动位置，不重播已有 chip）；服务端对齐与初始渲染走瞬时。
    private func renderEmotes(animatedLayout: Bool = false) {
        for sub in emoteFlowView.subviews {
            sub.removeFromSuperview()
        }
        let list = (currentEntry?.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) })
        currentEmoteList = list
        chipKeys = []
        var chipIndex = 0
        for item in list {
            guard let key = item.emote, !key.isEmpty else {
                // 个人主页原口径：空 key 不建 chip；首页原口径不设防，此处两页
                // 统一跳过空 key（空 key 的 BearyEmoteView 本就无图可播）。
                continue
            }
            let mine = item.mine ?? false
            let count = item.count ?? 0
            chipKeys.append(key)
            let chip: BearyEmoteChipView
            if chipIndex < emoteChipPool.count {
                chip = emoteChipPool[chipIndex]
                // 圆角长方形根治：复用 chip 须先复位 transform（chip-out 残留 0.5
                // 会使 flow 设 frame 时 bounds 翻倍、圆角与内容同缩一半）。
                chip.transform = .identity
                chip.render(key: key, count: count, mine: mine)
                chip.overlayButton.tag = chipIndex
            } else {
                let made = BearyEmoteChipView()
                made.render(key: key, count: count, mine: mine)
                made.overlayButton.tag = chipIndex
                made.overlayButton.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
                made.overlayButton.bearyAddPressFeedback()
                emoteChipPool.append(made)
                chip = made
            }
            emoteFlowView.addSubview(chip)
            chipIndex += 1
        }
        // 就地同步判等用（个人主页模式）：本轮实际渲染的 chip 签名。
        cellEmoteSignature = BearyEmoteOrder.signature(list.filter { ($0.emote ?? "").isEmpty == false })
        if cardMode == .feed {
            let addButton: BearyDiaryCardDashedAddButton
            if let reused = feedAddButton {
                addButton = reused
            } else {
                let made = BearyDiaryCardDashedAddButton(frame: .zero)
                made.translatesAutoresizingMaskIntoConstraints = false
                made.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
                made.tintColor = BearyColors.gray
                made.accessibilityLabel = "贴一只小熊"
                made.widthAnchor.constraint(equalToConstant: 34).isActive = true
                made.heightAnchor.constraint(equalToConstant: 34).isActive = true
                made.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
                // W6：同收藏钮，改通用按压（缩 .84 + .light）。
                made.bearyAddPressFeedback()
                feedAddButton = made
                addButton = made
            }
            emoteFlowView.addSubview(addButton)
            updateEmoteRowHeight()
        } else {
            let addButton: BearyDiaryCardDashedAddButton
            if let reused = profileAddButton {
                addButton = reused
            } else {
                let made = BearyDiaryCardDashedAddButton(frame: .zero)
                made.translatesAutoresizingMaskIntoConstraints = false
                made.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
                made.tintColor = BearyColors.gray
                made.accessibilityLabel = "贴一只小熊"
                made.widthAnchor.constraint(equalToConstant: 34).isActive = true
                made.heightAnchor.constraint(equalToConstant: 34).isActive = true
                made.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
                made.bearyAddPressFeedback()
                profileAddButton = made
                addButton = made
            }
            emoteFlowView.addSubview(addButton)
            updateEmoteRowHeight()
        }
        updateEmoteInteractivity()
        // 用户动作位移：+ 钮与已存 chip 随新布局帧动画滑到新位（只动位置，
        // 不重播已有 chip；新 chip 的出现动画由 playChipIn 另播，不冲突）。
        // 减动效下瞬时布局；行高约束本身瞬时改（换行数变化时行高仍瞬变，
        // 仅行内横向移位带动画）。
        if animatedLayout, UIAccessibility.isReduceMotionEnabled == false {
            emoteFlowView.setNeedsLayout()
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                self.emoteFlowView.layoutIfNeeded()
            }
        }
    }

    /// F7：互动门控与详情一致（首页模式 isPublic == true 才可互动）；先行反馈后
    /// 在途 chip 全量显示（旧 E3-3 pending 0.6 已废止，点赞/收藏同款口径）。
    /// A1（个人主页模式）：照抄首页口径——非公开日记的回应 chip 置灰禁用
    ///（overlay isEnabled=false + chip alpha=0.4），作者本人对自己私密日记
    /// 的回应同样不放行（无 isMine 例外）；“+”钮只控 busy 不按公开态
    /// 禁用/置灰，否则非公开提示（见 emoteAddTapped）无从触发。
    private func updateEmoteInteractivity() {
        if cardMode == .profile {
            let publicOK = currentEntry?.isPublic == true
            for sub in emoteFlowView.subviews {
                if let chip = sub as? BearyEmoteChipView {
                    chip.overlayButton.isEnabled = publicOK && !profileDisabled
                    sub.alpha = publicOK ? 1.0 : 0.4
                } else if let button = sub as? UIButton {
                    button.isEnabled = !profileDisabled
                }
            }
            return
        }
        let publicOK = currentEntry?.isPublic == true
        for sub in emoteFlowView.subviews {
            if let button = sub as? UIButton {
                button.isEnabled = publicOK && isEmoteBusy == false
                if publicOK == false {
                    button.alpha = 0.4
                } else {
                    button.alpha = 1.0
                }
                continue
            }
            guard let chip = sub as? BearyEmoteChipView else { continue }
            let overlay = chip.overlayButton
            overlay.isEnabled = publicOK && isEmoteBusy == false
            if publicOK == false {
                sub.alpha = 0.4
            } else {
                sub.alpha = 1.0
            }
        }
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        if cardMode == .profile {
            // A1 纵深守卫：chip 非公开时本已禁用（点按无事件），此处再拦一道，
            // 确保私密日记的回应绝不经本路径转发（含作者本人）。
            if currentEntry?.isPublic != true { return }
            let index = sender.tag
            guard index >= 0, index < chipKeys.count else { return }
            onEmoteTap?(chipKeys[index])
            return
        }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        let index = sender.tag
        if index < 0 || index >= chipKeys.count { return }
        let tappedKey = chipKeys[index]
        if tappedKey.isEmpty { return }
        chooseEmote(key: tappedKey)
    }

    @objc private func emoteAddTapped() {
        if cardMode == .profile {
            // A1：非公开卡片点“+”不打开选择器，改走提示回调（控制器弹 toast）
            // 并返回，杜绝旧静默丢弃；公开卡片原样走 onEmoteAdd。
            if currentEntry?.isPublic != true {
                onEmoteAddNotPublic?()
                return
            }
            onEmoteAdd?()
            return
        }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        onEmoteAddRequested?()
    }

    /// 首贴面板选定后的入口（首页模式）：按条目 id 校验（面板弹出期间 cell 可能已被复用），
    /// 校验失败静默丢弃；未登录时走 onRequireLogin；选定后 140ms 锁内再选丢弃。
    func handleEmoteSheetPick(entryIdValue: String, key: String) {
        if cellEntryId != entryIdValue { return }
        if key.isEmpty { return }
        if emotePickLocked { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        emotePickLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.emotePickLocked = false
            if strongSelf.cellEntryId != entryIdValue { return }
            strongSelf.chooseEmote(key: key)
        }
    }

    /// 贴/摘回应的唯一入口（首页模式；chip 与首贴面板共用，多选）：
    /// 同只再点即撤下那只；点自己没贴过的只直接 POST 新增，绝不因点新回应
    /// 而摘掉用户已贴的另一只；只有被点的那只计数变化。
    /// 先行反馈（点赞/收藏同款口径）：贴上立即进场 + 计数 +1，摘下先播退场
    /// 动画再离行，API 在后台跑；成功对齐服务端值，失败回滚 + 拒绝动效。
    private func chooseEmote(key: String) {
        if key.isEmpty || isEmoteBusy { return }
        guard let entryIdValue = cellEntryId, !entryIdValue.isEmpty else { return }
        if currentEntry?.isPublic != true { return }
        if SessionManager.shared.isLoggedIn == false {
            onRequireLogin?()
            return
        }
        var tappedMine = false
        for item in currentEmoteList {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key && item.mine == true {
                tappedMine = true
            }
        }
        emoteFlightKey = key
        emoteFlightAdded = tappedMine == false
        emoteFlightOriginal = currentEntry?.emotes ?? []
        emoteFlightServerEmotes = nil
        emoteFlightFailed = false
        emoteFlightUnauthorized = false
        emoteFlightAPIDone = false
        emoteFlightRemovalStaged = false
        isEmoteBusy = true
        updateEmoteInteractivity()
        if tappedMine {
            // 摘下：先播退场动画再离行；API 立即发出，回包到达若动画未完
            // 先记结果、不抢动画中的 chip，动画完再对齐或回滚。
            emoteFlightRemovalStaged = true
            animateEmoteChipOut(key: key) { [weak self] in
                guard let strongSelf = self, strongSelf.cellEntryId == entryIdValue else { return }
                strongSelf.emoteFlightRemovalStaged = false
                if strongSelf.emoteFlightFailed {
                    if strongSelf.emoteFlightUnauthorized {
                        // 未登录：先行态静默复原，再走登录页（不摇不 toast）。
                        strongSelf.currentEntry?.emotes = strongSelf.emoteFlightOriginal ?? []
                        strongSelf.renderEmotes()
                        strongSelf.onEmoteChanged?(entryIdValue, strongSelf.emoteFlightOriginal)
                        strongSelf.clearEmoteFlight()
                        strongSelf.onRequireLogin?()
                    } else {
                        strongSelf.rollbackEmoteFlight(entryIdValue: entryIdValue)
                    }
                    return
                }
                let removal = strongSelf.emoteDelta((strongSelf.emoteFlightOriginal ?? []), key: key, added: false)
                strongSelf.currentEntry?.emotes = removal
                strongSelf.renderEmotes(animatedLayout: true)
                strongSelf.onEmoteChanged?(entryIdValue, removal)
                if strongSelf.emoteFlightAPIDone {
                    strongSelf.alignEmoteFlight(entryIdValue: entryIdValue)
                }
            }
            postEmoteOnce(key: key)
            return
        }
        let optimistic = emoteDelta((currentEntry?.emotes ?? []), key: key, added: true)
        currentEntry?.emotes = optimistic
        renderEmotes(animatedLayout: true)
        playChipIn(forKey: key)
        onEmoteChanged?(entryIdValue, optimistic)
        postEmoteOnce(key: key)
    }

    /// 先行增量：贴上时该 key 计数 +1（无此 key 则 mine 新建 1）；摘下时
    /// 计数 −1（到 0 即整项消失，mine 恒 false 化——服务端同只 POST 即撤下）。
    private func emoteDelta(_ list: [EmoteCount], key: String, added: Bool) -> [EmoteCount] {
        var out: [EmoteCount] = []
        var found = false
        for var item in list {
            guard let itemKey = item.emote, !itemKey.isEmpty else { continue }
            if itemKey == key {
                found = true
                if added {
                    item.count = (item.count ?? 0) + 1
                    item.mine = true
                    out.append(item)
                } else {
                    let next = (item.count ?? 0) - 1
                    if next > 0 {
                        item.count = next
                        item.mine = false
                        out.append(item)
                    }
                }
            } else {
                out.append(item)
            }
        }
        if added && found == false {
            out.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return out
    }

    /// 在途 POST（首页模式）：只发请求与终态处理，先行渲染由 chooseEmote 做。
    /// cell 复用后回包到达时直接丢弃（不碰新条目）。
    private func postEmoteOnce(key: String) {
        guard let entryIdValue = cellEntryId, !entryIdValue.isEmpty else { return }
        BearyAPI.shared.postEmote(id: entryIdValue, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self, strongSelf.cellEntryId == entryIdValue else { return }
                switch result {
                case .success(let resp):
                    // 表情排序批：回包先按已显示顺序合并（新贴追加末尾），再对齐；
                    // 直接覆盖回包顺序会把刚贴的 count=1 按聚合顺序顶到前面。
                    let merged = resp.emotes.map { BearyEmoteOrder.merged(previous: strongSelf.currentEntry?.emotes, server: $0) }
                    strongSelf.emoteFlightServerEmotes = merged
                    strongSelf.emoteFlightAPIDone = true
                    if strongSelf.emoteFlightRemovalStaged {
                        return
                    }
                    strongSelf.alignEmoteFlight(entryIdValue: entryIdValue)
                case .failure(let err):
                    if strongSelf.emoteFlightRemovalStaged {
                        strongSelf.emoteFlightFailed = true
                        if case .unauthorized = err {
                            strongSelf.emoteFlightUnauthorized = true
                        }
                        strongSelf.emoteFlightAPIDone = true
                        return
                    }
                    if case .unauthorized = err {
                        // 未登录：先行态静默复原，再走登录页（不摇不 toast）。
                        strongSelf.currentEntry?.emotes = strongSelf.emoteFlightOriginal ?? []
                        strongSelf.renderEmotes()
                        strongSelf.onEmoteChanged?(entryIdValue, strongSelf.emoteFlightOriginal)
                        strongSelf.clearEmoteFlight()
                        strongSelf.onRequireLogin?()
                        return
                    }
                    strongSelf.rollbackEmoteFlight(entryIdValue: entryIdValue)
                }
            }
        }
    }

    /// 成功对齐：服务端值与先行值一致时不动（不重建、不重播已有 chip）；
    /// 不一致时瞬时重绘（非用户动作，不带位移动画）并通知容器。
    private func alignEmoteFlight(entryIdValue: String) {
        let merged = emoteFlightServerEmotes ?? currentEntry?.emotes
        if let merged = merged, BearyEmoteOrder.signature(merged) != BearyEmoteOrder.signature(currentEntry?.emotes) {
            currentEntry?.emotes = merged
            renderEmotes()
            onEmoteChanged?(entryIdValue, merged)
        }
        clearEmoteFlight()
    }

    /// 失败回滚：恢复点选前快照（位移带动画），摘下失败时被摘 chip 带出现
    /// 动画回来，再补拒绝动效（摇头 + toast）；容器同步回滚值。
    private func rollbackEmoteFlight(entryIdValue: String) {
        let key = emoteFlightKey
        let wasAdded = emoteFlightAdded
        let original = emoteFlightOriginal ?? []
        currentEntry?.emotes = original
        renderEmotes(animatedLayout: true)
        if wasAdded == false, let backKey = key {
            playChipIn(forKey: backKey)
            shakeEmoteChip(key: backKey)
        } else {
            shakeEmoteAddButton()
        }
        onEmoteFailed?()
        onEmoteChanged?(entryIdValue, original)
        clearEmoteFlight()
    }

    private func clearEmoteFlight() {
        isEmoteBusy = false
        emoteFlightKey = nil
        emoteFlightAdded = false
        emoteFlightOriginal = nil
        emoteFlightServerEmotes = nil
        emoteFlightFailed = false
        emoteFlightUnauthorized = false
        emoteFlightAPIDone = false
        emoteFlightRemovalStaged = false
        updateEmoteInteractivity()
    }
}

// MARK: - C6 卡片上下文菜单（取代 Q9 长按 + UIAlertController actionSheet，首页与个人主页共用）

extension BearyDiaryCardCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // 旧长按互斥口径平移：按钮、图片条、引用卡上的长按不弹菜单，
        // 各自原有手势照常走；头像/名字排除仅首页模式（个人主页原口径
        // 不排除，各保各的）；正文区长按仍弹菜单。
        if let hit = contentView.hitTest(location, with: nil) {
            var view: UIView? = hit
            while let current = view {
                if current is UIButton { return nil }
                if current === imagesScrollView || current === quoteView { return nil }
                if cardMode == .feed {
                    if current === avatarImageView || current === nameLabel { return nil }
                }
                if current === contentView { break }
                view = current.superview
            }
        }
        guard let entry = currentEntry else { return nil }
        // previewProvider=nil：系统以 interaction 所附 view（contentView 整卡）作
        // 原位浮起预览，菜单为系统毛玻璃 UIMenu；旧 sheet 的“取消”项由系统菜单
        // 的空白处点按/下滑手势承担，不再单列。
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return UIMenu(title: "", children: []) }
            var actions: [UIAction] = []
            if entry.isPublic == true {
                actions.append(UIAction(title: "分享", image: BearyIconImages.image(named: "icon_share", pointSize: 20)) { [weak self] _ in
                    self?.shareFromCardMenu()
                })
            }
            // P2 首页纯逻辑：首页模式私密卡不给“收藏”项——其收藏路径
            // feedBookmarkTapped 遇 isPublic != true 直接静默 return，留着就是死按钮
            // （分享项同款口径：仅公开卡出现）。个人主页模式走自有 onBookmark 路径，
            // 不在此改动，行为保持原样。
            // 收藏标题取实时态：首页模式 currentEntry 由 cell 内收藏路径就地维护，
            // 个人主页模式 cellBookmarkedByMe 由 syncInteraction 维护。
            if entry.isPublic == true || self.cardMode == .profile {
                let bookmarked = self.cardMode == .profile ? self.cellBookmarkedByMe : (self.currentEntry?.bookmarkedByMe ?? false)
                // 2026-10-28 定版：菜单图标走手绘 icon_bookmark（无 bookmark.slash 手绘资产，取消态以标题区分，图标同款）。
                actions.append(UIAction(title: bookmarked ? "取消收藏" : "收藏", image: BearyIconImages.image(named: "icon_bookmark", pointSize: 20)) { [weak self] _ in
                    self?.bookmarkFromCardMenu()
                })
            }
            if self.isCardMenuEditAvailable(entry: entry) {
                actions.append(UIAction(title: "编辑", image: BearyIconImages.image(named: "icon_edit", pointSize: 20)) { [weak self] _ in
                    self?.onContextMenuEdit?()
                })
            }
            if entry.isMine == true, entry.isPublic != true {
                actions.append(UIAction(title: "删除", image: BearyIconImages.image(named: "icon_trash", pointSize: 20), attributes: .destructive) { [weak self] _ in
                    self?.onContextMenuDelete?()
                })
            }
            return UIMenu(title: "", children: actions)
        }
    }
}

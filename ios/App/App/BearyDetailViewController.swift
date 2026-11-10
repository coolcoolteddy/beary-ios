// BearyDetailViewController.swift
//
// 日记详情页（批 B，2026-10-30 首页布局重做，单独 PR，不合入、不构建）。
// 全屏页（盖住底栏，fadeRise 进场，与 App 全屏页同款），顶栏只剩左上文字“关闭”；
// 版式骨架照搬首页日记卡片 BearyDiaryCardCell（mode=.feed），唯一有意偏离是
// 标题放开换行（首页单行截断；详情是全文页）与正文全文不折叠（首页折叠钮不出现）。
// 单层内容列（#213 保留）：宽 ≤820 时安全区宽−32（竖屏安全区横向 inset 为 0，393 宽即 361pt 不变），宽 ≥821 时 600 居中。
// 列内（2026-11-05 日记布局统一，与卡片同一套）：头像 40 + 间距 12 + 头行
// （@ 行 12 粗体橙 + 13 图标在作者行上方；作者行名 16.5 粗体、皇冠 19
// 带 drop-shadow、垫片吸宽、时间 13 灰、天气 15 灰、心情 13 灰 + 20 熊图，按文字
// 基线对齐）；头行之下是全宽正文栈：标题 16.5 粗体（放开换行）→正文 16/1.6，
// 标题与正文同左缘、同宽，左右与内容列齐平，不再缩进到昵称位置。
// 引用卡（BearyQuoteCardView，viewer 实时判定）；横向 216 图片条（间距 8、圆角 12、
// 宽按宽高比 0.55–2.22 倍高夹取、无尺寸默认 280、无图高 0）；操作行赞左、收藏紧邻赞右、分享钉右缘
// （无回应钮）；回应在下方流式 chip 行（BearyEmoteFlowView + 34 虚线 + 钮，
// 仅熊脸 key 显示，服务端数据不动）；篇末一条 2pt 全宽线收尾（限时存活期藏线改虚线框）。
// 本人卡右上角 21pt 灰色小地球（28 框、44 热区，对齐作者行；头行右缩进让出 28+8，
// 以内容列为基准即 −36，等价于首页以整屏为基准的 −52，屏上几何一致；正文栈右缩进恒 0）；
// 编辑／删除走长按系统上下文菜单（C6 同款，卡片内无 ⋯ 钮，关闭钮保留）。
// 限时：1.5pt 虚线框圆角 16、左右内缩 8／顶 +6／底按正文栈底 +16 + 倒计时灰字行（作者行下方、标题上方）。
// 纵向间距（头行 + 正文栈，2026-11-05 ChatGPT 间距跟进）：@→作者 4、作者→限时 4、
// 头行→正文栈 16（有标题）／14（无标题）、标题→正文 6、正文→图片 14、
// 图片→引用 12、引用→定位 12、定位→操作行 14、操作行→回应行 12、
// 正文栈底→底线 16、底线下 24 留白；头行顶：无 @ 行 16、有 @ 行 17。
// 旧详情口径的差异（本批改掉）：心情／天气／@ 不再用 faint 底 chip 行（心情天气
// 进作者行、@ 独占首行）；操作行不再左置四钮（回应钮删除、收藏去中文标签、
// 分享非公开隐藏时留 21pt 槽位占位）；回应不再用“回应”标题 + “写回应…”实心钮；
// 可见性不再用盒装 pill（锁／地球图标 + pill 行已删，图标即切换钮本身）。
// 不变：失败态（清为无正文居中提示）／占位态（私密占位优先于失败态，拉黑／举报
// 钉死占位）／dwell／引用 viewer 实时判定／已赞红 #ff3b30／限时到期单次定时／
// 快连点代次守卫／先行反馈失败回滚＋拒绝动效；游客态只读全文与图片，互动收进
// 一行素字提示条。
// 动画只走 transform／opacity；数字文案只动数字本身（只 setTitle，不重建行）；
// 新交互面禁用 tap 高亮与焦点描边。

import UIKit
import Photos

/// 详情限时虚线边框视图（116 详情框修）：自身按 bounds 重画虚线路径，
/// 不再由控制器在布局时手动算矩形——正文栈高度落定（引用加载、回应行出现）
/// 后 bounds 一变就重画，框底不再切穿“＋”回应钮。
/// 口径不变：1.5pt、虚线 [4,3]、圆角 16、line 色；不拦截点按；深浅切换自刷描边色。
final class BearyDetailDashedBorderView: UIView {
    private let borderLayer = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [4, 3]
        borderLayer.strokeColor = BearyColors.line.cgColor
        layer.addSublayer(borderLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: BearyCorners.single).cgPath
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            borderLayer.strokeColor = BearyColors.line.cgColor
        }
    }
}

final class BearyDetailViewController: UIViewController {

    // MARK: - 回调（容器 SceneDelegate 接线）

    /// 详情关闭后：列表定位回该卡（各页 guarded scroll，只滚已在列表里的 id，绝不插入）。
    var onDismissed: ((String) -> Void)?
    /// 本人菜单：编辑 → 容器先关详情再弹编辑器。
    var onEdit: ((Entry) -> Void)?
    /// 本人菜单：删除 → 容器先关详情再走确认删除流程。
    var onDelete: ((Entry) -> Void)?
    /// 作者名／头像／@ chip 点按 → 容器先关详情再开作者主页。
    var onAuthorTapped: ((Int) -> Void)?
    /// 引用卡点按 → 容器先关详情再走 gotoEntry（防 modal 叠 modal）。
    var onQuoteTapped: ((String) -> Void)?
    /// 可见性切换成功后：容器同步各列表（首页定向刷新 + 时间线重拉 + 我页重载）。
    var onVisibilityChanged: ((Entry) -> Void)?
    /// 点赞／收藏／回应变化后：容器同步首页行（timeline 侧沿用其 onInteractionChanged 口径）。
    var onInteractionChanged: ((String, Int?, Bool?, Bool?, [EmoteCount]?) -> Void)?
    /// 游客态互动点按 → 容器弹登录提示。
    var onRequireLogin: (() -> Void)?

    // MARK: - 状态

    private var entry: Entry
    private let isGuest: Bool
    private let isAuthor: Bool
    /// R22-A1：详情落盘桶——进页时按当时账号钉住，不跟随后来的切号走；
    /// 旧账号回包已由容器复核丢弃，此处再钉一次桶，防写盘时账号已变。
    private let snapshotBucket: String
    /// 快连点代次（2026-10-29 及时性口径）：点按不再锁按钮丢点按，每次
    /// 点按代次 +1 并立即按本次点按态渲染；在途回包代次落后于最新代次
    /// 时直接丢弃，不得覆盖更新的点按态；失败回滚到最后确认态。
    private var likeSeq = 0
    /// 审计动效组：点赞按下预览标记——bearyAddPressFeedback 已在 touchDown 给过
    /// press 轻震，likeTapped 里不再补 likeTap，只震一次；取消/滑出时清零。
    private var likePressPreviewActive = false
    private var likeConfirmedSeq = 0
    private var bookmarkSeq = 0
    private var bookmarkConfirmedSeq = 0
    private var confirmedLiked = false
    private var confirmedLikeCount = 0
    private var lastNavigationAt: Date?
    private var lastImageViewerAt: Date?
    private var confirmedBookmarked = false
    private var isEmoteBusy = false
    private var isVisibilityBusy = false
    /// 审计三轮第二批 9：限时到期单次定时器（只按最近 ephemeralUntil 排一次，
    /// 绝不按秒/按分钟全量刷新；到点只重算有效态，见 applyEphemeralExpiryIfNeeded）。
    private var ephemeralExpiryTimer: Timer?
    private var dwellStart: Date?
    private var dwellReported = false
    private var dismissedFired = false
    private var chipKeys: [String] = []
    /// 审计三轮第三批 26：上次 renderEmotes 渲染的排序后签名（key:count:mine 串），
    /// 相等即无变化、直接返回，不重建 chip；nil 表示尚未渲染过一次。
    private var renderedEmoteSignature: String?
    private var lastFlowWidth: CGFloat = 0
    /// 详情页重做（2026-10-30 预览定版，Li 点头）：单层内容列，两分支互斥。
    /// 宽 ≤820：leading = view 安全区 leading＋16、trailing = view 安全区 trailing−16
    /// （required 等式，宽 = 安全区宽−32；竖屏横向 inset 为 0，393 宽即 361pt 不变），不靠 centerX＋
    /// 不等式护栏、不靠 750 优先级补丁等式，内容内在宽不再反推列宽。
    /// 宽 ≥821：宽 600 居中。两组约束只激活一组，切换时在
    /// viewDidLayoutSubviews 里整组开关，状态不变不开关，避免布局循环。
    private var columnNarrowLeading: NSLayoutConstraint?
    private var columnNarrowTrailing: NSLayoutConstraint?
    private var columnWideWidth: NSLayoutConstraint?
    private var columnWideCenterX: NSLayoutConstraint?
    private var columnIsWide = false

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentColumnView = UIView()
    /// 批 B 头行栈：首页卡片 headerStack 同款（spacing 0 + setCustomSpacing 对照表，
    /// 见 updateDiaryStackSpacing；顶距由 headerStackTopConstraint 动态定 22/23）。
    /// 只放 @ 行、作者行、限时行；标题/正文一律在下方的 bodyStack 全宽排布。
    private let headerStack = UIStackView()
    /// 批 B 正文栈：标题、正文、图片条、引用卡、位置行、操作行、游客提示条、
    /// 回应行一律全宽（左右与内容列齐平），不再缩进到昵称位置。
    private let bodyStack = BearyPassThroughStackView()
    private var headerStackTopConstraint: NSLayoutConstraint?
    private var headerStackTrailingConstraint: NSLayoutConstraint?
    /// 正文栈顶：取头像底与头行底两者较大者 + 间距（有标题 12、无标题 8）；
    /// 两条 required ≥ 约束定下限，一条 999 的 = 约束把栈顶拉回头行底 + 间距。
    private var bodyStackTopFromAvatarConstraint: NSLayoutConstraint?
    private var bodyStackTopFromHeaderConstraint: NSLayoutConstraint?
    private var bodyStackTopPinConstraint: NSLayoutConstraint?
    private let separatorView = UIView()
    // 审计-编辑器详情：关闭钮视觉仍为 15pt 文字、高 52，宽按标题固有宽
    // （约 30pt）不足 44——改 Hit44 扩热区，视觉一字不动。
    private let closeButton = BearyHit44Button(type: .custom)
    private let avatarButton = BearyHit44Button(type: .custom)
    private let avatarImageView = UIImageView()
    /// 首页卡片同款：无图时背后首字母圆透出（avatarImageView 为空时可见）。
    private let avatarInitialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()
    /// 审计 P2-14：头像失败重试钮（广场同款，28pt 圆盘）。
    private lazy var avatarRetryButton: BearyFeedRetryButton = {
        bearyFeedRetryButton(target: self, action: #selector(detailImageRetryTapped(_:)))
    }()
    /// 审计 11：上次已渲染的头像 URL——URL 不变时保留当前图片，不重走
    /// bearySetImage（它会取消在途任务、清图重下，造成头像闪烁）。
    private var lastRenderedAvatarURL: URL?
    /// @ 行：首页 recipientRow 同款（13 图标 + 12 粗体橙，间距 5）；点按走 mentionTapped。
    /// 112 视觉扫查：@ 行文案是“@名”，图标须用 icon_at（编辑器 @ 钮、草稿箱 @ chip、
    /// 消息页 @ 角标同款）；此前误用 icon_mail 信封（系统信件图标），与 @ 语义不符。
    private let recipientIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_at", pointSize: 13)
        v.tintColor = BearyColors.ink
        v.contentMode = .scaleAspectFit
        return v
    }()
    private let recipientLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        // 113：底数 12 粗体不动，只加 scaledFont + adjusts（#322/#324 同款做法）。
        lb.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 12))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 1
        return lb
    }()
    private lazy var recipientRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [recipientIconView, recipientLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .center
        st.isHidden = true
        return st
    }()
    /// 作者行：首页 titleStack 同款（名 + 皇冠 + 垫片 + 时间 + 天气 + 心情，
    /// 间距 8、.firstBaseline 对齐）。
    private let nameButton = UIButton(type: .custom)
    private let crownView: BearyCrownView = {
        let v = BearyCrownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// 皇冠容器（卡片同款原因：作者行是 .firstBaseline 栈，纯 UIView 基线即底边，
    /// 皇冠直接进栈时底边钉在名字基线上、中心比 cap 中心高约 3.6pt）。
    /// 容器与名字按钮等高、底边钉基线，皇冠在内居中后中心即 cap 中心。
    private let crownWrapView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()
    private let titleSpacerLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()
    // 109：详情作者行时间与卡片同口径（13pt 灰 + 动态字号跟随；此前仅
    // UILabel() 默认，实为 17pt 默认色，与文件头“时间 13 灰”注释不符）。
    private let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
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
    /// 天气图标的 15×15 盒：图标在盒内居中；盒与气温标签同在左下角天气行。
    /// （原在作者行 timeLabel 旁做基线对齐，2026-11-10 移入正文区下面的天气行，
    /// 盒改为固定 15 高，不再与 timeLabel 等高。）
    private let weatherWrapLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.isHidden = true
        return lb
    }()
    /// 详情天气动态图标覆盖层（卡片落点行同款；底层静态图作 fallback）。
    private var weatherEmoteView: BearyEmoteView?
    /// 详情作者行气温（卡片同款口径：有后端 temperature_c 且有天气类型才显，
    /// 无值隐藏、不留空位；详情此前只显天气图标、气温丢了，卡片/详情不一致）。
    private let weatherTempLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.isHidden = true
        lb.setContentHuggingPriority(.required, for: .horizontal)
        lb.setContentCompressionResistancePriority(.required, for: .horizontal)
        return lb
    }()
    /// 天气行（左下角、正文区下面、位置行之前）：天气图标 15 + 气温，左对齐；
    /// 无天气数据时整行隐藏、不占位（显隐由 renderWeatherTemp 末尾同步）。
    private lazy var weatherRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [weatherWrapLabel, weatherTempLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 6
        st.alignment = .center
        st.isHidden = true
        return st
    }()
    private let moodLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()
    private lazy var moodStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [moodLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 3
        st.alignment = .center
        st.isHidden = true
        return st
    }()
    private var moodEmoteView: BearyEmoteView?
    private lazy var authorRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameButton, crownWrapView, titleSpacerLabel, timeLabel, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        // 姓名→皇冠间距 6（2026-11-05 ChatGPT 间距跟进；徽章已下线摘掉，
        // 皇冠直接贴名字；整行统一间距，名字→皇冠、皇冠→时间等同值）。
        st.spacing = 6
        st.alignment = .firstBaseline
        st.distribution = .fill
        return st
    }()
    /// 右上角 ⋯ 钮：时间线 moreButton 同款（21pt 灰色、28 框、44 热区），
    /// 不挂作者行内，挂 contentColumnView 右上角、对齐作者行；头行右缩进见
    /// refreshAuthorActions（⋯ 显时 −36、藏时 0，以内容列为基准）。
    private let moreButton = BearyHit44Button(type: .custom)
    private let bodyLabel = UILabel()
    /// 审计 P2-12：详情补标题行（卡片同款 16.5 粗体，空标题不占位）。
    /// 审计 P1-1（推翻 P2-12 单行决定，仅详情标题这一处）：标题自然换行，
    /// 不再单行截断；时间线日历 FLIP 例外不动。
    private let titleLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.cardTitleFont()
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 0
        lb.lineBreakMode = .byCharWrapping
        lb.isHidden = true
        return lb
    }()
    /// 横向 216 图片条：首页 imagesScrollView + imagesStack 同款（间距 8、
    /// 高只由 imageHeightConstraint 驱动：216 有图 / 0 无图；9 只槽位复用）。
    private let imagesScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.delaysContentTouches = false
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
    private var imageHeightConstraint: NSLayoutConstraint?
    private var imageSlots: [UIImageView] = []
    private var imageSlotWidthConstraints: [NSLayoutConstraint] = []
    private var imageSlotRetryButtons: [BearyFeedRetryButton] = []
    /// 实况覆盖层与长按手势（卡片同款：平时隐藏、长按播实况、点按进灯箱不动）。
    private var imageSlotLiveViews: [BearyLivePhotoView] = []
    private var imageSlotLivePresses: [UILongPressGestureRecognizer?] = []

    /// 图片条捏合拼图：双指捏合把间距 8 → 0、圆角 12 → 0（图贴在一起且无圆角），张开恢复 8 / 12。
    /// 只动 imagesStack.spacing 与槽位圆角，不动槽宽/高，不缩放单张图；灯箱自带的
    /// 单图捏合缩放不在此改动范围。滚动视图本身未开 zoom（min/max 均为 1），
    /// 其内置捏合手势不会抢占本手势。
    private var stripPinchStartProgress: CGFloat = 0
    private var stripPinchJoined = false

    private func installImageStripPinch() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(imageStripPinched(_:)))
        pinch.delegate = self
        imagesScrollView.addGestureRecognizer(pinch)
    }

    /// 捏合跟手圆角：progress 0 → 圆角 12，progress 1（贴合）→ 圆角 0，与间距同一进度走，
    /// 不在松手瞬间跳变；只改槽位图层圆角，不动其他圆角。
    private func applyImageStripCornerRadius(progress: CGFloat) {
        let radius = 12 * (1 - max(0, min(1, progress)))
        for slot in imageSlots { slot.layer.cornerRadius = radius }
    }

    @objc private func imageStripPinched(_ gesture: UIPinchGestureRecognizer) {
        // 单图时无间距可收，不接管手势（也不禁滚动）。
        let visibleCount = imageSlots.filter { !$0.isHidden }.count
        guard visibleCount >= 2 else { return }
        switch gesture.state {
        case .began:
            // 以当前实际间距起算，防上一轮贴合动画中途被新一轮捏合打断时跳变。
            stripPinchStartProgress = max(0, min(1, 1 - imagesStack.spacing / 8))
            imagesScrollView.isScrollEnabled = false
        case .changed:
            // scale < 1 为捏合（progress 增大、间距收小），scale > 1 为张开（反向）；
            // 从贴合态起手张开同样走这条式子，不会出现“贴合后张开无效”。
            let progress = max(0, min(1, stripPinchStartProgress + (1 - gesture.scale)))
            imagesStack.spacing = 8 * (1 - progress)
            applyImageStripCornerRadius(progress: progress)
            // 审计动效组：跟手过程只改值 + setNeedsLayout，不逐帧强制 layout；
            // 松手后的落点动画（.ended 的 UIView.animate 内）仍用 layoutIfNeeded 结算。
            imagesScrollView.setNeedsLayout()
        case .ended, .cancelled, .failed:
            imagesScrollView.isScrollEnabled = true
            let progress = max(0, min(1, stripPinchStartProgress + (1 - gesture.scale)))
            let wasJoined = stripPinchJoined
            stripPinchJoined = progress >= 0.5
            // 拼合/张开落点到位时各轻震一次：只在 .ended 且落点状态真的变化时震，
            // 跟手过程、取消/失败、原地未变都不震；震动走 BearyHaptics 口径，
            // 不拿减动效门控（两者不是一回事，见 BearyHaptics 头注释）。
            if gesture.state == .ended && wasJoined != stripPinchJoined {
                BearyHaptics.press()
            }
            // 捏合拼图落点走拖拽收尾统一弹簧 0.30s／damping 0.7（落点动画
            // 属性是间距／圆角、非缩放量，捏合速度无直接映射，初速度取 0）；减动效直接落终值，不播弹簧。
            if UIAccessibility.isReduceMotionEnabled {
                self.imagesStack.spacing = self.stripPinchJoined ? 0 : 8
                self.applyImageStripCornerRadius(progress: self.stripPinchJoined ? 1 : 0)
                self.imagesScrollView.layoutIfNeeded()
            } else {
                UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
                    self.imagesStack.spacing = self.stripPinchJoined ? 0 : 8
                    self.applyImageStripCornerRadius(progress: self.stripPinchJoined ? 1 : 0)
                    self.imagesScrollView.layoutIfNeeded()
                })
            }
        default:
            break
        }
    }

    private func resetImageStripPinch() {
        stripPinchJoined = false
        imagesStack.spacing = 8
        applyImageStripCornerRadius(progress: 0)
        imagesScrollView.isScrollEnabled = true
    }
    /// 批 E 详情位置行：官方 icon_location 13 灰 + 位置文案；公开篇作者本人
    /// 也只看区级（与他人视角一致），不再另附提示行。无位置/他人视角无区级/
    /// 公开篇无区级时整组隐藏，不留空行（与卡片同口径）。
    private let detailLocationIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyLocationIcon.image(pointSize: 13)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()
    private let detailLocationLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 13pt，大字号下位置行不跟随；单行截断，栈高自适应。
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.lineBreakMode = .byTruncatingTail
        return lb
    }()
    private lazy var detailLocationLineRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [detailLocationIconView, detailLocationLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 4
        st.alignment = .center
        return st
    }()
    private lazy var detailLocationStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [detailLocationLineRow])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.spacing = 4
        st.isHidden = true
        return st
    }()
    private let quoteView = BearyQuoteCardView(frame: .zero)
    /// 操作行：首页 actionStack 同款（赞左、收藏紧邻赞右、分享钉右缘，
    /// 点赞—收藏间距 BearySpace.xxl（24，规范 §3）；无回应钮；分享非公开
    /// 隐藏时 shareSlotSpacer 占位 24pt，行尾槽位不随分享显隐变化）。
    private let actionStack = UIStackView()
    private let likeButton = BearyHit44Button(type: .custom)
    /// 赞钮显式宽约束（卡片同款）：按钮固有宽不含标题边距，栈按固有宽给帧时
    /// 标题框只剩边距差，数字会被裁成左半弧（115 详情页 0 赞残影实证）；
    /// 故宽度一律显式算：图标宽（0 赞时）或图标宽 + 6 + 标题宽（有赞时）。
    private var likeButtonWidthConstraint: NSLayoutConstraint?
    private let bookmarkButton = BearyHit44Button(type: .custom)
    private let shareButton = BearyHit44Button(type: .custom)
    private lazy var shareSlotSpacer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.isAccessibilityElement = false
        v.widthAnchor.constraint(equalToConstant: 24).isActive = true
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return v
    }()
    private let guestPromptButton = BearyHit44Button(type: .custom)
    private let emoteFlowView = BearyEmoteFlowView()
    private var emoteFlowHeight: NSLayoutConstraint?
    /// 回应行末 + 钮：首页 feedAddButton 同款（34 虚线圆、16 + 号、灰色），
    /// 复用一个实例挂进 emoteFlowView，不随 renderEmotes 重建。
    private var emoteAddButton: BearyDiaryCardDashedAddButton?
    /// 审计 P2-18（详情部分）：详情占位迁入已有 BearyStateView，不新建组件；
    /// 无插图（iconName 为 nil 时图标圆整行隐藏），不强迫所有空态用相同插图。
    /// 失败态与占位共用本视图布局，一并受益（P1-2），不另起一套。
    private let placeholderStateView = BearyStateView()

    /// 第 22 轮 C2：失败横幅——“显示的是上次的内容”＋“重试”，挂正文栈首行
    /// （作者头行正下方）；失败时常驻、不自动消失，成功后 0.18s 淡出。
    private let staleBannerLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.text = "显示的是上次的内容"
        label.setContentHuggingPriority(UILayoutPriority.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var staleBannerRetryButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("重试", for: .normal)
        button.setTitleColor(BearyColors.ink, for: .normal)
        button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.setContentHuggingPriority(UILayoutPriority.required, for: .horizontal)
        button.accessibilityLabel = "重试加载"
        button.addTarget(self, action: #selector(staleBannerRetryTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    private lazy var staleBannerView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [staleBannerLabel, staleBannerRetryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.backgroundColor = BearyColors.surface2
        stack.layer.cornerRadius = 12
        stack.clipsToBounds = true
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.isHidden = true
        return stack
    }()

    private var staleBannerVisible = false
    private var staleBannerRetrying = false

    private let ephemeralLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 12pt，限时倒计时行不跟随大字号。
        l.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        l.adjustsFontForContentSizeCategory = true
        l.textColor = BearyColors.gray
        l.isHidden = true
        return l
    }()
    private lazy var ephemeralRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [ephemeralLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 4
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    /// 限时详情虚线边框视图（116 详情框修，取代旧 CAShapeLayer 手动算矩形）：
    /// 约束钉在内容列上（顶 +6、左右内缩 8、底按正文栈底 +16），
    /// 自身 layoutSubviews 按 bounds 重画，正文栈高度落定后框底跟着走；
    /// 插在 contentColumnView 最底层，不盖内容、不拦截点按；存活期底线藏、边框代之。
    private let ephemeralBorderView: BearyDetailDashedBorderView = {
        let v = BearyDetailDashedBorderView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()
    private var imageKeys: [String] = []

    init(entry: Entry, isGuest: Bool) {
        self.entry = entry
        self.isGuest = isGuest
        // 传入的 entry 来自服务端数据，即初始确认态。
        self.confirmedLiked = entry.likedByMe ?? false
        self.confirmedLikeCount = entry.likeCount ?? 0
        self.confirmedBookmarked = entry.bookmarkedByMe ?? false
        let viewerId = SessionManager.shared.currentUser?.id
        // R22-A1：authorId 在时以它为准；isMine 只在同一已验证会话且缺
        // 作者 ID 时兜底（进页前容器 routeFetchedEntry 已验过会话）。
        if let authorId = entry.authorId {
            self.isAuthor = viewerId != nil && authorId == viewerId
        } else {
            self.isAuthor = entry.isMine == true
        }
        // R22-A1：落盘桶按进页时账号钉住（let 属性须在 super.init 前初始化）。
        self.snapshotBucket = BearyDetailCache.bucket()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        // 详情闪退诊断（2026-10-30）：进页链路审计未找到可复现的强制解包陷阱，
        // 故在进页关键点留诊断埋点（设置页诊断日志可见）：若真机崩在 present
        // 之后、viewDidLoad 之前，日志里只有 present、无 viewDidLoad；若崩在
        // 渲染之后，日志里有 rendered。埋点只写日志，不改 UI 与业务。
        DiagFile.mark("detail.viewDidLoad id=\(entry.id ?? "?")")
        view.backgroundColor = BearyColors.bg
        buildLayout()
        if entry.placeholder == true {
            showPlaceholder(visibility: entry.visibility)
        } else {
            renderAll()
            // 单篇快照：进页只记浏览（卡片/已拉数据都算看过的内容），弱网 id 直达
            // 时先显这份旧正文；旧快照的确认时间与正文一字不动。
            markDetailSnapshotViewed()
        }
        DiagFile.mark("detail.rendered id=\(entry.id ?? "?")")
        // 审计 P2-20：详情页监听拉黑/举报——页内命中时转占位（不得继续出全文）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 审计三轮第二批 9：回前台复核限时到期（后台期间定时器不触发时补位）。
        NotificationCenter.default.addObserver(self, selector: #selector(handleForegroundEphemeralCheck(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        // 已到期（打开时即过期）直接按有效态落定，未到期才排单次定时。
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    deinit {
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    /// 审计 P2-20：页内拉黑/举报后钉死的占位态——后台补齐回包不得把全文顶回来
    /// （服务端单篇拉黑过滤为后端项，App 侧先以本地钉死兜底）。
    private var locallyHiddenByModeration = false

    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int, let authorId = entry.authorId, authorId == userId else { return }
        flipToModerationPlaceholder()
    }

    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, entryId == entry.id else { return }
        flipToModerationPlaceholder()
    }

    private func flipToModerationPlaceholder() {
        locallyHiddenByModeration = true
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        entry.placeholder = true
        showPlaceholder()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 停留计时：只在首次出现时起计；其上再弹灯箱／picker 后回页不重置。
        if dwellStart == nil && !dwellReported {
            dwellStart = Date()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 只在详情本身被 dismiss 时上报与回调（其上弹灯箱／picker 不触发）。
        guard isBeingDismissed else { return }
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        reportDwell()
        if !dismissedFired, let entryId = entry.id, !entryId.isEmpty {
            dismissedFired = true
            onDismissed?(entryId)
        }
    }

    /// 深浅切换：虚线边框视图内部自刷描边色（BearyDetailDashedBorderView
    /// traitCollectionDidChange），控制器不再手动重画；小地球图标走 template +
    /// 动态灰 tint，系统自动跟随，无需重设；心情播放器内部自带 trait 重刷。
    /// 但正文内联心情附件的深浅变体仍需控制器重建：主题切换时正文末尾
    /// 心情附件需换深浅变体，否则旧心情图停留在旧色貌。
    // 深浅与字号档位变化合一（#435 与 #421 各加了一个同名 override，
    // Swift 不允许多个，合为一个）：深浅变时重建正文内联心情附件的
    // 深浅变体；字号档位变时赞数显式宽按新字号重算（refreshActionRow
    // 按 live 字体算标题宽），否则大字号下数字被旧宽裁掉；正文/标题富文本
    // 字号仍按卡片同款口径只在下次 configure 更新，不在此重排（会丢滚动位）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            bodyLabel.attributedText = detailBodyAttributedText(entry.content ?? "", moodKey: entry.mood)
        }
        guard isViewLoaded else { return }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            refreshActionRow()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 详情重做：两分支互斥整组开关（状态不变不开关，避免布局循环）。
        // 宽 ≥821 用 600 居中，宽 ≤820 用安全区宽−32；切换时重算一次。
        let wantWide = view.bounds.width >= 821
        if wantWide != columnIsWide {
            columnIsWide = wantWide
            columnNarrowLeading?.isActive = !wantWide
            columnNarrowTrailing?.isActive = !wantWide
            columnWideWidth?.isActive = wantWide
            columnWideCenterX?.isActive = wantWide
        }
        // 批 B：回应行宽 = 正文栈宽（旧详情按整列宽算，右列窄 52pt 时会少算换行、
        // 行高偏矮；现按 bodyStack 实测宽算，与首页卡片同口径）。
        let width = bodyStack.bounds.width
        guard width > 0, width != lastFlowWidth else { return }
        lastFlowWidth = width
        emoteFlowHeight?.constant = emoteFlowView.height(forWidth: width)
    }

    // MARK: - 布局

    private func buildLayout() {
        // 顶栏：只剩左上文字“关闭”（15pt 墨字），右侧不放任何图标。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 15pt；顶栏钉高 52，走 cappedFont（与许愿墙顶栏同口径），不撑破顶栏。
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 52 高顶栏不动，行为仍是 closeTapped 关页）。
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.adjustsImageWhenHighlighted = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        view.addSubview(scrollView)

        contentColumnView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentColumnView)

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .vertical
        headerStack.spacing = 0
        headerStack.alignment = .fill
        headerStack.distribution = .fill
        contentColumnView.addSubview(headerStack)

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = 0
        bodyStack.alignment = .fill
        bodyStack.distribution = .fill
        // 清单 18：中间栈透传回应行扩后热区（只认 emoteFlowView 内钮，其他行不动）。
        bodyStack.passThroughRoot = emoteFlowView
        contentColumnView.addSubview(bodyStack)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentColumnView.addSubview(separatorView)

        // 详情重做（#213 保留）：单层内容列，一条 required 等式钉死列宽，不用
        // centerX＋≥/≤ 不等式护栏，不用 750 优先级补丁等式。
        // scrollView 本身全宽，不加左右 contentInset；列宽分支：
        // ≤820 安全区宽−32（竖屏横向 inset 为 0，393 宽即 361pt 不变），≥821 宽 600 居中。
        // 窄屏列改锚 view 安全区（此前锚 scrollView frame 边缘，横屏刘海/灵动岛一侧
        // 会侵入正文列左侧 16pt 边距内）：安全区随横竖屏自动变化，无需在
        // viewDidLayoutSubviews 里另算；scrollView 已先 addSubview 到 view，
        // contentColumnView 已先挂进 scrollView，激活时已有共同祖先 view，
        // 不触 #106 式无共同祖先激活崩溃。宽屏 600 居中分支与关闭钮（已用安全区）不动。
        columnNarrowLeading = contentColumnView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        columnNarrowTrailing = contentColumnView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        columnWideWidth = contentColumnView.widthAnchor.constraint(equalToConstant: 600)
        columnWideCenterX = contentColumnView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
        columnWideWidth?.isActive = false
        columnWideCenterX?.isActive = false
        // 详情闪退加固（2026-10-30 审计）：本段此前用 4 处强制解包激活约束；
        // 约束确在上一行刚赋值、正常路径不可能为空，但进页链路是全入口共用、
        // 一旦某一路异常即全崩，故改本地常量激活、彻底去掉强制解包，行为不变。
        let narrowLeading = columnNarrowLeading
        let narrowTrailing = columnNarrowTrailing
        // 批 B：头像顶 16、头行顶 16（无 @ 行时加作者行居中偏移、有 @ 行时 17，
        // 见 updateDiaryStackSpacing；@ 行显隐的 1pt 差值保留，只改基线不改相对行为）；
        // 头行右缩进：他人 0、本人 −36（让出小地球 28 + 间隙 8；以内容列为基准，
        // 等价于首页以整屏为基准的 −52，屏上几何一致）；正文栈左右与内容列齐平、
        // 右缩进恒 0（小地球只占头行高度，正文不让位）。
        let headerTop = headerStack.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 16)
        let headerTrailing = headerStack.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor, constant: 0)
        headerStackTopConstraint = headerTop
        headerStackTrailingConstraint = headerTrailing
        // 正文栈顶（2026-11-05 日记布局统一）：取头像底与头行底较大者 + 间距。
        // 初始间距按无标题 14 取，render 时经 updateDiaryStackSpacing 按标题显隐重定；
        // 两条 required ≥ 定下限，999 的 = 把栈顶拉回头行底 + 间距（头像更高时该条自动断开）。
        // 注意：贴头像底那条约束涉 avatarButton，须等 buildCardHeader() 里
        // avatarButton 入层级后再激活（#106 同款无共同祖先崩溃），此处只建头行侧两条。
        let bodyTopFromHeader = bodyStack.topAnchor.constraint(greaterThanOrEqualTo: headerStack.bottomAnchor, constant: 14)
        bodyStackTopFromHeaderConstraint = bodyTopFromHeader
        let bodyTopPin = bodyStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14)
        bodyTopPin.priority = UILayoutPriority(999)
        bodyStackTopPinConstraint = bodyTopPin
        guard let narrowLeading = narrowLeading, let narrowTrailing = narrowTrailing else { return }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 52),
            scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentColumnView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentColumnView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            narrowLeading,
            narrowTrailing,
            headerTop,
            // 106 闪退根因（2026-10-31 .ips 实证）：本行原先在此激活，但
            // avatarButton 要到后面的 buildCardHeader() 才 addSubview 到
            // contentColumnView——激活时两端无共同祖先，NSLayoutConstraint
            // 直接抛 AutoLayout 异常 → SIGABRT，全入口进详情必崩。
            // 故本约束改到 buildCardHeader() 内、avatarButton 入层级后再激活，
            // 几何（头行左缘 = 头像右缘 + 12）一字不变。
            headerTrailing,
            bodyStack.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor),
            bodyTopFromHeader,
            bodyTopPin,
            // 2026-11-08 底线 2→1 与卡片统一（Li 定，T3-D1）：线高减 1pt，顶距 16→17 守恒，
            // 内容列总高不变；底距 -24 不动。
            separatorView.topAnchor.constraint(equalTo: bodyStack.bottomAnchor, constant: 17),
            separatorView.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 1),
            separatorView.bottomAnchor.constraint(equalTo: contentColumnView.bottomAnchor, constant: -24),
        ])

        buildCardHeader()
        buildEphemeralRow()
        buildBody()
        buildStaleBanner()
        buildImages()
        buildQuote()
        buildWeatherRow()
        buildLocation()
        buildActionRow()
        buildEmoteRow()
        buildPlaceholderState()
        // 2026-10-31：长按上下文菜单已归并进右上角 ⋯ 菜单（时间线风格），不再挂
        // UIContextMenuInteraction；管理类操作一律走 ⋯，点赞／收藏／分享仍在操作行。
    }

    /// 首页卡片头部同款：左列头像 40 + 头行（@ 行、作者行）；⋯ 钮不进作者行，
    /// 挂内容列右上角、对齐作者行（见 buildLayout 末尾外的约束，此处一次设好）。
    private func buildCardHeader() {
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = 20
        // 首页 avatarContainer 同款 line 底：无图时首字母圆透出（旧详情 faint 底已改掉）。
        avatarImageView.backgroundColor = BearyColors.line
        avatarButton.translatesAutoresizingMaskIntoConstraints = false
        avatarButton.addSubview(avatarInitialLabel)
        avatarButton.addSubview(avatarImageView)
        avatarButton.addSubview(avatarRetryButton)
        contentColumnView.addSubview(avatarButton)
        NSLayoutConstraint.activate([
            avatarInitialLabel.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarInitialLabel.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarButton.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarButton.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 28),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 28),
            avatarImageView.topAnchor.constraint(equalTo: avatarButton.topAnchor),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarButton.leadingAnchor),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarButton.trailingAnchor),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarButton.bottomAnchor),
            avatarButton.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 16),
            avatarButton.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 40),
            avatarButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        avatarButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        avatarButton.bearyAddPressFeedback()

        // 106 闪退修复：头行左缘约束必须在此激活——此前它在 buildLayout()
        // 的大激活列表里、avatarButton 尚未入层级时就被激活，必抛异常。
        // avatarButton 已在上面 addSubview 到 contentColumnView，两端现已
        // 同属 contentColumnView 层级，激活安全；几何与旧值一致（+12）。
        // 正文栈贴头像底那条 ≥ 约束同样涉 avatarButton，一并在此激活。
        let bodyTopFromAvatar = bodyStack.topAnchor.constraint(greaterThanOrEqualTo: avatarButton.bottomAnchor, constant: 14)
        bodyStackTopFromAvatarConstraint = bodyTopFromAvatar
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: avatarButton.trailingAnchor, constant: 12),
            bodyTopFromAvatar,
        ])

        // @ 行：有 mentionedName 才显（见 renderHeaderMeta），点按进被 @ 者主页。
        recipientRow.isUserInteractionEnabled = true
        recipientRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mentionTapped)))
        headerStack.addArrangedSubview(recipientRow)

        // 118 闪退修复（.ips 实证）：作者行必须是懒初始化的 authorRow，
        // 它的 arrangedSubviews（nameButton、crownWrapView 等）只有在
        // authorRow 首次被访问时才入层级。下面皇冠块里有一条跨视图约束
        // crownWrapView.height == nameButton.height，若 authorRow 在此之前
        // 从未被访问，两端在激活时无共同祖先，NSLayoutConstraint 直接抛
        // 异常 → SIGABRT，全入口进详情必崩（与 106 同类）。故 authorRow
        // 必须在此先入栈（顺序不变：仍在 recipientRow 之后、⋯ 钮之前），
        // 让两端先同属 authorRow 层级，再激活皇冠约束才安全。
        headerStack.addArrangedSubview(authorRow)

        nameButton.titleLabel?.font = BearyDynamicType.cardTitleFont()
        nameButton.titleLabel?.adjustsFontForContentSizeCategory = true
        nameButton.titleLabel?.numberOfLines = 1
        nameButton.titleLabel?.lineBreakMode = .byTruncatingTail
        nameButton.setTitleColor(BearyColors.ink, for: .normal)
        nameButton.setTitleColor(BearyColors.ink, for: .highlighted)
        nameButton.contentHorizontalAlignment = .left
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        nameButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        nameButton.bearyAddPressFeedback()
        // 详情页皇冠无辉光（辉光仅首页 feed 卡片，见 CardCell 的 cardMode == .feed 门控）。
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        crownView.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownWrapView.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 皇冠在等高容器内居中（容器底边钉基线，中心即 cap 中心）。
        crownWrapView.addSubview(crownView)
        let crownWrapWidth = crownWrapView.widthAnchor.constraint(equalToConstant: 19)
        crownWrapWidth.priority = UILayoutPriority(999)
        let crownWrapHeight = crownWrapView.heightAnchor.constraint(equalTo: nameButton.heightAnchor)
        crownWrapHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            crownView.centerXAnchor.constraint(equalTo: crownWrapView.centerXAnchor),
            crownView.centerYAnchor.constraint(equalTo: crownWrapView.centerYAnchor),
            crownWrapWidth,
            crownWrapHeight,
        ])
        // 天气图标在包内居中（15×15 盒固定，图标在盒内居中；盒不再与
        // timeLabel 等高，天气行高由气温标签字号定）。
        weatherWrapLabel.addSubview(weatherImageView)
        NSLayoutConstraint.activate([
            weatherImageView.centerXAnchor.constraint(equalTo: weatherWrapLabel.centerXAnchor),
            weatherImageView.centerYAnchor.constraint(equalTo: weatherWrapLabel.centerYAnchor),
            weatherImageView.widthAnchor.constraint(equalToConstant: 15),
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
        ])
        weatherWrapLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 隐藏子视图的固定尺寸用 999 优先级，避免与 stack 压零冲突（首页同款）。
        let recipientIconHeight = recipientIconView.heightAnchor.constraint(equalToConstant: 13)
        recipientIconHeight.priority = UILayoutPriority(999)
        let crownWidth = crownView.widthAnchor.constraint(equalToConstant: 19)
        crownWidth.priority = UILayoutPriority(999)
        let weatherWidth = weatherWrapLabel.widthAnchor.constraint(equalToConstant: 15)
        weatherWidth.priority = UILayoutPriority(999)
        let weatherWrapHeight = weatherWrapLabel.heightAnchor.constraint(equalToConstant: 15)
        weatherWrapHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            recipientIconView.widthAnchor.constraint(equalToConstant: 13),
            recipientIconHeight,
            crownWidth,
            crownView.heightAnchor.constraint(equalToConstant: 19),
            weatherWidth,
            weatherWrapHeight,
        ])
        // authorRow 入栈已移到皇冠块之前（见上，118 闪退修复），此处不再重复添加。
        // 右上角 ⋯ 钮：时间线 moreButton 同款（21pt 灰色、28 框、44 热区），图标恒为三点。
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setImage(BearyFeedIconCache.image(named: "icon_more", pointSize: 24), for: .normal)
        moreButton.tintColor = BearyColors.gray
        moreButton.adjustsImageWhenHighlighted = false
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        moreButton.accessibilityLabel = "更多操作"
        moreButton.bearyAddPressFeedback()
        contentColumnView.addSubview(moreButton)
        NSLayoutConstraint.activate([
            moreButton.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: authorRow.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            moreButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func buildEphemeralRow() {
        // 限时倒计时行：只留倒计时灰字，位置在作者行下方、标题上方（与卡片同口径）；
        // 虚线边框视图挂 contentColumnView 最底层，约束钉住内容列矩形
        // （顶 +6、左右内缩 8、底按正文栈底 +16），正文栈高度一变框就跟着变，
        // 不再依赖布局时手动算矩形的旧时机（旧时机下回应行高度落定后框底
        // 仍停在旧位置，正好切穿“＋”回应钮）。
        headerStack.addArrangedSubview(ephemeralRow)
        contentColumnView.insertSubview(ephemeralBorderView, at: 0)
        NSLayoutConstraint.activate([
            ephemeralBorderView.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 6),
            ephemeralBorderView.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor, constant: 8),
            ephemeralBorderView.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor, constant: -8),
            ephemeralBorderView.bottomAnchor.constraint(equalTo: bodyStack.bottomAnchor, constant: 16),
        ])
    }

    /// 第 22 轮 C2：失败横幅挂正文栈首行（作者头行正下方、标题上方）；
    /// 隐藏时栈自动压零，不留空隙、不动其余间距。
    private func buildStaleBanner() {
        bodyStack.insertArrangedSubview(staleBannerView, at: 0)
    }

    private func buildBody() {
        bodyStack.addArrangedSubview(titleLabel)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping
        bodyLabel.textColor = BearyColors.ink
        bodyStack.addArrangedSubview(bodyLabel)
    }

    private func buildImages() {
        bodyStack.addArrangedSubview(imagesScrollView)
        imagesScrollView.addSubview(imagesStack)
        let imageHeight = imagesScrollView.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint = imageHeight
        NSLayoutConstraint.activate([
            imageHeight,
            imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
            imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
            imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
            imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
            imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
        ])
        makeImageSlots()
    }

    /// 首页 94 包槽位复用：9 只槽位一次建好（条目图片上限 9 张），renderImages
    /// 只改图／宽／显隐，不销毁重建；每槽位带 Feed 口径重试钮。
    private func makeImageSlots() {
        guard imageSlots.isEmpty else { return }
        for index in 0..<9 {
            let slot = UIImageView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.backgroundColor = BearyColors.line
            slot.contentMode = .scaleAspectFill
            slot.clipsToBounds = true
            slot.layer.cornerRadius = 12
            slot.isUserInteractionEnabled = true
            slot.tag = index
            slot.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
            slot.isHidden = true
            let liveView = BearyLivePhotoView(contentMode: .aspectFill)
            slot.addSubview(liveView)
            NSLayoutConstraint.activate([
                liveView.topAnchor.constraint(equalTo: slot.topAnchor),
                liveView.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                liveView.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                liveView.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            ])
            imageSlotLiveViews.append(liveView)
            imageSlotLivePresses.append(nil)
            imagesStack.addArrangedSubview(slot)
            let widthConstraint = slot.widthAnchor.constraint(equalToConstant: 280)
            // 隐藏槽位时 UIStackView 的 UISV-hiding 约束需压过槽位宽度：
            // 宽约束降到 999（仍主导宽度、捏合改 constant 不受影响），
            // 高度约束不动。
            widthConstraint.priority = UILayoutPriority(999)
            imageSlotWidthConstraints.append(widthConstraint)
            NSLayoutConstraint.activate([
                widthConstraint,
                slot.heightAnchor.constraint(equalToConstant: 216),
            ])
            let retry = bearyFeedRetryButton(target: self, action: #selector(detailImageRetryTapped(_:)))
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
        installImageStripPinch()
    }

    /// 天气行（左下角、正文区下面、位置行之前）：图标 15 + 气温，左对齐；
    /// 无天气数据时整行隐藏、不占位（显隐由 renderWeatherTemp 末尾同步）。
    private func buildWeatherRow() {
        bodyStack.addArrangedSubview(weatherRow)
    }

    /// 批 E 详情位置行（rebase 落点：新骨架正文栈 bodyStack，天气行之后、操作行之前；
    /// 旧详情挂在 chips 行后、引用卡之前，批 B 已删 chips 行与旧 stackView，故改挂正文栈）：
    /// 官方 icon_location 13 灰 + 位置文案；公开篇作者本人也只看区级，不再另附提示行；
    /// 无位置/他人视角无区级/公开篇无区级时整组隐藏，不留空行（与卡片同口径）。
    private func buildLocation() {
        bodyStack.addArrangedSubview(detailLocationStack)
        NSLayoutConstraint.activate([
            detailLocationIconView.widthAnchor.constraint(equalToConstant: 13),
            detailLocationIconView.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    private func buildQuote() {
        quoteView.translatesAutoresizingMaskIntoConstraints = false
        // 引用卡点按走共享卡 onTapped（卡片内手势 + 来源行按钮同一路，见 BearyQuoteCardView）；
        // gone/locked 不导航的守卫仍在 quoteTapped 内，不凭渲染快照放行。
        quoteView.onTapped = { [weak self] in self?.quoteTapped() }
        bodyStack.addArrangedSubview(quoteView)
    }

    private func buildActionRow() {
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.spacing = 16
        actionStack.alignment = .center

        likeButton.translatesAutoresizingMaskIntoConstraints = false
        likeButton.titleLabel?.font = BearyDynamicType.tabularDigitsFont(ofSize: 14)
        // 扫查组：此前 scaledFont 却缺 adjusts，档位变化时赞数字号不跟、
        // 显式宽也不重算；补 adjusts，宽重算见 traitCollectionDidChange。
        likeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.adjustsImageWhenHighlighted = false
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        likeButton.addTarget(self, action: #selector(likePressDown), for: .touchDown)
        likeButton.addTarget(self, action: #selector(likePressCancelled), for: [.touchUpOutside, .touchCancel])
        likeButton.bearyAddPressFeedback()
        // 显式宽约束（卡片同款，见 likeButtonWidthConstraint 注释）：初始只图标宽，
        // refreshActionRow 按赞数重算；不靠按钮固有宽，防数字被裁成左半弧。
        let likeWidth = likeButton.widthAnchor.constraint(equalToConstant: 24)
        likeWidth.isActive = true
        likeButtonWidthConstraint = likeWidth

        // 批 B：收藏／分享均为纯图标（首页同款，收藏去中文标签）；尺寸 21。
        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        bookmarkButton.adjustsImageWhenHighlighted = false
        bookmarkButton.setImage(BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 24), for: .normal)
        bookmarkButton.tintColor = BearyColors.gray
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        bookmarkButton.bearyAddPressFeedback()

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.adjustsImageWhenHighlighted = false
        shareButton.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 24), for: .normal)
        shareButton.tintColor = BearyColors.gray
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        shareButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            bookmarkButton.widthAnchor.constraint(equalToConstant: 24),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 24),
            shareButton.widthAnchor.constraint(equalToConstant: 24),
            shareButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // 收藏紧邻点赞右侧（首页 actionStack 同款）：顺序 [点赞， 收藏，
        // spacer， 分享， 占位 spacer]；中部 spacer 吸掉全部剩余宽度，分享
        // 仍钉右缘。点赞—收藏间距 BearySpace.xxl（24，规范 §3）：两钮框
        // 均为 24，BearyHit44Button 各向外扩 10，24 间距留 4pt 热区间隙、
        // 严格不交（详情栈是普通 UIStackView、没有卡片的 hitTest 兜底，
        // 更不能用 16）；其余间距仍栈 spacing 16，被 spacer 吸收。
        let actionSpacer = UIView()
        actionSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        actionStack.addArrangedSubview(likeButton)
        actionStack.addArrangedSubview(bookmarkButton)
        actionStack.addArrangedSubview(actionSpacer)
        actionStack.addArrangedSubview(shareButton)
        actionStack.addArrangedSubview(shareSlotSpacer)
        actionStack.setCustomSpacing(BearySpace.xxl, after: likeButton)
        bodyStack.addArrangedSubview(actionStack)

        // 游客提示条：与卡片游客展开态同文案，点按走登录提示；整行 44pt 可点。
        guestPromptButton.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 15pt；本行钉高 44，走 cappedFont，不撑破行高。
        guestPromptButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
        guestPromptButton.titleLabel?.adjustsFontForContentSizeCategory = true
        guestPromptButton.setTitle("登录后可点赞、回应、收藏 ›", for: .normal)
        guestPromptButton.setTitleColor(BearyColors.gray, for: .normal)
        guestPromptButton.setTitleColor(BearyColors.gray, for: .highlighted)
        guestPromptButton.contentHorizontalAlignment = .left
        guestPromptButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        guestPromptButton.addTarget(self, action: #selector(guestPromptTapped), for: .touchUpInside)
        guestPromptButton.bearyAddPressFeedback()
        bodyStack.addArrangedSubview(guestPromptButton)
    }

    private func buildEmoteRow() {
        // 回应行：首页同款——操作行下方流式 chip 行 + 行末 34 虚线 + 钮，
        // 不再设“回应”标题行与“写回应…”实心钮；行高由 emoteFlowHeight 驱动。
        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(emoteFlowView)
        emoteFlowHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteFlowHeight?.isActive = true
    }

    /// 首页 updateDiaryStackSpacing 同款对照表（详情无折叠钮，故正文后恒取 14）：
    /// @→作者 4、作者→限时 4；头行→正文栈 16（有标题）/ 14（无标题），由正文栈顶
    /// 三条约束定（见 buildLayout／buildCardHeader）；标题→正文 6（标题隐藏时 0）、
    /// 正文→图片 14、图片→引用 12、引用→定位 12、定位→操作行 14、操作行→回应行 12；
    /// 批 E 位置行插在引用卡与操作行之间（无位置时整组隐藏、不留空行）；
    /// 头行顶：无 @ 行 16、有 @ 行 17。
    private func updateDiaryStackSpacing() {
        // 作者行顶部统一 16（2026-11-05 ChatGPT 间距跟进）：@ 行显隐的 1pt
        // 差值保留（16／17），只改基线不改相对行为。
        // 名字行偏下（卡片同款，126 真机实测：整行 authorRow 被往下顶，
        // 时间比头像中心低约 11.5pt）：隐藏的 @ 行尾随 4pt 间距仍占位。
        // 隐藏时归零，显示时恢复；@ 行藏时作者行与头像（40 高、顶 16）
        // 垂直居中，作者行高取名字字体行高（动态字号变大时偏移跟着缩小）。
        headerStackTopConstraint?.constant = recipientRow.isHidden ? 16 + (40 - BearyDynamicType.cardTitleFont().lineHeight) / 2 : 17
        headerStack.setCustomSpacing(recipientRow.isHidden ? 0 : 4, after: recipientRow)
        headerStack.setCustomSpacing(4, after: authorRow)
        // 2026-11-05 日记布局统一：头行→正文栈间距不再走栈内 spacing，
        // 改由正文栈顶三条约束定——有标题 16、无标题 14（ChatGPT 间距跟进，
        // 在 #904 的 12／8 基础上放宽）；限时行是头行末行，其后间距即该值。
        let headerBodyGap: CGFloat = titleLabel.isHidden ? 14 : 16
        bodyStackTopFromAvatarConstraint?.constant = headerBodyGap
        bodyStackTopFromHeaderConstraint?.constant = headerBodyGap
        bodyStackTopPinConstraint?.constant = headerBodyGap
        // 失败横幅→标题 12：横幅隐藏时栈自动忽略，不留空隙。
        bodyStack.setCustomSpacing(12, after: staleBannerView)
        // 标题贴着正文走：标题→正文 6（ChatGPT 间距跟进，#904 为 4）；标题隐藏时其后间距置 0，正文直接贴头行间距。
        bodyStack.setCustomSpacing(titleLabel.isHidden ? 0 : 6, after: titleLabel)
        // 正文→图片 14（ChatGPT 间距跟进，#904 为 10）：正文与图片条直接相邻。
        bodyStack.setCustomSpacing(14, after: bodyLabel)
        // 图片→定位 12（ChatGPT 间距跟进）：图片条与定位行中间隔着引用卡与
        // 天气行，三段相邻间距（图片→引用、引用→天气、天气→定位）各取 12。
        bodyStack.setCustomSpacing(12, after: imagesScrollView)
        bodyStack.setCustomSpacing(12, after: quoteView)
        bodyStack.setCustomSpacing(12, after: weatherRow)
        // 定位→操作行 14（ChatGPT 间距跟进，#904 为 10）。
        bodyStack.setCustomSpacing(14, after: detailLocationStack)
        // 操作行→回应行 12（ChatGPT 间距跟进，#904 为 10）。
        bodyStack.setCustomSpacing(12, after: actionStack)
        bodyStack.setCustomSpacing(12, after: guestPromptButton)
    }

    /// 内容区（头像 + 头行 + 正文栈 + 小地球 + 底线）整体显隐：占位／失败态整藏，
    /// 恢复时小地球显隐与头行缩进由 refreshAuthorActions、底线显隐由
    /// refreshEphemeralViews 按限时态重算（不由本函数定）。
    private func setContentVisible(_ visible: Bool) {
        avatarButton.isHidden = !visible
        headerStack.isHidden = !visible
        bodyStack.isHidden = !visible
        if visible {
            refreshAuthorActions()
            refreshEphemeralViews()
        } else {
            moreButton.isHidden = true
            separatorView.isHidden = true
        }
    }

    private func buildPlaceholderState() {
        placeholderStateView.translatesAutoresizingMaskIntoConstraints = false
        placeholderStateView.isHidden = true
        // 占位不进右列：整页居中只显一句（mock 私密占位屏同款）。
        // 审计 P1-2：左右各留至少 24pt 边界、多行居中，锚在安全区内居中；
        // BearyStateView 副文案本身多行居中（numberOfLines = 0）。
        // 失败态与占位共用本视图布局，一并受益，不另起一套。
        view.addSubview(placeholderStateView)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            placeholderStateView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            placeholderStateView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            placeholderStateView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 24),
            placeholderStateView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - 渲染

    /// 审计 2026-11-02 第十节：占位文案按回包 visibility 区分——friends 显仅好友句，
    /// private 显私密句；无字段（nil）时显通用占位“该日记不可见”，不误标为私密。
    /// 拉黑/举报本地转占位仍走默认私密句（调用方不传参， moderation 占位口径不变）。
    private func showPlaceholder(visibility: String? = "private") {
        // 私密占位：仅一句文案，不带标题／封面／时间／作者名；内容栈整藏。
        // 文案每次显式配齐：同一视图多态共用，配齐防串味。
        // 副文案灰色多行居中（原 16pt 灰字 → 组件 12.5pt 灰色副文案，统一组件口径）；
        // 无插图、无动作钮（关闭重进即重试的约定不变）。
        let subtitle: String
        switch visibility {
        case "friends": subtitle = "该日记仅好友可见"
        case nil: subtitle = "该日记不可见"
        default: subtitle = "该日记已设为私密"
        }
        placeholderStateView.configure(kind: .empty, title: nil, subtitle: subtitle, iconName: nil, actionTitle: nil)
        setContentVisible(false)
        placeholderStateView.isHidden = false
    }

    /// 2026-11-05 Li 定（推翻 2026-10-29「失败清内容」）：后台补齐失败时
    /// 保留已显示的卡片旧内容，只给轻提示。
    /// 第 22 轮 C2：正文仍可读时，失败态留在详情头部（常驻横幅＋重试入口），
    /// 不再只弹 toast；无可读内容（占位）时仍走 toast（无“上次的内容”可留）。
    /// 页内已因拉黑/举报转占位时不动（隐私占位优先于失败态）。
    /// B1：详情取数统一裁决——首开补拉与手动重试共用（与 routeFetchedEntry 同口径）。
    enum DetailFetchDecision {
        case show(Entry)
        case showPlaceholder(Entry)
        case keepContent
    }

    /// B1：拉黑作者判定（作者本人永不命中；游客不承接拉黑表；与 SceneDelegate 同口径）。
    static func isBlockedAuthor(_ entry: Entry) -> Bool {
        if SessionManager.shared.isGuestMode { return false }
        guard let authorId = entry.authorId else { return false }
        if let viewerId = SessionManager.shared.currentUser?.id, viewerId == authorId { return false }
        return BearyBlockedStore.isBlocked(authorId)
    }

    /// B1：取数失败分流——明确无权限/找不到即已不可见（撤下全文）；
    /// 其余（弱网/服务端错/解码失败）沿用旧内容（见 showFetchFailed）。
    /// 401 不在此列：会话失效走全局未登录处理，旧内容先保留。
    static func isExplicitlyGone(_ error: APIError) -> Bool {
        if case .notFound = error { return true }
        return error.isPermissionDenied
    }

    /// B1：详情取数成功回包的统一裁决（首开补拉 gotoEntryImmediately 与
    /// 手动重试 retryFetchDetail 共用；与 routeFetchedEntry 同口径）：
    /// 作者直更、占位直更、拉黑转占位、有效公开直更、仅好友走服务端互关
    /// 校验、私密或过期公开转占位、公开但定不出作者保留旧内容。
    /// 仅好友档需一次互关请求，裁决经 completion 异步返回（主线程）。
    static func decideFetchedDetail(_ fetched: Entry, completion: @escaping (DetailFetchDecision) -> Void) {
        let viewerId = SessionManager.shared.currentUser?.id
        // R22-A1（#1108）：authorId 在时以它为准；isMine 只在缺作者 ID 时兜底——
        // 旧会话的 isMine=true 绝不能给新账号放行私密篇。
        let viewerIsAuthor: Bool
        if let authorId = fetched.authorId {
            viewerIsAuthor = viewerId != nil && authorId == viewerId
        } else {
            viewerIsAuthor = fetched.isMine == true
        }
        if viewerIsAuthor {
            completion(.show(fetched))
            return
        }
        if isBlockedAuthor(fetched) {
            var placeholderEntry = fetched
            placeholderEntry.placeholder = true
            completion(.showPlaceholder(placeholderEntry))
            return
        }
        if BearyEphemeral.isEffectivelyPublic(fetched), fetched.authorId != nil {
            completion(.show(fetched))
            return
        }
        if fetched.placeholder == true {
            completion(.show(fetched))
            return
        }
        if fetched.isFriendsOnly, let authorId = fetched.authorId, SessionManager.shared.isLoggedIn {
            BearyAPI.shared.fetchFollowState(userId: authorId) { stateResult in
                DispatchQueue.main.async {
                    switch stateResult {
                    case .success(let state)
                        where (state.mutual ?? false) || ((state.following ?? false) && (state.followedBy ?? false)):
                        completion(.show(fetched))
                    default:
                        var placeholderEntry = fetched
                        placeholderEntry.placeholder = true
                        completion(.showPlaceholder(placeholderEntry))
                    }
                }
            }
            return
        }
        if fetched.isPublic == true {
            if fetched.authorId != nil {
                // stored 公开但已过期：有效态为私密，切占位（不留卡片旧全文）。
                var placeholderEntry = fetched
                placeholderEntry.placeholder = true
                completion(.showPlaceholder(placeholderEntry))
            } else {
                // 公开但定不出作者：保留旧内容。
                completion(.keepContent)
            }
            return
        }
        var placeholderEntry = fetched
        placeholderEntry.placeholder = true
        completion(.showPlaceholder(placeholderEntry))
    }

    func showFetchFailed() {
        if locallyHiddenByModeration { return }
        if entry.placeholder != true {
            showStaleBanner()
            return
        }
        BearyToast.show(in: view, message: "加载失败，请稍后再试", actionTitle: "重试", action: { [weak self] in self?.retryFetchDetail() })
    }

    /// B1：回包/失败已明确本篇不可见（无权限/找不到）时撤下全文：
    /// 模型立占位旗、内容栈整藏、显过渡占位“这篇日记现在看不到了”。
    /// 弱网失败不走这里（见 showFetchFailed，保留旧内容）。
    func showBecameInvisible() {
        if locallyHiddenByModeration { return }
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        entry.placeholder = true
        placeholderStateView.configure(kind: .empty, title: nil, subtitle: "这篇日记现在看不到了", iconName: nil, actionTitle: nil)
        setContentVisible(false)
        placeholderStateView.isHidden = false
    }

    /// 第 22 轮 C2：失败横幅显现（常驻，直到补齐成功）。已在显时只恢复
    /// 可点按态（重试失败回来），不重播出现动效。顶部多出一条时保住阅读
    /// 位置：在顶时不补，横幅把内容往下推、本就是要让用户看到它。
    private func showStaleBanner() {
        guard !locallyHiddenByModeration, entry.placeholder != true else { return }
        if staleBannerVisible {
            setStaleBannerRetrying(false)
            return
        }
        staleBannerVisible = true
        setStaleBannerRetrying(false)
        let beforeHeight = scrollView.contentSize.height
        staleBannerView.isHidden = false
        staleBannerView.alpha = 0
        view.layoutIfNeeded()
        let grown = scrollView.contentSize.height - beforeHeight
        if grown > 0, scrollView.contentOffset.y > 0 {
            scrollView.contentOffset.y += grown
        }
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.staleBannerView.alpha = 1
        })
    }

    /// 第 22 轮 C2：补齐成功后横幅 0.18 秒淡出（BearyMotion.localStateDuration），
    /// 再收起；收起后内容上移，同步回补 offset，读到的位置不动（在顶时不补）。
    private func hideStaleBanner() {
        guard staleBannerVisible else { return }
        staleBannerVisible = false
        setStaleBannerRetrying(false)
        let beforeHeight = scrollView.contentSize.height
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.staleBannerView.alpha = 0
        }, completion: { _ in
            self.staleBannerView.isHidden = true
            self.staleBannerView.alpha = 1
            self.view.layoutIfNeeded()
            let shrunk = beforeHeight - self.scrollView.contentSize.height
            if shrunk > 0, self.scrollView.contentOffset.y > 0, !self.bodyStack.isHidden {
                let maxOffset = max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
                self.scrollView.contentOffset.y = min(max(0, self.scrollView.contentOffset.y - shrunk), maxOffset)
            }
        })
    }

    /// 第 22 轮 C2：横幅重试——重试中只更新这条（按钮置灰、“重试中”），
    /// 正文与其它区域一字不动；成功由 update(with:) 收横幅，失败回横幅可点按态。
    @objc private func staleBannerRetryTapped() {
        guard !staleBannerRetrying, !locallyHiddenByModeration else { return }
        setStaleBannerRetrying(true)
        retryFetchDetail()
    }

    private func setStaleBannerRetrying(_ retrying: Bool) {
        staleBannerRetrying = retrying
        staleBannerRetryButton.isEnabled = !retrying
        staleBannerRetryButton.setTitle(retrying ? "重试中" : "重试", for: .normal)
    }

    /// 详情失败重试：与 SceneDelegate 后台补齐同一可见性门（作者直更、
    /// 占位直更、拉黑转占位、公开且作者可定直更、公开但定不出作者不动、
                        // 轻提示，toast 重试钮仍在。
    /// 内容始终保留，不回全页失败态。
    private func retryFetchDetail() {
        guard !locallyHiddenByModeration, let entryId = entry.id, !entryId.isEmpty else {
            showFetchFailed()
            return
        }
        // R22-A1：发起时固定账号与会话代次（只读 BearyAPI.shared.authEpoch／
        // authAccountId，不动 SessionManager 私有成员；传输层不丢弃成功回包，
        // 比对只在调用方做）。回包先复核会话与日记 ID 再展示／落盘。
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // B3：发补拉时记下各互动字段当前值；回包合并时只合并期间没有变化的字段。
        let retryBaseline = captureSupplementBaseline()
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // R22-A1：切号后旧回包直接丢弃，不更新、不写盘、不 toast。
                guard requestEpoch == BearyAPI.shared.authEpoch,
                      requestAccountId == BearyAPI.shared.authAccountId,
                      requestAccountId == SessionManager.shared.currentUser?.id else { return }
                switch result {
                case .failure(let error):
                    // B1：明确无权限/找不到即撤下全文；弱网等失败保留旧内容＋轻提示。
                    if Self.isExplicitlyGone(error) {
                        self.showBecameInvisible()
                    } else {
                        self.showFetchFailed()
                    }
                    return
                case .success(let fetched):
                    guard fetched.id == entryId else { return }
                    if self.locallyHiddenByModeration { return }
                    // B1：与首开补拉同一裁决（有效公开＋互关；仅好友仍有权限时可恢复）。
                    Self.decideFetchedDetail(fetched) { [weak self] decision in
                        guard let self = self else { return }
                        // R22-A1：互关校验是异步回包，裁决到达时再验一次会话；
                        // 旧会话的结论不得写进新账号页面。
                        guard requestEpoch == BearyAPI.shared.authEpoch,
                              requestAccountId == BearyAPI.shared.authAccountId,
                              requestAccountId == SessionManager.shared.currentUser?.id else { return }
                        switch decision {
                        case .show(let updatedEntry):
                            self.update(with: updatedEntry, baseline: retryBaseline)
                        case .showPlaceholder(let placeholderEntry):
                            self.update(with: placeholderEntry, baseline: retryBaseline)
                        case .keepContent:
                            // 公开但定不出作者：保留旧内容，回到失败轻提示，toast 重试钮仍在。
                            self.showFetchFailed()
                        }
                    }
                }
            }
        }
    }

    private func renderAll() {
        setContentVisible(true)
        renderHeaderMeta()
        refreshVisibilityViews()
        refreshEphemeralViews()
        refreshAuthorActions()

        // 审计 P2-12：标题行（卡片同款，空标题不占位；详情全文页放开换行，
        // 首页单行截断是唯一偏离，见文件头）。
        let trimmedTitle = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.attributedText = trimmedTitle.isEmpty ? nil : BearyText.inlineAttributedText(from: trimmedTitle, font: BearyDynamicType.cardTitleFont(), color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark)
        titleLabel.isHidden = trimmedTitle.isEmpty

        // 正文 16pt（diaryBodyFont 即 scaled 16），行高 1.6（首页卡片口径）。
        // 旧心情改位：心情缀正文末尾（见 detailBodyAttributedText）。
        bodyLabel.attributedText = detailBodyAttributedText(entry.content ?? "", moodKey: entry.mood)
        bodyLabel.isHidden = (entry.content ?? "").isEmpty && (entry.mood ?? "").isEmpty

        renderImages()
        renderLocation()
        renderQuote()
        refreshActionRow()
        renderEmotes()
        updateDiaryStackSpacing()
    }

    /// 首页卡片头部渲染同款：头像（含首字母兜底）+ @ 行 + 名／徽章／皇冠／
    /// 时间（绝对时间 M月d日 H:mm，小时不补零；详情不跟首页的相对时间口径，
    /// 见预览映射表）+ 天气 15 图标 + 心情（20 熊图 + 13 灰字）。
    /// 空项一律隐藏、不留空位；心情 key 不变时复用播放器（深浅由其内部切换）。
    /// 旧日记心情改位：心情不再单独贴在作者行，改跟在正文最后一个字
    /// 后面——用静态熊图附件直接缀在正文 attributed 串末尾（紧贴末字、
    /// 无空格）；无心情时原样返回；正文为空且有心情时只显附件。
    /// 深浅变体按当前 trait 取，主题切换时由 trait handler 重建正文。
    private func detailBodyAttributedText(_ content: String, moodKey: String?) -> NSAttributedString {
        let font = BearyDynamicType.diaryBodyFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        paragraph.lineBreakMode = .byCharWrapping
        // 内联心情：正文里的记号先转回熊脸附件（与编辑器同一中间层）。
        let base = BearyText.inlineAttributedText(from: content, font: font, color: BearyColors.ink, paragraphStyle: paragraph, dark: traitCollection.userInterfaceStyle == .dark)
        guard let key = moodKey, !key.isEmpty,
              let image = BearyEmoteImages.image(for: key, dark: traitCollection.userInterfaceStyle == .dark) else { return base }
        let attachment = NSTextAttachment()
        attachment.image = image
        let emoteSize = font.pointSize * 1.2
        attachment.bounds = CGRect(x: 0, y: font.descender, width: emoteSize, height: emoteSize)
        let result = NSMutableAttributedString(attributedString: base)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private func renderHeaderMeta() {
        // 32 注销口径：作者已注销时显“用户已注销”，头像首字母同步为“用”。
        let authorNameValue = bearyDeletedAuthorDisplayName(entry.authorName) ?? "beary 用户"
        nameButton.setTitle(authorNameValue, for: .normal)
        avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        if let createdAt = entry.createdAt {
            timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
            // 审计 11：URL 不变且已有图时保留当前图片，不重走加载流程；
            // 在途任务不被取消、已图不被清掉。URL 变了、或上次加载已失败
            // （无图且重试钮已亮）时才重新加载；在途（无图、重试钮未亮）
            // 时不打断，让原任务自然完成。
            if lastRenderedAvatarURL != url || (avatarImageView.image == nil && !avatarRetryButton.isHidden) {
                bearyFeedLoadImage(into: avatarImageView, url: url, retryButton: avatarRetryButton, downsampleToWidth: 80)
                lastRenderedAvatarURL = url
            }
        } else {
            if lastRenderedAvatarURL != nil || avatarImageView.image != nil {
                avatarImageView.bearySetImage(url: nil)
                avatarRetryButton.isHidden = true
                avatarRetryButton.retryURL = nil
                lastRenderedAvatarURL = nil
            }
        }
        if let mentioned = entry.mentionedName, !mentioned.isEmpty {
            recipientRow.isHidden = false
            // 32 注销口径：被 @ 者已注销时显“@用户已注销”。
            recipientLabel.text = "@" + (bearyDeletedAuthorDisplayName(mentioned) ?? mentioned)
        } else {
            recipientRow.isHidden = true
            recipientLabel.text = nil
        }
        // Plus 皇冠按 authorPlus 显示（徽章已下线摘掉，皇冠不受影响）。
        setCrownHidden((entry.authorPlus ?? 0) != 1 || !crownView.hasCrown)
        renderWeatherTemp()
        moodStack.isHidden = true
        moodLabel.text = nil
        moodEmoteView?.removeFromSuperview()
        moodEmoteView = nil
    }

    /// 天气动态图标：底层静态图作 fallback（卡片落点行 playWeatherLottie 同款）。
    private func playWeatherLottie() {
        guard let weatherKey = entry.weather, !weatherKey.isEmpty, weatherImageView.isHidden == false else {
            stopWeatherLottie()
            return
        }
        let lottieKey = BearyText.weatherLottieKey(for: weatherKey)
        if let existing = weatherEmoteView, existing.superview === weatherImageView, existing.emoteKey == lottieKey {
            existing.play()
            return
        }
        stopWeatherLottie()
        guard let fallback = weatherImageView.image else { return }
        let overlay = BearyEmoteView(key: lottieKey, animated: true, fallbackImage: fallback)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        weatherImageView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: weatherImageView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: weatherImageView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: weatherImageView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: weatherImageView.bottomAnchor),
        ])
        weatherEmoteView = overlay
    }

    private func stopWeatherLottie() {
        weatherEmoteView?.stop()
        weatherEmoteView?.removeFromSuperview()
        weatherEmoteView = nil
    }

    /// 天气图标 + 气温标签（renderHeaderMeta 的一部分，审计 4/11 抽出）：
    /// 只变天气/气温时，后台补齐路径只调这里，不重走整段头部（含头像）。
    private func renderWeatherTemp() {
        // 复用／重刷先停旧播放器（卡片 configure 同款），再按新天气重建。
        stopWeatherLottie()
        if let weatherKey = entry.weather, !weatherKey.isEmpty,
           let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + BearyText.weatherStaticKey(for: weatherKey), pointSize: 15) {
            weatherImageView.image = weatherImage
            weatherImageView.isHidden = false
            weatherWrapLabel.isHidden = false
            // 天气图标改动态 Lottie（卡片落点行同款）。
            playWeatherLottie()
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
            weatherWrapLabel.isHidden = true
        }
        // 气温跟天气图标走同一处（卡片同款门：有气温且有天气类型才显）。
        // #427 的气温显示保留；作者行心情位按 #421 新模型一律隐藏，
        // 心情缀正文末尾（见 detailBodyAttributedText），不恢复旧心情位。
        if let temp = entry.temperatureC, entry.weather != nil, !entry.weather!.isEmpty {
            weatherTempLabel.text = "\(temp)°"
            weatherTempLabel.isHidden = false
        } else {
            weatherTempLabel.text = nil
            weatherTempLabel.isHidden = true
        }
        // 天气行显隐跟图标走：图标与气温全无时整行隐藏、不占位。
        weatherRow.isHidden = weatherWrapLabel.isHidden && weatherTempLabel.isHidden
    }


    /// 2026-10-29 第 17 项：后台补齐入口——卡片点按即时呈现后，后台 fetch 回包调它。
    /// 只更新变化处（字段级比对，变了才刷对应区），不重建栈、不重播已有元素的
    /// 动效、不闪 skeleton；弱网/失败时不调本函数，改走 showFetchFailed（保留旧内容＋轻提示）。
    /// 审计三轮第二批 10：按字段合并，不再整体覆盖——在途乐观互动的字段
    /// （点赞 likedByMe/likeCount、收藏 bookmarkedByMe/bookmarkCount、回应 emotes、
    /// 可见性 isPublic/publishedAt/ephemeralUntil）保留本地值，模型不再被回包
    /// 冲掉；第二条刷新路径（互动成功回包、onInteractionChanged 同步等）读到的
    /// 仍是先行态，而非已被覆盖的服务端旧值。字段级比对以合并后模型为准，
    /// 在途字段天然与旧值相等、不会误刷对应区；私密占位切换（内容→占位）
    /// 不受在途保护限制，隐私优先。id 不符的回包直接忽略（防御）。
    /// 116 数据填入动效：后台补齐导致文案变化时只淡入该元素本身
    /// （alpha 0→1、0.25s，不动 transform／布局、不重建节点、不缩放
    /// 弹一下）；减动效或未进窗口时直设终值。本函数只在 update(with:)
    /// 的变化分支里调用——初始 renderAll（首帧）与点赞操作行（已有
    /// 爆点／即时反馈）不走这里，避免首帧延迟与操作反馈冲突。
    private func fadeLabel(_ label: UILabel?) {
        guard let label = label else { return }
        guard !UIAccessibility.isReduceMotionEnabled, label.window != nil else {
            label.alpha = 1
            return
        }
        label.alpha = 0
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            label.alpha = 1
        })
    }

    private func fadeButtonTitle(_ button: UIButton) {
        guard !UIAccessibility.isReduceMotionEnabled, button.window != nil,
              let titleLabel = button.titleLabel else { return }
        titleLabel.alpha = 0
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            titleLabel.alpha = 1
        })
    }

    private func fadeView(_ view: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            view.alpha = 1
        })
    }

    /// B3 补拉基线：发补拉时记下各互动字段的当前值；回包合并时只合并
    /// 补拉期间没有变化的字段——期间已确认的操作（点赞/收藏/回应/可见性）
    /// 不再被旧回包覆盖。seq 守卫只拦仍在途的操作，基线补的是“操作先
    /// 成功、旧回包后到”的缺口；不另增代次字段（见 update(with:)）。
    struct SupplementBaseline {
        let likedByMe: Bool?
        let likeCount: Int?
        let bookmarkedByMe: Bool?
        let emotesSignature: String
        let isPublic: Bool?
        let visibility: String?
        let publishedAt: Int?
        let ephemeralUntil: Int?
    }

    /// 发补拉前调用，记下各互动字段当前值（见 SupplementBaseline）。
    func captureSupplementBaseline() -> SupplementBaseline {
        SupplementBaseline(
            likedByMe: entry.likedByMe,
            likeCount: entry.likeCount,
            bookmarkedByMe: entry.bookmarkedByMe,
            emotesSignature: BearyEmoteOrder.signature(entry.emotes),
            isPublic: entry.isPublic,
            visibility: entry.visibility,
            publishedAt: entry.publishedAt,
            ephemeralUntil: entry.ephemeralUntil
        )
    }

    /// 第 22 轮 C3：后台补齐时的阅读锚点——屏上可见的正文块／引用卡／
    /// 图片（记 key）及其相对视口顶的偏移；补齐后布局落定再恢复，读到的
    /// 位置不被上方高度变化顶走。只对实际变化的元素播已有淡入（见各分支
    /// 的 fadeLabel/fadeView），锚点恢复本身不动 alpha、不播动效。
    private struct ReadingAnchor {
        let view: UIView
        let key: String?
        let offsetFromVisibleTop: CGFloat
    }

    /// 阅读顺序的锚点候选：标题、正文、首张可见图、引用卡。
    private func readingAnchorCandidates() -> [(view: UIView, key: String?)] {
        var candidates: [(view: UIView, key: String?)] = []
        if !titleLabel.isHidden { candidates.append((titleLabel, nil)) }
        if !bodyLabel.isHidden { candidates.append((bodyLabel, nil)) }
        if let imageSlot = firstVisibleImageSlot() { candidates.append(imageSlot) }
        if !quoteView.isHidden { candidates.append((quoteView, nil)) }
        return candidates
    }

    /// 首张可见图片槽位及其 key（横向条内可见的第一格；无图时为 nil）。
    private func firstVisibleImageSlot() -> (view: UIView, key: String?)? {
        guard !imagesScrollView.isHidden else { return nil }
        for (index, slot) in imageSlots.enumerated() {
            guard !slot.isHidden else { continue }
            let frameInStrip = slot.convert(slot.bounds, to: imagesScrollView)
            guard frameInStrip.maxX > 0, frameInStrip.minX < imagesScrollView.bounds.width else { continue }
            let key = index < imageKeys.count ? imageKeys[index] : nil
            return (slot, key)
        }
        return nil
    }

    /// 更新前记住屏上最靠上的可见块及其相对视口顶的偏移；未进窗口、
    /// 正在拖动／减速中、或无可见块时不锚（手势拥有 offset）。
    private func captureReadingAnchor() -> ReadingAnchor? {
        guard isViewLoaded, view.window != nil,
              !scrollView.isDragging, !scrollView.isDecelerating else { return nil }
        view.layoutIfNeeded()
        let visibleTop = scrollView.contentOffset.y
        let visibleBottom = visibleTop + scrollView.bounds.height
        for candidate in readingAnchorCandidates() {
            let frame = candidate.view.convert(candidate.view.bounds, to: contentColumnView)
            guard frame.maxY > visibleTop, frame.minY < visibleBottom else { continue }
            return ReadingAnchor(view: candidate.view, key: candidate.key, offsetFromVisibleTop: frame.minY - visibleTop)
        }
        return nil
    }

    /// 布局落定后把锚点放回同一屏上位置（只改 offset）；图片锚点按 key
    /// 找现槽位，图被撤时退回整条图片区、再无则不动。
    private func restoreReadingAnchor(_ anchor: ReadingAnchor?) {
        guard let anchor = anchor else { return }
        guard isViewLoaded, view.window != nil,
              !scrollView.isDragging, !scrollView.isDecelerating else { return }
        view.layoutIfNeeded()
        let target: UIView?
        if let key = anchor.key {
            if let slotIndex = imageKeys.firstIndex(of: key), slotIndex < imageSlots.count {
                target = imageSlots[slotIndex]
            } else {
                target = imagesScrollView.isHidden ? nil : imagesScrollView
            }
        } else {
            target = anchor.view
        }
        guard let targetView = target, !targetView.isHidden else { return }
        let frame = targetView.convert(targetView.bounds, to: contentColumnView)
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset.y = min(max(0, frame.minY - anchor.offsetFromVisibleTop), maxOffset)
    }

    func update(with fetched: Entry, baseline: SupplementBaseline? = nil) {
        // 审计 P2-20：页内已因拉黑/举报转占位时，后台补齐一律忽略，不得复活全文。
        if locallyHiddenByModeration { return }
        guard fetched.id == entry.id else { return }
        let old = entry
        if fetched.placeholder == true {
            // 占位优先：只立占位旗，不整体覆盖模型（在途先行态不受占位回包冲掉；
            // 内容栈已整藏，占位期间模型其余字段不可见；后续内容回包再按合并恢复）。
            // B1：曾有内容在屏时，回包明确不可见即撤下全文并显过渡占位
            // “这篇日记现在看不到了”；已是占位时仍走 visibility 文案。
            if entry.placeholder != true {
                showBecameInvisible()
            } else {
                ephemeralExpiryTimer?.invalidate()
                ephemeralExpiryTimer = nil
                entry.placeholder = true
                showPlaceholder(visibility: fetched.visibility)
            }
            // 第 22 轮 C2：回包明确不可见，失败横幅一并收起（横幅只留给弱网旧内容）。
            hideStaleBanner()
            return
        }
        // 第 22 轮 C3：记住屏上可见块再合并——上方内容高度变化时，补齐后按锚点恢复位置。
        let readingAnchor = captureReadingAnchor()
        // 按字段合并：先取服务端全量，再把在途字段写回本地值。
        var merged = fetched
        // 及时性口径：代次未确认（有在途请求）时护乐观字段；在途请求全部
        // 落定（代次已确认）时，合并后的服务端值即新确认态。
        // B3：基线在补拉发出时记下（见 captureSupplementBaseline）；字段在
        // 补拉期间变化过（当前值 ≠ 发出时值）即视为已确认的新态，不取回包
        // 旧值——操作先成功、旧回包后到时，确认值不再被覆盖。
        let likeChangedDuringFetch = baseline.map { $0.likedByMe != old.likedByMe || $0.likeCount != old.likeCount } ?? false
        if likeSeq != likeConfirmedSeq || likeChangedDuringFetch {
            merged.likedByMe = old.likedByMe
            merged.likeCount = old.likeCount
        } else {
            confirmedLiked = merged.likedByMe ?? false
            confirmedLikeCount = merged.likeCount ?? 0
        }
        let bookmarkChangedDuringFetch = baseline.map { $0.bookmarkedByMe != old.bookmarkedByMe } ?? false
        if bookmarkSeq != bookmarkConfirmedSeq || bookmarkChangedDuringFetch {
            merged.bookmarkedByMe = old.bookmarkedByMe
            merged.bookmarkCount = old.bookmarkCount
        } else {
            confirmedBookmarked = merged.bookmarkedByMe ?? false
        }
        let emotesChangedDuringFetch = baseline.map { $0.emotesSignature != BearyEmoteOrder.signature(old.emotes) } ?? false
        if isEmoteBusy || emotesChangedDuringFetch {
            merged.emotes = old.emotes
        }
        let visibilityChangedDuringFetch = baseline.map { $0.isPublic != old.isPublic || $0.visibility != old.visibility || $0.publishedAt != old.publishedAt || $0.ephemeralUntil != old.ephemeralUntil } ?? false
        if isVisibilityBusy || visibilityChangedDuringFetch {
            merged.isPublic = old.isPublic
            merged.visibility = old.visibility
            merged.publishedAt = old.publishedAt
            merged.ephemeralUntil = old.ephemeralUntil
        }
        entry = merged
        // 单篇快照：后台补齐的新鲜数据即写盘（占位/拉黑态不写，见 saveDetailSnapshot）。
        saveDetailSnapshot()
        // 内容页本身被占位过时（本路径不会发生：卡片数据恒为内容态），先恢复内容区。
        setContentVisible(true)
        placeholderStateView.isHidden = true
        // 审计 4/11：头部按元素判定。天气/气温单独成支——只变气温时不
        // 再因缺 temperatureC 的分支条件漏刷，也不再整段重走头部；
        // 心情不参与头部渲染（#421 后心情只缀正文末尾），不再列入头部
        // 触发条件；淡入只给真正变化的文字，头像 URL 不变时由
        // renderHeaderMeta 内的 lastRenderedAvatarURL 守卫保留当前图片。
        let nameChanged = old.authorName != merged.authorName
        let timeChanged = old.createdAt != merged.createdAt
        let recipientChanged = old.mentionedName != merged.mentionedName
        let weatherChanged = old.weather != merged.weather || old.temperatureC != merged.temperatureC
        let headerMetaChanged = nameChanged || timeChanged || old.authorAvatar != merged.authorAvatar || old.authorPlus != merged.authorPlus || recipientChanged || old.mentionedUserId != merged.mentionedUserId
        if headerMetaChanged {
            renderHeaderMeta()
            // 116：头信息文案变化时只淡入真正变化的元素（头像图与
            // 天气图标为图片，到达即显，不在此淡入；气温是文字，变了才淡入）。
            if nameChanged { fadeButtonTitle(nameButton) }
            if timeChanged { fadeLabel(timeLabel) }
            if recipientChanged { fadeLabel(recipientLabel) }
            if weatherChanged && !weatherTempLabel.isHidden { fadeLabel(weatherTempLabel) }
        } else if weatherChanged {
            renderWeatherTemp()
            if !weatherTempLabel.isHidden { fadeLabel(weatherTempLabel) }
        }
        if old.title != merged.title {
            let trimmedTitle = (merged.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            titleLabel.attributedText = trimmedTitle.isEmpty ? nil : BearyText.inlineAttributedText(from: trimmedTitle, font: BearyDynamicType.cardTitleFont(), color: BearyColors.ink, paragraphStyle: nil, dark: traitCollection.userInterfaceStyle == .dark)
            titleLabel.isHidden = trimmedTitle.isEmpty
            if !trimmedTitle.isEmpty { fadeLabel(titleLabel) }
        }
        if old.content != merged.content || old.mood != merged.mood {
            // 心情只变时也要重建正文，否则新心情附件缀不上旧正文；
            // 必须走 detailBodyAttributedText（内联记号转图 + 旧心情缀末尾），
            // 不能退回纯文本，否则记号原串会直接露出来。
            bodyLabel.attributedText = detailBodyAttributedText(merged.content ?? "", moodKey: merged.mood)
            bodyLabel.isHidden = (merged.content ?? "").isEmpty && (merged.mood ?? "").isEmpty
            // 116：后台补齐文案变化时只淡入文案元素。
            if !bodyLabel.isHidden { fadeLabel(bodyLabel) }
        }
        // 审计 8：图片条按 key、尺寸、实况映射分别比对。只变尺寸或实况
        // 时不重走 renderImages（它会重下全部图片），只更新变化槽位的
        // 宽约束与实况覆盖层；key 变了（增删换图）才整条重建。
        let oldImageKeys = Array((old.images ?? []).filter { !$0.isEmpty }.prefix(9))
        let newImageKeys = Array((merged.images ?? []).filter { !$0.isEmpty }.prefix(9))
        let imageKeysChanged = oldImageKeys != newImageKeys
        let imageDimsChanged = (old.imgDims ?? [:]) != (merged.imgDims ?? [:])
        let liveMapChanged = (old.liveVideos ?? [:]) != (merged.liveVideos ?? [:])
        if imageKeysChanged || imageSlots.isEmpty {
            renderImages()
        } else if imageDimsChanged || liveMapChanged {
            for (slotIndex, imageKey) in newImageKeys.enumerated() {
                guard slotIndex < imageSlots.count, slotIndex < imageSlotWidthConstraints.count else { continue }
                if imageDimsChanged {
                    imageSlotWidthConstraints[slotIndex].constant = stripWidth(forKey: imageKey, dims: merged.imgDims, height: 216)
                }
                if liveMapChanged {
                    setLiveOverlay(index: slotIndex, staticKey: imageKey, liveKey: merged.liveVideos?[imageKey])
                }
            }
        }
        // 批 E：位置字段或可见性/限时态变化时位置行重算（公开翻私密恢复精确，反之脱敏）。
        if old.locationName != merged.locationName || old.locationDistrict != merged.locationDistrict || old.isPublic != merged.isPublic || old.ephemeralUntil != merged.ephemeralUntil {
            renderLocation()
        }
        let oldQuote = old.quote
        let newQuote = merged.quote
        // 引用卡更新判定：覆盖 renderQuote 实际使用的全部字段。只比 id/正文/
        // 删除/锁定/公开时会漏掉图片、作者信息与占位字段，导致后台补齐后
        // 旧卡仍停留在界面上。imgDims 目前服务端不下发（恒 nil），仍纳入
        // 判定，服务端透传后直接生效，不必再改条件。
        let quoteChanged = oldQuote?.id != newQuote?.id
            || oldQuote?.content != newQuote?.content
            || oldQuote?.gone != newQuote?.gone
            || oldQuote?.locked != newQuote?.locked
            || oldQuote?.isPublic != newQuote?.isPublic
            || (oldQuote?.images ?? []) != (newQuote?.images ?? [])
            || (oldQuote?.imgDims ?? [:]) != (newQuote?.imgDims ?? [:])
            || oldQuote?.authorName != newQuote?.authorName
            || oldQuote?.authorAvatar != newQuote?.authorAvatar
            || oldQuote?.authorHandle != newQuote?.authorHandle
            || oldQuote?.createdAt != newQuote?.createdAt
            || oldQuote?.visibility != newQuote?.visibility
            || oldQuote?.publishedAt != newQuote?.publishedAt
            || oldQuote?.ephemeralUntil != newQuote?.ephemeralUntil
        if quoteChanged {
            renderQuote()
            // 116：引用卡内容变化时只淡入卡片本身。
            if !quoteView.isHidden { fadeView(quoteView) }
        }
        // 元组数组无 Equatable，逐项比对（nil 与空均视作无回应，渲染同态，不多刷）。
        // 在途字段已在合并时保留本地值，故此处比对天然跳过在途区，无需另设 busy 门控。
        let oldEmoteList = old.emotes ?? []
        let newEmoteList = merged.emotes ?? []
        let emotesChanged = oldEmoteList.count != newEmoteList.count || zip(oldEmoteList, newEmoteList).contains { $0.emote != $1.emote || $0.count != $1.count || $0.mine != $1.mine }
        if old.likedByMe != merged.likedByMe || old.likeCount != merged.likeCount || old.bookmarkedByMe != merged.bookmarkedByMe || emotesChanged {
            refreshActionRow()
            renderEmotes()
        }
        // B3：可见性档位直接比对——私密与仅好友都可能是 isPublic == false，
        // 只比 isPublic 会漏掉私密↔仅好友的翻转，操作行/引用卡/小地球停在旧态。
        if old.isPublic != merged.isPublic || old.visibility != merged.visibility || old.publishedAt != merged.publishedAt || old.ephemeralUntil != merged.ephemeralUntil {
            refreshVisibilityViews()
            refreshEphemeralViews()
            refreshAuthorActions()
            // 有效公开态同时决定操作行压暗／分享显隐与引用卡占位态，
            // 可见性变化时一并刷这两处，否则小地球文案已变、私密门控仍停在旧态。
            refreshActionRow()
            renderQuote()
        }
        // 标题／@ 行显隐变化时重算头行／正文栈间距与顶距（标题隐藏时其后间距置 0、
        // @ 行显隐改顶距 22/23），其余字段变化不影响间距。
        updateDiaryStackSpacing()
        // 第 22 轮 C3：布局落定后按锚点恢复阅读位置（只动 offset，不重播已有淡入）。
        restoreReadingAnchor(readingAnchor)
        // 限时到期重排：回包可能带来新的 ephemeralUntil（或已过期），按新模型复核一次。
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
        // 第 22 轮 C2：补齐成功，失败横幅 0.18 秒淡出收起。
        hideStaleBanner()
    }

    /// 单篇磁盘快照写盘：占位/拉黑态与无 id 的篇不写（快照只存看过的内容态），
    /// 桶用进页时钉住的 snapshotBucket，不按写盘时当前账号取桶。
    /// 确认态写盘：只在后台补齐的新鲜数据到达时调（见 update(with:)）。
    private func saveDetailSnapshot() {
        BearyDetailCache.save(bucket: snapshotBucket, entry: entry)
    }

    /// 浏览记次：进页只刷新快照的上次浏览，确认时间与正文不动；
    /// 回看旧快照不再换成新的保存时间。
    private func markDetailSnapshotViewed() {
        BearyDetailCache.markViewed(bucket: BearyDetailCache.bucket(), entry: entry)
    }

    // MARK: - 限时到期（审计三轮第二批 9）

    /// 按最近 ephemeralUntil 排一次单次刷新：非限时／已占位／已拉黑钉死时不排；
    /// 已过期不在此排（调用方先走 applyEphemeralExpiryIfNeeded 落定）。
    /// 不做重复定时、不按秒轮询——倒计时文案本身是小时粒度，无需逐秒重刷。
    private func scheduleEphemeralExpiry() {
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        guard !locallyHiddenByModeration, entry.placeholder != true else { return }
        // 开发者模式时间旅行（仅内存）：假日下不按真实时钟排到期定时器，
        // 否则定时器会在真实到期点把假态显示翻回私密；退出开发者模式后回前台复核重排。
        guard BearyDevPreviewState.fakeDay == nil else { return }
        guard BearyEphemeral.isLive(entry), let until = entry.ephemeralUntil else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let interval = TimeInterval(until - nowMs) / 1000.0
        guard interval > 0 else { return }
        ephemeralExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleEphemeralExpiry()
        }
    }

    private func handleEphemeralExpiry() {
        ephemeralExpiryTimer = nil
        if !applyEphemeralExpiryIfNeeded() {
            // 定时器误触（模型已变、如手动翻转清了标记）：按当前模型重排，不丢后续到期点。
            scheduleEphemeralExpiry()
        }
    }

    /// 回前台复核：后台期间定时器未触发时，到期在此补位；未到期则重排单次定时。
    @objc private func handleForegroundEphemeralCheck(_ note: Notification) {
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    /// 到点重算有效态（纯本地重算，不发网络请求）：
    /// 已到期（ephemeralUntil 非空且已过）时，有效公开态恒为私密——
    /// 作者：切私密显示（小地球文案翻转、限时行与边框藏、操作行按私密压暗／分享藏、引用卡占位重算）；
    /// 非作者：切私密占位（内容栈整藏，只显一句私密文案）。
    /// 未到期／非限时／已占位／已拉黑钉死时返回 false（调用方据此重排定时）。
    @discardableResult
    private func applyEphemeralExpiryIfNeeded() -> Bool {
        guard !locallyHiddenByModeration else { return false }
        guard entry.placeholder != true else { return false }
        // 内容区藏起时（私密占位等）不动：占位文案不得被到期刷新改写。
        guard !bodyStack.isHidden else { return false }
        guard entry.ephemeralUntil != nil, !BearyEphemeral.isLive(entry) else { return false }
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        if isAuthor {
            refreshVisibilityViews()
            refreshEphemeralViews()
            refreshAuthorActions()
            refreshActionRow()
            renderQuote()
            return true
        }
        entry.placeholder = true
        // 审计 2026-11-02 第十节：限时到期即定向清该篇图片缓存（与手动转私密同口径），
        // 占位文案按回包 visibility 区分，无字段时通用占位不误标。
        BearyImageLoader.shared.evictEntryImages(keys: entry.images ?? [])
        BearyDiaryCardCell.invalidateQuote(id: entry.id ?? "")
        showPlaceholder(visibility: entry.visibility)
        return true
    }

    /// 2026-10-31：⋯ 钮图标恒为三点；可见性切换走菜单“修改权限”，点按即时切换。
    /// 限时已到期按私密算（与卡片同口径，走 BearyEphemeral 有效态）。
    /// 注意：旧详情的锁／地球双图标 + 盒装 pill 已随本批删除，私密态在视觉上
    /// 不再有锁图标可认——与首页卡片一致，属有意对齐（待真机验确认 Li 接受）。
    private func refreshVisibilityViews() {
        // 2026-10-31：⋯ 钮图标恒为三点，不再按公开态换文案；可见性切换走菜单
        // “修改权限”，原小地球无障碍文案（“改回私密”／“公开”）随地球钮废止。
        moreButton.accessibilityLabel = "更多操作"
    }

    /// 限时详情：存活期虚线边框 + 倒计时灰字（只留倒计时行）+ 底线藏（边框代之，
    /// 首页 refreshEphemeralState 同款）；到期或非限时按普通详情（边框与倒计时行均藏、底线显）。
    private func refreshEphemeralViews() {
        let live = BearyEphemeral.isLive(entry)
        if live, let until = entry.ephemeralUntil {
            ephemeralLabel.text = BearyEphemeral.remainingText(until: until)
            ephemeralRow.isHidden = false
        } else {
            ephemeralLabel.text = nil
            ephemeralRow.isHidden = true
        }
        ephemeralBorderView.isHidden = !live
        separatorView.isHidden = live
    }

    /// 作者行右侧显隐：本人卡显小地球、头行右缩进 −36 让位；他人／游客无地球、
    /// 头行恢复 0。游客永非作者，到不了本人分支。
    /// 皇冠显隐唯一入口：容器与皇冠同藏同显，不留 19pt 空位。
    private func setCrownHidden(_ hidden: Bool) {
        crownWrapView.isHidden = hidden
        crownView.isHidden = hidden
        if hidden { crownView.stop() } else { crownView.start() }
    }

    private func refreshAuthorActions() {
        // 2026-10-31：⋯ 显隐——本人卡（编辑／修改权限／删除）或他人公开卡
        // （举报／拉黑）显；游客与占位态（他人私密）无菜单项，藏；头行右缩进
        // −36 给 ⋯（28 框）留位，藏时恢复 0。
        let showMore = !isGuest && (isAuthor || BearyEphemeral.isEffectivelyPublic(entry))
        moreButton.isHidden = !showMore
        headerStackTrailingConstraint?.constant = showMore ? -36 : 0
    }

    /// 首页图片条同款（F5）：高 216、间距 8、圆角 12、槽底色 line、横向滚动、
    /// 宽按宽高比（0.55–2.22 倍高夹取，无尺寸老图默认 280）、无图高度压 0；
    /// 槽位复用（上限 9 张；超 9 张只显前 9 张，旧详情纵向无上限，见 PR 说明）。
    /// 条内走 thumb 图（首页同款），点图进灯箱仍按原图 key 打开。
    private func renderImages() {
        resetImageStripPinch()
        let allKeys = (entry.images ?? []).filter { !$0.isEmpty }
        imageKeys = allKeys
        let keys = Array(allKeys.prefix(9))
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
                setLiveOverlay(index: slotIndex, staticKey: nil, liveKey: nil)
            }
            return
        }
        imagesScrollView.isHidden = false
        imageHeightConstraint?.constant = 216
        for (imageIndex, imageKey) in keys.enumerated() {
            // 详情闪退加固：槽位池、重试钮池、宽约束池须同下标，任一池短了都跳过该图、
            // 不下标越界（正常路径三池同为 9，守卫只防池化异常，不改渲染）。
            guard imageIndex < imageSlots.count, imageIndex < imageSlotRetryButtons.count,
                  imageIndex < imageSlotWidthConstraints.count else { continue }
            let slot = imageSlots[imageIndex]
            slot.tag = imageIndex
            let strip = stripWidth(forKey: imageKey, dims: entry.imgDims, height: 216)
            bearyFeedLoadImage(into: slot, url: BearyImageURLs.imageURL(key: imageKey, thumb: true), retryButton: imageSlotRetryButtons[imageIndex], downsampleToWidth: strip * UIScreen.main.scale, blurUp: true)
            imageSlotWidthConstraints[imageIndex].constant = strip
            slot.isHidden = false
            setLiveOverlay(index: imageIndex, staticKey: imageKey, liveKey: entry.liveVideos?[imageKey])
        }
        for (slotIndex, slot) in imageSlots.dropFirst(keys.count).enumerated() {
            slot.bearySetImage(url: nil)
            slot.isHidden = true
            let retryIndex = keys.count + slotIndex
            if retryIndex < imageSlotRetryButtons.count {
                imageSlotRetryButtons[retryIndex].isHidden = true
                imageSlotRetryButtons[retryIndex].retryURL = nil
            }
            setLiveOverlay(index: retryIndex, staticKey: nil, liveKey: nil)
        }
    }

    /// 实况覆盖层开关（卡片同款；静态槽不挂长按手势，点按无延迟）。
    private func setLiveOverlay(index: Int, staticKey: String?, liveKey: String?) {
        guard index >= 0, index < imageSlotLiveViews.count, index < imageSlots.count,
              index < imageSlotLivePresses.count else { return }
        let overlay = imageSlotLiveViews[index]
        let slot = imageSlots[index]
        if let liveKey = liveKey, !liveKey.isEmpty, let staticKey = staticKey, !staticKey.isEmpty {
            overlay.configure(staticKey: staticKey, liveKey: liveKey)
            if imageSlotLivePresses[index] == nil {
                let press = UILongPressGestureRecognizer(target: self, action: #selector(liveLongPressed(_:)))
                press.minimumPressDuration = 0.4
                slot.addGestureRecognizer(press)
                imageSlotLivePresses[index] = press
            }
        } else {
            overlay.clear()
            if let press = imageSlotLivePresses[index] {
                slot.removeGestureRecognizer(press)
                imageSlotLivePresses[index] = nil
            }
        }
    }

    @objc private func liveLongPressed(_ sender: UILongPressGestureRecognizer) {
        let index = sender.view?.tag ?? -1
        guard index >= 0, index < imageSlotLiveViews.count else { return }
        let overlay = imageSlotLiveViews[index]
        if sender.state == .began {
            overlay.startPlayback()
            overlay.suppressTapUntil = Date().addingTimeInterval(3)
        } else if sender.state == .ended || sender.state == .cancelled {
            let until = Date().addingTimeInterval(0.35)
            if let existing = overlay.suppressTapUntil, existing > until {
                // 按住超 0.35 秒后的抬手仍在 began 的 3 秒窗内，不缩短。
            } else {
                overlay.suppressTapUntil = until
            }
        }
    }

    /// 首页 stripWidth 同款：216 高按宽高比定宽，0.55–2.22 倍高夹取，
    /// 无尺寸老图默认 280。
    private func stripWidth(forKey key: String, dims: [String: [Int]]?, height: CGFloat) -> CGFloat {
        if let dims = dims, let d = dims[key], d.count >= 2, d[0] > 0, d[1] > 0 {
            let raw = height * CGFloat(d[0]) / CGFloat(d[1])
            let low = height * 0.55
            let high = height * 2.22
            return round(max(low, min(high, raw)))
        }
        return 280
    }

    /// 批 E 详情位置行渲染：刷新点为 renderAll 与字段合并路径（批 B 已删 chips 行，
    /// 位置行改挂正文栈，见 buildLocation），
    /// 可见性翻转时位置行随 isPublic 变化同步变（作者本人：公开→区级、私密→精确；
    /// 他人视角恒为区级）。
    private func renderLocation() {
        guard let line = BearyLocationDisplay.display(entry: entry) else {
            detailLocationStack.isHidden = true
            detailLocationLabel.text = nil
            return
        }
        detailLocationStack.isHidden = false
        detailLocationLabel.text = line
    }

    /// 引用渲染代次：每次 renderQuote 即 +1。仅好友异步补全回调到达时须与
    /// 发起时代次一致，否则说明期间已有更新的渲染，旧回调一律丢弃，不得
    /// 用闭包捕获的旧快照覆盖新卡（同 ID 内容更新也会触发新渲染）。
    private var quoteRenderSeq = 0

    /// 引用卡 viewer 实时判定（卡片 presentQuoteCard 同口径）：作者本人或已公开才显全文，
    /// 否则占位；gone → 已删除，locked／未公开 → 引用规则简化占位文案
    /// （曾公开“该日记已设为私密”＋提醒句，从未公开“该日记未公开”，见 BearyQuoteGate.placeholderText）。
    private func renderQuote() {
        quoteRenderSeq += 1
        guard let quote = entry.quote, let quoteId = quote.id, !quoteId.isEmpty else {
            quoteView.isHidden = true
            return
        }
        let viewerId = SessionManager.shared.currentUser?.id
        let quoteIsMine = quote.authorId != nil && viewerId != nil && quote.authorId == viewerId
        if quote.gone == true {
            quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
            quoteView.isHidden = false
            return
        }
        if quote.locked == true {
            let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: true, visibility: quote.visibility)
            quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            quoteView.isHidden = false
            return
        }
        let content = quote.content ?? ""
        if content.isEmpty {
            if quote.isEffectivelyPublic == false {
                let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: false, visibility: quote.visibility)
                quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
            }
            quoteView.isHidden = false
            return
        }
        // 审计 2026-11-02 第十节：引用判定统一走有效态＋互关通道——作者本人或
        // 当前有效公开即显全文；仅好友档先占位、state 回包确认互关后再补全文
        // （回包到达时若引用已换篇或已有更新的渲染则丢弃，fail-closed）；其余一律占位。
        let showPlaceholderForQuote = {
            let placeholder = BearyQuoteGate.placeholderTextForQuote(publishedAt: quote.publishedAt, locked: false, visibility: quote.visibility)
            self.quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            self.quoteView.isHidden = false
        }
        if quoteIsMine || quote.isEffectivelyPublic {
            quoteView.configure(
                authorName: quote.authorName ?? "",
                authorAvatar: quote.authorAvatar,
                content: content,
                images: quote.images ?? [],
                dims: quote.imgDims,
                createdAt: quote.createdAt,
                allowThumbs: quote.isEffectivelyPublic || quoteIsMine,
                authorHandle: quote.authorHandle,
                sourceTappable: true
            )
            quoteView.isHidden = false
            return
        }
        if quote.visibility == "friends" {
            showPlaceholderForQuote()
            let renderSeq = quoteRenderSeq
            BearyQuoteGate.resolveQuoteFullAccess(quote: quote) { [weak self] canView in
                guard let self = self, canView, renderSeq == self.quoteRenderSeq, self.entry.quote?.id == quoteId else { return }
                self.quoteView.configure(
                    authorName: quote.authorName ?? "",
                    authorAvatar: quote.authorAvatar,
                    content: content,
                    images: quote.images ?? [],
                    dims: quote.imgDims,
                    createdAt: quote.createdAt,
                    allowThumbs: true,
                    authorHandle: quote.authorHandle,
                    sourceTappable: true
                )
                self.quoteView.isHidden = false
            }
            return
        }
        showPlaceholderForQuote()
    }

    // MARK: - 操作行

    /// 点赞点亮走红色、收藏点亮走橙色，与现有先行反馈口径；数字只 setTitle，不重建行。
    /// 批 B 操作行（首页同款）：赞左、收藏紧邻赞右、分享钉右缘，无回应钮；
    /// 收藏纯图标（无中文标签）；赞数口径（2026-10-31 Li 纠正，取代旧“详情页
    /// 0 赞恒显 0”例外）：0 赞时数字整段隐藏、只留爱心图标可点，与卡片
    /// 空数字位隐藏一致；有赞时显完整数字，宽度显式算（卡片同款）。
    private func refreshActionRow() {
        if isGuest {
            actionStack.isHidden = true
            guestPromptButton.isHidden = false
            return
        }
        actionStack.isHidden = false
        guestPromptButton.isHidden = true

        let liked = entry.likedByMe ?? false
        let likeCount = entry.likeCount ?? 0
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 24)
            ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 24)
        likeButton.setImage(heartImage, for: .normal)
        // 赞数 0 隐藏整段数字（2026-10-31 Li 纠正口径）：setTitle(nil) 后宽度只剩
        // 图标宽，不占数字位、不留残影；有赞时显完整数字，宽度显式算
        //（图标宽 + 6 边距 + 标题宽，卡片同款），不靠按钮固有宽。
        let imageWidth = heartImage?.size.width ?? 24
        if likeCount <= 0 {
            likeButton.setTitle(nil, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth
        } else {
            let titleText = "\(likeCount)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: likeButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.tintColor = liked ? BearyColors.likeRed : BearyColors.gray
        likeButton.setTitleColor(liked ? BearyColors.likeRed : BearyColors.gray, for: .normal)
        likeButton.setTitleColor(liked ? BearyColors.likeRed : BearyColors.gray, for: .highlighted)
        likeButton.accessibilityLabel = likeCount <= 0 ? "点赞" : "\(liked ? "已点赞" : "点赞")，\(likeCount)"

        let bookmarked = entry.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 24)
            ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 24)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
        bookmarkButton.accessibilityLabel = bookmarked ? "已收藏" : "收藏"
        shareButton.accessibilityLabel = "分享"

        // 卡片互动门控同口径：2026-10-31 私密自互动口径——点赞／收藏为“有效公开 或 作者本人”
        // 时正常显示，非作者看非公开篇仍压暗；分享不动，仍仅有效公开才有（私密不交出正文与链接），
        // 分享隐藏时留 24pt 槽位占位（首页 shareSlotSpacer 同款），行尾槽位不随分享显隐变化。
        // 限时已到期按私密算（与卡片同口径）。
        // 注意：按钮不禁用（首页卡片禁用），点按仍走详情原有拒绝动效 + toast
        // （审计 P2-11 口径），非作者的非公开互动有明确反馈而非静默无反应。
        // 后端缺口见 PR 说明：后端目前仍以 published=1 拦私密互动，作者私密请求仍会 404 回滚。
        let publicOK = BearyEphemeral.isEffectivelyPublic(entry)
        let interactOK = publicOK || isAuthor
        likeButton.alpha = interactOK ? 1.0 : 0.4
        bookmarkButton.alpha = interactOK ? 1.0 : 0.4
        shareButton.isHidden = !publicOK
        shareSlotSpacer.isHidden = !shareButton.isHidden
    }

    private func playDenyShake(on button: UIButton) {
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        if UIAccessibility.isReduceMotionEnabled { return }
        button.layer.removeAnimation(forKey: "bearyDetailDenyShake")
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        shake.duration = 0.4
        button.layer.add(shake, forKey: "bearyDetailDenyShake")
    }

    // MARK: - 回应行

    /// 审计三轮第三批 26：详情回应 chip 按 key 复用，不再全删全建。
    /// 旧实现每次先删全部 subviews 再逐个新建 chip：乐观先行、失败回滚与
    /// update 变化都会触发重建（成功路径虽有 signature 门控，乐观与失败
    /// 路径没有），chip 播放器从 0 帧重画、target 重挂。现改为：
    /// - 排序后签名（key:count:mine 串）与上次渲染一致时直接返回，什么都不动；
    /// - 已在场的 chip 按 key 复用，只调 render 更新计数与选中态（同 key 时
    ///   播放器不重播，只在停播时恢复），不重建、不重挂 target；
    /// - 新增 chip 从 transform 缩放＋opacity 淡入，删除 chip 先 transform
    ///   缩放＋opacity 淡出、动画结束再移出（减动效时直设终值／直删）；
    /// - 排序变化只调 subviews 顺序（依次置顶），不动 chip 本身；
    /// - 首渲染与旧实现一致即时出现，不播入场动画。
    /// 外观、排序（count 降序）、点按行为（tag 对齐 chipKeys）一律不变；
    /// 占位口径不动（占位时内容栈整藏，本函数不碰占位逻辑）。
    private func renderEmotes() {
        if isGuest {
            // 游客无回应行（提示条已在操作行位置）；flow 藏起即连 + 钮一并藏。
            emoteFlowView.isHidden = true
            return
        }
        // 批 B：只显示熊脸（小熊回应墙同款 BearyEmoteKeys.bearFaceKeys 过滤，
        // 仅显示层过滤、服务端模型不动）；空 key 不建 chip；同 key 只留首个
        // （模型侧 merged／emoteDelta 已按 key 去重，防重复 key 建出双 chip）。
        var seenKeys = Set<String>()
        var list: [EmoteCount] = []
        for item in (entry.emotes ?? []).sorted(by: { ($0.count ?? 0) > ($1.count ?? 0) }) {
            guard let key = item.emote, !key.isEmpty, !seenKeys.contains(key),
                  BearyEmoteKeys.bearFaceKeys.contains(key) else { continue }
            seenKeys.insert(key)
            list.append(item)
        }
        let newSignature = BearyEmoteOrder.signature(list)
        if newSignature == renderedEmoteSignature {
            // 签名一致直接返回（+ 钮已在首渲染时挂进 flow，不在此重建）；
            // 防御：+ 钮若不在场（不应发生），补挂一次，防行末无入口。
            if let add = emoteAddButton, add.superview == nil {
                emoteFlowView.addSubview(add)
            }
            return
        }
        let isFirstRender = renderedEmoteSignature == nil
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // 现存 chip：在场 chip 以播放器 key 为准（淡出中的 chip 已不在
        // chipKeys 里，仍凭播放器 key 认回、可复活）；播放器为空时回退
        // 旧 chipKeys＋tag 对齐。重复 key 只留首个，其余按孤 chip 处理。
        var allChips: [BearyEmoteChipView] = []
        var existing: [String: BearyEmoteChipView] = [:]
        for sub in emoteFlowView.subviews {
            guard let chip = sub as? BearyEmoteChipView else { continue }
            allChips.append(chip)
            if let key = chip.player?.emoteKey, !key.isEmpty {
                if existing[key] == nil { existing[key] = chip }
            } else if chip.overlayButton.tag >= 0, chip.overlayButton.tag < chipKeys.count {
                let key = chipKeys[chip.overlayButton.tag]
                if existing[key] == nil { existing[key] = chip }
            }
        }
        // 新增／复用：复用 chip 只更新计数与选中态，不重挂 target；新 chip
        // 建后先置 transform／opacity 起态再入场（首渲染与减动效直设终值）。
        var placed: [BearyEmoteChipView] = []
        for (index, item) in list.enumerated() {
            guard let key = item.emote, !key.isEmpty else { continue }
            if let chip = existing[key] {
                // 淡出中复活：先恢复可点按，再从当前态播回正态
                // （beginFromCurrentState 防跳变）；常态复用 transform／alpha
                // 已是终值，不播无用动画。
                chip.overlayButton.isEnabled = true
                if chip.transform != .identity || chip.alpha != 1.0 {
                    if reduceMotion {
                        chip.transform = .identity
                        chip.alpha = 1.0
                    } else {
                        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                            chip.transform = .identity
                            chip.alpha = 1.0
                        }
                    }
                }
                chip.render(key: key, count: item.count ?? 0, mine: item.mine ?? false)
                chip.overlayButton.tag = index
                placed.append(chip)
            } else {
                let chip = BearyEmoteChipView()
                chip.render(key: key, count: item.count ?? 0, mine: item.mine ?? false)
                chip.overlayButton.tag = index
                chip.overlayButton.addTarget(self, action: #selector(emoteChipTapped(_:)), for: .touchUpInside)
                chip.overlayButton.bearyAddPressFeedback()
                if isFirstRender || reduceMotion {
                    chip.transform = .identity
                    chip.alpha = 1.0
                } else {
                    chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    chip.alpha = 0
                }
                emoteFlowView.addSubview(chip)
                placed.append(chip)
                if !isFirstRender && !reduceMotion {
                    UIView.animateKeyframes(withDuration: 0.45, delay: 0, options: [], animations: {
                        UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.6) {
                            chip.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
                            chip.alpha = 1.0
                        }
                        UIView.addKeyframe(withRelativeStartTime: 0.6, relativeDuration: 0.4) {
                            chip.transform = .identity
                            chip.alpha = 1.0
                        }
                    }, completion: nil)
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
            }
        }
        // 排序：只调 subviews 顺序，不动 chip 本身（依次置顶即得新顺序）。
        for chip in placed {
            emoteFlowView.bringSubviewToFront(chip)
        }
        // 行末 + 钮：首页 feedAddButton 同款（34 虚线圆、16 + 号、灰色），
        // 复用一个实例；必须在 chip 置顶后再置顶一次——flow 按 subviews 顺序
        // 换行布局，chip 置顶会把先挂的 + 钮挤到行首，不补这一步 + 钮就跑到
        // chip 前面去了（本批实测逻辑点，见 PR 说明）。
        let addButton: BearyDiaryCardDashedAddButton
        if let reused = emoteAddButton {
            addButton = reused
        } else {
            let made = BearyDiaryCardDashedAddButton(frame: .zero)
            made.translatesAutoresizingMaskIntoConstraints = false
            made.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 24), for: .normal)
            made.tintColor = BearyColors.gray
            made.accessibilityLabel = "贴一只小熊"
            made.widthAnchor.constraint(equalToConstant: 34).isActive = true
            made.heightAnchor.constraint(equalToConstant: 34).isActive = true
            made.addTarget(self, action: #selector(emoteAddTapped), for: .touchUpInside)
            made.bearyAddPressFeedback()
            emoteAddButton = made
            addButton = made
        }
        if addButton.superview == nil {
            emoteFlowView.addSubview(addButton)
        }
        emoteFlowView.bringSubviewToFront(addButton)
        chipKeys = list.map { $0.emote ?? "" }
        renderedEmoteSignature = newSignature
        // 删除：未被本轮留用的现存 chip（含孤 chip）走 transform／opacity
        // 淡出，结束再移出；淡出期间先禁点按，防旧 tag 错指新 chipKeys。
        // 移出时若该 key 已复活（chipKeys 又含它）则不动。减动效直删。
        // 批 B：flow 非游客恒显（含 + 钮），chip 全空时也不藏行（旧实现
        // list 为空即藏行，+ 钮入口随之消失；现由 + 钮兜底回应入口）。
        let departing = allChips.filter { chip in
            !placed.contains(where: { $0 === chip })
        }
        emoteFlowView.isHidden = false
        if departing.isEmpty {
            // 无 departing 时上面一行已定显，无需再动。
        } else if reduceMotion {
            for chip in departing { chip.removeFromSuperview() }
        } else {
            for chip in departing {
                chip.overlayButton.isEnabled = false
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
                    chip.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                    chip.alpha = 0
                }, completion: { [weak self] _ in
                    guard let self = self else { return }
                    // 动画期内复活过的 chip 不动（chipKeys 已含该 key 即复活）。
                    if let key = chip.player?.emoteKey, !key.isEmpty, self.chipKeys.contains(key) {
                        return
                    }
                    chip.removeFromSuperview()
                    // 移出改变行高：强制下次布局重算（旧实现 render 末尾同款）。
                    self.lastFlowWidth = 0
                    self.view.setNeedsLayout()
                })
            }
        }
        lastFlowWidth = 0
        view.setNeedsLayout()
    }

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
        if added && !found {
            out.append(EmoteCount(emote: key, count: 1, mine: true))
        }
        return out
    }

    /// 选回应（chip 点按取下／picker 选定贴上共用）：先行增量 → POST → 成功对齐服务端值，
    /// 失败回滚＋拒绝动效；未登录走登录提示（先行态复原），非公开弹“公开后才能回应”。
    private func chooseEmote(key: String) {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            BearyToast.show(in: view, message: "公开后才能回应")
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        if isEmoteBusy { return }
        let original = entry.emotes ?? []
        let mine = original.first(where: { $0.emote == key })?.mine ?? false
        let optimistic = emoteDelta(original, key: key, added: !mine)
        entry.emotes = optimistic
        renderEmotes()
        refreshActionRow()
        isEmoteBusy = true
        BearyAPI.shared.postEmote(id: entryId, emote: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isEmoteBusy = false
                switch result {
                case .success(let resp):
                    if let server = resp.emotes {
                        let merged = BearyEmoteOrder.merged(previous: self.entry.emotes, server: server)
                        if BearyEmoteOrder.signature(merged) != BearyEmoteOrder.signature(self.entry.emotes) {
                            self.entry.emotes = merged
                            self.renderEmotes()
                        }
                    }
                    self.refreshActionRow()
                    self.onInteractionChanged?(entryId, nil, nil, nil, self.entry.emotes)
                case .failure(let err):
                    self.entry.emotes = original
                    self.renderEmotes()
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        // 批 B：旧回应钮已删，拒绝动效落在行末 + 钮（无 + 钮时落赞钮）。
                        if let add = self.emoteAddButton {
                            self.playDenyShake(on: add)
                        } else {
                            self.playDenyShake(on: self.likeButton)
                        }
                        BearyToast.show(in: self.view, message: "操作失败，请重试")
                    }
                }
            }
        }
    }

    private func presentEmotePicker() {
        if presentedViewController != nil { return }
        let sheet = BearyEmotePickerSheetViewController()
        sheet.modalPresentationStyle = .overFullScreen
        sheet.onPick = { [weak self] pickedKey in
            self?.dismiss(animated: BearyMotion.animated(true)) {
                self?.chooseEmote(key: pickedKey)
            }
        }
        present(sheet, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 分享

    private func presentShareSheet() {
        // 现有分享流程同口径：私密直接 return，不交出正文与链接。
        // 限时已到期按私密算。
        if !BearyEphemeral.isEffectivelyPublic(entry) { return }
        guard let entryId = entry.id, !entryId.isEmpty,
              let url = URL(string: "https://teddyhn.com/beary/d/" + entryId) else { return }
        let shareText = (entry.content ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var items: [Any] = ["beary 日记"]
        if !shareText.isEmpty {
            items.append(String(shareText.prefix(60)))
        }
        items.append(url)
        if presentedViewController != nil {
            UIPasteboard.general.string = url.absoluteString
            BearyToast.show(in: view, message: "链接已复制")
            return
        }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
            if completed == false, error != nil {
                UIPasteboard.general.string = url.absoluteString
                if let self = self {
                    BearyToast.show(in: self.view, message: "链接已复制")
                }
            }
        }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(activity, animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 停留埋点

    private func reportDwell() {
        guard !dwellReported, let start = dwellStart, let entryId = entry.id, !entryId.isEmpty else { return }
        dwellReported = true
        let ms = max(0, Int(Date().timeIntervalSince(start) * 1000))
        // 上报失败不得阻塞流程、不得弹 toast；游客 401 由 suppressUnauthorized 兜底。
        BearyAPI.shared.sendEvent(eventType: "dwell", targetId: entryId, durationMs: ms, completion: nil)
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func authorTapped() {
        // 本人名字不可点（自己主页走底栏“我的”）；他人作者行点按进作者主页。
        if isAuthor { return }
        guard let authorId = entry.authorId else { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onAuthorTapped?(authorId)
    }

    @objc private func mentionTapped() {
        guard let mentionedId = entry.mentionedUserId else { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onAuthorTapped?(mentionedId)
    }

    @objc private func moreTapped() {
        presentDetailMoreMenu()
    }

    /// 2026-10-31 详情 ⋯ 菜单（时间线风格 actionSheet）：本人篇 编辑（15 分钟内）／
    /// 修改权限／删除；他人公开篇 举报（已举报置灰）／拉黑；游客无菜单（⋯ 已藏）。
    /// 点赞／收藏／分享是互动，仍在底部操作行，不进菜单。
    private func presentDetailMoreMenu() {
        if isGuest { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        if isAuthor {
            if let deadline = entry.editDeadline, nowMs < deadline {
                sheet.addAction(UIAlertAction(title: "编辑", style: .default) { [weak self] _ in
                    guard let self = self else { return }
                    self.onEdit?(self.entry)
                })
            } else {
                // 审计-编辑器详情：过期（或 editDeadline 缺失即已锁，见时间线
                // 同口径注释）时编辑项不再直接消失，置灰并附说明。
                let expiredEdit = UIAlertAction(title: "编辑（已超 15 分钟不可编辑）", style: .default, handler: nil)
                expiredEdit.isEnabled = false
                sheet.addAction(expiredEdit)
            }
            sheet.addAction(UIAlertAction(title: "修改权限", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.visibilityTapped()
            })
            sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.onDelete?(self.entry)
            })
        } else if BearyEphemeral.isEffectivelyPublic(entry), let entryId = entry.id {
            let reported = BearyReportedStore.isReported(entryId: entryId)
            sheet.addAction(UIAlertAction(title: reported ? "已举报" : "举报", style: .default, handler: reported ? nil : { [weak self] _ in
                guard let self = self else { return }
                BearyReportFlow.present(from: self, entryId: entryId, entryLabel: nil)
            }))
            if reported {
                sheet.actions.last?.isEnabled = false
            }
            sheet.addAction(UIAlertAction(title: "拉黑", style: .destructive) { [weak self] _ in
                guard let self = self, let authorId = self.entry.authorId else { return }
                BearyBlockFlow.block(from: self, userId: authorId, userName: self.entry.authorName, onDone: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        // 审计 2026-11-02 弹窗组：present 不写死 animated，走减动效口径。
        present(sheet, animated: BearyMotion.animated(true))
    }

    @objc private func visibilityTapped() {
        guard isAuthor else { return }
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if isVisibilityBusy { return }
        // 审计 2026-11-02 第十节：已发布日记改三档——“修改权限”先弹三档选择器
        // （私密/仅好友/公开，当前档带 ✓），选同档即无变化、不发请求；
        // 仅好友→公开→仅好友全程可逆；限时与仅好友互斥规则不动（手动改档恒清限时标记）。
        // 引用规则简化（2026-10-31）：切公开先过引用门禁（私密来源时先问一并公开，
        // 他人来源无一并公开项）；改私密先查引用数提醒；改仅好友为收紧方向，直接放行。
        // 门禁/提醒期间置 busy 防重入，放弃时清 busy、原态未动（乐观落地只在 perform 里做）。
        BearyVisibility.presentPicker(from: self, entry: entry) { [weak self] targetVisibility in
            guard let self = self else { return }
            if targetVisibility == BearyVisibility.current(for: self.entry) { return }
            self.isVisibilityBusy = true
            if targetVisibility == "public" {
                BearyQuoteGate.gatePublicToggle(from: self, entry: self.entry) { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .proceed:
                        self.performVisibilityToggle(targetVisibility: targetVisibility)
                    case .publishTogether(let sourceId):
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "public") { setResult in
                            DispatchQueue.main.async {
                                switch setResult {
                                case .success:
                                    self.performVisibilityToggle(targetVisibility: targetVisibility, publishTogetherSourceId: sourceId)
                                case .failure:
                                    self.isVisibilityBusy = false
                                    BearyToast.show(in: self.view, message: "原日记公开失败，请重试")
                                }
                            }
                        }
                    case .aborted:
                        self.isVisibilityBusy = false
                    }
                }
            } else if targetVisibility == "private" {
                BearyQuoteGate.confirmPrivateToggleIfQuoted(from: self, entryId: entryId) { [weak self] confirmed in
                    guard let self = self else { return }
                    if confirmed {
                        self.performVisibilityToggle(targetVisibility: targetVisibility)
                    } else {
                        self.isVisibilityBusy = false
                    }
                }
            } else {
                self.performVisibilityToggle(targetVisibility: targetVisibility)
            }
        }
    }

    private func performVisibilityToggle(targetVisibility: String, publishTogetherSourceId: String? = nil) {
        guard isAuthor else { return }
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 游客永非作者，到不了这里；未登录同样到不了（作者必登录）。
        let original = entry
        isVisibilityBusy = true
        // 即时反馈（2026-10-29 定版）：点按瞬间先按目标态刷小地球无障碍文案
        // （refreshVisibilityViews 只动文案，不重建栈、不重播动效），失败回滚原态 + 拒绝动效。
        entry.isPublic = BearyVisibility.isPublicValue(targetVisibility)
        entry.visibility = targetVisibility
        entry.ephemeralUntil = nil
        refreshVisibilityViews()
        BearySoundPlayer.play(.visibilityClick)
        // 审计动效组：可见性翻转统一为“图标＋pill 文案＋轻震”——图标与文案
        // 已由上方 refreshVisibilityViews 先行刷出，此处补轻震。
        BearyHaptics.press()
        BearyAPI.shared.setVisibility(id: entryId, visibility: targetVisibility) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVisibilityBusy = false
                switch result {
                case .success(let resp):
                    // 成功回写以回包为准：visibility 缺失时回落 published/目标档；
                    // ephemeralUntil 缺失 = 手动翻转已清限时标记，写回 nil。
                    let isPublic = resp.visibility.map { BearyVisibility.isPublicValue($0) }
                        ?? resp.published.map { $0 == 1 }
                        ?? BearyVisibility.isPublicValue(targetVisibility)
                    self.entry.isPublic = isPublic
                    self.entry.visibility = resp.visibility ?? targetVisibility
                    // 秒开-网络层：转非公开成功即逐出本篇图片的本机缓存（内存+
                    // 磁盘），后续加载走网络、服务端按新可见性判定；失败回滚
                    // 分支不逐出（原态未变，缓存仍可信）；引用全文缓存同清，
                    // 旧引用卡不按旧可见性渲染。
                    if !isPublic {
                        BearyImageLoader.shared.evictEntryImages(keys: self.entry.images ?? [])
                        BearyDiaryCardCell.invalidateQuote(id: entryId)
                    }
                    if let publishedAt = resp.publishedAt {
                        self.entry.publishedAt = publishedAt
                    }
                    // 手动翻转清限时标记（与后端规则、时间线本地同步点同口径），
                    // 除非回包显式带回新的 ephemeralUntil。
                    self.entry.ephemeralUntil = resp.ephemeralUntil
                    BearyHaptics.publishSuccess()
                    self.refreshVisibilityViews()
                    self.refreshEphemeralViews()
                    self.refreshActionRow()
                    // 批 B 补缺（旧详情漏刷）：可见性翻转同时决定引用卡占位态，
                    // 此处不刷则占位停在旧态。
                    self.renderQuote()
                    // 手动翻转已清限时标记：旧到期定时作废（schedule 内先取消、nil 则不排）。
                    self.scheduleEphemeralExpiry()
                    self.onVisibilityChanged?(self.entry)
                case .failure(let err):
                    self.entry = original
                    self.refreshVisibilityViews()
                    // 失败回滚原态：原限时标记若在，按原到期点重排单次定时。
                    self.scheduleEphemeralExpiry()
                    // r29-2：一并公开第二步失败时源篇已公开，尝试恢复回私密；
                    // toast 按恢复结果区分，不用泛化“切换失败”。
                    if let sourceId = publishTogetherSourceId {
                        BearyAPI.shared.setVisibility(id: sourceId, visibility: "private") { [weak self] restoreResult in
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                switch restoreResult {
                                case .success:
                                    BearyToast.show(in: self.view, message: "公开失败，原日记已恢复私密")
                                case .failure:
                                    BearyToast.show(in: self.view, message: "公开失败，原日记恢复失败，请检查")
                                }
                            }
                        }
                    } else {
                        // 失败原因透传：限流时服务端 message 比通用文案有用（entry_write
                        // 120/小时打满即 429）；其余失败仍走通用文案。
                        let message: String
                        if case .server(let code, _) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                        else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                        else { message = "切换失败，请重试" }
                        BearyToast.show(in: self.view, message: message)
                    }
                    BearyHaptics.rejectionWarning()
                    BearySoundPlayer.play(.refuseBonk)
                    if UIAccessibility.isReduceMotionEnabled == false {
                        self.moreButton.layer.removeAnimation(forKey: "bearyDenyShake")
                        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                        shake.values = [0, -8, 8, -5, 5, 0]
                        shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                        shake.duration = 0.4
                        self.moreButton.layer.add(shake, forKey: "bearyDenyShake")
                    }
                }
            }
        }
    }

    @objc private func likePressDown() {
        likePressPreviewActive = true
        BearyHaptics.prepareLike()
    }

    @objc private func likePressCancelled() {
        likePressPreviewActive = false
    }

    @objc private func likeTapped() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计动效组：守卫标记在函数顶部统一消费——deny/未登录等早退路径
        // 同样清零，防残留标记影响下一次点按的守卫判定。
        let hadPressPreview = likePressPreviewActive
        likePressPreviewActive = false
        // 审计 P2-11：非作者的非公开时不再静默 return——拒绝动效＋“公开后才能互动”。
        // 2026-10-31 私密自互动口径：作者本人看自己私密篇时放行。
        if !BearyEphemeral.isEffectivelyPublic(entry) && !isAuthor {
            playDenyShake(on: likeButton)
            BearyToast.show(in: view, message: "公开后才能互动")
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        // 2026-10-29 及时性口径：快连点不再丢点按——每次点按都立即按本次
        // 点按后的态渲染；在途请求只带代次，过期回包直接丢弃。
        let currentlyLiked = entry.likedByMe ?? false
        let originalCount = entry.likeCount ?? 0
        let targetLiked = !currentlyLiked
        // 先行反馈（卡片口径）：点赞即填亮红＋计数 +1，取消即褪色＋计数 −1；
        // 液体炸开与填色同起——点按确认时即播，不再等服务端回包。
        // 审计动效组：touchDown 已由 bearyAddPressFeedback 给过一次 press 轻震，
        // 此处照搬卡片页 hadPressPreview 守卫——有预览时不再补 likeTap，只震一次；
        // 直达抬起（无 touchDown）时仍补一次；音效只在确认时播，不受守卫影响。
        if !currentlyLiked {
            if !hadPressPreview {
                BearyHaptics.likeTap()
            }
            BearySoundPlayer.play(.likePop)
        } else {
            // 取消点赞按点赞同款守卫：touchDown 已给 press 轻震时不再补，
            // 直达抬起（无 touchDown）时补一次；每点按只震一次，不双震。
            if !hadPressPreview {
                BearyHaptics.likeTap()
            }
            BearySoundPlayer.play(.unlikeSoft)
        }
        entry.likedByMe = targetLiked
        entry.likeCount = max(0, originalCount + (currentlyLiked ? -1 : 1))
        refreshActionRow()
        if targetLiked {
            BearyIconMotion.playLikeBurst(on: likeButton)
            BearyBurstParticles.burstLike(from: likeButton)
        } else {
            BearyIconMotion.clearLikeBurst(on: likeButton)
            BearyBurstParticles.clear(from: likeButton)
        }
        likeSeq += 1
        let reqSeq = likeSeq
        BearyAPI.shared.toggleLike(id: entryId, liked: targetLiked) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 代次守卫：已有更新点按时，过期回包直接丢弃。
                guard reqSeq == self.likeSeq else { return }
                self.likeConfirmedSeq = reqSeq
                BearyIconMotion.animateIconScale(on: self.likeButton, to: 1)
                switch result {
                case .success(let resp):
                    let newLiked = resp.liked ?? targetLiked
                    self.entry.likedByMe = newLiked
                    if let count = resp.count {
                        self.entry.likeCount = count
                    }
                    self.confirmedLiked = newLiked
                    self.confirmedLikeCount = self.entry.likeCount ?? 0
                    self.refreshActionRow()
                    // 炸开已在点按时播过，成功回包不再重播；取消点赞不炸。
                    self.onInteractionChanged?(entryId, self.entry.likeCount, newLiked, nil, nil)
                case .failure(let err):
                    // 失败回滚到最后服务端确认态（不是本次点按前的中间态）。
                    self.entry.likedByMe = self.confirmedLiked
                    self.entry.likeCount = self.confirmedLikeCount
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.playDenyShake(on: self.likeButton)
                        BearyToast.show(in: self.view, message: "操作失败，请重试")
                    }
                }
            }
        }
    }

    @objc private func bookmarkTapped() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 审计 P2-11：非作者的非公开时不再静默 return——拒绝动效＋“公开后才能互动”。
        // 2026-10-31 私密自互动口径：作者本人看自己私密篇时放行。
        if !BearyEphemeral.isEffectivelyPublic(entry) && !isAuthor {
            playDenyShake(on: bookmarkButton)
            BearyToast.show(in: view, message: "公开后才能互动")
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        // 及时性口径：快连点每次都立即落地，防重入只靠代次守卫。
        let currentlyBookmarked = entry.bookmarkedByMe ?? false
        let flipped = !currentlyBookmarked
        entry.bookmarkedByMe = flipped
        refreshActionRow()
        BearyIconMotion.playBookmarkPop(on: bookmarkButton)
        if flipped { BearyBurstParticles.burstStar(from: bookmarkButton) }
        if flipped { BearySoundPlayer.play(.bookmarkTick) } else { BearySoundPlayer.play(.unlikeSoft) }
        bookmarkSeq += 1
        let reqSeq = bookmarkSeq
        BearyAPI.shared.toggleBookmark(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 代次守卫：已有更新点按时，过期回包直接丢弃。
                guard reqSeq == self.bookmarkSeq else { return }
                self.bookmarkConfirmedSeq = reqSeq
                switch result {
                case .success(let resp):
                    let newBookmarked = resp.bookmarked ?? flipped
                    self.entry.bookmarkedByMe = newBookmarked
                    self.confirmedBookmarked = newBookmarked
                    self.refreshActionRow()
                    self.onInteractionChanged?(entryId, nil, nil, newBookmarked, nil)
                case .failure(let err):
                    // 失败回滚到最后服务端确认态。
                    self.entry.bookmarkedByMe = self.confirmedBookmarked
                    self.refreshActionRow()
                    if case .unauthorized = err {
                        self.onRequireLogin?()
                    } else {
                        self.playDenyShake(on: self.bookmarkButton)
                        BearyToast.show(in: self.view, message: "操作失败，请重试")
                    }
                }
            }
        }
    }

    @objc private func shareTapped() {
        presentShareSheet()
    }

    @objc private func guestPromptTapped() {
        onRequireLogin?()
    }

    /// 批 B：回应入口只剩行末 + 钮（首页 feedAddButton 同款）；旧“写回应…”
    /// 实心钮与操作行回应钮已删，本函数即 + 钮动作。
    @objc private func emoteAddTapped() {
        if isGuest {
            onRequireLogin?()
            return
        }
        if !BearyEphemeral.isEffectivelyPublic(entry) {
            BearyToast.show(in: view, message: "公开后才能回应")
            return
        }
        if !SessionManager.shared.isLoggedIn {
            onRequireLogin?()
            return
        }
        presentEmotePicker()
    }

    @objc private func emoteChipTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index >= 0, index < chipKeys.count else { return }
        chooseEmote(key: chipKeys[index])
    }

    /// 审计 P2-14：图片重试（广场同款 bearyFeedPerformRetry）。
    @objc private func detailImageRetryTapped(_ sender: BearyFeedRetryButton) {
        bearyFeedPerformRetry(sender)
    }

    @objc private func imageTapped(_ sender: UITapGestureRecognizer) {
        let index = sender.view?.tag ?? 0
        // 实况长按后的抬手点按：压住一次，不进灯箱（卡片同款 suppressTapUntil）。
        if index >= 0, index < imageSlotLiveViews.count,
           let until = imageSlotLiveViews[index].suppressTapUntil, until > Date() {
            return
        }
        guard !imageKeys.isEmpty, index >= 0, index < imageKeys.count else { return }
        if presentedViewController != nil { return }
        let now = Date()
        if let last = lastImageViewerAt, now.timeIntervalSince(last) < 0.8 { return }
        lastImageViewerAt = now
let viewer = BearyEntryImageViewerViewController(imageKeys: imageKeys, liveVideos: entry.liveVideos, startIndex: index)
        viewer.initialThumbnail = (sender.view as? UIImageView)?.image
        viewer.originFrameInWindow = sender.view.map { $0.convert($0.bounds, to: nil) }
        // 无障碍：关闭后焦点回被点的缩略图。
        viewer.focusReturnElement = sender.view
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func quoteTapped() {
        guard let quote = entry.quote, let quoteId = quote.id, !quoteId.isEmpty else { return }
        // gone/locked 卡不导航；其余一律经容器先校验可见性再放行（私密显占位）。
        if quote.gone == true || quote.locked == true { return }
        let now = Date()
        if let last = lastNavigationAt, now.timeIntervalSince(last) < 0.8 { return }
        lastNavigationAt = now
        onQuoteTapped?(quoteId)
    }
}

extension BearyDetailViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 只放行本图片条捏合与条自身滚动平移的共存：捏合 began 即禁了条的
        // 滚动，故自家平移本就滑不动；外层列表/详情页的竖滑若也放行，
        // 两指捏合时手指稍带竖向漂移就会一边捏合一边滚页。先识别意图者胜：
        // 捏合先成立则外层平移失败，竖滑先成立则捏合失败，不再双轨并行。
        // 该 delegate 只挂在捏合手势上，不影响点赞、点图等其他手势。
        return otherGestureRecognizer is UIPanGestureRecognizer
            && otherGestureRecognizer.view === imagesScrollView
    }
}

// MARK: - 单篇详情磁盘缓存（与 BearyFeedCache 同口径，不新增文件）
///
/// 看过单篇的正文按账号分桶、按篇分文件；id 直达（搜索/消息/深链/引用卡）
/// 网络拉不到时先显这份旧正文。占位/拉黑态不写盘；进详情的可见性门仍由
/// routeFetchedEntry 把关（仅好友篇离线直达时仍重验互关、失败落占位）。
/// 退出/401 时由 SessionManager 清桶。
enum BearyDetailCache {
    private static let filePrefix = "beary_detail_cache_"

    struct Snapshot: Codable {
        /// 保留字段：旧文件只有它；新写盘时与 confirmedAt 同值（旧读者仍可读到确认时间）。
        var savedAt: TimeInterval
        /// 上次服务端确认（后台补齐／重试成功时刷新；浏览不刷新）。
        /// 旧文件缺失时回落 savedAt。
        var confirmedAt: TimeInterval? = nil
        /// 上次浏览（进页只刷新它；清理按它挑最久未看的快照）。
        /// 旧文件缺失时回落 savedAt。
        var lastViewedAt: TimeInterval? = nil
        var entry: Entry

        /// 有效确认时间（旧文件 confirmedAt 缺失时取 savedAt）。
        var effectiveConfirmedAt: TimeInterval { confirmedAt ?? savedAt }
        /// 有效上次浏览（旧文件 lastViewedAt 缺失时取 savedAt）。
        var effectiveLastViewedAt: TimeInterval { lastViewedAt ?? savedAt }
    }

    /// 桶：登录账号 id，未登录记 guest 桶（游客看过的公开篇也能离线再看）。
    static func bucket() -> String {
        if let uid = SessionManager.shared.currentUser?.id { return "\(uid)" }
        return "guest"
    }

    private static func safeEntryId(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return id.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private static func fileURL(bucket: String, entryId: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket)_\(safeEntryId(entryId)).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.detailCache.io", qos: .utility)

    private static let generationLock = NSLock()
    private static var generations: [String: UInt64] = [:]

    private static func generation(for bucket: String) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generations[bucket] ?? 0
    }

    private static func bumpGeneration(for bucket: String) {
        generationLock.lock()
        generations[bucket, default: 0] += 1
        generationLock.unlock()
    }

    static func load(bucket: String, entryId: String, completion: @escaping (Snapshot?) -> Void) {
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket, entryId: entryId), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let result = capturedGeneration == generation(for: bucket) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 只写内容态：占位/无 id 的篇不写盘。
    /// 确认态写盘（后台补齐／重试成功时调）：刷新确认时间与正文；上次浏览
    /// 原样保留（后台补齐未必是用户在看，浏览时间只由 markViewed 刷新）。
    static func save(bucket: String, entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty, entry.placeholder != true else { return }
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket, entryId: entryId) else { return }
            let now = Date().timeIntervalSince1970
            let lastViewed = loadSnapshot(at: url)?.effectiveLastViewedAt ?? now
            let snap = Snapshot(savedAt: now, confirmedAt: now, lastViewedAt: lastViewed, entry: entry)
            writeSnapshot(snap, to: url)
            enforceLimits(bucket: bucket)
        }
    }

    /// 浏览记次（进页时调）：只刷新上次浏览，确认时间与正文一字不动；
    /// 无快照时才建一份（首看即确认时间，之后再看只动 lastViewedAt）。
    static func markViewed(bucket: String, entry: Entry) {
        guard let entryId = entry.id, !entryId.isEmpty, entry.placeholder != true else { return }
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket, entryId: entryId) else { return }
            let now = Date().timeIntervalSince1970
            if var existing = loadSnapshot(at: url) {
                existing.lastViewedAt = now
                writeSnapshot(existing, to: url)
            } else {
                let snap = Snapshot(savedAt: now, confirmedAt: now, lastViewedAt: now, entry: entry)
                writeSnapshot(snap, to: url)
                enforceLimits(bucket: bucket)
            }
        }
    }

    /// 读盘解码（ioQueue 内同步用；失败即 nil，不抛）。
    private static func loadSnapshot(at url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// 编码写盘（ioQueue 内同步用）。
    private static func writeSnapshot(_ snap: Snapshot, to url: URL) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(snap) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 单账号桶上限：200 篇／20MB；超限先清最久未看的快照（按
    /// lastViewedAt 升序删，直到计数与体积都回落到上限内）。
    static let maxSnapshotsPerBucket = 200
    static let maxSnapshotBytesPerBucket = 20 * 1024 * 1024

    /// 桶内清理（只在 ioQueue 内调用，与 save/markViewed 同队列串行）。
    private static func enforceLimits(bucket: String) {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let prefix = "\(filePrefix)\(bucket)_"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        var files: [(url: URL, size: Int, lastViewed: TimeInterval)] = []
        var totalBytes = 0
        for name in names where name.hasPrefix(prefix) {
            let url = base.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let lastViewed = loadSnapshot(at: url)?.effectiveLastViewedAt
                ?? (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            files.append((url: url, size: size, lastViewed: lastViewed))
            totalBytes += size
        }
        guard files.count > maxSnapshotsPerBucket || totalBytes > maxSnapshotBytesPerBucket else { return }
        files.sort { $0.lastViewed < $1.lastViewed }
        var index = 0
        while (files.count - index > maxSnapshotsPerBucket || totalBytes > maxSnapshotBytesPerBucket) && index < files.count {
            try? FileManager.default.removeItem(at: files[index].url)
            totalBytes -= files[index].size
            index += 1
        }
    }

    /// 清某账号桶下全部单篇快照（按文件名前缀枚举删除）。
    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let prefix = "\(filePrefix)\(bucket)_"
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
            for name in names where name.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }

    /// R22-B2：单篇失效——删除成功后按账号＋日记 ID 删该篇快照；代次＋1 使
    /// 删除前已排队的写盘／读盘一律作废（写盘不再把旧正文写回来），恢复后
    /// 新回包经 save 重建快照；与 purge 同走串行 ioQueue，删与写顺序有保证。
    static func invalidate(bucket: String, entryId: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket, entryId: entryId) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// BearyDetailViewController.swift
//
// 日记详情页（批 B，2026-10-30 首页布局重做，单独 PR，不合入、不构建）。
// 全屏页（盖住底栏，fadeRise 进场，与 App 全屏页同款），顶栏只剩左上文字“关闭”；
// 版式骨架照搬首页日记卡片 BearyDiaryCardCell（mode=.feed），唯一有意偏离是
// 标题放开换行（首页单行截断；详情是全文页）与正文全文不折叠（首页折叠钮不出现）。
// 单层内容列（#213 保留）：宽 ≤820 时屏宽−32（393 宽即 361pt），宽 ≥821 时 600 居中。
// 列内：头像 40 + 间距 12 + 右列；@ 行（12 粗体橙 + 13 图标）在作者行上方；
// 作者行（名 16.5 粗体、徽章 17、皇冠 19 带 drop-shadow、垫片吸宽、时间 13 灰、
// 天气 15 灰、心情 13 灰 + 20 熊图，按文字基线对齐）；标题 16.5 粗体；正文 16/1.6；
// 引用卡（BearyQuoteCardView，viewer 实时判定）；横向 216 图片条（间距 8、圆角 12、
// 宽按宽高比 0.55–2.22 倍高夹取、无尺寸默认 280、无图高 0）；操作行赞左 + 收藏分享右组
// （无回应钮）；回应在下方流式 chip 行（BearyEmoteFlowView + 34 虚线 + 钮，
// 仅熊脸 key 显示，服务端数据不动）；篇末一条 2pt 全宽线收尾（限时存活期藏线改虚线框）。
// 本人卡右上角 21pt 灰色小地球（28 框、44 热区，对齐作者行；右列右缩进让出 28+8，
// 以内容列为基准即 −36，等价于首页以整屏为基准的 −52，屏上几何一致）；
// 编辑／删除走长按系统上下文菜单（C6 同款，卡片内无 ⋯ 钮，关闭钮保留）。
// 限时：1.5pt 虚线框圆角 16、左右内缩 8／顶 +6／底按右列底 +16 + 倒计时灰字行（作者行下方、标题上方）。
// 纵向间距（右列内）：@→作者 4、作者→限时 4、限时→标题 4、标题→正文 4、
// 正文→引用 10、引用→图片 10、图片→操作行 10、操作行→回应行 10、右列底→底线 12、
// 底线下 24 留白；右列顶：无 @ 行 22、有 @ 行 23。
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
/// 不再由控制器在布局时手动算矩形——右列高度落定（引用加载、回应行出现）
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
        borderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
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
    /// 快连点代次（2026-10-29 及时性口径）：点按不再锁按钮丢点按，每次
    /// 点按代次 +1 并立即按本次点按态渲染；在途回包代次落后于最新代次
    /// 时直接丢弃，不得覆盖更新的点按态；失败回滚到最后确认态。
    private var likeSeq = 0
    private var likeConfirmedSeq = 0
    private var bookmarkSeq = 0
    private var bookmarkConfirmedSeq = 0
    private var confirmedLiked = false
    private var confirmedLikeCount = 0
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
    /// 宽 ≤820：leading = frame.leading＋16、trailing = frame.trailing−16
    /// （required 等式，宽 = 屏宽−32，393 宽即 361pt），不靠 centerX＋
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
    /// 批 B 右列：首页卡片 rightStack 同款（spacing 0 + setCustomSpacing 对照表，
    /// 见 updateRightStackSpacing；顶距由 rightStackTopConstraint 动态定 22/23）。
    private let rightStack = BearyPassThroughStackView()
    private var rightStackTopConstraint: NSLayoutConstraint?
    private var rightStackTrailingConstraint: NSLayoutConstraint?
    private let separatorView = UIView()
    private let closeButton = UIButton(type: .custom)
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
    /// @ 行：首页 recipientRow 同款（13 图标 + 12 粗体橙，间距 5）；点按走 mentionTapped。
    /// 112 视觉扫查：@ 行文案是“@名”，图标须用 icon_at（编辑器 @ 钮、草稿箱 @ chip、
    /// 消息页 @ 角标同款）；此前误用 icon_mail 信封（系统信件图标），与 @ 语义不符。
    private let recipientIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_at", pointSize: 13)
        v.tintColor = BearyColors.orange
        v.contentMode = .scaleAspectFit
        return v
    }()
    private let recipientLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        // 113：底数 12 粗体不动，只加 scaledFont + adjusts（#322/#324 同款做法）。
        lb.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 12))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.orange
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
    /// 作者行：首页 titleStack 同款（名 + 徽章 + 皇冠 + 垫片 + 时间 + 天气 + 心情，
    /// 间距 8、.firstBaseline 对齐）。
    private let nameButton = UIButton(type: .custom)
    private let badgeImageView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        return v
    }()
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
        let st = UIStackView(arrangedSubviews: [nameButton, badgeImageView, crownWrapView, titleSpacerLabel, timeLabel, weatherImageView, weatherTempLabel, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .firstBaseline
        st.distribution = .fill
        return st
    }()
    /// 右上角 ⋯ 钮：时间线 moreButton 同款（21pt 灰色、28 框、44 热区），
    /// 不挂作者行内，挂 contentColumnView 右上角、对齐作者行；右列右缩进见
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
            imagesScrollView.layoutIfNeeded()
        case .ended, .cancelled, .failed:
            imagesScrollView.isScrollEnabled = true
            let progress = max(0, min(1, stripPinchStartProgress + (1 - gesture.scale)))
            let wasJoined = stripPinchJoined
            stripPinchJoined = progress >= 0.5
            // 拼合/张开落点到位时各轻震一次：只在 .ended 且落点状态真的变化时震，
            // 跟手过程、取消/失败、原地未变都不震；减动效时不震（系统触感开关由 UIKit 自身遵循）。
            if gesture.state == .ended && wasJoined != stripPinchJoined && !UIAccessibility.isReduceMotionEnabled {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            UIView.animate(withDuration: 0.25, animations: {
                self.imagesStack.spacing = self.stripPinchJoined ? 0 : 8
                self.applyImageStripCornerRadius(progress: self.stripPinchJoined ? 1 : 0)
                self.imagesScrollView.layoutIfNeeded()
            })
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
    /// 批 E 详情位置行：官方 icon_location 13 灰 + 位置文案，作者本人看自己公开篇时
    /// 下方挂橙色提示；无位置/他人视角无区级时整组隐藏，不留空行（与卡片同口径）。
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
    private let detailLocationNoteLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 12pt，多行提示不跟随大字号。
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.orange
        lb.numberOfLines = 0
        lb.isHidden = true
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
        let st = UIStackView(arrangedSubviews: [detailLocationLineRow, detailLocationNoteLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.spacing = 2
        st.isHidden = true
        return st
    }()
    private let quoteView = BearyQuoteCardView(frame: .zero)
    /// 操作行：首页 actionStack 同款（赞左 + spacer 吸宽 + 收藏分享右组，组内 16；
    /// 无回应钮；分享非公开隐藏时 shareSlotSpacer 占位 21pt，防收藏钮滑位）。
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
        v.widthAnchor.constraint(equalToConstant: 21).isActive = true
        v.heightAnchor.constraint(equalToConstant: 21).isActive = true
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
    /// 约束钉在内容列上（顶 +6、左右内缩 8、底按右列底 +16），
    /// 自身 layoutSubviews 按 bounds 重画，右列高度落定后框底跟着走；
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
        self.isAuthor = entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId)
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
            showPlaceholder()
        } else {
            renderAll()
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
        // 宽 ≥821 用 600 居中，宽 ≤820 用屏宽−32；切换时重算一次。
        let wantWide = view.bounds.width >= 821
        if wantWide != columnIsWide {
            columnIsWide = wantWide
            columnNarrowLeading?.isActive = !wantWide
            columnNarrowTrailing?.isActive = !wantWide
            columnWideWidth?.isActive = wantWide
            columnWideCenterX?.isActive = wantWide
        }
        // 批 B：回应行宽 = 右列宽（旧详情按整列宽算，右列窄 52pt 时会少算换行、
        // 行高偏矮；现按 rightStack 实测宽算，与首页卡片同口径）。
        let width = rightStack.bounds.width
        guard width > 0, width != lastFlowWidth else { return }
        lastFlowWidth = width
        emoteFlowHeight?.constant = emoteFlowView.height(forWidth: width)
    }

    // MARK: - 布局

    private func buildLayout() {
        // 顶栏：只剩左上文字“关闭”（15pt 墨字），右侧不放任何图标。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // 扫查组：此前裸 15pt；顶栏钉高 52，走 cappedFont（与许愿墙顶栏同口径），不撑破顶栏。
        closeButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .highlighted)
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

        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.axis = .vertical
        rightStack.spacing = 0
        rightStack.alignment = .fill
        rightStack.distribution = .fill
        // 清单 18：中间栈透传回应行扩后热区（只认 emoteFlowView 内钮，其他行不动）。
        rightStack.passThroughRoot = emoteFlowView
        contentColumnView.addSubview(rightStack)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentColumnView.addSubview(separatorView)

        // 详情重做（#213 保留）：单层内容列，一条 required 等式钉死列宽，不用
        // centerX＋≥/≤ 不等式护栏，不用 750 优先级补丁等式。
        // scrollView 本身全宽，不加左右 contentInset；列宽分支：
        // ≤820 屏宽−32（393 宽即 361pt），≥821 宽 600 居中。
        columnNarrowLeading = contentColumnView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16)
        columnNarrowTrailing = contentColumnView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16)
        columnWideWidth = contentColumnView.widthAnchor.constraint(equalToConstant: 600)
        columnWideCenterX = contentColumnView.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
        columnWideWidth?.isActive = false
        columnWideCenterX?.isActive = false
        // 详情闪退加固（2026-10-30 审计）：本段此前用 4 处强制解包激活约束；
        // 约束确在上一行刚赋值、正常路径不可能为空，但进页链路是全入口共用、
        // 一旦某一路异常即全崩，故改本地常量激活、彻底去掉强制解包，行为不变。
        let narrowLeading = columnNarrowLeading
        let narrowTrailing = columnNarrowTrailing
        // 批 B：头像顶 14、右列顶 22（有 @ 行时 23，见 updateRightStackSpacing）；
        // 右列右缩进：他人 0、本人 −36（让出小地球 28 + 间隙 8；以内容列为基准，
        // 等价于首页以整屏为基准的 −52，屏上几何一致）。
        let rightTop = rightStack.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 22)
        let rightTrailing = rightStack.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor, constant: 0)
        rightStackTopConstraint = rightTop
        rightStackTrailingConstraint = rightTrailing
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
            rightTop,
            // 106 闪退根因（2026-10-31 .ips 实证）：本行原先在此激活，但
            // avatarButton 要到后面的 buildCardHeader() 才 addSubview 到
            // contentColumnView——激活时两端无共同祖先，NSLayoutConstraint
            // 直接抛 AutoLayout 异常 → SIGABRT，全入口进详情必崩。
            // 故本约束改到 buildCardHeader() 内、avatarButton 入层级后再激活，
            // 几何（右列左缘 = 头像右缘 + 12）一字不变。
            rightTrailing,
            separatorView.topAnchor.constraint(equalTo: rightStack.bottomAnchor, constant: 12),
            separatorView.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 2),
            separatorView.bottomAnchor.constraint(equalTo: contentColumnView.bottomAnchor, constant: -24),
        ])

        buildCardHeader()
        buildEphemeralRow()
        buildBody()
        buildImages()
        buildQuote()
        buildLocation()
        buildActionRow()
        buildEmoteRow()
        buildPlaceholderState()
        // 2026-10-31：长按上下文菜单已归并进右上角 ⋯ 菜单（时间线风格），不再挂
        // UIContextMenuInteraction；管理类操作一律走 ⋯，点赞／收藏／分享仍在操作行。
    }

    /// 首页卡片头部同款：左列头像 40 + 右列（@ 行、作者行）；⋯ 钮不进作者行，
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
            avatarButton.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 14),
            avatarButton.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor),
            avatarButton.widthAnchor.constraint(equalToConstant: 40),
            avatarButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        avatarButton.addTarget(self, action: #selector(authorTapped), for: .touchUpInside)
        avatarButton.bearyAddPressFeedback()

        // 106 闪退修复：右列左缘约束必须在此激活——此前它在 buildLayout()
        // 的大激活列表里、avatarButton 尚未入层级时就被激活，必抛异常。
        // avatarButton 已在上面 addSubview 到 contentColumnView，两端现已
        // 同属 contentColumnView 层级，激活安全；几何与旧值一致（+12）。
        NSLayoutConstraint.activate([
            rightStack.leadingAnchor.constraint(equalTo: avatarButton.trailingAnchor, constant: 12),
        ])

        // @ 行：有 mentionedName 才显（见 renderHeaderMeta），点按进被 @ 者主页。
        recipientRow.isUserInteractionEnabled = true
        recipientRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(mentionTapped)))
        rightStack.addArrangedSubview(recipientRow)

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
        // 首页 feed 模式皇冠带网页 drop-shadow（0 1px 1px 黑 30%）。
        crownView.layer.shadowColor = UIColor.black.cgColor
        crownView.layer.shadowOpacity = 0.30
        crownView.layer.shadowOffset = CGSize(width: 0, height: 1)
        crownView.layer.shadowRadius = 1
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        badgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        weatherImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 隐藏子视图的固定尺寸用 999 优先级，避免与 stack 压零冲突（首页同款）。
        let recipientIconHeight = recipientIconView.heightAnchor.constraint(equalToConstant: 13)
        recipientIconHeight.priority = UILayoutPriority(999)
        let badgeWidth = badgeImageView.widthAnchor.constraint(equalToConstant: 17)
        badgeWidth.priority = UILayoutPriority(999)
        let crownWidth = crownView.widthAnchor.constraint(equalToConstant: 19)
        crownWidth.priority = UILayoutPriority(999)
        let weatherWidth = weatherImageView.widthAnchor.constraint(equalToConstant: 15)
        weatherWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            recipientIconView.widthAnchor.constraint(equalToConstant: 13),
            recipientIconHeight,
            badgeWidth,
            badgeImageView.heightAnchor.constraint(equalToConstant: 17),
            crownWidth,
            crownView.heightAnchor.constraint(equalToConstant: 19),
            weatherWidth,
            weatherImageView.heightAnchor.constraint(equalToConstant: 15),
        ])
        rightStack.addArrangedSubview(authorRow)

        // 右上角 ⋯ 钮：时间线 moreButton 同款（21pt 灰色、28 框、44 热区），图标恒为三点。
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setImage(BearyFeedIconCache.image(named: "icon_more", pointSize: 21), for: .normal)
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
        // （顶 +6、左右内缩 8、底按右列底 +16），右列高度一变框就跟着变，
        // 不再依赖布局时手动算矩形的旧时机（旧时机下回应行高度落定后框底
        // 仍停在旧位置，正好切穿“＋”回应钮）。
        rightStack.addArrangedSubview(ephemeralRow)
        contentColumnView.insertSubview(ephemeralBorderView, at: 0)
        NSLayoutConstraint.activate([
            ephemeralBorderView.topAnchor.constraint(equalTo: contentColumnView.topAnchor, constant: 6),
            ephemeralBorderView.leadingAnchor.constraint(equalTo: contentColumnView.leadingAnchor, constant: 8),
            ephemeralBorderView.trailingAnchor.constraint(equalTo: contentColumnView.trailingAnchor, constant: -8),
            ephemeralBorderView.bottomAnchor.constraint(equalTo: rightStack.bottomAnchor, constant: 16),
        ])
    }

    private func buildBody() {
        rightStack.addArrangedSubview(titleLabel)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byCharWrapping
        bodyLabel.textColor = BearyColors.ink
        rightStack.addArrangedSubview(bodyLabel)
    }

    private func buildImages() {
        rightStack.addArrangedSubview(imagesScrollView)
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

    /// 批 E 详情位置行（rebase 落点：新骨架右列 rightStack，引用卡之后、操作行之前；
    /// 旧详情挂在 chips 行后、引用卡之前，批 B 已删 chips 行与旧 stackView，故改挂右列）：
    /// 官方 icon_location 13 灰 + 位置文案，作者本人看自己公开篇时下方挂橙色提示；
    /// 无位置/他人视角无区级时整组隐藏，不留空行（与卡片同口径）。
    private func buildLocation() {
        rightStack.addArrangedSubview(detailLocationStack)
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
        rightStack.addArrangedSubview(quoteView)
    }

    private func buildActionRow() {
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .horizontal
        actionStack.spacing = 16
        actionStack.alignment = .center

        likeButton.translatesAutoresizingMaskIntoConstraints = false
        likeButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        // 扫查组：此前 scaledFont 却缺 adjusts，档位变化时赞数字号不跟、
        // 显式宽也不重算；补 adjusts，宽重算见 traitCollectionDidChange。
        likeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.adjustsImageWhenHighlighted = false
        likeButton.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        likeButton.bearyAddPressFeedback()
        // 显式宽约束（卡片同款，见 likeButtonWidthConstraint 注释）：初始只图标宽，
        // refreshActionRow 按赞数重算；不靠按钮固有宽，防数字被裁成左半弧。
        let likeWidth = likeButton.widthAnchor.constraint(equalToConstant: 22)
        likeWidth.isActive = true
        likeButtonWidthConstraint = likeWidth

        // 批 B：收藏／分享均为纯图标（首页同款，收藏去中文标签）；尺寸 21。
        bookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        bookmarkButton.adjustsImageWhenHighlighted = false
        bookmarkButton.setImage(BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21), for: .normal)
        bookmarkButton.tintColor = BearyColors.gray
        bookmarkButton.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        bookmarkButton.bearyAddPressFeedback()

        shareButton.translatesAutoresizingMaskIntoConstraints = false
        shareButton.adjustsImageWhenHighlighted = false
        shareButton.setImage(BearyFeedIconCache.image(named: "icon_share", pointSize: 21), for: .normal)
        shareButton.tintColor = BearyColors.gray
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        shareButton.bearyAddPressFeedback()
        NSLayoutConstraint.activate([
            bookmarkButton.widthAnchor.constraint(equalToConstant: 21),
            bookmarkButton.heightAnchor.constraint(equalToConstant: 21),
            shareButton.widthAnchor.constraint(equalToConstant: 21),
            shareButton.heightAnchor.constraint(equalToConstant: 21),
        ])

        // 中部 spacer（最低 hugging / 最低抗压）吸掉全部剩余宽度，赞左、
        // 收藏分享右组、每篇位置固定一致（首页 actionStack 同款）。
        let actionSpacer = UIView()
        actionSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        actionStack.addArrangedSubview(likeButton)
        actionStack.addArrangedSubview(actionSpacer)
        actionStack.addArrangedSubview(bookmarkButton)
        actionStack.addArrangedSubview(shareButton)
        actionStack.addArrangedSubview(shareSlotSpacer)
        rightStack.addArrangedSubview(actionStack)

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
        rightStack.addArrangedSubview(guestPromptButton)
    }

    private func buildEmoteRow() {
        // 回应行：首页同款——操作行下方流式 chip 行 + 行末 34 虚线 + 钮，
        // 不再设“回应”标题行与“写回应…”实心钮；行高由 emoteFlowHeight 驱动。
        emoteFlowView.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(emoteFlowView)
        emoteFlowHeight = emoteFlowView.heightAnchor.constraint(equalToConstant: 0)
        emoteFlowHeight?.isActive = true
    }

    /// 首页 updateRightStackSpacing 同款对照表（详情无折叠钮，故正文后恒取 10）：
    /// @→作者 4、作者→限时 4、限时→标题 4、标题→正文 4（标题隐藏时 0，
    /// 作者行→正文仍为上行 4）、正文→引用 10、引用→图片 10、图片→操作行 10、
    /// 操作行→回应行 10；批 E 位置行插在引用卡与操作行之间，引用→位置 10、
    /// 位置→操作行 10（无位置时整组隐藏、不留空行）；右列顶：无 @ 行 22、有 @ 行 23。
    private func updateRightStackSpacing() {
        rightStackTopConstraint?.constant = recipientRow.isHidden ? 22 : 23
        rightStack.setCustomSpacing(4, after: recipientRow)
        rightStack.setCustomSpacing(4, after: authorRow)
        rightStack.setCustomSpacing(4, after: ephemeralRow)
        rightStack.setCustomSpacing(titleLabel.isHidden ? 0 : 4, after: titleLabel)
        rightStack.setCustomSpacing(10, after: bodyLabel)
        rightStack.setCustomSpacing(10, after: quoteView)
        rightStack.setCustomSpacing(10, after: imagesScrollView)
        rightStack.setCustomSpacing(10, after: detailLocationStack)
        rightStack.setCustomSpacing(10, after: actionStack)
        rightStack.setCustomSpacing(10, after: guestPromptButton)
    }

    /// 内容区（头像 + 右列 + 小地球 + 底线）整体显隐：占位／失败态整藏，
    /// 恢复时小地球显隐与右列缩进由 refreshAuthorActions、底线显隐由
    /// refreshEphemeralViews 按限时态重算（不由本函数定）。
    private func setContentVisible(_ visible: Bool) {
        avatarButton.isHidden = !visible
        rightStack.isHidden = !visible
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

    private func showPlaceholder() {
        // 私密占位：仅一句文案，不带标题／封面／时间／作者名；内容栈整藏。
        // 文案每次显式配齐：失败态（showFetchFailed）改过同一视图文案，复位防串味。
        // 副文案灰色多行居中（原 16pt 灰字 → 组件 12.5pt 灰色副文案，统一组件口径）；
        // 无插图、无动作钮（关闭重进即重试的约定不变）。
        placeholderStateView.configure(kind: .empty, title: nil, subtitle: "该日记已设为私密", iconName: nil, actionTitle: nil)
        setContentVisible(false)
        placeholderStateView.isHidden = false
    }

    /// 2026-10-29 Li 定（P0-3 包括项，推翻第 17 项“弱网/失败先出页面仍可看”）：
    /// 后台补齐失败时清为无正文态——内容栈整藏，居中一句失败文案，不留卡片旧内容；
    /// 不用私密占位文案（失败不是私密）；关闭钮仍可用，关了重进即重试。
    /// 页内已因拉黑/举报转占位时不动（隐私占位优先于失败态）。
    /// 与占位共用 BearyStateView 布局（P1-2 一并受益），无重试钮，不另起一套。
    func showFetchFailed() {
        if locallyHiddenByModeration { return }
        setContentVisible(false)
        placeholderStateView.configure(kind: .error, title: nil, subtitle: "加载失败，请稍后再试", iconName: nil, actionTitle: nil)
        placeholderStateView.isHidden = false
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
        updateRightStackSpacing()
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
        attachment.bounds = CGRect(x: 0, y: font.descender, width: font.pointSize, height: font.pointSize)
        let result = NSMutableAttributedString(attributedString: base)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private func renderHeaderMeta() {
        let authorNameValue = entry.authorName ?? "beary 用户"
        nameButton.setTitle(authorNameValue, for: .normal)
        avatarInitialLabel.text = String(authorNameValue.prefix(1)).uppercased()
        if let createdAt = entry.createdAt {
            timeLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
        } else {
            timeLabel.text = nil
        }
        if let avatarPath = entry.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
            bearyFeedLoadImage(into: avatarImageView, url: url, retryButton: avatarRetryButton, downsampleToWidth: 80)
        } else {
            avatarImageView.bearySetImage(url: nil)
            avatarRetryButton.isHidden = true
            avatarRetryButton.retryURL = nil
        }
        if let mentioned = entry.mentionedName, !mentioned.isEmpty {
            recipientRow.isHidden = false
            recipientLabel.text = "@" + mentioned
        } else {
            recipientRow.isHidden = true
            recipientLabel.text = nil
        }
        // BETA 徽章已下线：用户名右边不再显示佩戴徽章（Plus 皇冠不受影响）。
        badgeImageView.image = nil
        badgeImageView.isHidden = true
        setCrownHidden((entry.authorPlus ?? 0) != 1 || !crownView.hasCrown)
        if let weatherKey = entry.weather, !weatherKey.isEmpty,
           let weatherImage = BearyFeedIconCache.image(named: "icon_wx_" + weatherKey, pointSize: 15) {
            weatherImageView.image = weatherImage
            weatherImageView.isHidden = false
        } else {
            weatherImageView.image = nil
            weatherImageView.isHidden = true
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
        moodStack.isHidden = true
        moodLabel.text = nil
        moodEmoteView?.removeFromSuperview()
        moodEmoteView = nil
    }


    /// 2026-10-29 第 17 项：后台补齐入口——卡片点按即时呈现后，后台 fetch 回包调它。
    /// 只更新变化处（字段级比对，变了才刷对应区），不重建栈、不重播已有元素的
    /// 动效、不闪 skeleton；弱网/失败时不调本函数，改走 showFetchFailed 清为无正文态。
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
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            label.alpha = 1
        })
    }

    private func fadeButtonTitle(_ button: UIButton) {
        guard !UIAccessibility.isReduceMotionEnabled, button.window != nil,
              let titleLabel = button.titleLabel else { return }
        titleLabel.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            titleLabel.alpha = 1
        })
    }

    private func fadeView(_ view: UIView) {
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.alpha = 1
            return
        }
        view.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            view.alpha = 1
        })
    }

    func update(with fetched: Entry) {
        // 审计 P2-20：页内已因拉黑/举报转占位时，后台补齐一律忽略，不得复活全文。
        if locallyHiddenByModeration { return }
        guard fetched.id == entry.id else { return }
        let old = entry
        if fetched.placeholder == true {
            // 占位优先：只立占位旗，不整体覆盖模型（在途先行态不受占位回包冲掉；
            // 内容栈已整藏，占位期间模型其余字段不可见；后续内容回包再按合并恢复）。
            ephemeralExpiryTimer?.invalidate()
            ephemeralExpiryTimer = nil
            entry.placeholder = true
            showPlaceholder()
            return
        }
        // 按字段合并：先取服务端全量，再把在途字段写回本地值。
        var merged = fetched
        // 及时性口径：代次未确认（有在途请求）时护乐观字段；在途请求全部
        // 落定（代次已确认）时，合并后的服务端值即新确认态。
        if likeSeq != likeConfirmedSeq {
            merged.likedByMe = old.likedByMe
            merged.likeCount = old.likeCount
        } else {
            confirmedLiked = merged.likedByMe ?? false
            confirmedLikeCount = merged.likeCount ?? 0
        }
        if bookmarkSeq != bookmarkConfirmedSeq {
            merged.bookmarkedByMe = old.bookmarkedByMe
            merged.bookmarkCount = old.bookmarkCount
        } else {
            confirmedBookmarked = merged.bookmarkedByMe ?? false
        }
        if isEmoteBusy {
            merged.emotes = old.emotes
        }
        if isVisibilityBusy {
            merged.isPublic = old.isPublic
            merged.publishedAt = old.publishedAt
            merged.ephemeralUntil = old.ephemeralUntil
        }
        entry = merged
        // 内容页本身被占位过时（本路径不会发生：卡片数据恒为内容态），先恢复内容区。
        setContentVisible(true)
        placeholderStateView.isHidden = true
        if old.authorName != merged.authorName || old.createdAt != merged.createdAt || old.authorAvatar != merged.authorAvatar || old.authorBadge != merged.authorBadge || old.authorPlus != merged.authorPlus || old.mood != merged.mood || old.weather != merged.weather || old.mentionedName != merged.mentionedName || old.mentionedUserId != merged.mentionedUserId {
            renderHeaderMeta()
            // 116：头信息文案变化时只淡入文案元素（头像图与徽章／天气／
            // 心情图标为图片，到达即显，不在此淡入）。
            fadeButtonTitle(nameButton)
            fadeLabel(timeLabel)
            fadeLabel(recipientLabel)
            fadeLabel(moodLabel)
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
        if (old.images ?? []) != (merged.images ?? []) {
            renderImages()
        }
        // 批 E：位置字段或可见性/限时态变化时位置行重算（公开翻私密恢复精确，反之脱敏）。
        if old.locationName != merged.locationName || old.locationDistrict != merged.locationDistrict || old.isPublic != merged.isPublic || old.ephemeralUntil != merged.ephemeralUntil {
            renderLocation()
        }
        let oldQuote = old.quote
        let newQuote = merged.quote
        if oldQuote?.id != newQuote?.id || oldQuote?.content != newQuote?.content || oldQuote?.gone != newQuote?.gone || oldQuote?.locked != newQuote?.locked || oldQuote?.isPublic != newQuote?.isPublic {
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
        if old.isPublic != merged.isPublic || old.publishedAt != merged.publishedAt || old.ephemeralUntil != merged.ephemeralUntil {
            refreshVisibilityViews()
            refreshEphemeralViews()
            refreshAuthorActions()
            // 有效公开态同时决定操作行压暗／分享显隐与引用卡占位态，
            // 可见性变化时一并刷这两处，否则小地球文案已变、私密门控仍停在旧态。
            refreshActionRow()
            renderQuote()
        }
        // 标题／@ 行显隐变化时重算右列间距与顶距（标题隐藏时其后间距置 0、
        // @ 行显隐改顶距 22/23），其余字段变化不影响间距。
        updateRightStackSpacing()
        // 限时到期重排：回包可能带来新的 ephemeralUntil（或已过期），按新模型复核一次。
        if !applyEphemeralExpiryIfNeeded() {
            scheduleEphemeralExpiry()
        }
    }

    // MARK: - 限时到期（审计三轮第二批 9）

    /// 按最近 ephemeralUntil 排一次单次刷新：非限时／已占位／已拉黑钉死时不排；
    /// 已过期不在此排（调用方先走 applyEphemeralExpiryIfNeeded 落定）。
    /// 不做重复定时、不按秒轮询——倒计时文案本身是小时粒度，无需逐秒重刷。
    private func scheduleEphemeralExpiry() {
        ephemeralExpiryTimer?.invalidate()
        ephemeralExpiryTimer = nil
        guard !locallyHiddenByModeration, entry.placeholder != true else { return }
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
        // 失败态（showFetchFailed 藏了内容区）不动：失败态本身不露内容，
        // 且文案约定是“关闭重进即重试”，到期刷新不得把它改写成私密文案。
        guard !rightStack.isHidden else { return false }
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
        showPlaceholder()
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

    /// 作者行右侧显隐：本人卡显小地球、右列右缩进 −36 让位；他人／游客无地球、
    /// 右列恢复 0。游客永非作者，到不了本人分支。
    /// 皇冠显隐唯一入口：容器与皇冠同藏同显，不留 19pt 空位。
    private func setCrownHidden(_ hidden: Bool) {
        crownWrapView.isHidden = hidden
        crownView.isHidden = hidden
        if hidden { crownView.stop() } else { crownView.start() }
    }

    private func refreshAuthorActions() {
        // 2026-10-31：⋯ 显隐——本人卡（编辑／修改权限／删除）或他人公开卡
        // （举报／拉黑）显；游客与占位态（他人私密）无菜单项，藏；右列右缩进
        // −36 给 ⋯（28 框）留位，藏时恢复 0。
        let showMore = !isGuest && (isAuthor || BearyEphemeral.isEffectivelyPublic(entry))
        moreButton.isHidden = !showMore
        rightStackTrailingConstraint?.constant = showMore ? -36 : 0
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
            bearyFeedLoadImage(into: slot, url: BearyImageURLs.imageURL(key: imageKey, thumb: true), retryButton: imageSlotRetryButtons[imageIndex], downsampleToWidth: strip * UIScreen.main.scale)
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
    /// 位置行改挂右列，见 buildLocation），
    /// 可见性翻转时位置行随 isPublic 变化同步变（公开→私密恢复精确，他人视角反之）。
    private func renderLocation() {
        guard let display = BearyLocationDisplay.display(entry: entry) else {
            detailLocationStack.isHidden = true
            detailLocationLabel.text = nil
            detailLocationNoteLabel.text = nil
            detailLocationNoteLabel.isHidden = true
            return
        }
        detailLocationStack.isHidden = false
        detailLocationLabel.text = display.line
        if let note = display.note {
            detailLocationNoteLabel.text = note
            detailLocationNoteLabel.isHidden = false
        } else {
            detailLocationNoteLabel.text = nil
            detailLocationNoteLabel.isHidden = true
        }
    }

    /// 引用卡 viewer 实时判定（卡片 presentQuoteCard 同口径）：作者本人或已公开才显全文，
    /// 否则占位；gone → 已删除，locked／未公开 → 引用规则简化占位文案
    /// （曾公开“该日记已私密”＋提醒句，从未公开“该日记未公开”，见 BearyQuoteGate.placeholderText）。
    private func renderQuote() {
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
            let placeholder = BearyQuoteGate.placeholderText(publishedAt: quote.publishedAt, locked: true)
            quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            quoteView.isHidden = false
            return
        }
        let content = quote.content ?? ""
        if content.isEmpty {
            if quote.isPublic == false {
                let placeholder = BearyQuoteGate.placeholderText(publishedAt: quote.publishedAt, locked: false)
                quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            } else {
                quoteView.showGone(message: "引用的日记已删除", iconName: "icon_quote", sourceDeleted: true)
            }
            quoteView.isHidden = false
            return
        }
        guard quoteIsMine || quote.isPublic == true else {
            let placeholder = BearyQuoteGate.placeholderText(publishedAt: quote.publishedAt, locked: false)
            quoteView.showGone(message: placeholder.main, iconName: "icon_lock", detail: placeholder.detail, sourceHandle: quote.authorHandle, sourceDateMs: quote.createdAt)
            quoteView.isHidden = false
            return
        }
        quoteView.configure(
            authorName: quote.authorName ?? "",
            authorAvatar: quote.authorAvatar,
            content: content,
            images: quote.images ?? [],
            dims: quote.imgDims,
            createdAt: quote.createdAt,
            allowThumbs: quote.isPublic == true || quoteIsMine,
            authorHandle: quote.authorHandle,
            sourceTappable: true
        )
        quoteView.isHidden = false
    }

    // MARK: - 操作行

    /// 点赞点亮走红色、收藏点亮走橙色，与现有先行反馈口径；数字只 setTitle，不重建行。
    /// 批 B 操作行（首页同款）：赞左 + spacer + 收藏分享右组，无回应钮；
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
        let heartImage = BearyFeedIconCache.image(named: liked ? "icon_heart_fill" : "icon_heart", pointSize: 22)
            ?? BearyFeedIconCache.image(named: "icon_heart", pointSize: 22)
        likeButton.setImage(heartImage, for: .normal)
        // 赞数 0 隐藏整段数字（2026-10-31 Li 纠正口径）：setTitle(nil) 后宽度只剩
        // 图标宽，不占数字位、不留残影；有赞时显完整数字，宽度显式算
        //（图标宽 + 6 边距 + 标题宽，卡片同款），不靠按钮固有宽。
        let imageWidth = heartImage?.size.width ?? 22
        if likeCount <= 0 {
            likeButton.setTitle(nil, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth
        } else {
            let titleText = "\(likeCount)"
            let titleWidth = ceil((titleText as NSString).size(withAttributes: [NSAttributedString.Key.font: likeButton.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))]).width)
            likeButton.setTitle(titleText, for: .normal)
            likeButtonWidthConstraint?.constant = imageWidth + 6 + titleWidth
        }
        likeButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        likeButton.tintColor = liked ? BearyColors.likeRed : BearyColors.gray
        likeButton.setTitleColor(liked ? BearyColors.likeRed : BearyColors.gray, for: .normal)
        likeButton.setTitleColor(liked ? BearyColors.likeRed : BearyColors.gray, for: .highlighted)
        likeButton.accessibilityLabel = likeCount <= 0 ? "点赞" : "\(liked ? "已点赞" : "点赞")，\(likeCount)"

        let bookmarked = entry.bookmarkedByMe ?? false
        let bookmarkImage = BearyFeedIconCache.image(named: bookmarked ? "icon_bookmark_fill" : "icon_bookmark", pointSize: 21)
            ?? BearyFeedIconCache.image(named: "icon_bookmark", pointSize: 21)
        bookmarkButton.setImage(bookmarkImage, for: .normal)
        bookmarkButton.tintColor = bookmarked ? BearyColors.orange : BearyColors.gray
        bookmarkButton.accessibilityLabel = bookmarked ? "已收藏" : "收藏"
        shareButton.accessibilityLabel = "分享"

        // 卡片互动门控同口径：2026-10-31 私密自互动口径——点赞／收藏为“有效公开 或 作者本人”
        // 时正常显示，非作者看非公开篇仍压暗；分享不动，仍仅有效公开才有（私密不交出正文与链接），
        // 分享隐藏时留 21pt 槽位占位（首页 shareSlotSpacer 同款），防收藏钮滑到最右边缘。
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
                    UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                        chip.transform = .identity
                        chip.alpha = 1.0
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
            made.setImage(BearyFeedIconCache.image(named: "icon_plus", pointSize: 16), for: .normal)
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
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseIn], animations: {
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
        onAuthorTapped?(authorId)
    }

    @objc private func mentionTapped() {
        guard let mentionedId = entry.mentionedUserId else { return }
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
        present(sheet, animated: true)
    }

    @objc private func visibilityTapped() {
        guard isAuthor else { return }
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        if isVisibilityBusy { return }
        // 引用规则简化（2026-10-31）：切公开先过引用门禁（私密来源时先问一并公开，
        // 他人来源无一并公开项）；改私密先查引用数提醒。门禁/提醒期间置 busy 防重入，
        // 放弃时清 busy、原态未动（乐观落地只在 perform 里做）。
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        isVisibilityBusy = true
        if target == 1 {
            BearyQuoteGate.gatePublicToggle(from: self, entry: entry) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .proceed:
                    self.performVisibilityToggle()
                case .publishTogether(let sourceId):
                    BearyAPI.shared.setVisibility(id: sourceId, published: 1) { setResult in
                        DispatchQueue.main.async {
                            switch setResult {
                            case .success:
                                self.performVisibilityToggle()
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
        } else {
            BearyQuoteGate.confirmPrivateToggleIfQuoted(from: self, entryId: entryId) { [weak self] confirmed in
                guard let self = self else { return }
                if confirmed {
                    self.performVisibilityToggle()
                } else {
                    self.isVisibilityBusy = false
                }
            }
        }
    }

    private func performVisibilityToggle() {
        guard isAuthor else { return }
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        // 游客永非作者，到不了这里；未登录同样到不了（作者必登录）。
        // 目标态按有效态算：已到期限时篇 stored 仍为公开，但按私密算，点按应是公开（目标 1）。
        // （2026-10-29 第 18 项核实：详情页目标态本已正确，三处列表入口与之对齐，详情页不动算法。）
        let target = BearyEphemeral.isEffectivelyPublic(entry) ? 0 : 1
        let original = entry
        isVisibilityBusy = true
        // 即时反馈（2026-10-29 定版）：点按瞬间先按目标态刷小地球无障碍文案
        // （refreshVisibilityViews 只动文案，不重建栈、不重播动效），失败回滚原态 + 拒绝动效。
        entry.isPublic = target == 1
        entry.ephemeralUntil = nil
        refreshVisibilityViews()
        BearySoundPlayer.play(.visibilityClick)
        BearyAPI.shared.setVisibility(id: entryId, published: target) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isVisibilityBusy = false
                switch result {
                case .success(let resp):
                    let isPublic = resp.published.map { $0 == 1 } ?? (target == 1)
                    self.entry.isPublic = isPublic
                    // 秒开-网络层：转私密成功即逐出本篇图片的本机缓存（内存+
                    // 磁盘），后续加载走网络、服务端按新可见性判定；失败回滚
                    // 分支不逐出（原态未变，缓存仍可信）。
                    if !isPublic {
                        BearyImageLoader.shared.evictEntryImages(keys: self.entry.images ?? [])
                    }
                    if let publishedAt = resp.publishedAt {
                        self.entry.publishedAt = publishedAt
                    }
                    // 手动翻转清限时标记（与后端规则、时间线本地同步点同口径）。
                    self.entry.ephemeralUntil = nil
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
                    // 失败原因透传：限流时服务端 message 比通用文案有用（entry_write
                    // 120/小时打满即 429）；其余失败仍走通用文案。
                    let message: String
                    if case .server(let code) = err, code == "rate_limited" { message = "操作太频繁，请稍后再试" }
                    else if case .http(let status, _) = err, status == 429 { message = "操作太频繁，请稍后再试" }
                    else { message = "切换失败，请重试" }
                    BearyToast.show(in: self.view, message: message)
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

    @objc private func likeTapped() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
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
        if !currentlyLiked {
            BearyHaptics.likeTap()
            BearySoundPlayer.play(.likePop)
        } else {
            BearySoundPlayer.play(.unlikeSoft)
        }
        entry.likedByMe = targetLiked
        entry.likeCount = max(0, originalCount + (currentlyLiked ? -1 : 1))
        refreshActionRow()
        if targetLiked {
            BearyIconMotion.playLikeBurst(on: likeButton)
        } else {
            BearyIconMotion.clearLikeBurst(on: likeButton)
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
let viewer = BearyEntryImageViewerViewController(imageKeys: imageKeys, liveVideos: entry.liveVideos, startIndex: index)
        viewer.originFrameInWindow = sender.view.map { $0.convert($0.bounds, to: nil) }
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func quoteTapped() {
        guard let quote = entry.quote, let quoteId = quote.id, !quoteId.isEmpty else { return }
        // gone/locked 卡不导航；其余一律经容器先校验可见性再放行（私密显占位）。
        if quote.gone == true || quote.locked == true { return }
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

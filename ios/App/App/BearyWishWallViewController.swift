import UIKit

// ===== 功能许愿墙（2026-10-29 补缺第 21 项；进 100 包）=====
// 产品口径（Li 2026-10-29 定）：仅 Plus 会员可发起许愿（服务端校验，App 侧只隐藏
// 发起钮）；所有登录用户可赞成 / 反对，游客只看不能投；每人每条一票、可改投、
// 再点同票取消；列表按净赞成（赞成减反对）降序（服务端排好，App 不再重排）；
// 管理员可标记“已完成”。投票走即时反馈口径：点按瞬间改数与选中态，服务端回包
// 对齐，失败回滚 + 摇头 + toast + warning 震动（与 10-29 即时性总口径同款）。
// 界面：全屏 modal + fadeRise（同反馈页）；左上文字「关闭」15pt 墨字、标题 17；
// iPad 内容列 600 居中（顶栏与内容列同宽，P2-17 口径）；动效只走 transform /
// opacity，新行入场错峰、已有行不重播；无骨架屏（已删口径）；组件走 iOS 系统
// 组件，图标只用官方包（本页无主图标，状态 pill 纯文字）。
// 后端状态：本文件对应接口（GET /beary/api/wishes、POST /beary/api/wishes、
// POST /beary/api/wishes/:id/vote、POST /beary/api/wishes/:id/status）已于
// 2026-10-29 部署上线；接口失败时本页走失败态（重试钮），不编造假数据。

// MARK: - 行视图（纯代码行：标题 / 详情 / 发起人时间 / 净赞成 / 两票钮 / 状态 pill）

private final class WishRowView: UIView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let metaLabel = UILabel()
    private let netLabel = UILabel()
    // 08：投票区换行——voteRow 提为属性，另备一行 voteRowWrapped（仅换行态显形，内为弹性
    // spacer + netLabel，净数贴右缘）；换行态由 layoutSubviews 的 updateVoteWrap 判定。
    private var voteRow: UIStackView!
    private let voteRowWrapped = UIStackView()
    private let voteWrapSpacer = UIView()
    private var isVoteWrapped = false
    private let donePill = UILabel()
    // 展开/收起钮：视觉仍为 13pt 文字固有高，热区由 BearyHit44Button 的 point(inside:) 向外扩到 44pt（不改约束、不改文案）。
    private let expandButton = BearyHit44Button(type: .system)
    private var isDetailExpanded = false
    private var detailFullText = ""
    private var detailOverflow = false
    // 审计第 13 项：溢出结果缓存——键为内容＋字体＋可用宽度，三者都不变时
    // layoutSubviews 不再重复跑 boundingRect 量文字，只复用上次结果。
    private var cachedOverflowText: String?
    private var cachedOverflowFontName: String?
    private var cachedOverflowFontSize: CGFloat = 0
    private var cachedOverflowWidth: CGFloat = 0
    private var cachedOverflowResult = false
    private var hasCachedOverflow = false
    private let upButton = BearyButton.make(style: .secondaryOutline(.compact), title: "赞成")
    private let downButton = BearyButton.make(style: .secondaryOutline(.compact), title: "反对")
    private var isDoneRow = false
    /// 审计八轮第 3 项：上次票数——票数淡变只在数值真变时播；只比整数，
    /// 不读按钮标题，与 #1302 的 setVoteTitle（attributed 标题）不冲突。
    private var lastVoteCounts: (up: Int, down: Int)?
    private let doneButton = BearyButton.make(style: .secondaryOutline(.compact), title: "标记已完成")
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onMarkDone: (() -> Void)?
    var isAdminRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface1
        layer.cornerRadius = BearyCorners.single
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 3
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.numberOfLines = 0
        // 15：净赞成缩为操作行末尾的辅助文字——弱化为 12 灰字（与作者时间弱信息行同档），
        // 不再独占一行；文案本身（“净赞成 ±N”）不变，见 configure。
        // 审计视觉 12：净票数走 numberFont（12 semibold 等宽数字），票数变化时不抖。
        netLabel.font = BearyDynamicType.numberFont()
        netLabel.adjustsFontForContentSizeCategory = true
        netLabel.textColor = BearyColors.gray
        // 28：donePill 文字与底色均走动态色（文字 BearyColors.deepGreenText，底色经
        // BearyColors.alpha 重解，不再硬编码绿值与 alpha 底）；公开 pill 橙色
        // 不在本文件，绝不动。固定 56×18 容器配 cappedFont 上限 14（31），
        // 14pt 行高约 17pt 不撑破 18pt 高，3 字在 56 宽内不截断。
        donePill.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 14)
        donePill.adjustsFontForContentSizeCategory = true
        donePill.textColor = BearyColors.deepGreenText
        donePill.backgroundColor = BearyColors.alpha(BearyColors.green, 0.12)
        donePill.layer.cornerRadius = 9
        donePill.clipsToBounds = true
        donePill.textAlignment = .center
        donePill.text = "已完成"
        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)
        upButton.addTarget(self, action: #selector(voteTouchDown), for: .touchDown)
        downButton.addTarget(self, action: #selector(voteTouchDown), for: .touchDown)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        // P1-17（已改）：展开钮、完成钮与两票钮均补通用按压反馈；
        // 两票钮点按瞬间给 light（与点赞同款），成功分支不再另补，防双震；
        // 失败三件套（摇头＋warning＋toast）不动。
        // 29：详情展开钮——超三行时才出现，点按原位展开/收起，不新增二级页面；
        // 未超三行时隐藏（见 layoutSubviews 的 updateExpandVisibility）。
        expandButton.setTitle("展开", for: .normal)
        expandButton.setTitleColor(BearyColors.ink, for: .normal)
        expandButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        expandButton.titleLabel?.adjustsFontForContentSizeCategory = true
        expandButton.contentHorizontalAlignment = .leading
        expandButton.isHidden = true
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.bearyAddPressFeedback()
        doneButton.bearyAddPressFeedback()
        upButton.bearyAddPressFeedback()
        downButton.bearyAddPressFeedback()
        // 15：净赞成进操作行末尾——弹性 spacer 把它顶到行末，赞成/反对钮本身不动；
        // spacer 抗拉伸与抗压缩均最低，窄屏先压 spacer，不挤按钮与净赞成文案。
        let voteSpacer = UIView()
        voteSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        voteSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        voteRow = UIStackView(arrangedSubviews: [upButton, downButton, voteSpacer, netLabel])
        voteRow.axis = .horizontal
        voteRow.spacing = 8
        voteRow.alignment = .center
        // 08：换行行的第二行——弹性 spacer 把净数顶到右缘；默认隐藏，UIStackView 不为隐藏行占位。
        voteWrapSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        voteWrapSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        voteRowWrapped.addArrangedSubview(voteWrapSpacer)
        voteRowWrapped.axis = .horizontal
        voteRowWrapped.spacing = 8
        voteRowWrapped.alignment = .center
        voteRowWrapped.isHidden = true
        // 15：标题与 donePill 放同一横向容器——pill 占 56 宽时标题只剩剩余宽换行，
        // 首行不再被右上角悬浮 pill 盖住；未完成时 pill 隐藏，stack 自动不占位，标题回满宽。
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        donePill.setContentHuggingPriority(.required, for: .horizontal)
        donePill.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, donePill])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .top
        // 15：竖向栈减一层——netLabel 已随 voteRow 进操作行，不再单列；作者时间
        // metaLabel 仍为单独弱信息行，标题与 donePill 的同容器（titleRow）原样不动。
        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel, expandButton, metaLabel, voteRow, voteRowWrapped, doneButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            donePill.widthAnchor.constraint(equalToConstant: 56),
            donePill.heightAnchor.constraint(equalToConstant: 18),
            upButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
            downButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func upTapped() { onUp?() }
    @objc private func downTapped() { onDown?() }

    @objc private func voteTouchDown() {
        // 审计动效组：高频触发点按下时先 prepare，确认/失败反馈低延迟。
        BearyHaptics.prepareVote()
    }
    @objc private func doneTapped() { onMarkDone?() }

    @objc private func expandTapped() {
        // P2-10：高度一次落终值（不做高度插值动画），视觉衔接走内容淡入/transform；
        // 收起时恢复滚动偏移，使标题停在原位（内容缩短导致 scrollView 钳制偏移时
        // 标题本会被顶移，恢复后标题位置不变）。减动效时全部瞬时落位。
        isDetailExpanded.toggle()
        let expanding = isDetailExpanded
        var enclosingScroll: UIScrollView?
        var current: UIView? = superview
        while let view = current {
            if let scroll = view as? UIScrollView { enclosingScroll = scroll; break }
            current = view.superview
        }
        let oldOffset = enclosingScroll?.contentOffset
        detailLabel.layer.removeAllAnimations()
        updateExpandVisibility()
        // 高度一次落终值：先强制布局到最终态，再起内容动效，不让高度慢慢长出来。
        // 须连同滚动容器一起布局，否则 contentSize 未刷新、后一步的偏移钳制读到旧值。
        if let scroll = enclosingScroll { scroll.layoutIfNeeded() } else { superview?.layoutIfNeeded() }
        if let scroll = enclosingScroll, let old = oldOffset {
            let minY = -scroll.contentInset.top
            let maxY = max(scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom, minY)
            scroll.contentOffset = CGPoint(x: old.x, y: min(max(old.y, minY), maxY))
        }
        guard expanding, BearyMotion.animated(true) else {
            detailLabel.alpha = 1
            detailLabel.transform = .identity
            return
        }
        detailLabel.alpha = 0
        detailLabel.transform = CGAffineTransform(translationX: 0, y: 4)
        UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseOut], animations: {
            self.detailLabel.alpha = 1
            self.detailLabel.transform = .identity
        }, completion: nil)
    }

    /// 29：布局落定后量详情是否超三行——行宽取行宽减左右 16 内边距（label 帧未稳时
    /// 亦可用），超三行才显展开钮；展开态行数 0、文案“收起”，收起态行数 3、文案“展开”。
    /// 仅在取值变化时改属性，避免 layoutSubviews 内改布局引发循环。
    override func layoutSubviews() {
        super.layoutSubviews()
        updateExpandVisibility()
        updateVoteWrap()
    }

    /// 08：投票区宽度不足时净赞成自动换行——单行最少需要两票钮 + 净数 + 三处 8 间距
    /// （spacer 可压到 0）；超宽才换行，正常字号横向布局一字不动。两票钮始终同行相邻，
    /// 只挪净数；仅在换行态变化时才在两行之间搬 label，避免 layoutSubviews 内改布局引发循环。
    private func updateVoteWrap() {
        let availWidth = bounds.width - 32
        guard availWidth > 0 else { return }
        let needed = upButton.intrinsicContentSize.width
            + downButton.intrinsicContentSize.width
            + netLabel.intrinsicContentSize.width
            + 8 * 3
        let shouldWrap = needed > availWidth
        guard shouldWrap != isVoteWrapped else { return }
        isVoteWrapped = shouldWrap
        if shouldWrap {
            voteRow.removeArrangedSubview(netLabel)
            netLabel.removeFromSuperview()
            voteRowWrapped.addArrangedSubview(netLabel)
            voteRowWrapped.isHidden = false
        } else {
            voteRowWrapped.removeArrangedSubview(netLabel)
            netLabel.removeFromSuperview()
            voteRow.addArrangedSubview(netLabel)
            voteRowWrapped.isHidden = true
        }
    }

    private func updateExpandVisibility() {
        guard !detailLabel.isHidden, !detailFullText.isEmpty else {
            if !expandButton.isHidden { expandButton.isHidden = true }
            return
        }
        if isDetailExpanded {
            if detailLabel.numberOfLines != 0 { detailLabel.numberOfLines = 0 }
            if expandButton.isHidden { expandButton.isHidden = false }
            if expandButton.title(for: .normal) != "收起" { expandButton.setTitle("收起", for: .normal) }
            detailOverflow = true
            return
        }
        let availWidth = bounds.width - 32
        guard availWidth > 0, let font = detailLabel.font else { return }
        // 内容、字体、可用宽度三者与上次一致时直接复用溢出结果，不再量文字；
        // 任一输入变了才重新算（字体按 fontName + pointSize 比，动态字号变化也命中）。
        let overflow: Bool
        if hasCachedOverflow, cachedOverflowText == detailFullText,
           cachedOverflowFontName == font.fontName,
           cachedOverflowFontSize == font.pointSize,
           cachedOverflowWidth == availWidth {
            overflow = cachedOverflowResult
        } else {
            let rect = (detailFullText as NSString).boundingRect(
                with: CGSize(width: availWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            let lines = Int(ceil(rect.height / max(font.lineHeight, 1)))
            overflow = lines > 3
            cachedOverflowText = detailFullText
            cachedOverflowFontName = font.fontName
            cachedOverflowFontSize = font.pointSize
            cachedOverflowWidth = availWidth
            cachedOverflowResult = overflow
            hasCachedOverflow = true
        }
        if overflow != detailOverflow { detailOverflow = overflow }
        if detailLabel.numberOfLines != 3 { detailLabel.numberOfLines = 3 }
        if expandButton.isHidden != !overflow { expandButton.isHidden = !overflow }
        if overflow, expandButton.title(for: .normal) != "展开" { expandButton.setTitle("展开", for: .normal) }
    }

    /// 只改文案与选中态，不重播入场动效（已有行更新口径）。
    func configure(item: BearyAPI.WishItem, isAdmin: Bool) {
        titleLabel.text = item.title ?? ""
        // 29：详情文本变化时展开态复位（投票等仅改文案的 configure 不重置展开态）。
        let newDetail = item.detail ?? ""
        if newDetail != detailFullText {
            detailFullText = newDetail
            isDetailExpanded = false
            detailOverflow = false
            // 文本换了，旧溢出缓存失效，下次布局按新内容重新量。
            hasCachedOverflow = false
            cachedOverflowText = nil
            expandButton.isHidden = true
            // P2-10：文本换了，展开淡入动效的残态（alpha/位移）一并清掉，不留半透明行。
            detailLabel.layer.removeAllAnimations()
            detailLabel.alpha = 1
            detailLabel.transform = .identity
        }
        detailLabel.text = newDetail
        detailLabel.isHidden = newDetail.isEmpty
        let author = item.authorName ?? "beary 用户"
        let time = item.createdAt.map { BearyDiaryCardCell.feedTimeString(ms: $0) } ?? ""
        metaLabel.text = time.isEmpty ? author : "\(author) · \(time)"
        let up = item.upCount ?? 0
        let down = item.downCount ?? 0
        let net = up - down
        let voteChanged = lastVoteCounts == nil || lastVoteCounts?.up != up || lastVoteCounts?.down != down
        lastVoteCounts = (up, down)
        let newNetText = "净赞成 \(net >= 0 ? "+" : "")\(net)"
        fadeVoteCount(on: netLabel, changed: voteChanged) { self.netLabel.text = newNetText }
        // 变基衔接：main 的 configure 已改走 setVoteTitle（attributed 标题＋无障碍标签），
        // 淡变闭包里继续调它，不用 plain setTitle，避免丢掉 numberFont 与「赞成 N 票」读法。
        fadeVoteCount(on: upButton, changed: voteChanged) { self.setVoteTitle(self.upButton, name: "赞成", count: up) }
        fadeVoteCount(on: downButton, changed: voteChanged) { self.setVoteTitle(self.downButton, name: "反对", count: down) }
        setVoteSelected(upButton, selected: item.myVote == 1)
        setVoteSelected(downButton, selected: item.myVote == -1)
        let done = item.status == "done"
        isDoneRow = done
        donePill.isHidden = !done
        // 已完成即闭环：票钮置灰不可点（禁用态本身即不可用示意，不另弹 toast）。
        // 扫 bug 定版第 6 项：投票不再有在途禁用——在途时票钮保持可点，
        // configure 只按已完成态禁用，不把在途行提前解开/锁住。
        upButton.isEnabled = !done
        downButton.isEnabled = !done
        upButton.alpha = done ? 0.4 : 1
        downButton.alpha = done ? 0.4 : 1
        doneButton.isHidden = !(isAdmin && !done)
    }

    /// 审计八轮第 3 项（规范 §6）：票数变化时 0.18s opacity 交叉淡变
    /// （BearyMotion.localStateDuration，点赞数同款 transitionCrossDissolve）；
    /// 数值未变、减动效开、或视图未进窗口时直设终值。
    private func fadeVoteCount(on view: UIView, changed: Bool, assign: @escaping () -> Void) {
        guard changed, !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            assign()
            return
        }
        UIView.transition(with: view, duration: BearyMotion.localStateDuration, options: .transitionCrossDissolve, animations: assign)
    }

    /// 投票选中态走按钮公共样式（BearyButton.applyVoteSelected）；本处只转发，不再各写一套颜色。
    private func setVoteSelected(_ button: BearyButton, selected: Bool) {
        button.applyVoteSelected(selected)
    }

    /// 审计视觉 13：按钮标题只留操作名，计数另起一段走 numberFont 等宽数字；
    /// 计数段不写死前景色，跟随按钮 titleColor（选中态 applyVoteSelected 改色后仍生效）；
    /// 无障碍读作「赞成 N 票」/「反对 N 票」，计数随 configure 实时更新。
    private func setVoteTitle(_ button: BearyButton, name: String, count: Int) {
        let nameFont = button.titleLabel?.font ?? BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        let title = NSMutableAttributedString(string: name, attributes: [.font: nameFont])
        title.append(NSAttributedString(string: " \(count)", attributes: [.font: BearyDynamicType.numberFont()]))
        button.setAttributedTitle(title, for: .normal)
        button.accessibilityLabel = "\(name) \(count) 票"
    }

    /// 拒绝摇头（transform 平移关键帧，不动布局；与即时性总口径的拒绝动效同款）。
    /// 22(a)：补减动效早退——与标准 playDenyShake 一致，减动效时只跳视觉抖动；
    /// 本处调用点（voteTapped 失败分支）已另给 warning 震动，shake 本身不补震动/音效。
    func shake() {
        if UIAccessibility.isReduceMotionEnabled { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -8, 8, -5, 5, 0]
        anim.duration = BearyMotion.screen
        layer.add(anim, forKey: "wish-row-shake")
    }
}

// MARK: - 列表页

final class BearyWishWallViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let createButton = BearyButton.make(style: .primaryPill(.ink), title: "发起许愿")
    private let wishEmptyStateView = BearyStateView()
    // P2-18：加载/失败态迁入已有 BearyStateView（不新建组件）；空态走新增的
    // wishEmptyStateView（同样不传 iconName，不强迫空态套同一插图）。
    private let wishStateView = BearyStateView()
    /// r17-C9：快照态提示行——有旧结果且刷新失败时“显示的是上次的数据”；
    /// 确认结果为空时不显、只显空态。
    private let wishStaleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.text = "显示的是上次的数据"
        labelValue.isHidden = true
        return labelValue
    }()
    /// 许愿新建页的 EdgeDismiss 强持有（transitioningDelegate 弱引用）。
    private var wishCreateEdgeDismiss: BearyEdgeDismissController?
    private var wishes: [BearyAPI.WishItem] = []
    private var rowViews: [Int: WishRowView] = [:]
    private var voteGeneration: [Int: Int] = [:] // 每条许愿投票代次，旧回包丢弃用；
    /// 新一轮 04（2026-11-06 Li 改令，取代 2026-10-29“代次取代在途锁”定版）：
    /// 每条愿望写请求串行执行——voteInFlight（同一愿望同时只允许一个写请求）
    /// ＋ votePendingTarget（请求期间只记最后一次点按的绝对值票态，0 = 取消；
    /// 前一请求结束后再提交）。代次仍只守 UI（旧回包不覆盖新点按态），不管顺序。
    /// 注意：pendingVote 是游客登录待重放意图，与串行化无关，不复用。
    private var voteInFlight: Set<Int> = []
    private var votePendingTarget: [Int: Int] = [:]
    /// 2026-11-06（R23 #5）：每条许愿“标记完成”代次，投票 voteGeneration 同款；
    /// 旧回包丢弃用；失败回滚只恢复 status 字段，其余字段以当前显示态为准。
    private var markDoneGeneration: [Int: Int] = [:]
    /// 审计登录杂项：游客投票时存下的待重放意图（wishId, target），登录成功后补投。
    private var pendingVote: (wishId: Int, target: Int)?
    /// 每条许愿最后服务端确认态（点赞 confirmedLiked/confirmedLikeCount 同款）：
    /// 成功回包才刷新；最新一代请求失败时回滚到这里，不是回滚到本次点按前
    /// 的中间态（快连点下中间态早已被更新的点按覆盖，回滚到它即错）。
    // 注意不用 [Int: Int?] 存确认票：Swift 里 nil 票与“未播种”在字典取值上
    // 无法区分，快连点下播种守卫会把中间态误当确认基线。故票只存 1/-1，
    // 无票 = 字典缺 key；播种与否另用 confirmedSeeded 记（播种后缺 key 即真无票）。
    private var confirmedVote: [Int: Int] = [:]
    private var confirmedSeeded: Set<Int> = []
    private var confirmedUp: [Int: Int] = [:]
    private var confirmedDown: [Int: Int] = [:]
    private func seedConfirmedIfNeeded(wishId: Int, item: BearyAPI.WishItem) {
        guard !confirmedSeeded.contains(wishId) else { return }
        confirmedSeeded.insert(wishId)
        confirmedVote[wishId] = item.myVote
        confirmedUp[wishId] = item.upCount ?? 0
        confirmedDown[wishId] = item.downCount ?? 0
    }
    private var isLoading = false
    /// 第八轮审计 07：加载在途时又有刷新请求（创建愿望成功、登录后补投），
    /// 旧请求结束后立即补刷一次——否则 guard 直接丢弃，旧回包渲染创建前
    /// 的服务端快照，新愿望不出现，用户不离页重进就看不到。
    private var needsReloadAfterCurrentRequest = false
    /// R13-06：列表请求代次与发起时账号身份——登录后废弃旧访客请求用。
    /// fetchWishes 本身不带账号参数，身份核对只在调用层做：发起时记下
    /// currentUser.id（游客为 nil）与代次；回包时代次或身份对不上即丢弃，
    /// 不得把旧账号的 wishes 与确认态写回；身份变了则立即重拉一次，
    /// 保证当前账号至少完成一次属于自己的列表加载（登录路径的 loadWishes
    /// 曾被 isLoading 拦下时，正是由回包处的重拉补上；不移除 isLoading 门控，
    /// 避免制造重复请求）。
    private var wishListGeneration = 0
    private var wishListAccountId: Int?
    /// 当前账号身份：登录用户为 currentUser.id，游客为 nil。
    private var currentAccountId: Int? { SessionManager.shared.currentUser?.id }
    /// r17-C9：当前列表是否来自磁盘快照（未被新回包确认前）、是否已有新回包确认。
    private var showingCachedWishes = false
    private var wishesFreshConfirmed = false
    /// r17-C9：在途投票的 wish id——回包按 ID 替换时保留这些条目的本地乐观票态。
    private var voteInflight: Set<Int> = []
    /// 13：600 上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews；Feed 断点同款）。
    private var colCapConstraints: [NSLayoutConstraint] = []
    /// 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?
    var onCreated: ((BearyAPI.WishItem) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 44pt 热区不动，行为仍是 closeTapped 关页）。
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "功能许愿墙"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        view.addSubview(topBar)
        view.addSubview(scrollView)
        topBarView = topBar
        // 13：Feed 断点模式——600 上限只在宽 ≥821 激活（开关在 viewDidLayoutSubviews），
        // ≤820 时走 == 屏宽-32 的 iPhone 式全宽（左右 16），不再被常驻 600 上限收窄。
        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        let scrollWidth = scrollView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        scrollWidth.priority = .defaultHigh
        let scrollCap = scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints = [topBarCap, scrollCap]
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap,
            topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrollCap,
            scrollWidth,
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
        refreshPlusGate()
        wishEmptyStateView.translatesAutoresizingMaskIntoConstraints = false
        wishEmptyStateView.configure(kind: .empty, title: "还没有愿望", subtitle: "Plus 会员可以发起第一个", iconName: nil, actionTitle: nil)
        wishEmptyStateView.isHidden = true
        // P2-18：加载/失败两态的文案与重试动作与旧口径一致（“加载中…”/“加载失败”/“重试”），
        // 仅承载体换成 BearyStateView；空态走 wishEmptyStateView（见下），不进本视图。
        wishStateView.translatesAutoresizingMaskIntoConstraints = false
        wishStateView.isHidden = true
        contentStack.addArrangedSubview(createButton)
        contentStack.addArrangedSubview(wishStaleLabel)
        contentStack.addArrangedSubview(wishStateView)
        contentStack.addArrangedSubview(wishEmptyStateView)
        NSLayoutConstraint.activate([
            createButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
        ])
        // r17-C9：冷开进心愿墙先看到上次确认的首屏，再静默刷新。
        restoreCachedWishesIfNeeded()
        loadWishes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
        // 审计登录杂项：本页外获得 / 失去 Plus 后返回，发起钮显隐跟最新 Plus 态
        //（此前只在 viewDidLoad 与游客投票登录回调里刷新，旧态会滞留）。
        refreshPlusGate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 13：Feed 同款断点开关——状态不变不开关，避免布局循环。
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
        // 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
        subpageLayoutGuard.applyIfNeeded(page: "功能许愿墙", view: view, topView: topBarView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次。
        subpageLayoutGuard.applyAfterAppearance(page: "功能许愿墙", view: view, topView: topBarView)
    }

    @objc private func closeTapped() { dismiss(animated: BearyMotion.animated(true), completion: nil) }
    @objc private func retryTapped() { loadWishes() }

    /// App 侧 Plus 门三态（r17-C9）：仅决定发起钮显隐，真正校验在服务端
    ///（plus_until > now 或永久阈值）。true 已确认是 Plus；false 已确认不是；
    /// nil 未确认——冷启动快照的 plusUntil 为 nil，不得直接判非 Plus，须等
    /// /me（见 refreshPlusGate）。
    private func plusState() -> Bool? {
        guard let until = SessionManager.shared.currentUser?.plusUntil else { return nil }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return until >= 4102444800000 || until > now
    }

    /// Plus 门刷新：已确认按结果显隐；未确认时先隐藏发起钮、等一次 /me
    ///（同会话在途时订阅结果，不多发请求），回包后再定。
    private func refreshPlusGate() {
        if let plus = plusState() {
            createButton.isHidden = !plus
            return
        }
        createButton.isHidden = true
        guard !isGuest, SessionManager.shared.currentUser != nil else { return }
        SessionManager.shared.refreshMe { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.createButton.isHidden = !(self.plusState() ?? false)
            }
        }
    }

    private var isAdmin: Bool { SessionManager.shared.currentUser?.isAdmin == true }
    private var isGuest: Bool { SessionManager.shared.isGuestMode }

    @objc private func createTapped() {
        let vc = BearyWishCreateViewController()
        vc.modalPresentationStyle = .fullScreen
        // 全站返回手势补齐：许愿新建页此前只有 fadeRise、没有左边缘右滑；改走 EdgeDismiss。
        let wishCreateEdgeDismiss = BearyEdgeDismissController()
        // 审计残留 EdgeDismiss 确认补绑：closeTapped 与 isSubmitting／标题／
        // 详情均为 private，挂载处无法直接复用，故守卫读下方与 closeTapped
        // 同口径的 allowsInteractiveDismiss；shouldAllowInteractiveDismiss
        // 只有允许/拒绝两种语义，返回 false 时手势在 .began 即被拦下、不弹
        // 确认——提交在途或有未保存内容时拒绝滑走，用户走左上角返回钮弹确认。
        wishCreateEdgeDismiss.shouldAllowInteractiveDismiss = { [weak vc] in
            vc?.allowsInteractiveDismiss ?? true
        }
        wishCreateEdgeDismiss.attach(to: vc)
        vc.transitioningDelegate = wishCreateEdgeDismiss
        self.wishCreateEdgeDismiss = wishCreateEdgeDismiss
        vc.onCreated = { [weak self] wish in
            guard let self = self else { return }
            // 审计登录杂项：新愿望不再 insert(at:0) 永远置顶（与注释“服务端净赞成
            // 降序、App 不重排”冲突，直到下次重进才纠正）；创建成功后重拉，
            // 以服务端顺序为准（确认态由 loadWishes 成功分支播种）。
            self.loadWishes()
            BearyToast.show(in: self.view, message: "许愿已发布")
            self.onCreated?(wish)
        }
        // 117 终态偏离兜底：新建页无守卫，呈现完成时帧偏离就复位（与设置页 helper 同口径）。
        present(vc, animated: BearyMotion.animated(true)) { [weak vc] in
            guard let vc = vc, let window = vc.view.window else { return }
            let bounds = window.bounds
            if vc.view.frame != bounds || !vc.view.transform.isIdentity {
                vc.view.transform = .identity
                vc.view.frame = bounds
                vc.view.setNeedsLayout()
                vc.view.layoutIfNeeded()
            }
        }
    }

    /// 116 数据填入动效：状态视图由隐藏变可见时只淡入本身（alpha
    /// 0→1、0.18s，不动 transform／布局）；已可见时不重播；减动效或
    /// 未进窗口时直设终值。成功时状态视图直接隐藏、行走已有错峰。
    private func showStateViewFaded() {
        let wasHidden = wishStateView.isHidden
        wishStateView.isHidden = false
        guard wasHidden, !UIAccessibility.isReduceMotionEnabled, wishStateView.window != nil else {
            wishStateView.alpha = 1
            return
        }
        wishStateView.alpha = 0
        UIView.animate(withDuration: BearyMotion.micro, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.wishStateView.alpha = 1
        })
    }

    private func loadWishes() {
        guard !isLoading else {
            // 第八轮审计 07：加载在途时不丢弃本次刷新请求，记下来等旧请求
            // 结束后再补刷一次（创建愿望成功、登录后补投都走这里）。
            needsReloadAfterCurrentRequest = true
            return
        }
        isLoading = true
        // R13-06：发起时记录代次与账号身份，供回包时核对。
        wishListGeneration += 1
        wishListAccountId = currentAccountId
        let generation = wishListGeneration
        // r17-C9：有快照首屏时静默刷新，不盖加载态；无快照时走原有加载态。
        // 重试时先收起旧失败态（失败回包会重显），不让它在刷新期间继续占位。
        if showingCachedWishes {
            wishStateView.isHidden = true
        } else {
            // P2-18：加载态走 BearyStateView（转圈 + “加载中…”）；成功/失败回包时统一收起。
            wishStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            showStateViewFaded()
        }
        BearyAPI.shared.fetchWishes { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // R13-06：代次／身份守卫——游客请求在途时登录成功，旧访客回包
                // 直接丢弃，不得把访客版 wishes 与确认态写回、覆盖登录账号
                // 的补投状态；身份已变说明当前账号还欠一次自己的列表加载，
                // 立即重拉一次（登录时那次 loadWishes 被 isLoading 拦下过，
                // 正是由这里补上）；代次对不上但身份没变时只丢弃不重拉。
                guard generation == self.wishListGeneration, self.wishListAccountId == self.currentAccountId else {
                    self.isLoading = false
                    if self.wishListAccountId != self.currentAccountId {
                        self.loadWishes()
                    }
                    return
                }
                self.isLoading = false
                switch result {
                case .success(let resp):
                    self.wishStateView.isHidden = true
                    self.wishesFreshConfirmed = true
                    // 审计登录杂项：与 viewWillAppear 同款，列表成功回包时也刷新 Plus 门。
                    self.refreshPlusGate()
                    let serverWishes = resp.wishes ?? []
                    // r17-C9：回包后按 ID 替换——在途投票的条目保留本地乐观票态
                    //（选中态与票数），其余以服务端为准；行按 ID 复用，展开态不丢。
                    var merged: [BearyAPI.WishItem] = []
                    for var server in serverWishes {
                        if let id = server.id, self.voteInflight.contains(id),
                           let localIndex = self.indexOfWish(id) {
                            let local = self.wishes[localIndex]
                            server.myVote = local.myVote
                            server.upCount = local.upCount
                            server.downCount = local.downCount
                        }
                        merged.append(server)
                    }
                    self.wishes = merged
                    for item in self.wishes where item.id != nil && !self.voteInflight.contains(item.id!) {
                        self.confirmedSeeded.insert(item.id!)
                        self.confirmedVote[item.id!] = item.myVote
                        self.confirmedUp[item.id!] = item.upCount ?? 0
                        self.confirmedDown[item.id!] = item.downCount ?? 0
                    }
                    self.showingCachedWishes = false
                    self.wishStaleLabel.isHidden = true
                    self.renderWishes()
                    // 确认结果为空时旧快照失效，下次不再先恢复已撤的愿望；非空则落快照。
                    if let accountId = SessionManager.shared.currentUser?.id {
                        if merged.isEmpty {
                            BearyWishWallCache.purge(bucket: "\(accountId)")
                        } else {
                            self.saveWishesSnapshotIfNeeded(items: merged)
                        }
                    }
                case .failure:
                    // r17-C9：有旧结果且刷新失败时保留快照列表、标“显示的是上次的数据”；
                    // 失败态仍给重试入口（置于快照列表上方），不盖住已有行；无快照时走原有失败态。
                    if self.showingCachedWishes {
                        self.wishStaleLabel.isHidden = false
                        self.wishStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
                        self.showStateViewFaded()
                    } else {
                        // P2-18：失败态走 BearyStateView（“加载失败”+“重试”，动作复用 retryTapped）。
                        self.wishStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
                        self.showStateViewFaded()
                    }
                }
                // 第八轮审计 07：旧请求结束时若有待补刷的刷新请求，立即再拉一次。
                // 旗先清后调，避免补刷本身在途时又被记下导致循环；成功失败都补刷，
                // 最多多拉一轮（失败再失败时照常显失败态，不再自动重试）。
                if self.needsReloadAfterCurrentRequest {
                    self.needsReloadAfterCurrentRequest = false
                    self.loadWishes()
                }
            }
        }
    }

    /// r17-C9：冷开进心愿墙先看到上次确认的首屏——只有新回包尚未确认时才贴快照。
    private func restoreCachedWishesIfNeeded() {
        guard !isGuest, let accountId = SessionManager.shared.currentUser?.id else { return }
        BearyWishWallCache.load(accountId: accountId, sessionGeneration: SessionManager.shared.currentSessionGeneration) { [weak self] snap in
            guard let self = self, let snap = snap, !snap.items.isEmpty else { return }
            guard self.wishes.isEmpty, !self.wishesFreshConfirmed else { return }
            self.wishes = snap.items.map { $0.toWishItem() }
            for item in self.wishes where item.id != nil {
                self.confirmedSeeded.insert(item.id!)
                self.confirmedVote[item.id!] = item.myVote
                self.confirmedUp[item.id!] = item.upCount ?? 0
                self.confirmedDown[item.id!] = item.downCount ?? 0
            }
            self.showingCachedWishes = true
            self.wishStateView.isHidden = true
            self.renderWishes()
        }
    }

    /// r17-C9：最近确认的首屏落盘——标题、状态和票数（按 ID 存）；只存当前账号。
    private func saveWishesSnapshotIfNeeded(items: [BearyAPI.WishItem]) {
        guard let accountId = SessionManager.shared.currentUser?.id, !items.isEmpty else { return }
        let snapItems = items.compactMap { BearyWishWallCache.WishSnapshotItem(item: $0) }
        guard !snapItems.isEmpty else { return }
        BearyWishWallCache.save(accountId: accountId, sessionGeneration: SessionManager.shared.currentSessionGeneration, items: snapItems)
    }

    /// P0-9：按 wish ID 复用行——已有行只 configure 改文案，不重建、不重播入场动效；
    /// 展开态存在行视图自身，复用即保留（仅详情文本变化时 configure 内部复位）；
    /// 仅新增 ID 建行并入场错峰；消失 ID 摘除；顺序变化时同批行先摘后按服务端
    /// 顺序重挂（视图对象不变，展开态与按压态不丢）。服务端顺序即净赞成降序，不重排。
    private func renderWishes() {
        let oldRows = rowViews
        wishEmptyStateView.isHidden = !wishes.isEmpty
        var newRows: [WishRowView] = []
        var orderedRows: [WishRowView] = []
        for item in wishes {
            guard let id = item.id else { continue }
            if let row = oldRows[id] {
                row.configure(item: item, isAdmin: isAdmin)
                orderedRows.append(row)
            } else {
                let row = WishRowView()
                row.configure(item: item, isAdmin: isAdmin)
                row.onUp = { [weak self] in self?.voteTapped(wishId: id, target: 1) }
                row.onDown = { [weak self] in self?.voteTapped(wishId: id, target: -1) }
                row.onMarkDone = { [weak self] in self?.markDoneTapped(wishId: id) }
                rowViews[id] = row
                orderedRows.append(row)
                newRows.append(row)
            }
        }
        let liveIds = Set(wishes.compactMap { $0.id })
        for (id, row) in oldRows where !liveIds.contains(id) {
            row.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        // 先摘后重挂：栈内固定位（发起钮/stateView/空态）在前，行按服务端顺序跟后；
        // 摘除只脱离栈布局，不销毁视图，故复用行的展开态保留。
        for row in orderedRows { row.removeFromSuperview() }
        for row in orderedRows { contentStack.addArrangedSubview(row) }
        if !BearyMotion.animated(true) { return }
        for (index, row) in newRows.enumerated() {
            row.alpha = 0
            row.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: BearyMotion.normal, delay: min(Double(index) * 0.03, 0.24), options: [.curveEaseOut], animations: {
                row.alpha = 1
                row.transform = .identity
            }, completion: nil)
        }
    }

    private func indexOfWish(_ id: Int) -> Int? { wishes.firstIndex { $0.id == id } }

    /// 投票（新一轮 04，2026-11-06 Li 改令，取代 2026-10-29“代次取代在途锁”定版）：
    /// 游客走登录页；登录用户每次点按都立即按最后一次点按渲染（选中态 +
    /// 赞成/反对数点按瞬间就变，不等服务端、不置灰、不禁用票钮）；写请求按愿望
    /// 串行执行——在途时只记最后目标票态，前一请求结束后再提交最新目标（vote:
    /// 1/-1/0，0 = 取消本票），服务端不再收到乱序写入；代次仍只守 UI，过期回包
    /// （含过期失败）直接丢弃，不得覆盖更新的点按态、不得触发回滚；只有最新一代
    /// 回包生效：成功以服务端计数对齐并刷新确认态，失败回滚到最后确认态
    /// （confirmedVote/confirmedUp/confirmedDown）+ 摇头 + toast。
    private func voteTapped(wishId: Int, target: Int) {
        if isGuest {
            // 审计登录杂项：投票前先存待重放意图，登录成功后补投并 toast
            //（此前登录后不重放刚才那一票且无提示）。
            pendingVote = (wishId: wishId, target: target)
            presentLoginPage()
            return
        }
        guard let index = indexOfWish(wishId) else { return }
        let current = wishes[index]
        // 确认态兜底：本条若从未经过列表/新建播种（如行复用路径），
        // 以本次点按前的显示态为确认基线，失败回滚才有可回的态。
        seedConfirmedIfNeeded(wishId: wishId, item: current)
        // 三态票数算法（每次都从当前显示态算增量，故快连点不算错）：
        // 先减掉当前票（赞成 -1 或反对 -1），再加新票；再点同票 = 取消（新票 nil，
        // 只减不加）；赞成↔反对改投 = 一边 -1、另一边 +1；计数下限钳 0。
        let newVote: Int? = (current.myVote == target) ? nil : target
        var next = current
        var up = current.upCount ?? 0
        var down = current.downCount ?? 0
        if current.myVote == 1 { up -= 1 }
        if current.myVote == -1 { down -= 1 }
        if newVote == 1 { up += 1 }
        if newVote == -1 { down += 1 }
        next.upCount = max(0, up)
        next.downCount = max(0, down)
        next.myVote = newVote
        wishes[index] = next
        rowViews[wishId]?.configure(item: next, isAdmin: isAdmin)
        // 审计登录杂项：wishDing 不再点按瞬间播（失败才回滚时音效语义与结果
        // 相反），改到服务端成功回包后播放，见下方 success 分支。
        voteGeneration[wishId, default: 0] += 1
        let gen = voteGeneration[wishId] ?? 0
        let sendVote = newVote ?? 0
        // 新一轮 04：写请求按愿望串行——在途时只记最后目标票态，不再发请求；
        // 前一请求结束后再提交最新目标（见 sendVoteRequest 回调）。
        if voteInFlight.contains(wishId) {
            votePendingTarget[wishId] = sendVote
            return
        }
        sendVoteRequest(wishId: wishId, sendVote: sendVote, gen: gen)
    }

    /// 发一次投票写请求（串行队列的唯一发请求入口）：记在途，回调结束时先清
    /// 在途，再看请求期间有没有新点按——有则提交最后目标票态（旧回包不应用，
    /// 屏幕早已按最后一次点按渲染；新请求带最新代次），无则按代次守卫正常
    /// 处理回包。同一愿望的请求只会按点按顺序依次发出，服务端不再乱序写入。
    /// R22 #8：回包结算顺序——先清在途标记（两套标记都清，本条已不在列表时
    /// 也要结算，否则脏标记永久拦住后续快照确认态）；有待发目标时本次回包是
    /// 中间态，成功只刷新确认态（待发请求失败时回滚到它）、不碰界面、不播
    /// 音效，失败静默，随即发出最新目标。
    private func sendVoteRequest(wishId: Int, sendVote: Int, gen: Int) {
        voteInFlight.insert(wishId)
        voteInflight.insert(wishId)
        BearyAPI.shared.voteWish(id: wishId, vote: sendVote) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.voteInFlight.remove(wishId)
                // R22 #8：先清快照在途标记——本条已不在列表时也要结算，
                // 否则 voteInflight 脏标记永久拦住后续快照确认态。
                self.voteInflight.remove(wishId)
                // 串行：请求期间又有新点按——只提交最后目标票态。
                if let pending = self.votePendingTarget[wishId] {
                    self.votePendingTarget.removeValue(forKey: wishId)
                    // R22 #8：中间态成功回包只刷新确认态（待发请求失败时回滚
                    // 到它）、不碰界面、不播音效。
                    if case .success(let resp) = result {
                        self.confirmedSeeded.insert(wishId)
                        self.confirmedVote[wishId] = resp.myVote
                        self.confirmedUp[wishId] = resp.up ?? self.confirmedUp[wishId] ?? 0
                        self.confirmedDown[wishId] = resp.down ?? self.confirmedDown[wishId] ?? 0
                    }
                    self.sendVoteRequest(wishId: wishId, sendVote: pending, gen: self.voteGeneration[wishId] ?? gen)
                    return
                }
                // 代次守卫（点赞 likeSeq 同款）：已有更新点按时过期回包直接丢弃，
                // 不回滚、不摇头、不弹 toast，屏幕只反映最后一次点按。
                guard let idx = self.indexOfWish(wishId), self.voteGeneration[wishId] == gen else { return }
                switch result {
                case .success(let resp):
                    // 审计登录杂项：成功音只在服务端成功回包后播。
                    BearySoundPlayer.play(.wishDing)
                    var confirmed = self.wishes[idx]
                    confirmed.upCount = resp.up ?? confirmed.upCount
                    confirmed.downCount = resp.down ?? confirmed.downCount
                    confirmed.myVote = resp.myVote
                    self.wishes[idx] = confirmed
                    self.confirmedSeeded.insert(wishId)
                    self.confirmedVote[wishId] = confirmed.myVote
                    self.confirmedUp[wishId] = confirmed.upCount ?? 0
                    self.confirmedDown[wishId] = confirmed.downCount ?? 0
                    self.rowViews[wishId]?.configure(item: confirmed, isAdmin: self.isAdmin)
                case .failure:
                    // 失败回滚口径（点赞同款）：滚到最后服务端确认态，不是本次
                    // 点按前的中间态——快连点下中间态已被更新点按覆盖，滚回去即错。
                    var rolledBack = self.wishes[idx]
                    rolledBack.myVote = self.confirmedVote[wishId]
                    rolledBack.upCount = self.confirmedUp[wishId] ?? rolledBack.upCount
                    rolledBack.downCount = self.confirmedDown[wishId] ?? rolledBack.downCount
                    self.wishes[idx] = rolledBack
                    self.rowViews[wishId]?.configure(item: rolledBack, isAdmin: self.isAdmin)
                    self.rowViews[wishId]?.shake()
                    BearyHaptics.rejectionWarning()
                    BearyToast.show(in: self.view, message: "投票失败，请稍后再试")
                }
            }
        }
    }

    /// 标记完成（R23 #5，投票代次口径同款）：失败只回滚本次改的 status 字段，
    /// 请求期间列表重载 / 票数变化带进来的新字段一律保留；代次守卫丢弃旧回包，
    /// 已有更新标记请求时旧失败不得覆盖新状态、不得弹 toast。
    private func markDoneTapped(wishId: Int) {
        guard let index = indexOfWish(wishId) else { return }
        let oldStatus = wishes[index].status
        var next = wishes[index]
        next.status = "done"
        wishes[index] = next
        rowViews[wishId]?.configure(item: next, isAdmin: isAdmin)
        markDoneGeneration[wishId, default: 0] += 1
        let gen = markDoneGeneration[wishId] ?? 0
        BearyAPI.shared.markWishDone(id: wishId) { [weak self] result in
            DispatchQueue.main.async {
                // 代次守卫（投票 voteGeneration 同款）：已有更新标记请求时
                // 旧回包直接丢弃，不回滚、不弹 toast，屏幕只反映最后一次操作。
                guard let self = self, let idx = self.indexOfWish(wishId), self.markDoneGeneration[wishId] == gen else { return }
                switch result {
                case .success:
                    BearyToast.show(in: self.view, message: "已标记完成")
                case .failure:
                    // 只滚 status：其余字段（票数等）以当前显示态为准，
                    // 请求期间重载 / 票数变化带进来的新值不得被旧快照盖掉。
                    var rolledBack = self.wishes[idx]
                    rolledBack.status = oldStatus
                    self.wishes[idx] = rolledBack
                    self.rowViews[wishId]?.configure(item: rolledBack, isAdmin: self.isAdmin)
                    // 审计视觉 15：标记失败补摇头＋警告震动（toast 已有）；乐观 status＋失败回滚不动（R23 #5 定版）。
                    self.rowViews[wishId]?.shake()
                    BearyHaptics.rejectionWarning()
                    BearyToast.show(in: self.view, message: "标记失败，请稍后再试")
                }
            }
        }
    }

    /// 游客投票走登录弹窗（成功后刷新 /me 与列表，失败态不留残页）。
    private func presentLoginPage() {
        let login = BearyLoginSheet.make()
        login.onLoggedIn = { [weak self] referralText in
            // 添加账号会话守卫：正常是空操作；防迂回路径下守卫仍 armed 时
            // 后续一次取消把新号恢复成旧号，成功先解 arm。
            SessionManager.shared.completeAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            SessionManager.shared.refreshMe { _ in
                DispatchQueue.main.async {
                    self?.refreshPlusGate()
                    // 审计登录杂项：登录成功后补投待重放的那一票并 toast；登录页
                    // 带来的邀请绑定文案（若有）与补投提示合为一次 toast（新 toast
                    // 会盖掉旧 toast，分开发会丢一条）。补投后重拉列表以服务端为准。
                    var messages: [String] = []
                    if let referralText = referralText, !referralText.isEmpty {
                        messages.append(BearyReferralFeedback.toastText(base: referralText, plusUntil: SessionManager.shared.currentUser?.plusUntil))
                    }
                    // refreshMe 失败仍是游客时不补投（voteTapped 会重弹登录页）：
                    // 意图保留，待下次成功登录再重放。
                    if let pending = self?.pendingVote, !(self?.isGuest ?? true) {
                        self?.pendingVote = nil
                        self?.voteTapped(wishId: pending.wishId, target: pending.target)
                        messages.append("已补投刚才那一票")
                    }
                    if !messages.isEmpty, let view = self?.view {
                        BearyToast.show(in: view, message: messages.joined(separator: "，"))
                    }
                    self?.loadWishes()
                }
            }
        }
        login.onCancelled = { [weak self] in
            SessionManager.shared.cancelAccountAddSession()
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
        present(login, animated: BearyMotion.animated(true), completion: nil)
    }
}

// MARK: - 发起页（标题必填 + 详情可选两项；服务端再校验 Plus 与长度）

final class BearyWishCreateViewController: UIViewController, UITextViewDelegate {
    private let scrollView = UIScrollView()
    private let titleField = UITextField()
    private let detailView = UITextView()
    private let detailPlaceholder = UILabel()
    private let submitButton = BearyButton.make(style: .primaryPill(.ink), title: "发布许愿")
    // 30：长度提示（服务端：标题 1–100、详情 ≤2000）与字段级错误行。
    private let titleCountLabel = UILabel()
    private let detailCountLabel = UILabel()
    private let fieldErrorLabel = UILabel()
    /// 字段级错误行隐藏时压为 0 高（非栈容器里 hidden 仍占约束位，需显式压高才不留空隙）。
    private var fieldErrorHeight: NSLayoutConstraint?
    private static let titleLimit = 100
    private static let detailLimit = 2000
    /// 11 轮审计第 10 项：表单级错误文案（服务端笼统 bad wish 时用，两框均不变红）。
    private static let formErrorText = "标题需为 1–100 字，详情最多 2000 字，请检查后重试"
    /// 11 轮审计第 10 项：错误定位拆三类——标题错只标标题框、详情错只标详情框、
    /// 表单级错误只显示错误行。旧的全局 fieldErrorShown 让任一错误都双框变红，
    /// 归因是错的，故拆掉。
    private enum WishFieldError {
        case none
        case title
        case detail
        case form
    }
    private var wishFieldError: WishFieldError = .none
    /// 11：提交锁——锁期间 titleChanged 不得重新启用提交钮（服务端幂等另有工人做）。
    private var isSubmitting = false
    /// 提交在途时关闭钮的引用：提交期间一并禁用，失败后恢复；成功即随页关闭，无需恢复。
    private var createCloseButton: BearyHit44Button?
    /// 13：600 上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews；与列表页同款）。
    private var colCapConstraints: [NSLayoutConstraint] = []
    /// 17：当前焦点框（键盘弹出时把它滚到可见区）。
    private weak var activeField: UIView?
    /// 117 子页空白守卫：新建页此前无守卫，与列表页同款补上。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?
    var onCreated: ((BearyAPI.WishItem) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // 全屏页左上角统一左箭头：此前是文字“关闭”，现改 icon_back 图标钮
        // （左上角位置与 44pt 热区不动，行为仍是 closeTapped 关页）。
        closeButton.setTitle(nil, for: .normal)
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        createCloseButton = closeButton
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "发起许愿"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.placeholder = "愿望标题"
        // 31：44 高单行框配 cappedFont（上限 20，行高不撑破 44 高）；详情框可滚动，
        // 故走 scaledFont（反馈页 160 框同款），超大字号下框内滚动而非截断。
        titleField.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16))
        titleField.adjustsFontForContentSizeCategory = true
        titleField.textColor = BearyColors.ink
        // 审计视觉 10：标题框去系统描边，走 surface2 底＋12 圆角；聚焦走聚焦阴影（见 refreshTitleBorder）。
        // .none 后系统内边距消失，左右各补 12pt 垫片，文字不贴圆角边。
        titleField.borderStyle = .none
        titleField.backgroundColor = BearyColors.surface2
        titleField.layer.cornerRadius = 12
        titleField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        titleField.leftViewMode = .always
        titleField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        titleField.rightViewMode = .always
        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        detailView.adjustsFontForContentSizeCategory = true
        detailView.textColor = BearyColors.ink
        // 审计视觉 04：详情框去 1pt 墨色边框，走 surface2 底＋12 圆角；聚焦走聚焦阴影（见 refreshDetailBorder）。
        detailView.backgroundColor = BearyColors.surface2
        detailView.layer.borderWidth = 0
        detailView.layer.cornerRadius = 12
        detailView.delegate = self
        detailPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        detailPlaceholder.text = "补充说明（可选）"
        detailPlaceholder.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        detailPlaceholder.adjustsFontForContentSizeCategory = true
        detailPlaceholder.textColor = BearyColors.gray
        detailView.addSubview(detailPlaceholder)
        // 30：计数行右对齐、超限变红；字段级错误行默认隐藏，见 submitTapped 的 bad wish 分支。
        for label in [titleCountLabel, detailCountLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = BearyColors.gray
            label.textAlignment = .right
        }
        titleCountLabel.text = "0/100"
        detailCountLabel.text = "0/2000"
        fieldErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldErrorLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        fieldErrorLabel.adjustsFontForContentSizeCategory = true
        fieldErrorLabel.textColor = BearyColors.red
        fieldErrorLabel.numberOfLines = 0
        fieldErrorLabel.text = Self.formErrorText
        fieldErrorLabel.isHidden = true
        fieldErrorHeight = fieldErrorLabel.heightAnchor.constraint(equalToConstant: 0)
        fieldErrorHeight?.isActive = true
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.isEnabled = false
        submitButton.alpha = 0.4
        titleField.addTarget(self, action: #selector(titleFieldDidBegin), for: .editingDidBegin)
        titleField.addTarget(self, action: #selector(fieldDidEnd), for: .editingDidEnd)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        scrollView.delaysContentTouches = false
        view.addSubview(topBar)
        topBarView = topBar
        view.addSubview(scrollView)
        scrollView.addSubview(titleField)
        scrollView.addSubview(titleCountLabel)
        scrollView.addSubview(detailView)
        scrollView.addSubview(detailCountLabel)
        scrollView.addSubview(fieldErrorLabel)
        scrollView.addSubview(submitButton)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // 13：发起页上限统一到 600（原字段/按钮 568），断点开关与列表页同款。
        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints.append(topBarCap)
        // 17：表单入滚动容器，底部跟随 keyboardLayoutGuide（键盘弹出时滚动区收缩、
        // 内容可滚；键盘收起时 ≤ 安全区底约束兜底，不致伸到 Home 条下）。
        let scrollBottomToKeyboard = scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        scrollBottomToKeyboard.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap,
            topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollBottomToKeyboard,
            titleField.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            titleField.heightAnchor.constraint(equalToConstant: 44),
            titleCountLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            detailView.topAnchor.constraint(equalTo: titleCountLabel.bottomAnchor, constant: 8),
            detailView.heightAnchor.constraint(equalToConstant: 160),
            detailPlaceholder.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 8),
            detailPlaceholder.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 8),
            detailCountLabel.topAnchor.constraint(equalTo: detailView.bottomAnchor, constant: 4),
            fieldErrorLabel.topAnchor.constraint(equalTo: detailCountLabel.bottomAnchor, constant: 8),
            submitButton.topAnchor.constraint(equalTo: fieldErrorLabel.bottomAnchor, constant: 12),
            submitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BearyButtonStyle.primaryPill(.ink).height),
            // 内容底含提交钮 +16 边距——键盘顶起后提交钮也可滚到可见区。
            submitButton.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
        ] + fieldColumnConstraints(for: titleField)
          + fieldColumnConstraints(for: titleCountLabel)
          + fieldColumnConstraints(for: detailView)
          + fieldColumnConstraints(for: detailCountLabel)
          + fieldColumnConstraints(for: fieldErrorLabel)
          + fieldColumnConstraints(for: submitButton))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 审计视觉 04/10：详情框与标题框边框主题刷新——边框色走 bearyDynamicBorderColor
    ///（CGColor 赋值即固化），深浅切换后按当前态（错误／聚焦／普通）重刷两框边框；
    /// 只重刷边框，不动占位 / 计数 / 校验。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshTitleBorder()
            refreshDetailBorder()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 13：Feed 同款断点开关——状态不变不开关，避免布局循环。
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
        subpageLayoutGuard.applyIfNeeded(page: "新建许愿", view: view, topView: topBarView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 117 终态偏离兜底：动画结束后的最终帧再校一次。
        subpageLayoutGuard.applyAfterAppearance(page: "新建许愿", view: view, topView: topBarView)
    }

    /// 13：表单字段居中列约束——宽 == 滚动容器 frame 宽-32（defaultHigh，≤820 全宽-32）
    /// + 600 上限（存入 colCapConstraints，≥821 才激活）+ 左右 ≥16 + 居中。
    private func fieldColumnConstraints(for field: UIView) -> [NSLayoutConstraint] {
        let fullWidth = field.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        fullWidth.priority = .defaultHigh
        let cap = field.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints.append(cap)
        return [
            field.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            cap,
            fullWidth,
            field.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
        ]
    }

    /// 左缘右滑守卫：与下方 closeTapped 逐条同口径（提交在途，或标题／详情
    /// 任一非空 → 不允许直接滑走，改走左上角返回钮的确认流程）。internal
    /// 而非 private——挂载处 createTapped（另一类）要读它；closeTapped 本身
    /// 与所读状态均为 private，无法直接复用，故单列此只读镜像，不改原逻辑。
    var allowsInteractiveDismiss: Bool {
        guard !isSubmitting else { return false }
        let hasTitle = !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDetail = !detailView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(hasTitle || hasDetail)
    }

    /// P0-13：关闭未保存提示——空内容（标题与详情均空白）直接关；有修改时先弹
    /// 确认，“继续编辑”留页、“放弃修改”才关（编辑资料页“放弃未保存的改动？”同款口径）。
    @objc private func closeTapped() {
        // 提交在途时关闭入口统一为“正在提交，请稍候”：不弹放弃改动确认、
        // 不直接退出——已发出的创建请求无取消路径，退出会让用户误以为已取消、
        // 实际愿望仍在服务端创建成功；等请求结束再按成功／失败结果处理。
        guard !isSubmitting else {
            BearyToast.show(in: view, message: "正在提交，请稍候")
            return
        }
        let hasTitle = !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDetail = !detailView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasTitle || hasDetail else {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
            return
        }
        BearyConfirmSheet.show(from: self, title: "放弃未保存的改动？", message: nil, actions: [
            BearyConfirmSheet.Action(title: "继续编辑", style: .cancel),
            BearyConfirmSheet.Action(title: "放弃修改", style: .destructive) { [weak self] in
                self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            },
        ])
    }

    /// 11 轮审计第 10 项：错误态唯一入口——标题／详情错只标对应输入框并配单字段
    /// 文案；表单级错误只显示错误行（位置不变），两框均不变红；无错时清掉错误行与红边。
    /// 显时松开 0 高约束，隐时压回 0 高，见属性注释。
    private func setWishFieldError(_ error: WishFieldError) {
        wishFieldError = error
        switch error {
        case .none:
            fieldErrorLabel.text = Self.formErrorText
            fieldErrorLabel.isHidden = true
            fieldErrorHeight?.isActive = true
        case .title:
            fieldErrorLabel.text = "标题需为 1–100 字，请检查后重试"
            fieldErrorLabel.isHidden = false
            fieldErrorHeight?.isActive = false
        case .detail:
            fieldErrorLabel.text = "详情最多 2000 字，请检查后重试"
            fieldErrorLabel.isHidden = false
            fieldErrorHeight?.isActive = false
        case .form:
            fieldErrorLabel.text = Self.formErrorText
            fieldErrorLabel.isHidden = false
            fieldErrorHeight?.isActive = false
        }
        // 审计视觉 04/10：错误显隐即边框态变化，同步刷新两框边框。
        refreshTitleBorder()
        refreshDetailBorder()
    }

    /// 11 轮审计第 10 项：服务端 bad wish 归因——服务端只回单一 'bad wish'
    ///（worker.js:9129），不带字段信息；按服务端口径重算当前两字段：标题
    /// trim 后判空／>100、详情不 trim／>2000，长度按 JS .length（UTF-16 计，
    /// 与 Swift .count 口径不同，多 emoji 时两端计数会差出一位）；能定位到
    /// 字段才标该框，都合规时（如入库后回读失败）归表单级错误，不标任一框。
    private func fieldError(forBadWish title: String, detail: String) -> WishFieldError {
        if title.isEmpty || title.utf16.count > Self.titleLimit { return .title }
        if detail.utf16.count > Self.detailLimit { return .detail }
        return .form
    }

    /// 审计视觉 04/10：输入框边框三态（BearyInputContainer 同款）——仅当错误
    /// 归因到本字段时才画 1pt 红边框并清掉阴影；聚焦走聚焦阴影、边框 0；
    /// 其余态边框 0、无阴影。表单级错误不标任一框。
    private func refreshTitleBorder() {
        if wishFieldError == .title {
            titleField.layer.borderWidth = 1
            titleField.layer.bearyDynamicBorderColor = BearyColors.red
            titleField.layer.shadowOpacity = 0
        } else if activeField === titleField {
            titleField.layer.borderWidth = 0
            BearyShadow.applyFocused(to: titleField.layer)
        } else {
            titleField.layer.borderWidth = 0
            titleField.layer.shadowOpacity = 0
        }
    }

    private func refreshDetailBorder() {
        if wishFieldError == .detail {
            detailView.layer.borderWidth = 1
            detailView.layer.bearyDynamicBorderColor = BearyColors.red
            detailView.layer.shadowOpacity = 0
        } else if activeField === detailView {
            detailView.layer.borderWidth = 0
            BearyShadow.applyFocused(to: detailView.layer)
        } else {
            detailView.layer.borderWidth = 0
            detailView.layer.shadowOpacity = 0
        }
    }

    /// 30：长度提示唯一刷新点——标题/详情计数与超限变红；超限时提交钮禁用
    /// （服务端同限，客户端先拦；超长 400 的 bad wish 由 submitTapped 按服务
    /// 端口径重算归因，能定位字段只标该框，否则只显示表单级错误行）。
    private func updateLengthHints() {
        let titleCount = (titleField.text ?? "").count
        let detailCount = detailView.text.count
        titleCountLabel.text = "\(titleCount)/\(Self.titleLimit)"
        titleCountLabel.textColor = titleCount > Self.titleLimit ? BearyColors.red : BearyColors.gray
        detailCountLabel.text = "\(detailCount)/\(Self.detailLimit)"
        detailCountLabel.textColor = detailCount > Self.detailLimit ? BearyColors.red : BearyColors.gray
    }

    /// 11：提交钮启用态唯一入口——提交锁期间直接返回，标题变化不得重新启用提交钮。
    @objc private func titleChanged() {
        updateLengthHints()
        setWishFieldError(.none)
        guard !isSubmitting else { return }
        let trimmed = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !trimmed.isEmpty && trimmed.count <= Self.titleLimit && detailView.text.count <= Self.detailLimit
        submitButton.isEnabled = ok
        submitButton.alpha = ok ? 1 : 0.4
    }

    func textViewDidChange(_ textView: UITextView) {
        detailPlaceholder.isHidden = !textView.text.isEmpty
        // 详情变化同样影响提交启用态（超 2000 即禁），复用 titleChanged 的唯一入口。
        titleChanged()
    }

    @objc private func titleFieldDidBegin() {
        activeField = titleField
        refreshTitleBorder()
    }
    @objc private func fieldDidEnd() {
        activeField = nil
        refreshTitleBorder()
        refreshDetailBorder()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        activeField = textView
        refreshDetailBorder()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        activeField = nil
        refreshDetailBorder()
    }

    /// 17：键盘弹出/变框后（keyboardLayoutGuide 已收缩滚动区），下一 runloop 待布局
    /// 完成后再把焦点框滚到可见区，避免按旧 bounds 算错；减动效时瞬时落位。
    @objc private func keyboardWillShow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let field = self.activeField else { return }
            self.view.layoutIfNeeded()
            let rect = field.convert(field.bounds, to: self.scrollView)
            self.scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -8), animated: BearyMotion.animated(true))
        }
    }

    @objc private func submitTapped() {
        guard !isSubmitting else { return }
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.titleLimit, detailView.text.count <= Self.detailLimit else { return }
        let detail = detailView.text ?? ""
        isSubmitting = true
        setWishFieldError(.none)
        submitButton.isEnabled = false
        submitButton.alpha = 0.4
        createCloseButton?.isEnabled = false
        createCloseButton?.alpha = 0.4
        BearyAPI.shared.createWish(title: title, detail: detail) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let wish):
                    self.onCreated?(wish)
                    self.dismiss(animated: BearyMotion.animated(true), completion: nil)
                case .failure(let err):
                    // 11：解锁后按当前标题重新评估启用态，不再无条件 isEnabled = true
                    //（提交期间标题被清空时，失败后提交钮仍应保持禁用）。
                    self.isSubmitting = false
                    // 失败后表单内容保留：不清空标题／详情，只恢复关闭钮与提交钮启用态，可再提交。
                    self.createCloseButton?.isEnabled = true
                    self.createCloseButton?.alpha = 1
                    self.titleChanged()
                    // 11 轮审计第 10 项：超长 400 'bad wish' 按服务端口径重算归因——
                    // 能定位到字段只标该框，无法定位只显示表单级错误行、不标任一框；
                    // 不弹通用 toast；其余失败映射不变（not_plus / rate_limited / 通用 toast）。
                    if case .server(let code, _) = err, code == "bad wish" {
                        self.setWishFieldError(self.fieldError(forBadWish: title, detail: detail))
                        return
                    }
                    let message: String
                    if case .server(let code, _) = err, code == "not_plus" {
                        message = "仅 Plus 会员可发起许愿"
                    } else if case .server(let code, _) = err, code == "rate_limited" {
                        message = "操作太频繁，请稍后再试"
                    } else {
                        message = "发布失败，请重试"
                    }
                    BearyToast.show(in: self.view, message: message)
                }
            }
        }
    }
}

// MARK: - 心愿墙首屏磁盘缓存（r17-C9，与 BearyFeedCache 同口径，不新增文件）
//
// 保存当前账号最近确认的首屏标题、状态和票数；按账号分桶，读取时校验
// 账号 id 与会话代次（退出/401/换号后代次推进，旧快照弃用）；退出/401
// 时由 SessionManager 清桶。投票选中态与发布资格按当前会话确认，不进快照。
enum BearyWishWallCache {
    private static let filePrefix = "beary_wish_wall_cache_"

    /// 首屏条目快照（WishItem 本身只有 Decodable，另存可编码形态）。
    struct WishSnapshotItem: Codable {
        var id: Int
        var title: String?
        var detail: String?
        var authorName: String?
        var status: String?
        var upCount: Int
        var downCount: Int
        var myVote: Int?
        var createdAt: Int?

        init?(item: BearyAPI.WishItem) {
            guard let id = item.id else { return nil }
            self.id = id
            self.title = item.title
            self.detail = item.detail
            self.authorName = item.authorName
            self.status = item.status
            self.upCount = item.upCount ?? 0
            self.downCount = item.downCount ?? 0
            self.myVote = item.myVote
            self.createdAt = item.createdAt
        }

        func toWishItem() -> BearyAPI.WishItem {
            BearyAPI.WishItem(
                id: id, authorId: nil, authorName: authorName, authorAvatar: nil,
                title: title, detail: detail, status: status,
                upCount: upCount, downCount: downCount, myVote: myVote, createdAt: createdAt
            )
        }
    }

    struct Snapshot: Codable {
        var savedAt: TimeInterval
        var accountId: Int
        var sessionGeneration: Int
        var items: [WishSnapshotItem]
    }

    private static func fileURL(bucket: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("\(filePrefix)\(bucket).json")
    }

    private static let ioQueue = DispatchQueue(label: "beary.wishWallCache.io", qos: .utility)

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

    /// 读取：账号 id 与会话代次双重校验——任一不符即弃用，不递出旧号/旧会话快照。
    static func load(accountId: Int, sessionGeneration: Int, completion: @escaping (Snapshot?) -> Void) {
        let bucket = "\(accountId)"
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            var snap: Snapshot?
            if let url = fileURL(bucket: bucket), let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                snap = try? decoder.decode(Snapshot.self, from: data)
            }
            let valid = snap?.accountId == accountId && snap?.sessionGeneration == sessionGeneration
            let result = (capturedGeneration == generation(for: bucket) && valid) ? snap : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func save(accountId: Int, sessionGeneration: Int, items: [WishSnapshotItem]) {
        let bucket = "\(accountId)"
        let snap = Snapshot(savedAt: Date().timeIntervalSince1970, accountId: accountId, sessionGeneration: sessionGeneration, items: items)
        let capturedGeneration = generation(for: bucket)
        ioQueue.async {
            guard capturedGeneration == generation(for: bucket) else { return }
            guard let url = fileURL(bucket: bucket) else { return }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(snap) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static func purge(bucket: String) {
        bumpGeneration(for: bucket)
        ioQueue.async {
            guard let url = fileURL(bucket: bucket) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

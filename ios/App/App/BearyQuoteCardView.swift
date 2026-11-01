import UIKit

// ===== BearyQuoteCardView 共享引用卡（B 批卡片合并）=====
// 来源二合一：首页的独立 BearyFeedQuoteView（F11 lite 卡：左侧 3pt 线、
// faint 底、圆角 8、15px 引号图标、日期行内末位、42px 缩略图条
// flex 分配、gone/locked/加载失败三态）＋个人主页 cell 内 quoteContainer
// 手写卡（同款 faint 底、9/12 内边距、15px 图标、13.5 正文、42px 缩略图、
// 日期、gone 两文案）。统一后两页视觉以 Feed 卡为准（个人主页侧圆角
// 12→8、补左侧线，内边距与字号一字不动）；个人主页侧的 gone 卡点按仍
// 透传（allowGoneTap，控制器弹提示），首页侧 gone 卡点按仍无动作。
// 缩略图池化：两页原实现各有缺口——首页每 configure 新建一批缩略图视图
// （旧下载无视图可取消）、个人主页 #70 已池化；本视图内置 quoteThumbPool，
// clear/configure 复用视图起新图（bearySetImage 先取消该视图在途任务），
// 池化口径与 94 包主图 9 槽位同款（上限 9 张，池按需增长、不预建）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyQuoteCardView: UIView {

    /// F2：引用卡点按（gone/locked 时首页 cell 侧不动作；加载失败时走 onRetryTapped）。
    var onTapped: (() -> Void)?
    var onRetryTapped: (() -> Void)?
    /// 个人主页口径：gone 卡点按仍透传给控制器（弹“已删除/还没公开”提示），
    /// 首页保持 false（gone 卡点按无动作）。
    var allowGoneTap = false
    private var isLoadFailedState = false
    /// 占位态标志（115 批去重用）：showGone 置 true、clear() 清掉；点按守卫凭它
    /// 而不再凭 goneRowStack 是否可见——已删除卡去重后占位行整行隐藏，守卫仍须拦住点按。
    private var isGoneState = false

    private let leftBorderView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    // 52 批：lite 卡不带头像名（原 avatarContainer 已删）；引用规则简化
    // （2026-10-31）后“仅你可见”角标随混合态取消而下线，本视图不再有顶部名行。

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 3
        // P3-3：引用正文同款长串断行（字号行高不动）。
        lb.lineBreakMode = .byCharWrapping
        return lb
    }()

    /// 引用规则简化来源行（2026-10-31）：内容上方一行，12px 灰字（比正文 13.5 小一档），
    /// 格式“引用自 @handle · 日期”（日期走现行卡片 feedTimeString 口径）。
    /// 可点条件由调用方按 viewer 权限给（sourceTappable）：有权限看原文时点按走 onTapped
    /// 进原日记详情；占位态（已私密/已删除）下只展示、不点按、不泄露正文。
    /// 本行即原尾部日期的归宿：尾部 dateLabel 随之删除，同一卡不再出现两次日期。
    private let sourceButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        btn.titleLabel?.adjustsFontForContentSizeCategory = true
        btn.titleLabel?.lineBreakMode = .byTruncatingTail
        btn.setTitleColor(BearyColors.gray, for: .normal)
        btn.setTitleColor(BearyColors.gray, for: .disabled)
        btn.contentHorizontalAlignment = .left
        btn.isHidden = true
        return btn
    }()

    private var sourceTappable = false

    /// gone/locked 失效文案：13px 灰字（网页 .quote-card.gone 口径）。
    private let goneLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 0
        lb.isHidden = true
        return lb
    }()

    /// D8b：引用卡左侧 15px 引号图标（网页 .quote-card .icon 口径：宽 15、灰色、上边距 2）。
    private let quoteIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = BearyFeedIconCache.image(named: "icon_quote", pointSize: 15)
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private let quoteIconWrap: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    /// D8d：失效态图标（gone 用 beary-quote、locked 用 beary-lock，15px 灰色；加载失败态无图标）。
    private let goneIconView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.tintColor = BearyColors.gray
        v.contentMode = .scaleAspectFit
        return v
    }()

    private lazy var goneRowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [goneIconView, goneLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
        st.isHidden = true
        return st
    }()

    private let thumbsScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.showsHorizontalScrollIndicator = false
        sv.isHidden = true
        return sv
    }()

    private let thumbsStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 5
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private lazy var textStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [contentLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        // 正文栈只剩 [正文]（日期与缩略图已移到横向行栈，见 rowStack）。
        st.spacing = 6
        return st
    }()

    // 52 批：lite 卡不带头像名（原 avatarContainer 已删）；D8：行栈为横向 flex：
    // [15px 引号图标][正文栈][42px 缩略图条]（尾部日期已并入顶部来源行，见 sourceButton）。
    private lazy var rowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [quoteIconWrap, textStack, thumbsScrollView])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
        return st
    }()

    /// 卡片纵向容器：[来源行][正常行][占位行]，隐藏项自动塌掉（来源行隐藏时
    /// 正常行即贴卡顶，不留空位；占位行与正常行互斥显隐，见 showGone/configure）。
    private lazy var contentStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [sourceButton, rowStack, goneRowStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.spacing = 4
        st.alignment = .fill
        st.distribution = .fill
        return st
    }()

    private var thumbsHeightConstraint: NSLayoutConstraint?
    private var thumbsWidthConstraint: NSLayoutConstraint?
    /// A23：缩略图条总宽（单张 42 + 间距 5）；布局时按网页 .quote-thumbs flex:1 分配，
    /// 不再封顶 180，超出部分在条内横向滚动。
    private var thumbsTotalWidth: CGFloat = 0
    /// 引用缩略图池（#70 个人主页池化口径的共享版）：复用视图起新图即先取消
    /// 在途任务；clear 时先取消全部在途加载，视图留池不销毁。
    private var quoteThumbPool: [UIImageView] = []
    /// fixall-cell 5-17“本轮已算”标记：上次算过缩略图条宽时的输入快照。
    /// 审计 15 项第 6 项：缓存键改为内容文本＋字体＋可用宽度——命中判断
    /// 不再先做 sizeThatFits 文本测量；正文自然宽只在键变化后才实测。
    private var lastThumbsLayoutBoundsWidth: CGFloat = -1
    private var lastThumbsLayoutTotalWidth: CGFloat = -1
    private var lastThumbsLayoutContent: String?
    private var lastThumbsLayoutFont: UIFont?

    private func invalidateThumbsLayoutCache() {
        lastThumbsLayoutBoundsWidth = -1
        lastThumbsLayoutTotalWidth = -1
        lastThumbsLayoutContent = nil
        lastThumbsLayoutFont = nil
    }

    /// fixall-cell 5-17：缩略图条宽的唯一计算入口（原 layoutSubviews 内联块抽出）。
    /// 正文自然宽与卡宽无关，configure 时已可算出，此处只在输入
    /// 快照变化时重算；快照未变时直接返回，layoutSubviews 因此不再每轮写约束。
    /// 行内元素现为 [图标][正文栈][图条]（日期已并入顶部来源行，不再占行内宽）。
    private func refreshThumbsWidth() {
        guard thumbsScrollView.isHidden == false, thumbsTotalWidth > 0 else { return }
        let rowWidth = bounds.width - 24
        if rowWidth <= 0 { return }
        // 审计 15 项第 6 项：先用内容文本＋字体＋可用宽度判缓存命中，
        // 命中直接返回，不先做 sizeThatFits；未命中才实测正文自然宽。
        if bounds.width == lastThumbsLayoutBoundsWidth,
           thumbsTotalWidth == lastThumbsLayoutTotalWidth,
           contentLabel.text == lastThumbsLayoutContent,
           contentLabel.font == lastThumbsLayoutFont {
            return
        }
        lastThumbsLayoutBoundsWidth = bounds.width
        lastThumbsLayoutTotalWidth = thumbsTotalWidth
        lastThumbsLayoutContent = contentLabel.text
        lastThumbsLayoutFont = contentLabel.font
        // 正文自然宽（单行实测）与缩略图条按 flex:1 分享剩余空间：
        // 正文短时条带拿剩余全部，正文长时两者对半、正文换行。
        let contentSingleLine = contentLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
        let textNatural = contentSingleLine
        let gaps: CGFloat = 2 * 8
        let avail = rowWidth - 15 - gaps
        if avail <= 0 { return }
        let thumbsWidth: CGFloat
        if textNatural < avail / 2 {
            thumbsWidth = min(thumbsTotalWidth, avail - textNatural)
        } else {
            thumbsWidth = min(thumbsTotalWidth, avail / 2)
        }
        if let current = thumbsWidthConstraint?.constant, abs(current - thumbsWidth) > 0.5 {
            thumbsWidthConstraint?.constant = thumbsWidth
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // fixall-cell 5-17：布局回调只调带缓存守卫的 refreshThumbsWidth，
        // 输入未变时不写约束（原 0.5pt 门限保留在 refresh 内）。
        refreshThumbsWidth()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // F2：引用卡可点（此前 isUserInteractionEnabled=false 导致点按全被行导航吞掉）。
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped(_:))))
        sourceButton.addTarget(self, action: #selector(sourceTapped), for: .touchUpInside)
        backgroundColor = BearyColors.faint
        layer.cornerRadius = 8
        clipsToBounds = true
        thumbsScrollView.addSubview(thumbsStack)
        quoteIconWrap.addSubview(quoteIconView)
        addSubview(leftBorderView)
        addSubview(contentStack)
        let height = thumbsScrollView.heightAnchor.constraint(equalToConstant: 0)
        thumbsHeightConstraint = height
        let thumbsWidth = thumbsScrollView.widthAnchor.constraint(equalToConstant: 0)
        thumbsWidthConstraint = thumbsWidth
        // 引用卡被右列 stack 隐藏时 stack 会将其高度压为 0，内部高度/上下边距用 999，
        // 避免与零高度约束冲突；显示时 999 照常生效。
        let contentTop = contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        contentTop.priority = UILayoutPriority(999)
        let contentBottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        contentBottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            leftBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorderView.topAnchor.constraint(equalTo: topAnchor),
            leftBorderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorderView.widthAnchor.constraint(equalToConstant: 3),
            contentTop,
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentBottom,
            height,
            thumbsWidth,
            quoteIconView.topAnchor.constraint(equalTo: quoteIconWrap.topAnchor, constant: 2),
            quoteIconView.leadingAnchor.constraint(equalTo: quoteIconWrap.leadingAnchor),
            quoteIconView.trailingAnchor.constraint(equalTo: quoteIconWrap.trailingAnchor),
            quoteIconView.bottomAnchor.constraint(equalTo: quoteIconWrap.bottomAnchor),
            quoteIconView.widthAnchor.constraint(equalToConstant: 15),
            quoteIconView.heightAnchor.constraint(equalToConstant: 15),
            goneIconView.widthAnchor.constraint(equalToConstant: 15),
            goneIconView.heightAnchor.constraint(equalToConstant: 15),
            thumbsStack.topAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.topAnchor),
            thumbsStack.bottomAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.bottomAnchor),
            thumbsStack.leadingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.leadingAnchor),
            thumbsStack.trailingAnchor.constraint(equalTo: thumbsScrollView.contentLayoutGuide.trailingAnchor),
            thumbsStack.heightAnchor.constraint(equalTo: thumbsScrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// F2：gone 态（showGone）首页不触发 onTapped（cell 侧同样守卫，双保险），
    /// 个人主页 allowGoneTap 时透传给控制器弹提示；加载失败态点按走重试；正常卡点按走 onTapped。
    /// 来源行点按由 sourceButton 自处理：卡片手势落在来源行内时直接返回，防一次点按
    /// 触发按钮与卡片两次导航（按钮未命中时手势照常走卡片路径）。
    @objc private func quoteTapped(_ gesture: UITapGestureRecognizer) {
        if sourceButton.isHidden == false {
            let location = gesture.location(in: sourceButton)
            if sourceButton.bounds.contains(location) {
                return
            }
        }
        if isLoadFailedState {
            onRetryTapped?()
            return
        }
        if isGoneState, allowGoneTap == false {
            return
        }
        onTapped?()
    }

    /// 来源行点按：仅 sourceTappable 时走 onTapped（即卡片正常点按同一路）；
    /// 占位态下按钮被禁用，点按无动作、不导航、不泄露正文。
    @objc private func sourceTapped() {
        if sourceTappable {
            onTapped?()
        }
    }

    /// 来源行文案组装（handle/日期皆无时返回 nil，调用方据此隐藏整行，不编造）。
    /// deleted 时无可信 handle/日期，固定写“引用自已删除的日记”。
    private static func sourceRowText(handle: String?, dateMs: Int?, deleted: Bool) -> String? {
        if deleted {
            return "引用自已删除的日记"
        }
        let handleText = (handle ?? "").isEmpty ? nil : "@\(handle!)"
        let dateText = (dateMs ?? 0) > 0 ? BearyDiaryCardCell.feedTimeString(ms: dateMs!) : nil
        if let handleText = handleText, let dateText = dateText {
            return "引用自 \(handleText) · \(dateText)"
        }
        if let handleText = handleText {
            return "引用自 \(handleText)"
        }
        return dateText
    }

    /// 来源行唯一写入口：configure 与 showGone 均走这里，保证两态口径一致。
    /// tappable=false 时按钮禁用（灰字不变，见 .disabled 同色），点按无动作。
    func setSourceRow(handle: String?, dateMs: Int?, tappable: Bool, deleted: Bool) {
        guard let text = BearyQuoteCardView.sourceRowText(handle: handle, dateMs: dateMs, deleted: deleted) else {
            sourceButton.setTitle(nil, for: .normal)
            sourceButton.isHidden = true
            sourceButton.isEnabled = false
            sourceTappable = false
            return
        }
        sourceButton.setTitle(text, for: .normal)
        sourceButton.isHidden = false
        sourceTappable = tappable
        sourceButton.isEnabled = tappable
    }

    func clear() {
        contentLabel.attributedText = nil
        contentLabel.text = nil
        sourceButton.setTitle(nil, for: .normal)
        sourceButton.isHidden = true
        sourceButton.isEnabled = false
        sourceTappable = false
        goneLabel.attributedText = nil
        goneLabel.text = nil
        goneLabel.isHidden = true
        goneIconView.image = nil
        goneIconView.isHidden = false
        goneRowStack.isHidden = true
        isLoadFailedState = false
        isGoneState = false
        rowStack.isHidden = false
        // 池化：先取消全部在途缩略图加载，视图离栈留池，不销毁。
        for thumbView in quoteThumbPool {
            thumbView.bearySetImage(url: nil)
        }
        for view in thumbsStack.arrangedSubviews {
            thumbsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbsScrollView.isHidden = true
        thumbsHeightConstraint?.constant = 0
        thumbsWidthConstraint?.constant = 0
        invalidateThumbsLayoutCache()
    }

    /// 失效态：隐藏正常行、显示 15px 图标 + 13px 灰字文案（卡片本身不隐藏）。
    /// gone 用 beary-quote、locked 用 beary-lock（网页 quoteHtml 两分支口径）；调用方按态传图标。
    /// detail 非空时第二行 12px 灰字挂提醒句（引用规则简化：已私密占位卡的
    /// “原日记已转私密，引用内容已隐藏”）；无 detail 时只显主句。
    /// 来源行（sourceHandle/sourceDateMs）同样挂在占位卡上方：占位态只展示、
    /// 不点按；deleted 时写“引用自已删除的日记”；两者皆无时来源行隐藏。
    /// 115 批去重：sourceDeleted 时来源行已说清“已删除”，正文重复行
    /// “引用的日记已删除”不再显示（占位行整行隐藏，只留来源行）；点按仍由
    /// isGoneState 拦住，不因行隐藏而误导航。已私密 + 提醒句、未公开口径不动。
    func showGone(message: String, iconName: String = "icon_quote", detail: String? = nil, sourceHandle: String? = nil, sourceDateMs: Int? = nil, sourceDeleted: Bool = false) {
        clear()
        setSourceRow(handle: sourceHandle, dateMs: sourceDateMs, tappable: false, deleted: sourceDeleted)
        isGoneState = true
        if sourceDeleted {
            goneLabel.attributedText = nil
            goneLabel.text = nil
            goneLabel.isHidden = true
            goneIconView.image = nil
            goneIconView.isHidden = true
            goneRowStack.isHidden = true
            rowStack.isHidden = true
            return
        }
        if let detail = detail, !detail.isEmpty {
            let combined = NSMutableAttributedString(string: message, attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13)),
                .foregroundColor: BearyColors.gray,
            ])
            combined.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12)),
                .foregroundColor: BearyColors.gray,
            ]))
            goneLabel.attributedText = combined
        } else {
            goneLabel.text = message
        }
        goneLabel.isHidden = false
        goneIconView.image = BearyFeedIconCache.image(named: iconName, pointSize: 15)
        goneIconView.isHidden = false
        goneRowStack.isHidden = false
        rowStack.isHidden = true
    }

    /// F3：加载失败态（非 gone）：同样 13px 灰字、无图标，但点按可重试（isLoadFailedState）。
    func showLoadFailed(message: String) {
        clear()
        goneLabel.text = message
        goneLabel.isHidden = false
        goneIconView.isHidden = true
        goneRowStack.isHidden = false
        rowStack.isHidden = true
        isLoadFailedState = true
    }

    // D8c：网页 .quote-thumbs 口径为固定 42x42（不按 stripW 算宽），故 strip 宽函数已删；
    // configure 的 dims 参数保留（调用点仍传被引用篇自己的 imgDims），宽不再由它驱动。

    /// iCity：configure 不再接受 showDeliveringPill / publishAt（投递 pill 与倒计时已删）。
    /// 引用规则简化（2026-10-31）：“仅你可见”角标随混合态取消而下线，本函数不再接受
    /// showOnlyYouBadge，调用点亦全部清掉。占位态（showGone）不带日期与缩略图：
    /// clear() 已把日期行与缩略图区藏起，showGone 只显图标 + 占位文案（+ 可选提醒句）。
    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int? = nil, allowThumbs: Bool = true, authorHandle: String? = nil, sourceTappable: Bool = false) {
        clear()
        // 52 批：lite 卡不带头像名——authorName/authorAvatar 参数仅为调用点兼容保留，不再赋值给任何视图。
        // 来源行：handle + 原尾部日期（feedTimeString 口径）并入本行，尾部不再重复显日期。
        setSourceRow(handle: authorHandle, dateMs: createdAt, tappable: sourceTappable, deleted: false)
        if content.isEmpty {
            contentLabel.isHidden = true
        } else {
            contentLabel.isHidden = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.55
            // P3-3：引用正文富文本同步按字符断行（字号行高不动）。
            paragraph.lineBreakMode = .byCharWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13.5)),
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
            ]
            contentLabel.attributedText = NSAttributedString(string: content, attributes: attrs)
        }
        // D8c：缩略图只当 quote.is_public 或宿主本人时出（allowThumbs 门控）；
        // 网页 .quote-thumbs 口径：与正文同行、单张 42x42、圆角 7、间距 5（thumbsStack.spacing）。
        // 条带宽按 flex:1 在布局时分配（见 layoutSubviews），不封顶；超出横向滚动。
        let keys = images.filter { !$0.isEmpty }
        if keys.isEmpty || allowThumbs == false {
            thumbsScrollView.isHidden = true
            thumbsHeightConstraint?.constant = 0
            thumbsWidthConstraint?.constant = 0
            thumbsTotalWidth = 0
        } else {
            thumbsScrollView.isHidden = false
            thumbsHeightConstraint?.constant = 42
            let totalThumbWidth = CGFloat(keys.count) * 42 + CGFloat(max(0, keys.count - 1)) * 5
            thumbsTotalWidth = totalThumbWidth
            thumbsWidthConstraint?.constant = totalThumbWidth
            for (thumbIndex, key) in keys.enumerated() {
                let thumbView: UIImageView
                if thumbIndex < quoteThumbPool.count {
                    thumbView = quoteThumbPool[thumbIndex]
                } else {
                    thumbView = UIImageView()
                    thumbView.translatesAutoresizingMaskIntoConstraints = false
                    thumbView.backgroundColor = BearyColors.faint
                    thumbView.contentMode = .scaleAspectFill
                    thumbView.clipsToBounds = true
                    thumbView.layer.cornerRadius = 8
                    NSLayoutConstraint.activate([
                        thumbView.widthAnchor.constraint(equalToConstant: 42),
                        thumbView.heightAnchor.constraint(equalToConstant: 42),
                    ])
                    quoteThumbPool.append(thumbView)
                }
                // 复用视图起新图：bearySetImage 先取消该视图在途任务（旧卡
                // 的下载不再串位），再置占位、起新下载；尺寸约束只在建池时
                // 激活一次，不随 configure 累积重复约束。
                thumbView.bearySetImage(url: BearyImageURLs.imageURL(key: key, thumb: true), placeholder: nil, downsampleToWidth: 42 * UIScreen.main.scale)
                thumbsStack.addArrangedSubview(thumbView)
            }
            // 本轮未复用的池视图离栈（留池供下轮），不残留绘制。
            for surplus in quoteThumbPool.dropFirst(keys.count) {
                surplus.removeFromSuperview()
            }
        }
        // fixall-cell 5-17：父布局前算一次——卡宽已落位时 configure 即把
        // 条宽算到 flex 值，不必等 layoutSubviews；卡宽未落位（0）时
        // refresh 提前返回，仍由 layoutSubviews 首轮算出。
        refreshThumbsWidth()
    }
}

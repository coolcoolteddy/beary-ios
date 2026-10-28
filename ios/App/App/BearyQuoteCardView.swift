import UIKit

// ===== BearyQuoteCardView 共享引用卡（B 批卡片合并）=====
// 来源二合一：首页的独立 BearyFeedQuoteView（F11 lite 卡：左侧 3pt 线、
// faint 底、圆角 8、15px 引号图标、「仅你可见」角标、日期行内末位、42px 缩略图条
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

    private let leftBorderView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = BearyColors.line
        return v
    }()

    /// iCity“仅你可见”角标（lite 卡口径）：11/600/blue、blue 13% 底、圆角 6、padding 2/7。
    /// 仅当作者本人看自己私密日记被引用进公开日记时显示；别人看同一张卡时是占位，见不到它。
    private let onlyYouBadgeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("仅你可见", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        btn.setTitleColor(BearyColors.blue, for: .normal)
        btn.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.13)
        btn.layer.cornerRadius = 6
        btn.clipsToBounds = true
        btn.contentEdgeInsets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        btn.isUserInteractionEnabled = false
        btn.isHidden = true
        return btn
    }()

    // 52 批：lite 卡不带头像名——nameRow 只剩“仅你可见”角标（隐藏时该行自动塌掉）。
    private lazy var nameRow: UIStackView = {
        let st = UIStackView(arrangedSubviews: [onlyYouBadgeButton])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .center
        return st
    }()

    private let contentLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13.5)
        lb.textColor = BearyColors.ink
        lb.numberOfLines = 3
        // P3-3：引用正文同款长串断行（字号行高不动）。
        lb.lineBreakMode = .byCharWrapping
        return lb
    }()

    private let dateLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 12)
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        lb.isHidden = true
        return lb
    }()

    /// gone/locked 失效文案：13px 灰字（网页 .quote-card.gone 口径）。
    private let goneLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.systemFont(ofSize: 13)
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
        let st = UIStackView(arrangedSubviews: [nameRow, contentLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        // 正文栈只剩 [角标行][正文]（日期与缩略图已移到横向行栈，见 rowStack）。
        st.spacing = 6
        return st
    }()

    // 52 批：lite 卡不带头像名（原 avatarContainer 已删）；D8：行栈为横向 flex：
    // [15px 引号图标][正文栈][42px 缩略图条][日期]，日期为行内最后一个元素、位于右上角。
    private lazy var rowStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [quoteIconWrap, textStack, thumbsScrollView, dateLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = 8
        st.alignment = .top
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
    /// 布局输入（卡宽/图条总宽/日期显隐与宽度/正文自然宽）全未变时，
    /// layoutSubviews 不再重算、不再写约束，只读返回。
    private var lastThumbsLayoutBoundsWidth: CGFloat = -1
    private var lastThumbsLayoutTotalWidth: CGFloat = -1
    private var lastThumbsLayoutDateHidden = true
    private var lastThumbsLayoutDateWidth: CGFloat = -1
    private var lastThumbsLayoutTextNatural: CGFloat = -1

    private func invalidateThumbsLayoutCache() {
        lastThumbsLayoutBoundsWidth = -1
        lastThumbsLayoutTotalWidth = -1
        lastThumbsLayoutDateHidden = true
        lastThumbsLayoutDateWidth = -1
        lastThumbsLayoutTextNatural = -1
    }

    /// fixall-cell 5-17：缩略图条宽的唯一计算入口（原 layoutSubviews 内联块抽出）。
    /// 正文自然宽与 pill 宽与卡宽无关，configure 时已可算出，此处只在输入
    /// 快照变化时重算；快照未变时直接返回，layoutSubviews 因此不再每轮写约束。
    private func refreshThumbsWidth() {
        guard thumbsScrollView.isHidden == false, thumbsTotalWidth > 0 else { return }
        let rowWidth = bounds.width - 24
        if rowWidth <= 0 { return }
        let dateWidth = dateLabel.isHidden ? 0 : dateLabel.intrinsicContentSize.width
        // 正文自然宽（单行实测；角标行宽取大者）与缩略图条按 flex:1 分享剩余空间：
        // 正文短时条带拿剩余全部，正文长时两者对半、正文换行。
        let contentSingleLine = contentLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
        let pillWidth = onlyYouBadgeButton.isHidden ? 0 : onlyYouBadgeButton.intrinsicContentSize.width
        let textNatural = max(contentSingleLine, pillWidth)
        if bounds.width == lastThumbsLayoutBoundsWidth,
           thumbsTotalWidth == lastThumbsLayoutTotalWidth,
           dateLabel.isHidden == lastThumbsLayoutDateHidden,
           dateWidth == lastThumbsLayoutDateWidth,
           textNatural == lastThumbsLayoutTextNatural {
            return
        }
        lastThumbsLayoutBoundsWidth = bounds.width
        lastThumbsLayoutTotalWidth = thumbsTotalWidth
        lastThumbsLayoutDateHidden = dateLabel.isHidden
        lastThumbsLayoutDateWidth = dateWidth
        lastThumbsLayoutTextNatural = textNatural
        let visibleCount = 3 + (dateLabel.isHidden ? 0 : 1)
        let gaps = CGFloat(visibleCount - 1) * 8
        let avail = rowWidth - 15 - dateWidth - gaps
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
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        backgroundColor = BearyColors.faint
        layer.cornerRadius = 8
        clipsToBounds = true
        thumbsScrollView.addSubview(thumbsStack)
        quoteIconWrap.addSubview(quoteIconView)
        addSubview(leftBorderView)
        addSubview(rowStack)
        addSubview(goneRowStack)
        let height = thumbsScrollView.heightAnchor.constraint(equalToConstant: 0)
        thumbsHeightConstraint = height
        let thumbsWidth = thumbsScrollView.widthAnchor.constraint(equalToConstant: 0)
        thumbsWidthConstraint = thumbsWidth
        // 引用卡被右列 stack 隐藏时 stack 会将其高度压为 0，内部高度/上下边距用 999，
        // 避免与零高度约束冲突；显示时 999 照常生效。
        let rowTop = rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        rowTop.priority = UILayoutPriority(999)
        let rowBottom = rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        rowBottom.priority = UILayoutPriority(999)
        let goneRowTop = goneRowStack.topAnchor.constraint(equalTo: topAnchor, constant: 9)
        goneRowTop.priority = UILayoutPriority(999)
        let goneRowBottom = goneRowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        goneRowBottom.priority = UILayoutPriority(999)
        onlyYouBadgeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            leftBorderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorderView.topAnchor.constraint(equalTo: topAnchor),
            leftBorderView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorderView.widthAnchor.constraint(equalToConstant: 3),
            rowTop,
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowBottom,
            goneRowTop,
            goneRowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            goneRowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            goneRowBottom,
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
        textStack.setCustomSpacing(2, after: nameRow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// F2：gone 态（showGone）首页不触发 onTapped（cell 侧同样守卫，双保险），
    /// 个人主页 allowGoneTap 时透传给控制器弹提示；加载失败态点按走重试；正常卡点按走 onTapped。
    @objc private func quoteTapped() {
        if isLoadFailedState {
            onRetryTapped?()
            return
        }
        if goneRowStack.isHidden == false, allowGoneTap == false {
            return
        }
        onTapped?()
    }

    func clear() {
        contentLabel.attributedText = nil
        contentLabel.text = nil
        dateLabel.text = nil
        dateLabel.isHidden = true
        onlyYouBadgeButton.isHidden = true
        goneLabel.text = nil
        goneLabel.isHidden = true
        goneIconView.image = nil
        goneIconView.isHidden = false
        goneRowStack.isHidden = true
        isLoadFailedState = false
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
    func showGone(message: String, iconName: String = "icon_quote") {
        clear()
        goneLabel.text = message
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

    /// iCity：configure 不再接受 showDeliveringPill / publishAt（投递 pill 与倒计时已删）；
    /// 私密被引角标改走 showOnlyYouBadge。占位态（showGone）不带日期与缩略图：
    /// clear() 已把日期行与缩略图区藏起，showGone 只显图标 + 占位文案。
    func configure(authorName: String, authorAvatar: String?, content: String, images: [String], dims: [String: [Int]]?, createdAt: Int? = nil, allowThumbs: Bool = true, showOnlyYouBadge: Bool = false) {
        clear()
        // 52 批：lite 卡不带头像名——authorName/authorAvatar 参数仅为调用点兼容保留，不再赋值给任何视图。
        if let createdAt = createdAt, createdAt > 0 {
            dateLabel.text = BearyDiaryCardCell.feedTimeString(ms: createdAt)
            dateLabel.isHidden = false
        }
        onlyYouBadgeButton.isHidden = showOnlyYouBadge == false
        if content.isEmpty {
            contentLabel.isHidden = true
        } else {
            contentLabel.isHidden = false
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.55
            // P3-3：引用正文富文本同步按字符断行（字号行高不动）。
            paragraph.lineBreakMode = .byCharWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13.5),
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
                    thumbView.layer.cornerRadius = 7
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

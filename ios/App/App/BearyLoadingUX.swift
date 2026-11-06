import UIKit

/// 信息流加载体验三件套（2026-11-05 Li 新令）：骨架屏扫光＋图片模糊到清晰
/// （见 UIImageView.bearySetImageWithBlurUp）＋加载更多脚部。
/// 核心：提前占位固定布局，再加动画，不跳动。动效只走 transform/opacity；
/// 减动效开时全部瞬时、无动画。骨架只盖内容列表区，页面框架（顶栏/tab/
/// 分区）仍按框架先行先出；此前“不用骨架屏”口径由本批取代（骨架已删的
/// 旧注释见各页 updateOverlayState，本批已同步改掉）。

// MARK: - 骨架卡片

/// 与真实日记卡片匹配的骨架：头像圆、名字/时间行、标题/正文行、216 高图片块，
/// 按卡片布局占位（左右 16、头像 40、图片块圆角 12）。
final class BearySkeletonCardView: UIView {

    /// 扫光周期：光带每 1.5 秒从左扫过一次。
    static let shimmerDuration: TimeInterval = 1.5

    private static func skeletonBaseColor() -> UIColor {
        UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.92, alpha: 1)
        }
    }

    private static func shimmerBandColor() -> UIColor {
        UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 1, alpha: 0.65)
        }
    }

    private var blocks: [UIView] = []
    private let shimmerContainer = UIView()
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var shimmering = false
    private var lastShimmerSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.bg
        // 头像圆 40
        let avatar = UIView()
        avatar.backgroundColor = Self.skeletonBaseColor()
        avatar.layer.cornerRadius = 20
        // 名字行 / 时间行
        let nameBar = bar(width: 120, height: 14)
        let timeBar = bar(width: 80, height: 12)
        // 标题行 / 正文行
        let titleBar = bar(height: 16)
        let bodyBar1 = bar(height: 12)
        let bodyBar2 = bar(height: 12)
        // 图片块 216 高
        let imageBlock = UIView()
        imageBlock.backgroundColor = Self.skeletonBaseColor()
        imageBlock.layer.cornerRadius = 12
        blocks = [avatar, nameBar, timeBar, titleBar, bodyBar1, bodyBar2, imageBlock]
        for b in blocks {
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
        }
        shimmerContainer.translatesAutoresizingMaskIntoConstraints = false
        shimmerContainer.isUserInteractionEnabled = false
        addSubview(shimmerContainer)
        shimmerContainer.layer.mask = maskLayer
        gradientLayer.colors = [UIColor.clear.cgColor, Self.shimmerBandColor().cgColor, UIColor.clear.cgColor]
        gradientLayer.locations = [0.42, 0.5, 0.58]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        // 斜向光带：图层自身转 -20°，位置沿 x 扫过（transform 与 position 互不干扰）。
        gradientLayer.transform = CATransform3DMakeRotation(-0.35, 0, 0, 1)
        shimmerContainer.layer.addSublayer(gradientLayer)
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
            nameBar.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            nameBar.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            nameBar.widthAnchor.constraint(equalToConstant: 120),
            nameBar.heightAnchor.constraint(equalToConstant: 14),
            timeBar.topAnchor.constraint(equalTo: nameBar.bottomAnchor, constant: 6),
            timeBar.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            timeBar.widthAnchor.constraint(equalToConstant: 80),
            timeBar.heightAnchor.constraint(equalToConstant: 12),
            titleBar.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 12),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleBar.heightAnchor.constraint(equalToConstant: 16),
            bodyBar1.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 10),
            bodyBar1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bodyBar1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bodyBar1.heightAnchor.constraint(equalToConstant: 12),
            bodyBar2.topAnchor.constraint(equalTo: bodyBar1.bottomAnchor, constant: 8),
            bodyBar2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bodyBar2.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.7, constant: -16),
            bodyBar2.heightAnchor.constraint(equalToConstant: 12),
            imageBlock.topAnchor.constraint(equalTo: bodyBar2.bottomAnchor, constant: 12),
            imageBlock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            imageBlock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageBlock.heightAnchor.constraint(equalToConstant: 216),
            imageBlock.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            shimmerContainer.topAnchor.constraint(equalTo: topAnchor),
            shimmerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            shimmerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            shimmerContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func bar(width: CGFloat? = nil, height: CGFloat) -> UIView {
        let v = UIView()
        v.backgroundColor = Self.skeletonBaseColor()
        v.layer.cornerRadius = height / 2
        if let width = width {
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 遮罩只露骨架块本身：光带只在块上扫，不照亮整片底色。
        let path = UIBezierPath()
        for b in blocks {
            path.append(UIBezierPath(roundedRect: b.frame, cornerRadius: b.layer.cornerRadius))
        }
        maskLayer.path = path.cgPath
        maskLayer.frame = bounds
        // 图层放大两倍、绕中心转 -20° 后仍盖住全幅；光带在图层中央，
        // 位置 x 从 -0.2W 扫到 1.2W 即完整扫过一次。
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: w * 2, height: h * 2)
        gradientLayer.position = CGPoint(x: bounds.width * 0.5, y: bounds.height * 0.5)
        // 尺寸变了才重开扫光（旋转/分屏）；普通布局不重启，光带不跳。
        if shimmering, lastShimmerSize != bounds.size {
            lastShimmerSize = bounds.size
            restartShimmerAnimation()
        }
        // 首次布局完成（bounds 落定）时起扫：didMoveToWindow 时 bounds
        // 可能还是 0，startShimmer 会直接返回，靠这里补上。
        if window != nil, bounds.width > 0 { startShimmer() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startShimmer() } else { stopShimmer() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            gradientLayer.colors = [UIColor.clear.cgColor, Self.shimmerBandColor().cgColor, UIColor.clear.cgColor]
        }
    }

    func startShimmer() {
        guard BearyMotion.animated(true) else { return }
        guard !shimmering, window != nil, bounds.width > 0 else { return }
        shimmering = true
        restartShimmerAnimation()
    }

    func stopShimmer() {
        shimmering = false
        gradientLayer.removeAnimation(forKey: "beary-shimmer-sweep")
    }

    private func restartShimmerAnimation() {
        gradientLayer.removeAnimation(forKey: "beary-shimmer-sweep")
        let w = max(bounds.width, 1)
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -0.2 * w
        anim.toValue = 1.2 * w
        anim.duration = Self.shimmerDuration
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        gradientLayer.add(anim, forKey: "beary-shimmer-sweep")
    }
}

/// 骨架行：内容即 BearySkeletonCardView；复用时重开扫光。
final class BearySkeletonCell: UITableViewCell {

    static let reuseIdentifier = "BearySkeletonCell"

    private let skeletonView = BearySkeletonCardView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = BearyColors.bg
        contentView.backgroundColor = BearyColors.bg
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(skeletonView)
        NSLayoutConstraint.activate([
            skeletonView.topAnchor.constraint(equalTo: contentView.topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        alpha = 1
        transform = .identity
    }
}

// MARK: - 加载更多脚部

/// 信息流底部脚部：加载中 3 个跳动小圆点；到底显示“没有更多了”；
/// 分页失败显示可点重试。调用方按状态显隐（hidden 时高 0）。
final class BearyLoadMoreFooterView: UIView {

    enum State {
        case hidden
        case loading
        case end
        case failed
    }

    static let height: CGFloat = 56

    var onRetry: (() -> Void)?

    private let dotsStack = UIStackView()
    private var dots: [UIView] = []
    private let endLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    private(set) var state: State = .hidden

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.bg
        for _ in 0..<3 {
            let dot = UIView()
            dot.backgroundColor = BearyColors.gray
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            dots.append(dot)
            dotsStack.addArrangedSubview(dot)
        }
        dotsStack.axis = .horizontal
        dotsStack.spacing = 10
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotsStack)
        endLabel.text = "没有更多了"
        endLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        endLabel.adjustsFontForContentSizeCategory = true
        endLabel.textColor = BearyColors.gray
        endLabel.textAlignment = .center
        endLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(endLabel)
        retryButton.setTitle("加载失败，重试", for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.setTitleColor(BearyColors.gray, for: .normal)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            dotsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            endLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            endLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // 初始态 hidden：三个子视图先全部藏起（setState(.hidden) 在 state
        // 已是 .hidden 时直接返回，不会再藏一遍）。
        dotsStack.isHidden = true
        endLabel.isHidden = true
        retryButton.isHidden = true
        setState(.hidden)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func retryTapped() { onRetry?() }

    func setState(_ newState: State) {
        guard newState != state else {
            if newState == .loading { startDots() }
            return
        }
        state = newState
        stopDots()
        dotsStack.isHidden = newState != .loading
        endLabel.isHidden = newState != .end
        retryButton.isHidden = newState != .failed
        if newState == .loading { startDots() }
    }

    private func startDots() {
        guard BearyMotion.animated(true) else { return }
        for (i, dot) in dots.enumerated() {
            dot.layer.removeAnimation(forKey: "beary-dot-bounce")
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            anim.fromValue = 0
            anim.toValue = -6
            anim.duration = 0.45
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            dot.layer.add(anim, forKey: "beary-dot-bounce")
        }
    }

    private func stopDots() {
        for dot in dots {
            dot.layer.removeAnimation(forKey: "beary-dot-bounce")
            dot.transform = .identity
        }
    }
}

// MARK: - 共享入场错峰与 300px 预加载

enum BearyLoadingUX {

    /// 新内容入场：淡入 + 从下方 yOffset 处上移（transform + opacity）。
    /// delayStep 为每块错峰步进（首屏 60ms、分页 50ms）；减动效直接落终值。
    static func staggerIn(cells: [UIView], delayStep: TimeInterval, yOffset: CGFloat, duration: TimeInterval = 0.25) {
        guard BearyMotion.animated(true) else {
            for cell in cells { cell.alpha = 1; cell.transform = .identity }
            return
        }
        for (order, cell) in cells.enumerated() {
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: 0, y: yOffset)
            let delay = min(Double(order) * delayStep, 0.24)
            UIView.animate(withDuration: duration, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
                cell.alpha = 1
                cell.transform = .identity
            }, completion: nil)
        }
    }

    /// 离屏 300px 预加载：把 indexPaths 里行顶已进入“可视底 + 300px”
    /// 的条目图经 BearyImagePrefetcher 预热（预算与流量口径由预取器定）。
    static func prefetchNearViewport(tableView: UITableView, indexPaths: [IndexPath], entryForRow: (IndexPath) -> Entry?, viewerId: Int?) {
        let visibleBottom = tableView.contentOffset.y + tableView.bounds.height
        var entries: [Entry] = []
        for path in indexPaths {
            let rect = tableView.rectForRow(at: path)
            guard rect.minY < visibleBottom + 300 else { continue }
            if let entry = entryForRow(path) { entries.append(entry) }
        }
        guard !entries.isEmpty else { return }
        BearyImagePrefetcher.shared.prefetch(entries: entries, lastVisibleIndex: -1, viewerId: viewerId)
    }
}

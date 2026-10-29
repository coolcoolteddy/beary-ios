// 6A：图片灯箱查看器（原详情页文件尾部整段抽出，详情页删除时保留，
// Profile/Timeline 继续复用；仅一处图标缓存调用由详情私有缓存改走共享 BearyIconImages，
// 私有淡入淡出动画类同步改名，行为一字未动）。
import UIKit

class BearyEntryImageViewerViewController: UIViewController, UIGestureRecognizerDelegate, UIViewControllerTransitioningDelegate {

    private let imageKeys: [String]
    /// 2026-10-29 第 15 项：本地图模式（个人页头像/封面查看，不新造查看器）——
    /// 非空时以 UIImage 直显，不走服务端 key 加载；单图查看，翻页全程以
    /// imageKeys.count > 1 守门，本地模式自然不翻页；计数/圆点按 count ≤ 1 隐藏。
    private let localImages: [UIImage]
    private var currentIndex: Int
    private let imageView = UIImageView()
    // 灯箱相邻图：拖动时贴在当前图边上同步跟手的那一张（见 updateNeighbor）。
    // 单图轨道没有分页容器，旧路径是当前图先滑出、再换图滑入，两图从不同时
    // 在屏、中间只剩黑底——即“不连贯、中间有间隙”的根因。
    private let neighborImageView = UIImageView()
    private var neighborIndex: Int?
    private var neighborDirection: Int = 0
    private let retryLabel = UILabel()
    private let counterLabel = UILabel()
    private let closeButton = BearyButton.closeButton()
    private let dotsStack = UIStackView()
    private var dotViews: [UIView] = []
    private var scale: CGFloat = 1
    private var tx: CGFloat = 0
    private var ty: CGFloat = 0
    private var panTx0: CGFloat = 0
    private var panTy0: CGFloat = 0
    private var pinchScale0: CGFloat = 1
    private var pinchActive: Bool = false
    /// 拖动手势引用：旋转中途重算相邻图位置时，凭它判断手指是否仍在拖动
    /// （回弹/翻页动画中的 transform 由动画自身驱动，不干扰）。
    private var panGesture: UIPanGestureRecognizer?
    private var isNavigating: Bool = false
    private var isFailed: Bool = false
    private var loadingKey: String?

    init(imageKeys: [String], startIndex: Int) {
        self.imageKeys = imageKeys
        self.localImages = []
        if startIndex >= 0 && startIndex < imageKeys.count {
            self.currentIndex = startIndex
        } else {
            self.currentIndex = 0
        }
        super.init(nibName: nil, bundle: nil)
        // E-G12：网页灯箱开场 200ms 淡入、关场 160ms 淡出，不用默认滑入滑出。
        modalPresentationStyle = .fullScreen
        transitioningDelegate = self
    }

    /// 本地图模式入口（个人页头像/封面）：与服务端 key 模式同一查看器、
    /// 同一淡入淡出转场与捏合/拖动，纯查看、无编辑入口。
    convenience init(images: [UIImage], startIndex: Int) {
        self.init(imageKeys: [], localImages: images, startIndex: startIndex)
    }

    init(imageKeys: [String], localImages: [UIImage], startIndex: Int) {
        self.imageKeys = imageKeys
        self.localImages = localImages
        if startIndex >= 0 && startIndex < max(imageKeys.count, localImages.count) {
            self.currentIndex = startIndex
        } else {
            self.currentIndex = 0
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        transitioningDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 灯箱底色 0.92 黑为例外（2026-10-28 定）：透 8% 保留底层上下文，不改纯黑；深色背景纯黑定版不覆盖灯箱。
        view.backgroundColor = UIColor(white: 0, alpha: 0.92)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        neighborImageView.contentMode = .scaleAspectFit
        neighborImageView.backgroundColor = .clear
        neighborImageView.translatesAutoresizingMaskIntoConstraints = false
        neighborImageView.isHidden = true
        view.addSubview(neighborImageView)
        retryLabel.text = "图片加载失败，重试"
        retryLabel.textColor = .white
        retryLabel.font = UIFont.systemFont(ofSize: 14)
        retryLabel.textAlignment = .center
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryLabel.isHidden = true
        view.addSubview(retryLabel)
        counterLabel.textColor = .white
        counterLabel.font = UIFont.systemFont(ofSize: 14)
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = imageKeys.count <= 1
        view.addSubview(counterLabel)
        // 底部圆点指示器（网页 .lb-dots 口径）：bottom safe+24、gap 8、圆点 6、非当前白 35%、当前白；仅多图显示。
        dotsStack.axis = .horizontal
        dotsStack.spacing = 8
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.isHidden = imageKeys.count <= 1
        for _ in imageKeys {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = UIColor(white: 1, alpha: 0.35)
            dot.layer.cornerRadius = 3
            dot.clipsToBounds = true
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            dotsStack.addArrangedSubview(dot)
            dotViews.append(dot)
        }
        view.addSubview(dotsStack)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(stageTapped(_:)))
        singleTap.numberOfTapsRequired = 1
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(stageDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
        pan.delegate = self
        panGesture = pan
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            neighborImageView.topAnchor.constraint(equalTo: view.topAnchor),
            neighborImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            neighborImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            neighborImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            retryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // E2：图片加载失败重试态按可视区中心往上 30pt 统一放（原正中心）。
            retryLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dotsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            dotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        updateCounter()
        loadCurrent()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    private func applyTransform(animated: Bool) {
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        if animated == true && UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: 0.25, animations: {
                self.imageView.transform = transform
            })
        } else {
            imageView.transform = transform
        }
    }

    private func resetZoom(animated: Bool) {
        hideNeighbor()
        scale = 1
        tx = 0
        ty = 0
        applyTransform(animated: animated)
    }

    private func clampPan() {
        // 1-1：按 imageView 缩放后尺寸与视口尺寸算限幅（原 120*scale 固定值
        // 与图实际显示尺寸无关：小图放大后拖出大片黑边、大图边缘提前顶住）。
        // imageView 全屏约束 + scaleAspectFit：显示尺寸 = 图按视口等比适配；
        // 未加载出图时回退视口尺寸。transform 为平移后缩放，tx/ty 本身即
        // 屏上点数，故限幅 = 缩放后尺寸超出视口的一半；图小于视口的轴钳为 0。
        let viewport = view.bounds
        var displayed = viewport.size
        if let image = imageView.image, image.size.width > 0, image.size.height > 0, viewport.width > 0, viewport.height > 0 {
            let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
            displayed = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        }
        let limX = max(0, (displayed.width * scale - viewport.width) / 2)
        let limY = max(0, (displayed.height * scale - viewport.height) / 2)
        tx = max(-limX, min(limX, tx))
        ty = max(-limY, min(limY, ty))
    }

    private func updateCounter() {
        counterLabel.text = "\(currentIndex + 1) / \(imageKeys.count)"
        for (dotIndex, dot) in dotViews.enumerated() {
            dot.backgroundColor = (dotIndex == currentIndex) ? .white : UIColor(white: 1, alpha: 0.35)
        }
    }

    private func loadCurrent() {
        // 2026-10-29 第 15 项：本地图模式——UIImage 直显，不走网络、不预取、
        // 不置失败态（本地图恒有图，失败重试入口不适用）。
        if !localImages.isEmpty {
            guard currentIndex >= 0 && currentIndex < localImages.count else { return }
            loadingKey = nil
            isFailed = false
            retryLabel.isHidden = true
            imageView.image = localImages[currentIndex]
            return
        }
        if imageKeys.isEmpty || currentIndex < 0 || currentIndex >= imageKeys.count {
            return
        }
        let key = imageKeys[currentIndex]
        loadingKey = key
        isFailed = false
        retryLabel.isHidden = true
        imageView.image = nil
        // E-G3：网页灯箱建全部 slide 并逐张 decode——本页单图轨道，至少预取相邻两张进
        // 图片缓存（切图时不再等网络，空白只剩解码一帧）；翻页同样走 loadCurrent，预取随之跟进。
        prefetchAdjacent()
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else {
            isFailed = true
            retryLabel.isHidden = false
            return
        }
        // S10 灯箱下采样：imageView 约束为全屏宽（leading/trailing = view），
        // 故查看器页宽即 view.bounds.width；为 0 时回退 UIScreen.main.bounds.width。
        // 下采样宽度 = 页宽 × 屏幕 scale；缩放/滑动行为不变。
        let pageWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        BearyImageLoader.shared.load(url: url, downsampleToWidth: pageWidth * UIScreen.main.scale) { [weak self] img in
            guard let self = self else { return }
            if self.loadingKey != key {
                return
            }
            if let img = img {
                self.imageView.image = img
                self.isFailed = false
                self.retryLabel.isHidden = true
            } else {
                self.isFailed = true
                self.retryLabel.isHidden = false
            }
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    /// E-G3 相邻图预取：前后各一张（回绕也算相邻，与本页循环翻页一致），
    /// 只暖缓存、不动当前图；单图时不预取。
    private func prefetchAdjacent() {
        if imageKeys.count <= 1 {
            return
        }
        for offset in [-1, 1] {
            let index = (currentIndex + offset + imageKeys.count) % imageKeys.count
            if index == currentIndex {
                continue
            }
            guard let url = BearyImageURLs.imageURL(key: imageKeys[index], thumb: false) else {
                continue
            }
            BearyImageLoader.shared.load(url: url) { _ in }
        }
    }

    private func pageWidthValue() -> CGFloat {
        view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
    }

    /// 拖动时相邻图跟手：相邻图静止时贴在当前图外侧（下一张在右、上一张在左），
    /// 随当前图同量平移，两图始终相邻无间隙；拖动回 0 或方向翻转时重算/隐藏。
    /// 相邻图通常已由 prefetchAdjacent 暖过缓存，加载失败时该槽位留空（不比旧路径差）。
    private func updateNeighbor(forDragX dragX: CGFloat) {
        guard imageKeys.count > 1, scale == 1 else { hideNeighbor(); return }
        if dragX == 0 { hideNeighbor(); return }
        let direction = dragX < 0 ? 1 : -1
        let target = (currentIndex + direction + imageKeys.count) % imageKeys.count
        if neighborIndex != target || neighborDirection != direction {
            neighborIndex = target
            neighborDirection = direction
            neighborImageView.image = nil
            neighborImageView.isHidden = false
            if let url = BearyImageURLs.imageURL(key: imageKeys[target], thumb: false) {
                let w = pageWidthValue()
                BearyImageLoader.shared.load(url: url, downsampleToWidth: w * UIScreen.main.scale) { [weak self] img in
                    guard let self = self, self.neighborIndex == target else { return }
                    self.neighborImageView.image = img
                }
            }
        }
        let w = pageWidthValue()
        neighborImageView.transform = CGAffineTransform(translationX: dragX + CGFloat(direction) * w, y: 0)
    }

    private func hideNeighbor() {
        neighborIndex = nil
        neighborDirection = 0
        neighborImageView.isHidden = true
        neighborImageView.transform = .identity
    }

    /// 旋转中途重算：拖动过程中旋转屏幕时，相邻图按新宽度重贴边（只动相邻图
    /// 位置，不动当前图）；仅手指仍在拖动时重算——回弹/翻页动画中的 transform
    /// 由动画自身驱动，不干扰；未拖动时相邻图隐藏，本分支自然跳过。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scale == 1, neighborIndex != nil, neighborImageView.isHidden == false,
              let pan = panGesture, pan.state == .began || pan.state == .changed else { return }
        let w = pageWidthValue()
        neighborImageView.transform = CGAffineTransform(translationX: tx + CGFloat(neighborDirection) * w, y: 0)
    }

    // MARK: - E-G12 淡入淡出转场

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerFadeAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerFadeAnimator(presenting: false)
    }

    @objc private func stageTapped(_ sender: UITapGestureRecognizer) {
        // 失败图点按重试，不关闭（网页 img-err 口径）；关闭钮点按由按钮自身处理。
        if isFailed == true {
            loadCurrent()
            return
        }
        let point = sender.location(in: view)
        if closeButton.frame.contains(point) {
            return
        }
        closeTapped()
    }

    @objc private func stageDoubleTapped(_ sender: UITapGestureRecognizer) {
        if isNavigating == true {
            return
        }
        hideNeighbor()
        if scale > 1 {
            resetZoom(animated: true)
        } else {
            scale = 2
            tx = 0
            ty = 0
            applyTransform(animated: true)
        }
    }

    @objc private func pinchChanged(_ sender: UIPinchGestureRecognizer) {
        if isNavigating == true {
            return
        }
        if sender.state == .began {
            pinchActive = true
            hideNeighbor()
            pinchScale0 = scale
        } else if sender.state == .changed {
            pinchActive = true
            scale = max(1, min(4, pinchScale0 * sender.scale))
            clampPan()
            applyTransform(animated: false)
        } else if sender.state == .ended || sender.state == .cancelled {
            pinchActive = false
            if scale < 1.15 {
                resetZoom(animated: true)
            } else {
                clampPan()
                applyTransform(animated: true)
            }
        }
    }

    @objc private func panChanged(_ sender: UIPanGestureRecognizer) {
        if isNavigating == true || pinchActive == true {
            return
        }
        let translation = sender.translation(in: view)
        if sender.state == .began {
            panTx0 = tx
            panTy0 = ty
        } else if sender.state == .changed {
            if scale > 1 {
                // 放大后平移，限幅按缩放后图尺寸算（见 clampPan）。
                tx = panTx0 + translation.x
                ty = panTy0 + translation.y
                clampPan()
            } else {
                // 未放大：轨道跟手，只跟横向；相邻图同步贴在边上跟手（见 updateNeighbor）。
                tx = translation.x
                ty = 0
                updateNeighbor(forDragX: tx)
            }
            applyTransform(animated: false)
        } else if sender.state == .ended || sender.state == .cancelled {
            if scale > 1 {
                // 放大态平移停在当前位置（已限幅），不翻页、不回弹。
                clampPan()
                applyTransform(animated: true)
                return
            }
            let totalDx = translation.x
            let totalDy = translation.y
            // 网页口径：横向 >60px 且横向占优才翻页，否则回弹。
            if imageKeys.count > 1 && abs(totalDx) > 60 && abs(totalDx) > abs(totalDy) * 1.5 {
                navigate(direction: totalDx < 0 ? 1 : -1)
            } else {
                tx = 0
                ty = 0
                if UIAccessibility.isReduceMotionEnabled {
                    applyTransform(animated: false)
                    hideNeighbor()
                } else {
                    // 回弹时相邻图同步退回屏外再隐藏，避免回弹瞬间相邻图闪没。
                    let w = pageWidthValue()
                    let dir = neighborDirection
                    let hasNeighbor = neighborIndex != nil
                    UIView.animate(withDuration: 0.25, animations: {
                        self.applyTransform(animated: false)
                        if hasNeighbor {
                            self.neighborImageView.transform = CGAffineTransform(translationX: CGFloat(dir) * w, y: 0)
                        }
                    }, completion: { _ in self.hideNeighbor() })
                }
            }
        }
    }

    private func navigate(direction: Int) {
        if imageKeys.count <= 1 || isNavigating == true {
            return
        }
        let next = currentIndex + direction
        let isWrap = next < 0 || next >= imageKeys.count
        let wrapped = (next + imageKeys.count) % imageKeys.count
        if isWrap == true {
            // 回绕瞬时归位：不做长距离倒带动效（网页 trackTo(!wrap) 口径）。
            currentIndex = wrapped
            resetZoom(animated: false)
            updateCounter()
            loadCurrent()
            return
        }
        // 连续翻页：拖动时相邻图已贴在边上跟手（updateNeighbor），直接把两图
        // 一次动画到终位再交接——当前图出屏、相邻图正好居中，全程相邻无间隙。
        // 相邻图未就绪时回落旧的两段式路径（行为不变）。
        if neighborIndex == wrapped && neighborImageView.image != nil {
            isNavigating = true
            let width = pageWidthValue()
            let offX: CGFloat = direction > 0 ? -width : width
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let commit: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.currentIndex = wrapped
                self.scale = 1
                self.tx = 0
                self.ty = 0
                self.imageView.image = self.neighborImageView.image
                self.imageView.transform = .identity
                self.hideNeighbor()
                // 5-16（选 commit 内同步清态，不走 loadCurrent 重载闪图）：
                // 相邻图既已成功显示，上一张的失败态必须同步清除，否则
                // 成功图上仍压着“图片加载失败，重试”；loadingKey 同步
                // 跟进为当前图 key，后续 loadCurrent 回包代次校验才对得上。
                self.isFailed = false
                self.retryLabel.isHidden = true
                self.loadingKey = self.imageKeys[wrapped]
                self.updateCounter()
                self.prefetchAdjacent()
                self.isNavigating = false
            }
            if reduceMotion == true {
                commit()
                return
            }
            UIView.animate(withDuration: 0.25, animations: {
                self.tx = offX
                self.ty = 0
                self.applyTransform(animated: false)
                self.neighborImageView.transform = .identity
            }, completion: { _ in
                commit()
            })
            return
        }
        hideNeighbor()
        isNavigating = true
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let offX: CGFloat = direction > 0 ? -width : width
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let slideOut: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.currentIndex = wrapped
            self.scale = 1
            self.tx = -offX
            self.ty = 0
            self.applyTransform(animated: false)
            self.updateCounter()
            self.loadCurrent()
            self.tx = 0
            self.ty = 0
            self.applyTransform(animated: reduceMotion == false)
            self.isNavigating = false
        }
        if reduceMotion == true {
            slideOut()
            return
        }
        tx = offX
        ty = 0
        UIView.animate(withDuration: 0.25, animations: {
            self.applyTransform(animated: false)
        }, completion: { _ in
            slideOut()
        })
    }
}

/// 网页灯箱同款纯透明度转场：开场 200ms 淡入、关场 160ms 淡出。
private final class BearyImageViewerFadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return presenting ? 0.2 : 0.16
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let duration = transitionDuration(using: transitionContext)
        if presenting {
            guard let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            transitionContext.containerView.addSubview(toView)
            toView.alpha = 0
            UIView.animate(withDuration: duration, animations: {
                toView.alpha = 1
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            UIView.animate(withDuration: duration, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}

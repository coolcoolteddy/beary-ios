// 6A：图片灯箱查看器（原详情页文件尾部整段抽出，详情页删除时保留，
// Profile/Timeline 继续复用；仅一处图标缓存调用由详情私有缓存改走共享 BearyIconImages，
// 私有淡入淡出动画类同步改名，行为一字未动）。
import UIKit
import Photos

class BearyEntryImageViewerViewController: UIViewController, UIGestureRecognizerDelegate, UIViewControllerTransitioningDelegate {

    private let imageKeys: [String]
    /// 实况映射（静态图 key → 视频 key；nil = 无实况，灯箱纯静态，与旧版一致）。
    /// 调用方在创建时传入本篇 entry.liveVideos（详情/卡片容器/照片墙均已接线）。
    var liveVideos: [String: String]?
    /// 实况覆盖层：盖在 imageView 之上，平时隐藏、实况就绪后显现，长按播实况；
    /// 自身不接手势，点按关闭/双击缩放/捏合/拖动翻页一律走原手势。
    private var liveOverlay: BearyLivePhotoView?
    /// 实况长按抬手后的误触屏蔽：只挡紧随其后的那一次舞台点按（长按抬手
    /// 时手指离屏常被识别成一次点按），挡完即清，不再用时间窗持续屏蔽。
    /// 普通图（无可播实况）长按不立此旗，抬手后点按立即生效。
    private var suppressNextStageTapAfterLive = false
    /// 本次长按是否真的播了实况（began 时 hasLivePhoto 才置位）；只有它为真，
    /// 抬手才立起上面的一次性屏蔽，普通图长按抬手不留任何屏蔽。
    private var livePlaybackStarted = false
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
    /// 110：目标图未加载时的加载反馈（网页同款圆环，黑底用 bright 白版）——
    /// 不是骨架屏，也不再用下拉刷新那套 icon_refresh；只在 imageView 无图可显
    /// 且有在途加载时转，图到/失败即停。
    private let loadingSpinner = BearyWebRingSpinnerView(bright: true)
    /// 111：灯箱底色占位层——目标图未到时盖住全屏、底色走页面底色
    /// BearyColors.bg（浅白／深黑，随 trait 自动跟随），不是纯黑、不是
    /// 骨架屏；图到／失败即藏，旧图绝不滑回的口径不动。
    private let placeholderView = UIView()
    private let retryLabel = UILabel()
    private let counterLabel = UILabel()
    private let closeButton = BearyButton.closeButton()
    private let dotsStack = UIStackView()
    /// 批 C：照片页灯箱专用——非 nil 时底部出现“查看日记”钮，点按回传当前图序号
    /// （调用方凭序号找所属日记进详情）；nil 时钮不出现，旧调用方行为一字不动。
    var onViewEntryAtIndex: ((Int) -> Void)?

    private lazy var viewEntryButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("查看日记", for: .normal)
        buttonValue.setTitleColor(.white, for: .normal)
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.backgroundColor = UIColor(white: 1, alpha: 0.16)
        buttonValue.layer.cornerRadius = 18
        buttonValue.clipsToBounds = true
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        buttonValue.addTarget(self, action: #selector(viewEntryButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private var viewEntryBottomToDotsConstraint: NSLayoutConstraint?
    private var viewEntryBottomToSafeConstraint: NSLayoutConstraint?
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
    /// 纵向甩关闭拖动状态：0 未定、1 横向翻页、2 纵向甩关闭（上甩/下甩对称）——一根手势内
    /// 定向后不再切换，避免斜向拖动中途从翻页跳成纵向甩（或反向）。
    private var panMode: Int = 0
    private var isNavigating: Bool = false
    private var isFailed: Bool = false
    private var loadingKey: String?
    /// 关场回到原处：调用方在 present 前传入被点缩略图在 window 坐标下的
    /// 矩形（未传时关场走淡出兜底，同样不闪）；全屏模态下底层表无法滚动，
    /// present 时 captured 的矩形在关场时仍然有效。
    var originFrameInWindow: CGRect?
    /// 关场动画只在“当前图就是打开时那张”时走回到原处；翻页后关场走淡出
    /// 兜底（原处已不是当前图对应的缩略图，硬缩回去反而错位）。
    var initialIndex: Int = 0
    /// 下甩关闭拖动态：竖向为主且向下时进入，横向翻页不再接管本次手势。
    private var dismissDragActive: Bool = false

    init(imageKeys: [String], startIndex: Int) {
        self.imageKeys = imageKeys
        self.localImages = []
        if startIndex >= 0 && startIndex < imageKeys.count {
            self.currentIndex = startIndex
        } else {
            self.currentIndex = 0
        }
        self.initialIndex = self.currentIndex
        super.init(nibName: nil, bundle: nil)
        // E-G12：网页灯箱开场 200ms 淡入；关场见 BearyImageViewerReturnAnimator
        //（回到原处动效，缺原处时淡出兜底），不用默认滑入滑出。
        modalPresentationStyle = .fullScreen
        transitioningDelegate = self
    }

    /// 实况入口（旧 init 原样保留，无实况调用方不受影响）。
    convenience init(imageKeys: [String], liveVideos: [String: String]?, startIndex: Int) {
        self.init(imageKeys: imageKeys, startIndex: startIndex)
        self.liveVideos = liveVideos
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
        self.initialIndex = self.currentIndex
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
        placeholderView.backgroundColor = BearyColors.bg
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.isHidden = true
        view.addSubview(placeholderView)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        neighborImageView.contentMode = .scaleAspectFit
        neighborImageView.backgroundColor = .clear
        neighborImageView.translatesAutoresizingMaskIntoConstraints = false
        neighborImageView.isHidden = true
        view.addSubview(neighborImageView)
        // 实况覆盖层：与 imageView 同框、随 applyTransform 同步缩放平移；
        // 平时隐藏（原静态图可见），实况就绪后显现，长按播实况。
        let liveOverlay = BearyLivePhotoView(contentMode: .aspectFit)
        view.addSubview(liveOverlay)
        self.liveOverlay = liveOverlay
        loadingSpinner.tintColor = .white
        view.addSubview(loadingSpinner)
        retryLabel.text = "图片加载失败，重试"
        retryLabel.textColor = .white
        retryLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        retryLabel.adjustsFontForContentSizeCategory = true
        retryLabel.textAlignment = .center
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryLabel.isHidden = true
        view.addSubview(retryLabel)
        counterLabel.textColor = .white
        counterLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = imageKeys.count <= 1
        view.addSubview(counterLabel)
        // 批 C：照片页灯箱可能一次带几十张图，圆点全画会溢出屏宽——
        // 超 20 张时只留顶部计数“n / N”，圆点隐藏（旧单篇灯箱 ≤9 张不受影响）。
        if onViewEntryAtIndex != nil {
            view.addSubview(viewEntryButton)
        }
        // 底部圆点指示器（网页 .lb-dots 口径）：bottom safe+24、gap 8、圆点 6、非当前白 35%、当前白；仅多图显示。
        dotsStack.axis = .horizontal
        dotsStack.spacing = 8
        dotsStack.alignment = .center
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        dotsStack.isHidden = imageKeys.count <= 1 || imageKeys.count > 20
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
        let livePress = UILongPressGestureRecognizer(target: self, action: #selector(liveLongPressed(_:)))
        livePress.minimumPressDuration = 0.4
        livePress.delegate = self
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(livePress)
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: view.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            neighborImageView.topAnchor.constraint(equalTo: view.topAnchor),
            neighborImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            neighborImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            neighborImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            liveOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            liveOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            liveOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            liveOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // E2：图片加载失败重试态按可视区中心往上 30pt 统一放（原正中心）。
            retryLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // 32 清单第 17 项：计数跟随放大后不得压到右上关闭钮之下（文案短，平时不触发；极端字号下宁可截尾不断钮）。
            counterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            counterLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            dotsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            dotsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        if onViewEntryAtIndex != nil {
            let toDots = viewEntryButton.bottomAnchor.constraint(equalTo: dotsStack.topAnchor, constant: -16)
            let toSafe = viewEntryButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
            viewEntryBottomToDotsConstraint = toDots
            viewEntryBottomToSafeConstraint = toSafe
            toDots.isActive = !dotsStack.isHidden
            toSafe.isActive = dotsStack.isHidden
            NSLayoutConstraint.activate([
                viewEntryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                viewEntryButton.heightAnchor.constraint(equalToConstant: 36),
            ])
        }
        updateCounter()
        loadCurrent()
    }

    @objc private func viewEntryButtonTapped() {
        // 主动操作即表示抬手误触期已过，待挡的一次点按不再生效。
        suppressNextStageTapAfterLive = false
        onViewEntryAtIndex?(currentIndex)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    private func applyTransform(animated: Bool) {
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        if animated == true && UIAccessibility.isReduceMotionEnabled == false {
            UIView.animate(withDuration: 0.25, animations: {
                self.imageView.transform = transform
                self.liveOverlay?.transform = transform
            })
        } else {
            imageView.transform = transform
            liveOverlay?.transform = transform
        }
    }

    /// 实况覆盖层跟随当前图：本地图模式与无实况图一律清掉；有实况时配
    /// 置（同 key 重复调用不重复加载）；翻页/切图时由 loadCurrent 与
    /// navigate 的 commit 调用，缩放平移由 applyTransform 同步。
    private func updateLiveOverlay() {
        guard let overlay = liveOverlay else { return }
        if !localImages.isEmpty || imageKeys.isEmpty || currentIndex < 0 || currentIndex >= imageKeys.count {
            overlay.clear()
            return
        }
        let key = imageKeys[currentIndex]
        overlay.configure(staticKey: key, liveKey: liveVideos?[key])
    }

    @objc private func liveLongPressed(_ sender: UILongPressGestureRecognizer) {
        if sender.state == .began {
            // 只有当前图确有可播实况才响应：普通图上 startPlayback 本就是空操作
            // （livePhoto 为 nil 时不播），旧代码却无条件立起 3 秒压制窗，导致
            // 普通图长按后 3 秒内舞台点按全部失灵（点按关闭无反应）。
            guard liveOverlay?.hasLivePhoto == true else { return }
            liveOverlay?.startPlayback()
            livePlaybackStarted = true
        } else if sender.state == .ended || sender.state == .cancelled {
            // 抬手后只屏蔽一次误触，不持续屏蔽后续主动点击。旧的 3 秒窗 +
            // ended 0.35 秒缩短分支一并删除：该分支对常规长按（按住 < 2.65 秒）
            // 恒不生效（began 的 3 秒窗总比 ended 的 0.35 秒窗晚到期），等于
            // 全程跑满 3 秒；按住超 2.65 秒才走到的缩短逻辑亦随时间窗机制废止。
            if livePlaybackStarted {
                suppressNextStageTapAfterLive = true
            }
            livePlaybackStarted = false
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

    /// 110：加载圈显隐。只在“无图可显且有在途加载”时转：首张/切图
    /// 未加载时屏上是加载圈而非纯黑中场；旧图仍在（P2-25 保留）时不转，
    /// 旧图即过渡占位；失败时停并走重试文案；本地图模式恒有图，不转。
    private func updateLoadingSpinner() {
        if !localImages.isEmpty || isFailed || imageView.image != nil || loadingKey == nil {
            loadingSpinner.stopSpinning()
            placeholderView.isHidden = true
        } else {
            loadingSpinner.startSpinning()
            // 111：与加载圈同条件显隐——目标未到时底色占位层先盖住
            // 全屏（页面底色），弱网切图不再是纯黑中场；图到即藏。
            placeholderView.isHidden = false
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
            updateLoadingSpinner()
            updateLiveOverlay()
            return
        }
        if imageKeys.isEmpty || currentIndex < 0 || currentIndex >= imageKeys.count {
            return
        }
        let key = imageKeys[currentIndex]
        loadingKey = key
        isFailed = false
        retryLabel.isHidden = true
        // 审计 P2-25：切图/重试时不再先置 nil 回落黑屏——旧图保留到新图到达
        // （首张加载时 imageView 本就为空，无变化；失败时旧图仍在、重试文案在上）。
        // imageView.image = nil（旧写法，已删）
        // E-G3：网页灯箱建全部 slide 并逐张 decode——本页单图轨道，至少预取相邻两张进
        // 图片缓存（切图时不再等网络，空白只剩解码一帧）；翻页同样走 loadCurrent，预取随之跟进。
        prefetchAdjacent()
        updateLiveOverlay()
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else {
            isFailed = true
            retryLabel.isHidden = false
            updateLoadingSpinner()
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
            self.updateLoadingSpinner()
        }
        // 110：发出加载后立即按“无图可显且在途”判定圈显隐（首张/切图
        // 未加载时圈即转，不等回包；旧图仍在时不转，旧图即过渡）。
        updateLoadingSpinner()
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    /// E-G3 相邻图预取：前后各一张（回绕也算相邻，与本页循环翻页一致），
    /// 只暖缓存、不动当前图；单图时不预取。
    /// 111：预取必须带与展示加载同款下采样宽度——旧口径不带下采样时
    /// 内存键与展示键不一致（内存键含下采样宽度），预取只暖了磁盘、
    /// 展示时仍需解码一遍；现与 loadCurrent 同宽，内存直接命中。
    private func prefetchAdjacent() {
        if imageKeys.count <= 1 {
            return
        }
        let downsampleWidth = pageWidthValue() * UIScreen.main.scale
        for offset in [-1, 1] {
            let index = (currentIndex + offset + imageKeys.count) % imageKeys.count
            if index == currentIndex {
                continue
            }
            guard let url = BearyImageURLs.imageURL(key: imageKeys[index], thumb: false) else {
                continue
            }
            BearyImageLoader.shared.load(url: url, downsampleToWidth: downsampleWidth) { _ in }
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

    // MARK: - 关场回到原处（供 BearyImageViewerReturnAnimator 用）

    /// 关场起始图与矩形：aspectFit 显示矩形再套当前 transform（捏合缩放/
    /// 平移、下甩跟手位移都在 transform 里），用 CGRect.applying 精确算，
    /// 不估算中心点。无图时返回 nil，走淡出兜底。
    func dismissStartInfo() -> (image: UIImage, rect: CGRect)? {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitRect = CGRect(
            x: (bounds.width - image.size.width * fit) / 2,
            y: (bounds.height - image.size.height * fit) / 2,
            width: image.size.width * fit,
            height: image.size.height * fit
        )
        // 关场起点必须是图在屏上的真实显示矩形：UIView transform 是绕
        // imageView 中心（= view 中心）作用的，而 CGRect.applying 是绕坐标
        // 原点作用——纯平移时两者恰好相等，捏合缩放后起点会整体错位、
        // 临时图在动画第一帧就跳一下。convert 按图层 transform 换算，
        // 本查看器只有平移＋缩放（无旋转），换算结果即精确显示矩形。
        return (image, imageView.convert(fitRect, to: view))
    }

    /// 关场动画器读当前下标（currentIndex 本身是 private）。
    var currentIndexForDismiss: Int { currentIndex }

    /// 回到原处路径专用：原图藏起，改由 container 里的临时图做主角；
    /// 淡出兜底路径不调它，旧图随 fromView 一起淡出。
    func setDismissImageHidden(_ hidden: Bool) {
        imageView.isHidden = hidden
    }

    /// 关场时藏起全部 chrome（计数、圆点、关闭钮、重试、加载圈、相邻图），
    /// 只留图片本身做回到原处的主角；淡出兜底路径不调它，旧图随 fromView 一起淡出。
    func setDismissChromeHidden(_ hidden: Bool) {
        counterLabel.isHidden = hidden ? true : imageKeys.count <= 1
        dotsStack.isHidden = hidden ? true : (imageKeys.count <= 1 || imageKeys.count > 20)
        closeButton.isHidden = hidden
        viewEntryButton.isHidden = hidden
        retryLabel.isHidden = hidden ? true : !isFailed
        if hidden {
            loadingSpinner.stopSpinning()
            placeholderView.isHidden = true
            hideNeighbor()
        }
    }

    /// 下甩跟手时的 chrome/底色同步：图往下走多少，底色与 chrome 就淡多少；
    /// 取消时传 0 恢复原样。
    private func applyDismissDragProgress(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        view.backgroundColor = UIColor(white: 0, alpha: 0.92 * (1 - p * 0.7))
        counterLabel.alpha = 1 - p
        dotsStack.alpha = 1 - p
        closeButton.alpha = 1 - p
    }

    private func resetDismissDragAppearance() {
        view.backgroundColor = UIColor(white: 0, alpha: 0.92)
        counterLabel.alpha = 1
        dotsStack.alpha = 1
        closeButton.alpha = 1
    }

    // MARK: - E-G12 淡入转场 + 回到原处关场

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerFadeAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerReturnAnimator(viewer: self)
    }

    @objc private func stageTapped(_ sender: UITapGestureRecognizer) {
        // 实况长按抬手后的那一次误触点按：挡一次即清，后续主动点按不再受影响。
        if suppressNextStageTapAfterLive {
            suppressNextStageTapAfterLive = false
            return
        }
        // 失败图点按重试，不关闭（网页 img-err 口径）；关闭钮点按由按钮自身处理。
        if isFailed == true {
            loadCurrent()
            return
        }
        // 审计 P2-25：放大后单点不关闭（scale > 1 时只做缩放/拖动，关闭走关闭钮或缩回后点按）。
        if scale > 1 {
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
        // 双击缩放是主动操作，待挡的一次抬手误触不再生效，不留给后面的点按。
        suppressNextStageTapAfterLive = false
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
            // 捏合是主动操作，清掉待挡的一次抬手误触，不留给后面的点按。
            suppressNextStageTapAfterLive = false
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
                // 清单 16：捏合结束重定平移基线。捏合期间 panChanged 因
                // pinchActive 早退，pan 的 .began 仍是捏合前的旧基线；若此时
                // pan 手势仍在进行（多指未松开，不会再有 .began），下一次
                // .changed 会用旧基线 + 自 pan 开始累计的 translation 算 tx/ty，
                // 而捏合期 clampPan 已动过 tx/ty，造成位移跳变。此处把基线
                // 重定为“当前 tx/ty 减当前 translation”：重定瞬间 tx/ty 不变，
                // 后续增量连续。只在 scale > 1 的平移模式且 pan 仍在进行时做
                // （scale == 1 时 tx 直接等于 translation，无基线可言；pan 已
                // 结束时不动，下次 .began 会重设）。时序注意：本重定以
                // translation 自手势开始累计为前提（系统侧若在触点数变化时
                // 自行重置 translation，则重定本身会引入跳变，真机须验此点）。
                if let pan = panGesture, pan.state == .began || pan.state == .changed {
                    let translation = pan.translation(in: view)
                    panTx0 = tx - translation.x
                    panTy0 = ty - translation.y
                }
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
            // 拖动（翻页/甩关闭）是主动操作，清掉待挡的一次抬手误触。
            suppressNextStageTapAfterLive = false
            // 灯箱对子统一定位：panMode 与 dismissDragActive 同步清零
            // （0=未定，1=横向翻页，2=纵向甩关闭；dismissDragActive 即 panMode==2）。
            panMode = 0
            dismissDragActive = false
        } else if sender.state == .changed {
            if scale > 1 {
                // 放大后平移，限幅按缩放后图尺寸算（见 clampPan）。
                tx = panTx0 + translation.x
                ty = panTy0 + translation.y
                clampPan()
                applyTransform(animated: false)
            } else if panMode == 2 {
                // 纵向甩关闭跟手（#431 渲染口径为准：位移 + 底色/chrome 淡）：
                // 上下对称，图跟手指走，进度取位移绝对值。
                hideNeighbor()
                tx = 0
                ty = translation.y
                applyTransform(animated: false)
                applyDismissDragProgress(abs(ty) / 320)
            } else if panMode == 1 {
                // 横向翻页跟手，只跟横向；相邻图同步贴在边上跟手（见 updateNeighbor）。
                tx = translation.x
                ty = 0
                updateNeighbor(forDragX: tx)
                applyTransform(animated: false)
            } else {
                // 未定：位移过 12pt 才定向——纵向占优（往上或往下都一样）进
                // 纵向甩关闭，其余进横向翻页；定向前图不动，避免斜拖中途跳变。
                // 定向后不再改向（横向中途不再切纵向，反之亦然）。
                if max(abs(translation.x), abs(translation.y)) > 12 {
                    if abs(translation.y) > abs(translation.x) {
                        panMode = 2
                        dismissDragActive = true
                        hideNeighbor()
                        tx = 0
                        ty = translation.y
                        applyTransform(animated: false)
                        applyDismissDragProgress(abs(ty) / 320)
                    } else {
                        panMode = 1
                        tx = translation.x
                        ty = 0
                        updateNeighbor(forDragX: tx)
                        applyTransform(animated: false)
                    }
                }
            }
        } else if sender.state == .ended || sender.state == .cancelled {
            if panMode == 2 {
                // 纵向甩关闭收尾（#431 关场动画器为准）：位移绝对值 >120pt
                // 统一阈值（上下一致），或纵向快甩（|vy|>900 且纵向占优）。
                // 取消态一律弹回，不关场。关场前绝不复位 tx/ty/transform：
                // ReturnAnimator 的 dismissStartInfo 直接读 imageView.transform
                // 作临时图起点，复位会让临时图先跳回中心再缩，闪一帧鬼影。
                let velocity = sender.velocity(in: view)
                let flickVertical = abs(velocity.y) > 900 && abs(velocity.y) > abs(velocity.x) * 1.5
                let shouldDismiss = sender.state == .ended && (abs(ty) > 120 || flickVertical)
                panMode = 0
                dismissDragActive = false
                if shouldDismiss {
                    dismiss(animated: UIAccessibility.isReduceMotionEnabled == false, completion: nil)
                } else {
                    hideNeighbor()
                    tx = 0
                    ty = 0
                    resetDismissDragAppearance()
                    applyTransform(animated: true)
                }
                return
            }
            panMode = 0
            dismissDragActive = false
            if scale > 1 {
                // 放大态平移停在当前位置（已限幅），不翻页、不回弹。
                clampPan()
                applyTransform(animated: true)
                return
            }
            let totalDx = translation.x
            let totalDy = translation.y
            // 网页口径：横向 >60px 且横向占优才翻页，否则回弹。
            // 110：补速度口径——快甩（横向速度 >700pt/s 且横向占优）即使
            // 位移不足 60 也翻页，免得轻甩看起来“滑不动”；慢拖仍按位移
            // 阈值，不误触；每 pan 只 navigate 一次，不串页。
            let velocity = sender.velocity(in: view)
            let flickPages = abs(velocity.x) > 700 && abs(velocity.x) > abs(velocity.y) * 1.5
            let distancePages = abs(totalDx) > 60 && abs(totalDx) > abs(totalDy) * 1.5
            if imageKeys.count > 1 && (distancePages || flickPages) {
                // 位移达标按位移方向，快甩达标按末速度方向。
                let direction = distancePages ? (totalDx < 0 ? 1 : -1) : (velocity.x < 0 ? 1 : -1)
                navigate(direction: direction)
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
                self.liveOverlay?.transform = .identity
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
                self.updateLiveOverlay()
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
        // 110：回落路径统一走相邻图轨道，不再两段式。旧两段式是
        // “当前图先滑出（邻槽空着即黑场）→交接时把旧图从另一侧滑回→
        // 新图到达才替换”，即中间黑 + 滑回的是上一张、弱网下尤其明显。
        // 现：目标槽位先贴到翻页方向外侧（拖动中已贴好的槽位不重置，
        // 避免跳变；未贴时新建槽位并起目标加载，与 loadCurrent 在途合并），
        // 两图一次动画同步到位；交接时目标已加载即用目标图，未加载则
        // imageView 先空 + 加载圈（见 updateLoadingSpinner），loadCurrent
        // 回包到达即填图，旧图绝不滑回来。减动效时瞬时交接，不播动画。
        isNavigating = true
        let width = pageWidthValue()
        let offX: CGFloat = direction > 0 ? -width : width
        let hadNeighborSlot = (neighborIndex == wrapped)
        neighborIndex = wrapped
        neighborDirection = direction
        if !hadNeighborSlot {
            neighborImageView.image = nil
            neighborImageView.isHidden = false
            neighborImageView.transform = CGAffineTransform(translationX: CGFloat(direction) * width, y: 0)
            if let url = BearyImageURLs.imageURL(key: imageKeys[wrapped], thumb: false) {
                BearyImageLoader.shared.load(url: url, downsampleToWidth: width * UIScreen.main.scale) { [weak self] img in
                    guard let self = self, self.neighborIndex == wrapped else { return }
                    self.neighborImageView.image = img
                }
            }
        } else {
            neighborImageView.isHidden = false
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let commitFallback: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.currentIndex = wrapped
            self.scale = 1
            self.tx = 0
            self.ty = 0
            self.imageView.transform = .identity
            self.liveOverlay?.transform = .identity
            if let targetImage = self.neighborImageView.image {
                self.imageView.image = targetImage
                self.isFailed = false
                self.retryLabel.isHidden = true
                self.loadingKey = self.imageKeys[wrapped]
            } else {
                // 目标未到：先空 + 加载圈，loadCurrent 回包填图（不留旧图）。
                self.imageView.image = nil
            }
            self.hideNeighbor()
            self.updateCounter()
            self.loadCurrent()
            self.isNavigating = false
        }
        if reduceMotion == true {
            commitFallback()
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.tx = offX
            self.ty = 0
            self.applyTransform(animated: false)
            self.neighborImageView.transform = .identity
        }, completion: { _ in
            commitFallback()
        })
    }
}

/// 网页灯箱同款纯透明度转场：只做开场 200ms 淡入。
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
    }
}

/// 关场回到原处动画器（点按关闭、下甩关闭、灯箱内“查看日记”跳转关场
/// 全部走它，动画路径只有这一条，不留一种闪一种不闪）。
///
/// 闪的根因（旧 BearyImageViewerFadeAnimator 关场分支）：.fullScreen 模态
/// 在 present 完成后会把底层页从层级里移除；旧关场动画只把 fromView 的
/// alpha 淡到 0，却没有先把底层页（toView）加回 container——160ms 里
/// container 底层是窗口黑底，动画结束底层页才瞬间恢复，视觉上就是闪一下。
/// 本动画器关场第一步就把 toView 加到 fromView 之下、铺满 container，
/// 再淡 fromView／缩图，底层页全程在位，结束时不再有“突然出现”的一帧。
private final class BearyImageViewerReturnAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private weak var viewer: BearyEntryImageViewerViewController?

    init(viewer: BearyEntryImageViewerViewController) {
        self.viewer = viewer
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        // 底层页先就位（见上闪的根因），再做一切动画。
        toView.frame = container.bounds
        container.addSubview(toView)
        container.addSubview(fromView)

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard reduceMotion == false,
              let viewer = viewer,
              viewer.currentIndexForDismiss == viewer.initialIndex,
              let origin = viewer.originFrameInWindow,
              let start = viewer.dismissStartInfo() else {
            // 兜底：减动效、无图、无原处、翻页后关场——走 160ms 淡出，
            // 但 toView 已在位，同样不闪。
            UIView.animate(withDuration: reduceMotion ? 0 : 0.16, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }

        // 主路径：原图藏起，临时图从灯箱显示位缩回原处缩略图位；
        // 临时图盖在 fromView 之上，fromView 底色与自身 alpha 同步淡出，
        // 原处缩略图是被临时图盖着“长出来”的，结束前不会突然跳出来抢位。
        viewer.setDismissChromeHidden(true)
        viewer.setDismissImageHidden(true)
        let startRect = fromView.convert(start.rect, to: container)
        let tempView = UIImageView(image: start.image)
        tempView.frame = startRect
        tempView.contentMode = .scaleToFill
        tempView.clipsToBounds = true
        tempView.layer.cornerRadius = 12
        container.addSubview(tempView)
        let targetRect = container.convert(origin, from: nil)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
            fromView.alpha = 0
            tempView.frame = targetRect
        }, completion: { _ in
            tempView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}

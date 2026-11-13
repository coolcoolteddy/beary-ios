// 6A：图片灯箱查看器（原详情页文件尾部整段抽出，详情页删除时保留，
// Profile/Timeline 继续复用；仅一处图标缓存调用由详情私有缓存改走共享 BearyIconImages，
// 私有淡入淡出动画类同步改名，行为一字未动）。
import UIKit
import Photos

class BearyEntryImageViewerViewController: UIViewController, UIGestureRecognizerDelegate, UIViewControllerTransitioningDelegate {

    /// 第 22 轮 B5：灯箱持有的照片数组是打开时的快照；相册重滤撤下失效
    /// 照片时经 pruneImageKeys 同步更新，故须为 var（旧 let 只读）。
    private var imageKeys: [String]
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
    /// B5 画面与入口的同一 ID：当前屏上这张图对应的照片 key（本地图模式
    /// 为 "local:<下标>"）；nil = 屏上无图（加载中／失败）。「查看日记」
    /// 只在它等于当前下标的 key 时启用，弱网回绕不再出现“看着末张、
    /// 点进首张”。只在 imageView.image 被赋值／清空处同步维护，
    /// 失败回包不碰它（旧图仍在屏时 ID 不变）。
    private var displayedImageKey: String?
    /// 当前下标对应的照片 key（与 displayedImageKey 同口径比对）。
    private var currentPhotoKey: String? {
        if !localImages.isEmpty {
            guard currentIndex >= 0, currentIndex < localImages.count else { return nil }
            return "local:\(currentIndex)"
        }
        guard currentIndex >= 0, currentIndex < imageKeys.count else { return nil }
        return imageKeys[currentIndex]
    }
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
    /// ①-6：下甩遮罩——view 背景改透明后，由它承载 0.92→0.276 的底色
    /// alpha（只改 opacity，合规范 §6；p=1 时有效 alpha 0.276，与旧
    /// view.backgroundColor 0.92*(1-p*0.7) 的现行视觉一致）。
    private let dismissScrimView = UIView()
    private let retryButton = BearyHit44Button(type: .custom)
    private let counterLabel = UILabel()
    private let closeButton = BearyButton.closeButton()
    private let dotsStack = UIStackView()
    /// 批 C：照片页灯箱专用——非 nil 时底部出现“查看日记”钮，点按回传当前图序号
    /// （调用方凭序号找所属日记进详情）；nil 时钮不出现，旧调用方行为一字不动。
    var onViewEntryAtIndex: ((Int) -> Void)?

    private lazy var viewEntryButton: UIButton = {
        // 按钮普查：视觉高 36，热区用 Hit44 扩到 44（上下邻居为圆点指示与安全区，无互叠按钮）。
        let buttonValue = BearyHit44Button(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setTitle("查看日记", for: .normal)
        buttonValue.setTitleColor(.white, for: .normal)
        // B5：入口未就绪时只置灰文案（背景不动），与 isEnabled 门同口径。
        buttonValue.setTitleColor(UIColor(white: 1, alpha: 0.45), for: .disabled)
        buttonValue.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        buttonValue.titleLabel?.adjustsFontForContentSizeCategory = true
        buttonValue.backgroundColor = UIColor(white: 1, alpha: 0.16)
        buttonValue.layer.cornerRadius = BearyCorners.single
        buttonValue.clipsToBounds = true
        buttonValue.contentEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        buttonValue.addTarget(self, action: #selector(viewEntryButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private var viewEntryBottomToDotsConstraint: NSLayoutConstraint?
    private var viewEntryBottomToSafeConstraint: NSLayoutConstraint?
    private var dotViews: [UIView] = []
    /// C1 相册分页共享：网格续拉的新页追加到灯箱末尾（见 appendImageKeys）。
    /// hasMorePages 由网格在打开时与每次续拉后同步；onRequestMorePages
    /// 由网格接 fetchNextPageIfNeeded。未接线的调用方（详情／时间线）
    /// 两值保持默认，翻页与回绕行为一字不动。
    var hasMorePages = false
    var onRequestMorePages: (() -> Void)?
    /// C1：已向网格要过下一页、在等回包（防重复请求）。
    private var isRequestingMorePages = false
    /// C1：最近一次续拉失败（提示文案切到失败态，下次越过末尾再请求一次）。
    private var loadMoreFailed = false
    /// C1：越过已加载末尾时记下的下标——新页到了且仍停在该下标时，
    /// 自动往前翻一页（接上用户“继续往后看”的意图）。
    private var pendingAdvanceFromIndex: Int?
    /// C1：边缘加载提示（计数下方）：「正在加载更多照片」／失败文案。
    private let loadMoreSpinner = UIActivityIndicatorView(style: .medium)
    private let loadMoreLabel = UILabel()
    private let loadMoreStack = UIStackView()
    private var scale: CGFloat = 1
    /// 审计 15 项第 8 项：放大后已升级到的高清解码宽度（同图同宽不再重复加载）。
    private var zoomHiResKey: String?
    private var zoomHiResWidth: CGFloat = 0
    private var tx: CGFloat = 0
    private var ty: CGFloat = 0
    private var panTx0: CGFloat = 0
    private var panTy0: CGFloat = 0
    private var pinchScale0: CGFloat = 1
    private var pinchActive: Bool = false
    /// 审计三轮 11：捏合锚点基线——.began 时记下双指中心与当时的
    /// tx/ty/scale，.changed 时按当前双指中心重算平移，让捏合中心
    /// 的内容始终留在手指下（旧写法只改缩放、不补偿平移）。
    private var pinchCenter0: CGPoint = .zero
    private var pinchTx0: CGFloat = 0
    private var pinchTy0: CGFloat = 0
    /// 拖动手势引用：旋转中途重算相邻图位置时，凭它判断手指是否仍在拖动
    /// （回弹/翻页动画中的 transform 由动画自身驱动，不干扰）。
    private var panGesture: UIPanGestureRecognizer?
    /// 纵向甩关闭拖动状态：0 未定、1 横向翻页、2 纵向甩关闭（上甩/下甩对称）——一根手势内
    /// 定向后不再切换，避免斜向拖动中途从翻页跳成纵向甩（或反向）。
    private var panMode: Int = 0
    private var isNavigating: Bool = false
    private var isFailed: Bool = false
    private var loadingKey: String?
    /// 高清升级竞态守门：第 4 项——每次“当前图身份”变化（loadCurrent 发起、
    /// 翻页交接直接换图）即 +1；在途回包凭发起时代次校验，过期代次一律丢弃，
    /// 避免旧图或旧升级覆盖新图。升级回包另有清晰度优先级（见
    /// maybeUpgradeZoomResolution），代次只管“是不是这张图这一轮”。
    private var imageLoadGeneration = 0
    /// 先显缩略图：调用方把被点缩略图上已显示的 UIImage 传进来（零网络），
    /// 打开即铺满显示，高清到了再换；拿不到时为 nil，走现有转圈等高清口径。
    /// 与 liveVideos／originFrameInWindow 同口径：present 前赋值。
    var initialThumbnail: UIImage?
    /// 当前屏上这张是不是先显的缩略图（高清换上时用短淡入、只换一次）。
    private var showingInitialThumbnail = false
    /// 关场回到原处：调用方在 present 前传入被点缩略图在 window 坐标下的
    /// 矩形（未传时关场走淡出兜底，同样不闪）；全屏模态下底层表无法滚动，
    /// present 时 captured 的矩形在关场时仍然有效。
    var originFrameInWindow: CGRect?
    /// 无障碍：关闭后焦点返回的原缩略图视图（由调用方在 present 前传入；
    /// 未传入时不发焦点通知）。只传视图引用，不改关场动画与矩形逻辑。
    var focusReturnElement: UIView?
    /// C3 关场回当前照片：调用方按下标提供该照片当前在 window 下的
    /// 缩略图矩形与焦点视图（网格格未在视口内时返回 nil，走淡出兜底）。
    /// 提供方存在时它全权决定关场原处与焦点（见 dismissOriginFrame 与
    /// dismissViewer）；未提供时沿用 originFrameInWindow／focusReturnElement
    /// 的旧口径。
    var dismissOriginProvider: ((Int) -> (frame: CGRect, element: UIView?)?)?
    /// 无障碍：打开首焦点只发一次。
    private var didPostViewerOpenFocus = false
    /// 关场回到原处：无 dismissOriginProvider 时，只在“当前图就是打开时
    /// 那张”时走回到原处；翻页后关场走淡出兜底（原处已不是当前图对应
    /// 的缩略图，硬缩回去反而错位）。有提供方时由它按当前下标给原处。
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
        // ①-6：view 背景改透明，底色改由最底层遮罩承载——下甩跟手只改
        // 遮罩 opacity（规范 §6 只走 transform/opacity），不再改 backgroundColor；
        // 遮罩 alpha 0.92→0.276，与旧口径现行视觉一致。审计原修法只加遮罩、
        // 保留 0.92 背景不动，p=1 时会叠成 0.92＋遮罩、复现不了现行视觉，故不采用。
        view.backgroundColor = .clear
        dismissScrimView.backgroundColor = .black
        dismissScrimView.alpha = 0.92
        dismissScrimView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissScrimView)
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
        retryButton.setTitle("图片加载失败，重试", for: .normal)
        retryButton.setTitleColor(.white, for: .normal)
        retryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        // 失败重试现为真实 UIButton：VoiceOver 双击即触发 .touchUpInside，
        // 不再只靠 .button 读法（纯 UILabel 时双击走 accessibilityActivate，
        // 未实现即无动作，也不会转发给舞台点按手势）；关闭钮为纯图标钮，补“关闭”读法。
        // 文案／字号／颜色／位置一字不动，只换承载控件。
        retryButton.isAccessibilityElement = true
        retryButton.accessibilityLabel = "图片加载失败，点按重试"
        retryButton.accessibilityTraits = .button
        retryButton.titleLabel?.textAlignment = .center
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        view.addSubview(retryButton)
        counterLabel.textColor = .white
        // ①-10：会变的序号走等宽数字（规范 §11 tabularDigitsFont，现成入口，14 不变）。
        counterLabel.font = BearyDynamicType.tabularDigitsFont(ofSize: 14)
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textAlignment = .center
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(counterLabel)
        // C1：边缘加载提示（计数下方）：翻到已加载末尾、还有后续页时显
        //「正在加载更多照片」，失败时切失败文案；平时隐藏。
        loadMoreSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadMoreSpinner.color = .white
        loadMoreLabel.translatesAutoresizingMaskIntoConstraints = false
        loadMoreLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        loadMoreLabel.adjustsFontForContentSizeCategory = true
        loadMoreLabel.textColor = UIColor(white: 1, alpha: 0.75)
        loadMoreStack.translatesAutoresizingMaskIntoConstraints = false
        loadMoreStack.axis = .horizontal
        loadMoreStack.alignment = .center
        loadMoreStack.spacing = 6
        loadMoreStack.isHidden = true
        loadMoreStack.addArrangedSubview(loadMoreSpinner)
        loadMoreStack.addArrangedSubview(loadMoreLabel)
        view.addSubview(loadMoreStack)
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
        rebuildDots()
        view.addSubview(dotsStack)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityLabel = "关闭"
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
            dismissScrimView.topAnchor.constraint(equalTo: view.topAnchor),
            dismissScrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dismissScrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dismissScrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // E2：图片加载失败重试态按可视区中心往上 30pt 统一放（原正中心）。
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // 32 清单第 17 项：计数跟随放大后不得压到右上关闭钮之下（文案短，平时不触发；极端字号下宁可截尾不断钮）。
            counterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            counterLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            loadMoreStack.topAnchor.constraint(equalTo: counterLabel.bottomAnchor, constant: 8),
            loadMoreStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
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
        updateViewEntryAvailability()
        maybeRequestMorePages()
    }

    @objc private func viewEntryButtonTapped() {
        // B5：入口与画面同 ID 兜底——屏上图不是当前下标那张时不发
        //（按钮禁用态本已不发点按，此处防任何旁路调用）。
        guard displayedImageKey != nil, displayedImageKey == currentPhotoKey else { return }
        // 主动操作即表示抬手误触期已过，待挡的一次点按不再生效。
        suppressNextStageTapAfterLive = false
        onViewEntryAtIndex?(currentIndex)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    /// 拖拽收尾统一弹簧（规范 §6）：0.26s／damping 0.7；松手速度经
    /// springVelocityAlongReturn 归一化后由 initialSpringVelocity 传入，
    /// 慢拖（松手速度≈0）归一化结果即 0。减动效门控走 BearyMotion.animated，
    /// 与原直接判 UIAccessibility.isReduceMotionEnabled 等效，减动效开时
    /// 直切终态不播动画。additionalAnimations 与图片回弹放进同一动画块
    /// （审计残留第 10 项：灯箱下拉未过阈值回弹时，背景/chrome 复位须与
    /// 图片同块动，否则瞬间跳回、图片却随后滑回，视觉错位）；无附加
    /// 动画时默认 nil，其余调用点一律不动。
    private func applyTransform(animated: Bool, initialSpringVelocity: CGFloat = 0, additionalAnimations: (() -> Void)? = nil) {
        let transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
        if BearyMotion.animated(animated) {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: initialSpringVelocity, options: .curveEaseOut, animations: {
                self.imageView.transform = transform
                self.liveOverlay?.transform = transform
                additionalAnimations?()
            })
        } else {
            imageView.transform = transform
            liveOverlay?.transform = transform
            additionalAnimations?()
        }
    }

    /// 松手速度归一化：沿回弹方向的速度分量（pt/s，正值＝朝终态走）除以
    /// 回弹距离（pt），得 initialSpringVelocity（单位：全程距离／秒）。
    /// 逆向速度（手指朝远离终态的方向甩）不传，取 0，避免弹回先反向冲出；
    /// 距离为 0 时取 0；限幅 2，避免小距离把速度放大成抖动。
    private func springVelocityAlongReturn(velocityAlongReturn: CGFloat, distance: CGFloat) -> CGFloat {
        guard distance > 0 else { return 0 }
        return max(0, min(2, velocityAlongReturn / distance))
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
            // 有 liveKey 但未就绪时也响应：加载中转圈可见，失败时长按重试；
            // startPlayback 返回 false（正在加载中）时不立压制窗，点按照常。
            guard liveOverlay?.hasLivePhoto == true || liveOverlay?.hasLiveKey == true else { return }
            livePlaybackStarted = liveOverlay?.startPlayback() ?? false
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

    private func resetZoom(animated: Bool, initialSpringVelocity: CGFloat = 0) {
        hideNeighbor()
        scale = 1
        tx = 0
        ty = 0
        applyTransform(animated: animated, initialSpringVelocity: initialSpringVelocity)
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
        // S2：总数取 max（本地图模式 imageKeys 为空时不再读成“/ 0”）。
        let totalCount = max(imageKeys.count, localImages.count)
        let newText = "\(currentIndex + 1) / \(totalCount)"
        // ①-10：切图时序号 0.18s 交叉淡变（规范 §6 局部状态动效）；
        // 文字不变时不播，减动效开时直换。
        if counterLabel.text != newText {
            if BearyMotion.animated(true) {
                UIView.transition(with: counterLabel, duration: BearyMotion.localStateDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                    self.counterLabel.text = newText
                }, completion: nil)
            } else {
                counterLabel.text = newText
            }
        }
        // 无障碍：计数视觉文案是“1 / 9”，VoiceOver 直接读会含糊；补一句
        // 完整读法“第 1 张，共 9 张”，切图时 updateCounter 重算，焦点停在
        // 计数上即可读到当前页；底部圆点是纯装饰 UIView，不另做无障碍元素。
        counterLabel.accessibilityLabel = "第 \(currentIndex + 1) 张，共 \(totalCount) 张"
        for (dotIndex, dot) in dotViews.enumerated() {
            dot.backgroundColor = (dotIndex == currentIndex) ? .white : UIColor(white: 1, alpha: 0.35)
        }
    }

    /// B5：「查看日记」启用门——屏上图与当前下标是同一张照片、且不在
    /// 翻页动画中途时才启用；未到图／动画中途／无此入口时禁用（文案
    /// 不变，只置灰防误点）。无入口的调用方（详情／时间线）直接返回，
    /// 不实例化懒加载按钮。
    private func updateViewEntryAvailability() {
        guard onViewEntryAtIndex != nil else { return }
        let ready = !isNavigating && displayedImageKey != nil && displayedImageKey == currentPhotoKey
        viewEntryButton.isEnabled = ready
    }

    /// 第 22 轮 B5：撤下已失效的照片（限时到期／互关解除后相册重滤时调用）。
    /// 只删 invalid 里的 key、其余顺序不变；当前图被撤时就近留下一张
    /// （优先同位、否则末张）；全部撤完即关闭灯箱；本地图模式不走 key，不动。
    /// 在途加载凭 loadCurrent 的代次守门丢弃，不会把已撤的图盖回来。
    func pruneImageKeys(_ invalidKeys: Set<String>) {
        guard localImages.isEmpty else { return }
        guard !invalidKeys.isEmpty else { return }
        let currentKey = (currentIndex >= 0 && currentIndex < imageKeys.count) ? imageKeys[currentIndex] : nil
        let keptKeys = imageKeys.filter { !invalidKeys.contains($0) }
        guard keptKeys != imageKeys else { return }
        guard !keptKeys.isEmpty else {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
            return
        }
        imageKeys = keptKeys
        if let currentKey = currentKey, let keptIndex = keptKeys.firstIndex(of: currentKey) {
            currentIndex = keptIndex
        } else {
            currentIndex = min(currentIndex, keptKeys.count - 1)
            showingInitialThumbnail = false
        }
        initialIndex = min(initialIndex, keptKeys.count - 1)
        zoomHiResKey = nil
        zoomHiResWidth = 0
        resetZoom(animated: false)
        rebuildDots()
        updateCounter()
        loadCurrent()
    }

    /// C1：圆点与总数同步（打开时与追加新页后都走这里）：≤20 张画圆点，
    /// 超 20 张只留顶部计数；「查看日记」钮的底部锚点随圆点显隐切换。
    /// 第 22 轮 B5：重建时同步清计数显隐（≤1 张藏计数与圆点）。
    private func rebuildDots() {
        for dot in dotViews {
            dotsStack.removeArrangedSubview(dot)
            dot.removeFromSuperview()
        }
        dotViews.removeAll()
        // S2：计数取 max（本地图模式 imageKeys 为空时，计数／圆点不再按 0 张隐藏）。
        let totalCount = max(imageKeys.count, localImages.count)
        counterLabel.isHidden = totalCount <= 1
        dotsStack.isHidden = totalCount <= 1 || totalCount > 20
        for _ in 0..<totalCount {
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
        if onViewEntryAtIndex != nil {
            viewEntryBottomToDotsConstraint?.isActive = !dotsStack.isHidden
            viewEntryBottomToSafeConstraint?.isActive = dotsStack.isHidden
        }
    }

    /// C1：网格和灯箱订阅同一个分页结果——网格续拉的新页按照片 key
    /// 追加到灯箱末尾（去重：已在灯箱里的 key 不重复加）。调用方在
    /// 主线程调；新页到了且用户仍停在越过末尾那张时，自动往前翻一页。
    func appendImageKeys(_ keys: [String], liveVideos newLiveVideos: [String: String]?, hasMorePages: Bool) {
        self.hasMorePages = hasMorePages
        isRequestingMorePages = false
        loadMoreFailed = false
        let oldCount = imageKeys.count
        var seen = Set(imageKeys)
        var added = 0
        for key in keys {
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            imageKeys.append(key)
            added += 1
        }
        if let newLiveVideos = newLiveVideos, !newLiveVideos.isEmpty {
            if liveVideos == nil {
                liveVideos = newLiveVideos
            } else {
                for (key, value) in newLiveVideos {
                    liveVideos?[key] = value
                }
            }
        }
        rebuildDots()
        updateCounter()
        updateLoadMoreHint()
        if added > 0 {
            prefetchAdjacent()
        }
        guard let from = pendingAdvanceFromIndex else { return }
        pendingAdvanceFromIndex = nil
        // 仍停在越过末尾那张、手指已离开、且新页确实到了，才自动往前翻；
        // 用户已翻走或手指还在拖动时不抢方向，留给下次滑动。
        guard from == currentIndex, from == oldCount - 1,
              imageKeys.count > oldCount, !isNavigating,
              panGesture?.state != .began, panGesture?.state != .changed else { return }
        navigate(direction: 1)
    }

    /// C1：续拉失败时由网格通知——提示切到失败文案，下次越过末尾再请求一次。
    func notifyMorePagesFailed() {
        isRequestingMorePages = false
        loadMoreFailed = true
        updateLoadMoreHint()
    }

    /// C1：落到已加载最后一张、还有后续页时向网格要下一页（只发一次，
    /// 回包／失败前不再重复要）。打开即在末尾时同样触发，先把下一页暖好。
    private func maybeRequestMorePages() {
        updateLoadMoreHint()
        guard onRequestMorePages != nil, hasMorePages, !isRequestingMorePages,
              !imageKeys.isEmpty, currentIndex == imageKeys.count - 1 else { return }
        isRequestingMorePages = true
        loadMoreFailed = false
        onRequestMorePages?()
        updateLoadMoreHint()
    }

    /// C1：边缘提示——只在已加载末尾、还有后续页时显（「正在加载更多照片」，
    /// 失败时为「更多照片加载失败，继续滑动重试」）；其余位置隐藏。
    private func updateLoadMoreHint() {
        let show = onRequestMorePages != nil && hasMorePages && !imageKeys.isEmpty
            && currentIndex == imageKeys.count - 1
        loadMoreStack.isHidden = !show
        guard show else {
            loadMoreSpinner.stopAnimating()
            return
        }
        let text = loadMoreFailed ? "更多照片加载失败，继续滑动重试" : "正在加载更多照片"
        loadMoreLabel.text = text
        loadMoreLabel.accessibilityLabel = text
        if loadMoreFailed {
            loadMoreSpinner.stopAnimating()
        } else {
            loadMoreSpinner.startAnimating()
        }
    }

    /// 110：加载圈显隐。只在“无图可显且有在途加载”时转：首张/切图
    /// 未加载时屏上是加载圈而非纯黑中场；旧图仍在（P2-25 保留）时不转，
    /// 旧图即过渡占位；失败时停并走重试文案；本地图模式恒有图，不转。
    private func updateLoadingSpinner() {
        if !localImages.isEmpty || isFailed || imageView.image != nil || loadingKey == nil {
            loadingSpinner.stopSpinning()
            placeholderView.isHidden = true
            // 审计 15 项第 15 项：图到/失败后恢复灯箱原有白色控件。
            counterLabel.textColor = .white
            loadingSpinner.setBright(true)
        } else {
            // 审计 15 项第 15 项：加载占位期间前景色与占位底匹配——
            // 占位底走 BearyColors.bg（浅白／深黑），浅色下不用纯白圈
            // 与白计数，深色下仍用原有 bright 白版。
            let dark = traitCollection.userInterfaceStyle == .dark
            loadingSpinner.setBright(dark)
            counterLabel.textColor = dark ? .white : BearyColors.ink
            loadingSpinner.startSpinning()
            // 111：与加载圈同条件显隐——目标未到时底色占位层先盖住
            // 全屏（页面底色），弱网切图不再是纯黑中场；图到即藏。
            placeholderView.isHidden = false
        }
    }

    /// 审计 15 项第 15 项：深浅切换时若正处加载占位，前景色跟随重算。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateLoadingSpinner()
        }
    }

    private func loadCurrent() {
        // 2026-10-29 第 15 项：本地图模式——UIImage 直显，不走网络、不预取、
        // 不置失败态（本地图恒有图，失败重试入口不适用）。
        if !localImages.isEmpty {
            guard currentIndex >= 0 && currentIndex < localImages.count else { return }
            loadingKey = nil
            isFailed = false
            retryButton.isHidden = true
            imageView.image = localImages[currentIndex]
            displayedImageKey = currentPhotoKey
            updateLoadingSpinner()
            updateLiveOverlay()
            return
        }
        if imageKeys.isEmpty || currentIndex < 0 || currentIndex >= imageKeys.count {
            return
        }
        let key = imageKeys[currentIndex]
        loadingKey = key
        imageLoadGeneration += 1
        let generation = imageLoadGeneration
        // 审计 15 项第 8 项：切图后放大高清状态清零，下次放大重新按需升级。
        zoomHiResKey = nil
        zoomHiResWidth = 0
        isFailed = false
        retryButton.isHidden = true
        // 先显缩略图：只在打开那张、屏上无图时用一次（零网络，打开即见图、
        // 不转圈）；高清回包后即清标记；切到别的图时标记同步清零，旧缩略图
        // 绝不复活到别的图上。缩略图拿不到（nil）时走现有转圈等高清口径。
        if currentIndex == initialIndex, imageView.image == nil, let thumb = initialThumbnail {
            imageView.image = thumb
            displayedImageKey = currentPhotoKey
            showingInitialThumbnail = true
            initialThumbnail = nil
        } else if currentIndex != initialIndex {
            showingInitialThumbnail = false
        }
        // 审计 P2-25：切图/重试时不再先置 nil 回落黑屏——旧图保留到新图到达
        // （首张加载时 imageView 本就为空，无变化；失败时旧图仍在、重试文案在上）。
        // imageView.image = nil（旧写法，已删）
        // E-G3：网页灯箱建全部 slide 并逐张 decode——本页单图轨道，至少预取相邻两张进
        // 图片缓存（切图时不再等网络，空白只剩解码一帧）；翻页同样走 loadCurrent，预取随之跟进。
        prefetchAdjacent()
        updateLiveOverlay()
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else {
            isFailed = true
            retryButton.isHidden = false
            updateLoadingSpinner()
            return
        }
        // S10 灯箱下采样：imageView 约束为全屏宽（leading/trailing = view），
        // 故查看器页宽即 view.bounds.width；为 0 时回退 UIScreen.main.bounds.width。
        // 下采样宽度 = 页宽 × 屏幕 scale；缩放/滑动行为不变。
        let pageWidth = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        BearyImageLoader.shared.load(url: url, downsampleToWidth: pageWidth * UIScreen.main.scale) { [weak self] img in
            guard let self = self else { return }
            if self.loadingKey != key || generation != self.imageLoadGeneration {
                return
            }
            // 第 4 项·高清优先：同图已显示更高清升级版时，迟到的基础回包
            // 不再覆盖回去（基础宽恒小于升级宽；旋转后基础宽若已反超，
            // 则它不再是“更低”，照常接受）。失败分支同样跳过：好图已在屏，
            // 不应再压上失败态。
            let baseWidth = self.pageWidthValue() * UIScreen.main.scale
            if self.zoomHiResKey == key && self.zoomHiResWidth > baseWidth {
                return
            }
            if let img = img {
                // 高清到了：正显缩略图时短淡入换上（未放大时走局部状态时长；
                // 已放大直接换，transform 一字不动；减动效开时直接换）。
                if self.showingInitialThumbnail, self.scale == 1, BearyMotion.animated(true) {
                    UIView.transition(with: self.imageView, duration: BearyMotion.localStateDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                        self.imageView.image = img
                    }, completion: nil)
                } else {
                    self.imageView.image = img
                }
                // B5：高清到了，屏上图即当前 key，入口随之放行。
                self.displayedImageKey = key
                self.showingInitialThumbnail = false
                self.isFailed = false
                self.retryButton.isHidden = true
            } else {
                // 高清失败：缩略图仍在屏（上一步未清图），只亮重试入口。
                self.isFailed = true
                self.retryButton.isHidden = false
            }
            self.updateLoadingSpinner()
            self.updateViewEntryAvailability()
        }
        // 110：发出加载后立即按“无图可显且在途”判定圈显隐（首张/切图
        // 未加载时圈即转，不等回包；旧图仍在时不转，旧图即过渡）。
        updateLoadingSpinner()
    }

    /// 无障碍：打开首焦点只发一次——多图落到计数（读“第 N 张，共 M 张”），
    /// 单图落到关闭钮。未开 VoiceOver 时 post 为空操作。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 灯箱圈上屏重加：viewDidLoad 里 loadCurrent 调 startSpinning 时，
        // view 还没被转场挂进容器（转场先取 view 再 addSubview），动画加在
        // 未上屏的图层上不转；且 spinning 已置真，后续 updateLoadingSpinner
        // 会被 startSpinning 首行 guard 挡回、动画补不上。上屏后先停再重算，
        // 强制重加一次；图已到／失败时重算走停分支，无视觉变化。
        loadingSpinner.stopSpinning()
        updateLoadingSpinner()
        guard !didPostViewerOpenFocus else { return }
        didPostViewerOpenFocus = true
        let target: UIView = imageKeys.count > 1 ? counterLabel : closeButton
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: target)
        }
    }

    /// 无障碍：统一关场入口——关闭钮与纵向甩关闭都走这里；dismiss 完成
    /// 后若调用方传入的原缩略图仍在窗口内，焦点回到它；未传入时不发。
    /// 失败图「图片加载失败，点按重试」本身不是问题，本支不动它。
    /// C3：有关场回当前照片的提供方时，焦点回当前照片对应的格
    ///（格不在视口内时提供方给 nil，不发焦点通知）；没有提供方时
    /// 沿用调用方传入的 focusReturnElement。
    private func dismissViewer() {
        var returnElement = focusReturnElement
        if let provider = dismissOriginProvider {
            if let info = provider(currentIndex) {
                returnElement = info.element
            } else {
                returnElement = nil
            }
        }
        dismiss(animated: UIAccessibility.isReduceMotionEnabled == false) {
            if let element = returnElement, !element.isHidden, element.window != nil {
                UIAccessibility.post(notification: .layoutChanged, argument: element)
            }
        }
    }

    @objc private func closeTapped() {
        dismissViewer()
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

    /// 审计 15 项第 8 项：放大后按需后台解码更高清版本。首屏继续用当前
    /// 轻量版本；目标宽度 = 页宽 × 屏幕 scale × 当前缩放，封顶 3072
    /// （像素预算）；同图已升级到同宽或更高时不重复加载；回包时图已
    /// 切走、缩放已回 1 时不替换；替换只换 imageView.image，当前
    /// transform（缩放位置）一字不动。
    /// 第 4 项·竞态守门：回包另凭发起时代次校验（过期代次丢弃），并按
    /// 清晰度优先级接受——只接受不低于已显示升级版的结果，迟到的低清
    /// 回包丢弃且不拉低 zoomHiResWidth 水位，画面不再重新变糊。
    private func maybeUpgradeZoomResolution() {
        guard scale > 1, localImages.isEmpty, currentIndex >= 0, currentIndex < imageKeys.count else { return }
        let key = imageKeys[currentIndex]
        let baseWidth = pageWidthValue() * UIScreen.main.scale
        let targetWidth = min(baseWidth * scale, 3072)
        if zoomHiResKey == key && targetWidth <= zoomHiResWidth { return }
        guard targetWidth > baseWidth else { return }
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else { return }
        let generation = imageLoadGeneration
        BearyImageLoader.shared.load(url: url, downsampleToWidth: targetWidth) { [weak self] img in
            guard let self = self, let img = img else { return }
            guard self.currentIndex >= 0, self.currentIndex < self.imageKeys.count,
                  self.imageKeys[self.currentIndex] == key, self.scale > 1,
                  generation == self.imageLoadGeneration else { return }
            if self.zoomHiResKey == key && targetWidth <= self.zoomHiResWidth { return }
            self.imageView.image = img
            self.showingInitialThumbnail = false
            self.zoomHiResKey = key
            self.zoomHiResWidth = targetWidth
        }
    }

    /// 拖动时相邻图跟手：相邻图静止时贴在当前图外侧（下一张在右、上一张在左），
    /// 随当前图同量平移，两图始终相邻无间隙；拖动回 0 或方向翻转时重算/隐藏。
    /// 相邻图通常已由 prefetchAdjacent 暖过缓存，加载失败时该槽位留空（不比旧路径差）。
    private func updateNeighbor(forDragX dragX: CGFloat) {
        guard imageKeys.count > 1, scale == 1 else { hideNeighbor(); return }
        if dragX == 0 { hideNeighbor(); return }
        let direction = dragX < 0 ? 1 : -1
        // C1：已到已加载末尾、还有后续页时，往前没有相邻图可贴——
        // 不把回绕首张贴上来（新页到了才有下一张），当前图跟手即可。
        if direction == 1, currentIndex == imageKeys.count - 1, (hasMorePages || isRequestingMorePages) {
            hideNeighbor()
            return
        }
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

    /// C3 关场原处矩形：优先问调用方要当前下标那张的原处（网格格在
    /// 视口内才给得出，画面用 transform 和 opacity 缩回它）；提供方
    /// 存在但给不出（格不在视口内）时不回落旧原处，走淡出兜底。
    /// 没有提供方时沿用旧口径——只在当前图就是打开时那张时回原处。
    func dismissOriginFrame() -> CGRect? {
        if let provider = dismissOriginProvider {
            return provider(currentIndex)?.frame
        }
        guard currentIndex == initialIndex else { return nil }
        return originFrameInWindow
    }

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
        retryButton.isHidden = hidden ? true : !isFailed
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
        // ①-6：只改最底层遮罩的 opacity（0.92→0.276），现行视觉原样复现；
        // view 背景已是透明，不再改 backgroundColor。
        dismissScrimView.alpha = 0.92 * (1 - p * 0.7)
        counterLabel.alpha = 1 - p
        dotsStack.alpha = 1 - p
        closeButton.alpha = 1 - p
        // 审计 15 项第 11 项：底部“查看日记”钮同套渐隐，取消时由下
        // 方 resetDismissDragAppearance 一并恢复。
        viewEntryButton.alpha = 1 - p
    }

    private func resetDismissDragAppearance() {
        // ①-6：复位同步改遮罩 alpha 回 0.92（与 applyDismissDragProgress 同口径）。
        dismissScrimView.alpha = 0.92
        counterLabel.alpha = 1
        dotsStack.alpha = 1
        closeButton.alpha = 1
        viewEntryButton.alpha = 1
    }

    // MARK: - E-G12 淡入转场 + 回到原处关场

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerFadeAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyImageViewerReturnAnimator(viewer: self)
    }

    @objc private func retryTapped() {
        // 失败重试钮：与舞台点按失败分支共用 loadCurrent；仅失败态才重载。
        // 主动点按即表示抬手误触期已过，待挡的一次舞台点按不再生效（同 viewEntryButtonTapped 口径）。
        guard isFailed == true else { return }
        suppressNextStageTapAfterLive = false
        loadCurrent()
    }

    @objc private func stageTapped(_ sender: UITapGestureRecognizer) {
        // 实况长按抬手后的那一次误触点按：挡一次即清，后续主动点按不再受影响。
        if suppressNextStageTapAfterLive {
            suppressNextStageTapAfterLive = false
            return
        }
        let point = sender.location(in: view)
        // 重试钮自身 target/action 已处理：舞台手势在此放行，避免同一触摸
        // 再走失败分支重复调 loadCurrent（代次 +1、重复取图）；钮隐藏时
        // 该区域仍走原路径（失败分支／关闭），行为不变。
        if retryButton.isHidden == false && retryButton.frame.contains(point) {
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
            // 审计三轮 11：双击以点击位置为中心放大——点下的内容留在
            // 手指下（旧写法 tx/ty 清零，点下的细节会被推离手指）。
            // transform = 先缩放后平移（见 applyTransform），t' = C − P；
            // 再 clampPan 限幅，点在边缘附近时尽量靠近手指。
            scale = 2
            let point = sender.location(in: view)
            tx = view.bounds.midX - point.x
            ty = view.bounds.midY - point.y
            clampPan()
            applyTransform(animated: true)
        }
        // 审计 15 项第 8 项：双击放大后按需升级清晰度（缩回时内部守卫直接返回）。
        maybeUpgradeZoomResolution()
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
            pinchCenter0 = sender.location(in: view)
            pinchTx0 = tx
            pinchTy0 = ty
        } else if sender.state == .changed {
            pinchActive = true
            // 审计三轮 11：按双指中心同步补偿平移——以 .began 时双指
            // 中心下的内容为锚点，t' = P − C − (s'/s0)·(P0 − C − t0)；
            // 双指整体移动时图跟着走（pan 手势在捏合期早退，不冲突），
            // 再 clampPan 限幅。1～4 倍范围与旧口径一致。
            let newScale = max(1, min(4, pinchScale0 * sender.scale))
            let center = sender.location(in: view)
            let viewCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let ratio = newScale / pinchScale0
            tx = center.x - viewCenter.x - ratio * (pinchCenter0.x - viewCenter.x - pinchTx0)
            ty = center.y - viewCenter.y - ratio * (pinchCenter0.y - viewCenter.y - pinchTy0)
            scale = newScale
            clampPan()
            applyTransform(animated: false)
        } else if sender.state == .ended || sender.state == .cancelled {
            pinchActive = false
            if scale < 1.15 {
                // 捏合缩放松手：捏合速度是 scale/s（负值＝收拢、朝终态），
                // 沿回弹方向的分量除以缩放回落距离（scale − 1）归一化；
                // 慢捏／取消态速度≈0 时自然落 0。
                let springVelocity = springVelocityAlongReturn(velocityAlongReturn: -sender.velocity, distance: scale - 1)
                resetZoom(animated: true, initialSpringVelocity: springVelocity)
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
                // 审计 15 项第 8 项：捏合结束且仍放大时按需升级清晰度。
                maybeUpgradeZoomResolution()
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
                    dismissViewer()
                } else {
                    // 纵向弹回：纵向松手速度沿回弹方向的分量（ty > 0 时回弹
                    // 向上，分量取 −velocity.y）除以 |ty| 归一化；归一化前
                    // 先算，tx/ty 清零后距离就没了。慢拖速度≈0 即 0。
                    let returnSpeed = ty > 0 ? -velocity.y : velocity.y
                    let springVelocity = springVelocityAlongReturn(velocityAlongReturn: returnSpeed, distance: abs(ty))
                    hideNeighbor()
                    tx = 0
                    ty = 0
                    // 审计残留第 10 项：背景/chrome 复位原在动画块外同步调用，
                    // 瞬间跳回、图片却随后滑回，视觉错位；现经 additionalAnimations
                    // 与图片回弹放进同一弹簧块（0.26s／damping 0.7＋松手速度归一化，
                    // 减动效开时直切终态），阈值与弹簧参数均不动。
                    applyTransform(animated: true, initialSpringVelocity: springVelocity, additionalAnimations: { self.resetDismissDragAppearance() })
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
            // 取消态不翻页：只有正常松手（.ended）才进翻页判断，距离
            // （>60）与速度（>700）阈值不变；取消态落入下方 else 回弹
            // 分支，恢复当前位置、相邻图同步退回屏外再隐藏（与纵向
            // 分支“取消态一律弹回”一致）。
            if sender.state == .ended && imageKeys.count > 1 && (distancePages || flickPages) {
                // 位移达标按位移方向，快甩达标按末速度方向。
                let direction = distancePages ? (totalDx < 0 ? 1 : -1) : (velocity.x < 0 ? 1 : -1)
                navigate(direction: direction)
            } else {
                // 横向弹回：本分支要同步驱动相邻图，不能走 applyTransform
                // 单图路径，动画块内仍用同一统一弹簧 0.26s／damping 0.7；
                // 横向松手速度沿回弹方向的分量除以 |tx| 归一化，归一化前
                // 先算，tx/ty 清零后距离就没了。减动效分支原样直切终态。
                let returnSpeed = tx > 0 ? -velocity.x : velocity.x
                let springVelocity = springVelocityAlongReturn(velocityAlongReturn: returnSpeed, distance: abs(tx))
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
                    UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: springVelocity, options: .curveEaseOut, animations: {
                        self.applyTransform(animated: false)
                        if hasNeighbor {
                            self.neighborImageView.transform = CGAffineTransform(translationX: CGFloat(dir) * w, y: 0)
                        }
                    }, completion: { _ in self.hideNeighbor() })
                }
            }
        }
    }

    /// B5 回绕即时交接：目标图已在手（相邻槽／内存缓存）时直接换上，
    /// 与快路径 commit 同口径清失败态、跟进 loadingKey 与代次，
    /// 不再走 loadCurrent 重新异步取图（回包只是同一张图）。
    private func handoverWrapTarget(image: UIImage) {
        let targetKey = imageKeys[currentIndex]
        imageView.image = image
        displayedImageKey = targetKey
        showingInitialThumbnail = false
        isFailed = false
        retryButton.isHidden = true
        loadingKey = targetKey
        imageLoadGeneration += 1
        zoomHiResKey = nil
        zoomHiResWidth = 0
        hideNeighbor()
        updateLoadingSpinner()
        updateLiveOverlay()
        prefetchAdjacent()
    }

    /// B5：目标图内存缓存同步取图（只读内存，不读磁盘、不发网络）——
    /// 预取已暖过的全尺寸图（与 loadCurrent 同下采样宽）可直接交接。
    private func cachedWrapTargetImage(forKey key: String) -> UIImage? {
        guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else { return nil }
        return BearyImageLoader.shared.cachedImage(url: url, downsampleToWidth: pageWidthValue() * UIScreen.main.scale)
    }

    private func navigate(direction: Int) {
        if imageKeys.count <= 1 || isNavigating == true {
            return
        }
        let next = currentIndex + direction
        let wrapped = (next + imageKeys.count) % imageKeys.count
        // 审计 15 项第 2 项：延迟提交按目标 key 重新定位——commit 在翻页
        // 动画（BearyMotion.normal）结束时才执行，动画期间到期过滤可能
        // 缩短 imageKeys；旧下标 wrapped 可能指向另一张图或越界。
        let targetKey = imageKeys[wrapped]
        let isWrap = next < 0 || next >= imageKeys.count
        if isWrap, direction == 1 {
            // C1：还有后续页时不回绕——先请网格续拉，等新页到了再往前翻；
            // 确认末页（hasMorePages 为 false）后才走原有回绕。
            // navigate 只在 pan .ended 调，手指已离开，直接弹回当前图
            //（相邻槽里是回绕首张，不留；减动效时 resetZoom 直切终态）。
            // 只拦向前越过末尾：从首张往回翻不在此列（updateNeighbor
            // 同口径只拦向前，首张往回仍正常回绕到末张）。
            if hasMorePages || isRequestingMorePages {
                pendingAdvanceFromIndex = currentIndex
                if !isRequestingMorePages {
                    isRequestingMorePages = true
                    loadMoreFailed = false
                    onRequestMorePages?()
                }
                updateLoadMoreHint()
                resetZoom(animated: true)
                return
            }
        }
        // 审计三轮 05：回绕不再瞬时归位——旧路径先改下标/页码再加载，
        // 弱网下页码与“查看日记”已指新图、画面仍是旧图。现与普通翻页
        // 同走相邻槽位交接（拖动时 updateNeighbor 已按取模贴好回绕目标）：
        // 目标就绪走快速交接、未就绪走回落路径（先空＋加载圈，旧图不冒充
        // 新图）；页码与代次/loadingKey/isNavigating 都在 commit 里同步。
        // 动画与普通翻页同为沿滑动方向的一页滑入，不是长距离倒带。
        // B5 补：回绕目标在内存缓存里、相邻槽又没就绪时直接即时交接——
        // 缓存图与 loadCurrent 同下采样宽，只是同一张图，不等一次异步
        // 回包、不闪空＋加载圈；相邻槽已就绪时走下方快路径（带滑入动画）。
        if isWrap, !(neighborIndex == wrapped && neighborImageView.image != nil),
           let cached = cachedWrapTargetImage(forKey: imageKeys[wrapped]) {
            currentIndex = wrapped
            resetZoom(animated: false)
            updateCounter()
            handoverWrapTarget(image: cached)
            updateViewEntryAvailability()
            return
        }
        // 连续翻页：拖动时相邻图已贴在边上跟手（updateNeighbor），直接把两图
        // 一次动画到终位再交接——当前图出屏、相邻图正好居中，全程相邻无间隙。
        // 相邻图未就绪时走回落路径（目标槽位先空＋加载圈，见下方 110 注释）。
        if neighborIndex == wrapped && neighborImageView.image != nil {
            isNavigating = true
            updateViewEntryAvailability()
            let width = pageWidthValue()
            let offX: CGFloat = direction > 0 ? -width : width
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let commit: () -> Void = { [weak self] in
                guard let self = self else { return }
                // 目标已撤（动画期间 prune 掉）：放弃本次翻页，安全回退
                // 到当前图，不用旧下标读新数组。
                guard let resolvedIndex = self.imageKeys.firstIndex(of: targetKey) else {
                    self.abortStalePageTurn()
                    return
                }
                self.currentIndex = resolvedIndex
                self.scale = 1
                self.tx = 0
                self.ty = 0
                self.imageView.image = self.neighborImageView.image
                self.displayedImageKey = self.imageKeys[resolvedIndex]
                self.showingInitialThumbnail = false
                self.imageView.transform = .identity
                self.liveOverlay?.transform = .identity
                self.hideNeighbor()
                // 5-16（选 commit 内同步清态，不走 loadCurrent 重载闪图）：
                // 相邻图既已成功显示，上一张的失败态必须同步清除，否则
                // 成功图上仍压着“图片加载失败，重试”；loadingKey 同步
                // 跟进为当前图 key，后续 loadCurrent 回包代次校验才对得上。
                // 第 4 项：此处直接换图、未走 loadCurrent，代次也须同步 +1，
                // 否则换图前在途的旧升级回包仍可能凭旧代次蒙混过关。
                self.isFailed = false
                self.retryButton.isHidden = true
                self.loadingKey = self.imageKeys[resolvedIndex]
                self.imageLoadGeneration += 1
                // 快速通道交接：当前显示的是相邻槽位的基础图，高清标记须随图清零
                //（否则回 A 时标记仍在、再放大跳过升级）；加载圈同步重算，
                // 否则 A 加载中的圈与占位层会一直盖在已就绪的 B 图上。
                self.zoomHiResKey = nil
                self.zoomHiResWidth = 0
                self.updateLoadingSpinner()
                self.updateCounter()
                self.prefetchAdjacent()
                self.updateLiveOverlay()
                self.isNavigating = false
                self.updateViewEntryAvailability()
                self.maybeRequestMorePages()
            }
            if reduceMotion == true {
                commit()
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, animations: {
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
        updateViewEntryAvailability()
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
            // 目标已撤（动画期间 prune 掉）：放弃本次翻页，安全回退
            // 到当前图，不用旧下标读新数组。
            guard let resolvedIndex = self.imageKeys.firstIndex(of: targetKey) else {
                self.abortStalePageTurn()
                return
            }
            self.currentIndex = resolvedIndex
            self.scale = 1
            self.tx = 0
            self.ty = 0
            self.imageView.transform = .identity
            self.liveOverlay?.transform = .identity
            if let targetImage = self.neighborImageView.image {
                self.imageView.image = targetImage
                self.displayedImageKey = self.imageKeys[resolvedIndex]
                self.isFailed = false
                self.retryButton.isHidden = true
                self.loadingKey = self.imageKeys[resolvedIndex]
            } else {
                // 目标未到：先空 + 加载圈，loadCurrent 回包填图（不留旧图）。
                self.imageView.image = nil
                self.displayedImageKey = nil
            }
            self.showingInitialThumbnail = false
            self.hideNeighbor()
            self.updateCounter()
            self.loadCurrent()
            self.isNavigating = false
            self.updateViewEntryAvailability()
            self.maybeRequestMorePages()
        }
        if reduceMotion == true {
            commitFallback()
            return
        }
        UIView.animate(withDuration: BearyMotion.normal, animations: {
            self.tx = offX
            self.ty = 0
            self.applyTransform(animated: false)
            self.neighborImageView.transform = .identity
        }, completion: { _ in
            commitFallback()
        })
    }

    /// 审计 15 项第 2 项：翻页动画期间目标照片被撤时的安全回退——动画已把
    /// 当前图滑出、相邻图滑入，复位 transform 回到当前图、撤掉相邻槽、
    /// 重新加载当前下标（prune 若换了当前图，loadCurrent 会跟进新下标；
    /// 全部撤完时 prune 已关灯箱，loadCurrent 的空表守卫直接返回）。
    private func abortStalePageTurn() {
        scale = 1
        tx = 0
        ty = 0
        imageView.transform = .identity
        liveOverlay?.transform = .identity
        hideNeighbor()
        updateCounter()
        loadCurrent()
        isNavigating = false
        updateViewEntryAvailability()
        maybeRequestMorePages()
    }
}

/// 网页灯箱同款纯透明度转场：只做开场 200ms 淡入。
private final class BearyImageViewerFadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let duration = transitionDuration(using: transitionContext)
        guard let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        transitionContext.containerView.addSubview(toView)
        toView.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, options: presenting ? .curveEaseOut : .curveEaseIn, animations: {
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
        return 0.25
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
              let origin = viewer.dismissOriginFrame(),
              let start = viewer.dismissStartInfo() else {
            // 兜底：减动效、无图、无原处、翻页后关场——走 0.26s 淡出，
            // 但 toView 已在位，同样不闪。
            UIView.animate(withDuration: reduceMotion ? 0 : BearyMotion.normal, animations: {
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
        // 关场回原位走弹簧（规范 §6，第十轮收敛）：阻尼 0.7——原 0.85 防冲出原位
        // 口径作废，0.7 弹簧回弹有轻微超调、可能短暂冲出原位，需真机回归；
        // 时长 0.26s（motion.normal），目标矩形不动，回 targetRect。
        UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            fromView.alpha = 0
            tempView.frame = targetRect
        }, completion: { _ in
            tempView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}

import UIKit
import Lottie

/// Beary 表情 Lottie 播放封装。
///
/// 播放口径：先从 0 播到 op 一次，再从 loop_start 标记播到 loop_end 标记无限循环。
/// 循环终点是 loop_end 标记，不是 op，首次描线等一次性内容只在首播出现一次。
/// 兜底说明：loop_start 标记缺失时从 0 开始循环，loop_end 标记缺失时循环到 op。
/// 深浅版本按当前 traitCollection 选择，文件以平铺方式放在 Bundle.main 的 Resources 中，
/// 文件名为 key 加 json 后缀，深色版在 key 后加 dark 后缀。
/// 解析失败或取不到 JSON 时回退到 PNG 静态图，不抛错，不中断调用方布局。
/// 减动效开启时一律只显示循环段末帧（完成帧），不自动播放，play 调用同样只停在完成帧。
/// 完成帧取 CachedEmote.staticFrame：恒落在 [0, op) 半开区间内，永不等于 op（见该属性注释）。
/// 首次解析（LottieAnimation.filepath + markers 解码）不在视图创建调用链上同步做：
/// 未命中缓存时先挂 PNG 占位，后台线程解析、回主线程挂接；缓存命中仍同步挂接（只建视图，不解析）。
/// 颜色与玻璃效果均不由本文件决定，颜色走调用方约束与 BearyColors。
public final class BearyEmoteView: UIView {

    public let emoteKey: String

    /// 非表情 Lottie 的回退图覆盖（天气选择器用）：设置后 showFallback 用它而非表情包 lookup。
    /// 须在 loadEmote 之前生效，故经带 fallbackImage 的指定构造器传入；表情调用方不传，行为不变。
    public var fallbackImageOverride: UIImage?

    private var isPlaying: Bool
    /// 是否正在播放（供 chip 复用时判断：同 key 已在播时不再重播，避免每次
    /// 渲染都从 0 帧重画描线；停播态仍需 play() 恢复，见 BearyEmoteChipView.render）。
    var isPlayingNow: Bool { isPlaying }
    /// 静态帧持有态：showStaticFrame() 置真，play()/stop() 清掉；attach 时若为真，
    /// 未播放的视图停在循环段末帧而非 0 帧（0 帧是首播描线起点，未完成态）。
    private var heldStaticFrame: Bool = false
    private var playbackGeneration: Int = 0
    /// ①专用加载代次：只在 teardownContent（即每次 loadEmote / 主题切换）时递增，
    /// stop()/startPlayback() 不动它——后台解析完成时凭它判断视图是否仍在等同一批内容。
    /// 用 playbackGeneration 会误杀：stop() 也递增它，加载中 stop 后再 play 将永远等不到挂接。
    private var loadGeneration: Int = 0
    private var animationView: LottieAnimationView?
    private var fallbackImageView: UIImageView?
    private var currentEmote: CachedEmote?

    private struct CachedEmote {
        let animation: LottieAnimation
        let loopStart: CGFloat
        let loopEnd: CGFloat
        let endFrame: CGFloat
        /// 对应 JSON 文件字节数：解析后模型实际占用更大，故只作缓存预算的代理值，
        /// 预算因此取保守值（见 cacheByteBudget）。
        let estimatedBytes: Int
        /// 减动效静态帧：必须落在 [0, op) 半开区间内，不得等于 op。
        /// 审计 12 项核实：80 只 loop_end 均 == op，属边界落点；lottie-ios 对
        /// currentFrame == op 渲染末帧还是空白，JSON 无法证明，故静态帧取
        /// min(loopEnd, endFrame - 1)：loopEnd 在区间内时原值不动，仅把 == op 的
        /// 边界情形退一帧。JSON 只能证明落点，渲染结果仍待真机复验。
        var staticFrame: CGFloat {
            guard endFrame > 1 else { return 0 }
            return min(loopEnd, endFrame - 1)
        }
    }

    /// 仅解码 Bodymovin 顶层 markers 数组（cm=标记名、tm=帧号）。
    /// 其余字段不建模，JSONDecoder 会跳过未知键。
    private struct EmoteMarkersFile: Decodable {
        struct Marker: Decodable {
            let cm: String
            let tm: CGFloat
        }
        let markers: [Marker]?
    }

    private static var cache: [String: CachedEmote] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 16
    /// 字节双预算：以 JSON 文件大小为代理估算占用（解析后模型实际更大，故取保守值；
    /// 全量 80 只约 75.9MB，单只 speechless 约 19.6MB——预算须小于总量且容得下常用组合）。
    private static let cacheByteBudget = 48 * 1024 * 1024
    private static var cacheBytes: Int = 0

    /// ①后台解析队列（userInitiated）：只做 Lottie 解析 + markers 解码，不建 UIView。
    /// 与预热队列分开，避免预热排队挡住当前视图急需的解析。
    private static let parseQueue = DispatchQueue(label: "com.beary.emote-parse", qos: .userInitiated)
    /// ②预热队列（utility，串行）：预热解析走这里，优先级低于按需解析，不抢主线程。
    private static let prewarmQueue = DispatchQueue(label: "com.beary.emote-prewarm", qos: .utility)

    /// ②预热集合（只预热当前 trait 的一个版本，不同时预热深浅两版，避免占满 16 条 LRU）：
    /// agree——编辑器心情顺序第 1 位、最常用确认回应，且仅 28KB，几乎零成本；
    /// happy / love——通用高频正向回应，且各约 1.4MB，是小文件里最值得提前解析的两只；
    /// hug / applause / wave——高频社交回应（安慰/喝彩/打招呼），各仅约 30–60KB，成本可忽略。
    /// 刻意不预热 shy（约 7.2MB）与 speechless（约 19.6MB）：两者合计占预热队列绝大部分时间，
    /// 且预热会把它们顶进 LRU 挤掉常用项；它们改为按需后台解析 + PNG 占位更划算。
    /// 下一候选是 cheer（约 1.0MB），如需扩容先加它，不要先加两只巨文件。
    private static let prewarmEmoteKeys = ["agree", "happy", "love", "hug", "applause", "wave"]
    /// 每种外观（light/dark）只预热一次；复用 cacheLock 保护。
    private static var prewarmScheduled: Set<String> = []

    /// G24：失败 key 的负缓存（key → 过期时间，TTL 300 秒）：文件缺失/
    /// 解析失败不再每次重复读盘；过期后自动失效、可重试。
    private static var negativeCache: [String: Date] = [:]
    private static let negativeCacheTTL: TimeInterval = 300

    /// M23：存活播放器弱引用登记（减动效开启时对全部存活播放器 stop 回循环段末帧）。
    private static var livePlayers = NSHashTable<BearyEmoteView>.weakObjects()
    private static var reduceMotionObserverInstalled = false
    /// M23：减动效通知观察者 token（App 生命周期内常驻，不移除）。
    private static var reduceMotionObserver: NSObjectProtocol?
    /// 2026-10-29 第 24 项：前台恢复观察者 token（App 生命周期内常驻，不移除，
    /// 与减动效观察者同模式）；后台切回前台时对全部存活播放器调 resumeAfterForeground。
    private static var foregroundResumeObserverInstalled = false
    private static var foregroundResumeObserver: NSObjectProtocol?
    /// 内存警告时清解析缓存（只清缓存字典，不停正在播的视图：视图自持 CachedEmote，
    /// 下次加载重新解析；清掉后大文件不再常驻内存）。
    private static var memoryWarningObserver: NSObjectProtocol?
    private static var memoryWarningObserverInstalled = false

    public convenience init(key: String, animated: Bool) {
        self.init(key: key, animated: animated, fallbackImage: nil)
    }

    /// E4 懒加载：deferred=true 时构造不解析 Lottie、不触发预热，只挂静态回退图
    /// （心情为表情 PNG、天气为调用方传的 wx 静态图）；首次用到时调用方调
    /// ensureLoaded() 才真正加载，播放意图（play 前已记的 isPlaying / heldStaticFrame）
    /// 在挂接时兑现。默认 false，旧调用点行为不变。
    private var isDeferredLoad = false
    private var loadStarted = false

    // fallbackImage 补默认值 nil：旧 2 参调用走便捷构造器不变；编辑器心情条
    // 可直接以 (key:animated:deferred:) 调用，省去显式传 nil。
    public init(key: String, animated: Bool, fallbackImage: UIImage? = nil, deferred: Bool = false) {
        self.emoteKey = key
        self.isPlaying = animated && UIAccessibility.isReduceMotionEnabled == false
        super.init(frame: .zero)
        self.fallbackImageOverride = fallbackImage
        backgroundColor = .clear
        clipsToBounds = false
        Self.registerLivePlayer(self)
        Self.installReduceMotionObserver()
        Self.installForegroundResumeObserver()
        Self.installMemoryWarningObserver()
        if deferred {
            self.isDeferredLoad = true
            // 只挂静态回退，不解析、不预热；layoutSubviews 会把回退图铺满 bounds。
            self.showFallback(dark: self.isDark)
        } else {
            loadEmote()
            Self.schedulePrewarm(dark: self.isDark)
        }
    }

    /// E4：触发延迟加载（幂等；已加载/已触发时为空操作）。调用方在选择条
    /// 点开时调一次即可，后续 play/showStaticFrame 按原口径走已加载的动画。
    public func ensureLoaded() {
        guard isDeferredLoad, !loadStarted else { return }
        loadStarted = true
        loadEmote()
    }

    deinit {
        Self.unregisterLivePlayer(self)
    }

    private static func registerLivePlayer(_ player: BearyEmoteView) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        livePlayers.add(player)
    }

    private static func unregisterLivePlayer(_ player: BearyEmoteView) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        livePlayers.remove(player)
    }

    /// M23：监听减动效变化通知（只装一次）；开启时对所有存活播放器
    /// stop() 回循环段末帧（减动效下 stop 显示完成帧，见 stop）。关闭时不自动重播（等调用方下次 play）。
    private static func installReduceMotionObserver() {
        cacheLock.lock()
        let installed = reduceMotionObserverInstalled
        if !installed {
            reduceMotionObserverInstalled = true
        }
        cacheLock.unlock()
        guard !installed else { return }
        reduceMotionObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { _ in
            guard UIAccessibility.isReduceMotionEnabled else { return }
            cacheLock.lock()
            let players = livePlayers.allObjects
            cacheLock.unlock()
            for player in players {
                player.stop()
            }
        }
    }

    /// 2026-10-29 第 24 项：前台恢复观察者（只装一次，常驻不移除；与减动效
    /// 观察者同模式）。根因：Lottie 的 playOnce→循环接力在 App 后台挂起时
    /// 可能被打断——completion 以 finished=false 回调即不再进循环，isPlaying
    /// 仍为真但动画已死，切回前台后全部表情停住。恢复时只对 isPlaying 为真
    /// 且仍在窗口内的播放器续播（resumeAfterForeground 内再守门），各面
    /// （Feed/时间线/详情/个人页/编辑器心情条等）共用此一处逻辑，不各处另造。
    private static func installForegroundResumeObserver() {
        cacheLock.lock()
        let installed = foregroundResumeObserverInstalled
        if !installed {
            foregroundResumeObserverInstalled = true
        }
        cacheLock.unlock()
        guard !installed else { return }
        foregroundResumeObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            cacheLock.lock()
            let players = livePlayers.allObjects
            cacheLock.unlock()
            for player in players {
                player.resumeAfterForeground()
            }
        }
    }

    /// 前台恢复：后台挂起可能打断 playOnce→循环的接力（见上），isPlaying 仍为真
    /// 但动画已死。本方法从当前帧续播到 op 再进循环，不回 0 帧重画描线；
    /// 减动效下不恢复播放（仍停完成帧，口径不变）；冻结静态帧
    /// （heldStaticFrame，如心情条未选中项旧口径）的与已离窗的不动。
    func resumeAfterForeground() {
        guard isPlaying, window != nil else { return }
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        guard let view = animationView, let cached = currentEmote else {
            // 仍在后台解析或 PNG 占位：只保住起播意图，挂接时兑现，不丢。
            if fallbackImageView != nil { isPlaying = true }
            return
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        let fromFrame = view.currentFrame
        view.play(fromFrame: fromFrame, toFrame: cached.endFrame, loopMode: .playOnce) { [weak self] finished in
            guard let self = self else { return }
            guard finished else { return }
            guard self.playbackGeneration == generation else { return }
            guard self.isPlaying else { return }
            guard UIAccessibility.isReduceMotionEnabled == false else { return }
            self.animationView?.play(fromFrame: cached.loopStart, toFrame: cached.loopEnd, loopMode: .loop) { _ in }
        }
    }

    /// 内存警告观察者（只装一次，常驻不移除）：收到警告即清空解析缓存与字节计数，
    /// 正在播的视图不受影响（自持 CachedEmote），下次加载重新解析。
    private static func installMemoryWarningObserver() {
        cacheLock.lock()
        let installed = memoryWarningObserverInstalled
        if !installed {
            memoryWarningObserverInstalled = true
        }
        cacheLock.unlock()
        guard !installed else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            cacheLock.lock()
            cache.removeAll()
            cacheOrder.removeAll()
            cacheBytes = 0
            cacheLock.unlock()
        }
    }

    /// 离屏停播：cell 滚出可视区会被 tableView 移出层级（window 变 nil），此时停播，
    /// 避免不可见 cell 的动画继续消耗；切 tab 只改 isHidden 不离窗，故切页停播不在此
    /// 覆盖（需控制器层钩子，见批报告）。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        animationView?.frame = bounds
        fallbackImageView?.frame = bounds
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard let previous = previousTraitCollection else { return }
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        // E4：延迟加载尚未触发时，深浅切换只换静态回退图，不因此提前解析。
        if isDeferredLoad && !loadStarted {
            fallbackImageView?.removeFromSuperview()
            fallbackImageView = nil
            showFallback(dark: self.isDark)
            return
        }
        let wasPlaying = isPlaying
        teardownContent()
        isPlaying = wasPlaying
        loadEmote()
        Self.schedulePrewarm(dark: self.isDark)
    }

    /// 开始播放：先播 0 到 op 一次，完成后进入 loop_start 到 loop_end 的无限循环。
    /// 减动效开启时只显示循环段末帧（完成帧）。
    /// 后台加载中调用 play 时视图上还是 PNG 占位：只记下起播意图就返回，
    /// 挂接时 attachCachedEmote 见 isPlaying 为真即起播，不丢这次 play；
    /// 永久回退（解析失败）时该意图无动画可播，无害。
    public func play() {
        heldStaticFrame = false
        guard fallbackImageView == nil else {
            isPlaying = UIAccessibility.isReduceMotionEnabled == false
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            isPlaying = false
            if let view = animationView, let cached = currentEmote {
                view.currentFrame = cached.staticFrame
            }
            return
        }
        isPlaying = true
        startPlayback()
    }

    /// 停止播放：停在当前帧，不回 0 帧。资产口径：首播是 0→op 的描线过程，
    /// 0 帧是描线未完成态（线未画完），停回 0 帧会把已画完的熊退回未完成态；
    /// 当前帧才是用户最后看到的完成/进行态。减动效开启时停在循环段末帧
    /// （完成帧），这也是减动效通知观察者调用本方法时应有的静态态。
    /// 回退静态图时为空操作。
    public func stop() {
        isPlaying = false
        heldStaticFrame = false
        playbackGeneration += 1
        if let view = animationView {
            view.stop()
            if UIAccessibility.isReduceMotionEnabled, let cached = currentEmote {
                view.currentFrame = cached.staticFrame
            }
        }
    }

    /// 冻结静态帧：不播放，只停在循环段末帧（完成帧）。未加载完成时先记
    /// heldStaticFrame，后台挂接时 attachCachedEmote 按此置静态帧，不回 0 帧；
    /// 已是 PNG 回退时本身就是静态图，无操作。供心情面板“只播选中、其余
    /// 冻结”用，与 stop()（停在当前帧）不同。
    public func showStaticFrame() {
        isPlaying = false
        heldStaticFrame = true
        playbackGeneration += 1
        if let view = animationView, let cached = currentEmote {
            view.stop()
            view.currentFrame = cached.staticFrame
        }
    }

    private var isDark: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private func loadEmote() {
        teardownContent()
        let dark = isDark
        let cacheKey = Self.cacheKey(for: emoteKey, dark: dark)
        // 缓存命中：只建 LottieAnimationView，不做任何解析，仍可同步挂接。
        if let cached = Self.cachedHit(for: cacheKey) {
            self.attachCachedEmote(cached)
            return
        }
        // 未命中：先挂 PNG 占位（布局不空、不卡主线程），再决定是否后台解析。
        self.showFallback(dark: dark)
        // G24 负缓存期内（文件缺失/解析失败 300 秒内）：不重复读盘、不派发后台解析。
        if Self.isNegativeCached(cacheKey) {
            return
        }
        // ①首次解析走后台：teardown 之后取到的代次，completion 回主线程时凭它验旧。
        let generation = self.loadGeneration
        let key = self.emoteKey
        Self.loadEmoteInBackground(for: key, dark: dark) { [weak self] loaded in
            guard let self = self else { return }
            guard self.loadGeneration == generation else { return }
            guard self.isDark == dark else { return }
            guard self.animationView == nil else { return }
            guard let loaded = loaded else { return }
            self.attachCachedEmote(loaded)
        }
    }

    /// 主线程专用：把已解析好的缓存项挂成 Lottie 视图（建视图、定初始帧/起播）。
    /// 调用方保证在主线程：loadEmote 的缓存命中分支、后台解析的 completion（已回主线程）。
    /// 不调 teardownContent——它会递增 loadGeneration，挂接完成不应再动代次；
    /// 这里只摘掉 PNG 占位。
    private func attachCachedEmote(_ cached: CachedEmote) {
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        currentEmote = cached
        let view = LottieAnimationView(animation: cached.animation)
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        animationView = view
        if UIAccessibility.isReduceMotionEnabled {
            // ③减动效完成帧：cached.staticFrame（即 loop_end 标记，但恒退到 [0, op) 内，
            // 见 staticFrame 注释；标记缺失时 loadEmoteFromBundle 已兜底为 op，
            // 零长段已兜底为整段末帧，再由 staticFrame 退一帧）。
            view.currentFrame = cached.staticFrame
        } else if isPlaying {
            startPlayback()
        } else if heldStaticFrame {
            view.currentFrame = cached.staticFrame
        } else {
            // 扫荡 B：不播放的静态表情同样停完成帧，不回 0 帧。
            // 0 帧是描线未完成态（见 stop() 注释）：animated:false 的心情位
            // （详情/卡片/草稿心情 chip、引导页初始态）从不调 play()，旧口径
            // 在 Lottie 挂接后把已完整的 PNG 占位换成未画完的 0 帧，全程残缺；
            // 完成帧与 PNG 占位一致，挂接无闪变。减动效分支本就走完成帧，
            // 本分支与之对齐；heldStaticFrame 分支保留，语义不变。
            view.currentFrame = cached.staticFrame
        }
    }

    /// PNG 占位：未命中缓存时的即时静态内容，也是解析失败后的最终回退。
    private func showFallback(dark: Bool) {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = false
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.image = fallbackImageOverride ?? BearyEmoteImages.image(for: emoteKey, dark: dark)
        addSubview(imageView)
        fallbackImageView = imageView
    }

    /// ①后台解析入口（静态方法，不持有任何视图）：parseQueue 上同步解析并写缓存，
    /// 再回主线程调 completion。视图是否已释放、是否已换批内容，由调用方在 completion
    /// 里用 [weak self] + loadGeneration 验——本方法本身不判断视图存活。
    private static func loadEmoteInBackground(for key: String, dark: Bool, completion: @escaping (CachedEmote?) -> Void) {
        parseQueue.async {
            let loaded = Self.cachedEmoteEntry(for: key, dark: dark)
            DispatchQueue.main.async {
                completion(loaded)
            }
        }
    }

    /// ②预热入口（供调用方在启动/首屏出现后显式调用；首个 BearyEmoteView 创建时也会自动调度一次，
    /// 同一外观只调度一次，重复调用为空操作）。只解析当前外观版本，不同时预热深浅两版。
    public static func prewarmCommonEmotes(dark: Bool) {
        Self.schedulePrewarm(dark: dark)
    }

    /// ②预热调度：先占位标记防重复，再在 utility 队列上延迟 1 秒顺序解析。
    /// 延迟是给按需解析让路：首个视图自己的解析走 userInitiated 队列先跑，1 秒内大概率已写缓存，
    /// 预热循环里 cachedEmoteEntry 命中缓存即跳过，不重复解析同一只。
    private static func schedulePrewarm(dark: Bool) {
        let variant = dark ? "dark" : "light"
        cacheLock.lock()
        let already = prewarmScheduled.contains(variant)
        if !already {
            prewarmScheduled.insert(variant)
        }
        cacheLock.unlock()
        guard !already else { return }
        prewarmQueue.asyncAfter(deadline: .now() + 1.0) {
            for key in Self.prewarmEmoteKeys {
                _ = Self.cachedEmoteEntry(for: key, dark: dark)
            }
        }
    }

    private func teardownContent() {
        playbackGeneration += 1
        loadGeneration += 1
        animationView?.removeFromSuperview()
        animationView = nil
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        currentEmote = nil
    }

    private func startPlayback() {
        guard let view = animationView, let cached = currentEmote else { return }
        if UIAccessibility.isReduceMotionEnabled {
            view.currentFrame = cached.staticFrame
            return
        }
        playbackGeneration += 1
        let generation = playbackGeneration
        view.play(fromFrame: 0, toFrame: cached.endFrame, loopMode: .playOnce) { [weak self] finished in
            guard let self = self else { return }
            guard finished else { return }
            guard self.playbackGeneration == generation else { return }
            guard self.isPlaying else { return }
            guard UIAccessibility.isReduceMotionEnabled == false else { return }
            self.animationView?.play(fromFrame: cached.loopStart, toFrame: cached.loopEnd, loopMode: .loop) { _ in }
        }
    }

    private static func cacheKey(for key: String, dark: Bool) -> String {
        dark ? "\(key)#dark" : "\(key)#light"
    }

    private static func cachedEmoteEntry(for key: String, dark: Bool) -> CachedEmote? {
        let cacheKey = Self.cacheKey(for: key, dark: dark)
        if isNegativeCached(cacheKey) {
            return nil
        }
        if let hit = cachedHit(for: cacheKey) {
            return hit
        }
        guard let loaded = loadEmoteFromBundle(for: key, dark: dark) else {
            storeNegative(cacheKey)
            return nil
        }
        store(loaded, for: cacheKey)
        return loaded
    }

    /// G24：负缓存命中判断（过期条目顺手清除，过期后可重试）。
    private static func isNegativeCached(_ cacheKey: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let expiry = negativeCache[cacheKey] else { return false }
        if expiry > Date() {
            return true
        }
        negativeCache.removeValue(forKey: cacheKey)
        return false
    }

    private static func storeNegative(_ cacheKey: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        negativeCache[cacheKey] = Date().addingTimeInterval(negativeCacheTTL)
    }

    private static func cachedHit(for cacheKey: String) -> CachedEmote? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let hit = cache[cacheKey] else { return nil }
        cacheOrder.removeAll(where: { $0 == cacheKey })
        cacheOrder.append(cacheKey)
        return hit
    }

    private static func store(_ value: CachedEmote, for cacheKey: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let old = cache[cacheKey] {
            cacheBytes -= old.estimatedBytes
        }
        cache[cacheKey] = value
        cacheBytes += value.estimatedBytes
        cacheOrder.removeAll(where: { $0 == cacheKey })
        cacheOrder.append(cacheKey)
        // 数量 + 字节双预算：超任一预算即淘汰，淘汰顺序按占用从大到小
        // （大文件先淘汰）；新存入的条目最后才动，避免刚存入即被逐出导致
        // 大文件反复解析；只剩新条目时即使仍超预算也保留，不做空缓存。
        while (cacheOrder.count > cacheLimit || cacheBytes > cacheByteBudget) && cacheOrder.count > 1 {
            let victim = cacheOrder.filter({ $0 != cacheKey }).max(by: { (cache[$0]?.estimatedBytes ?? 0) < (cache[$1]?.estimatedBytes ?? 0) })
            guard let key = victim else { break }
            if let removed = cache.removeValue(forKey: key) {
                cacheBytes -= removed.estimatedBytes
            }
            cacheOrder.removeAll(where: { $0 == key })
        }
        if cacheBytes < 0 {
            cacheBytes = 0
        }
    }

    private static func loadEmoteFromBundle(for key: String, dark: Bool) -> CachedEmote? {
        let name = dark ? "\(key)_dark" : key
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
            NSLog("[BearyEmote] load failed key=%@ dark=%@ reason=missing-json", key, dark ? "dark" : "light")
            return nil
        }
        // G24：op 取自 LottieAnimation.filepath 解析后的模型（endFrame）。
        // 循环标记取自 JSON 原文件：所钉 Lottie 4.6.1 里模型上的 markers 是
        // internal、marker(named:) 也不存在（CI #44 实证），故直接解码
        // markers 数组（cm=名、tm=帧号，与旧 Marker.time 同值），
        // 首帧缓存后不再重复读盘。
        guard let animation = LottieAnimation.filepath(url.path) else {
            NSLog("[BearyEmote] load failed key=%@ dark=%@ reason=animation-parse-failed", key, dark ? "dark" : "light")
            return nil
        }
        // 缓存预算代理值：JSON 文件字节数（解析后模型实际更大，预算取保守值）。
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let endFrame = CGFloat(animation.endFrame)
        guard endFrame > 0 else {
            NSLog("[BearyEmote] load failed key=%@ dark=%@ reason=nonpositive-endFrame endFrame=%f", key, dark ? "dark" : "light", endFrame)
            return nil
        }
        // markers 缺失时的兜底：loop_start 缺失则从 0 循环，loop_end 缺失则循环到 op。
        var loopStart: CGFloat = 0
        var loopEnd: CGFloat = endFrame
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(EmoteMarkersFile.self, from: data),
           let markers = decoded.markers {
            if let startMarker = markers.first(where: { $0.cm == "loop_start" }) {
                loopStart = startMarker.tm
            }
            if let endMarker = markers.first(where: { $0.cm == "loop_end" }) {
                loopEnd = endMarker.tm
            }
        }
        if loopStart < 0 {
            loopStart = 0
        }
        if loopStart > endFrame {
            loopStart = endFrame
        }
        if loopEnd < loopStart {
            loopEnd = endFrame
        }
        if loopEnd > endFrame {
            loopEnd = endFrame
        }
        // G25：零长循环段（loopEnd <= loopStart，如两者同为 endFrame）不得
        // 以 .loop 播放——退化为循环整段 0…endFrame，并打日志。
        if loopEnd <= loopStart {
            NSLog("[BearyEmote] degenerate loop key=%@ dark=%@ loopStart=%f loopEnd=%f endFrame=%f; falling back to full-segment loop", key, dark ? "dark" : "light", loopStart, loopEnd, endFrame)
            loopStart = 0
            loopEnd = endFrame
        }
        return CachedEmote(animation: animation, loopStart: loopStart, loopEnd: loopEnd, endFrame: endFrame, estimatedBytes: fileSize)
    }
}

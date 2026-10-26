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
/// 减动效开启时一律只显示首帧，不自动播放，play 调用同样只停在首帧。
/// 颜色与玻璃效果均不由本文件决定，颜色走调用方约束与 BearyColors。
public final class BearyEmoteView: UIView {

    public let emoteKey: String

    private var isPlaying: Bool
    private var playbackGeneration: Int = 0
    private var animationView: LottieAnimationView?
    private var fallbackImageView: UIImageView?
    private var currentEmote: CachedEmote?

    private struct CachedEmote {
        let animation: LottieAnimation
        let loopStart: CGFloat
        let loopEnd: CGFloat
        let endFrame: CGFloat
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

    /// G24：失败 key 的负缓存（key → 过期时间，TTL 300 秒）：文件缺失/
    /// 解析失败不再每次重复读盘；过期后自动失效、可重试。
    private static var negativeCache: [String: Date] = [:]
    private static let negativeCacheTTL: TimeInterval = 300

    /// M23：存活播放器弱引用登记（减动效开启时对全部存活播放器 stop 回首帧）。
    private static var livePlayers = NSHashTable<BearyEmoteView>.weakObjects()
    private static var reduceMotionObserverInstalled = false
    /// M23：减动效通知观察者 token（App 生命周期内常驻，不移除）。
    private static var reduceMotionObserver: NSObjectProtocol?

    public init(key: String, animated: Bool) {
        self.emoteKey = key
        self.isPlaying = animated && UIAccessibility.isReduceMotionEnabled == false
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        Self.registerLivePlayer(self)
        Self.installReduceMotionObserver()
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
    /// stop() 回首帧。关闭时不自动重播（等调用方下次 play）。
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
        let wasPlaying = isPlaying
        teardownContent()
        isPlaying = wasPlaying
        loadEmote()
    }

    /// 开始播放：先播 0 到 op 一次，完成后进入 loop_start 到 loop_end 的无限循环。
    /// 回退静态图时为空操作，减动效开启时只显示首帧。
    public func play() {
        guard fallbackImageView == nil else { return }
        if UIAccessibility.isReduceMotionEnabled {
            isPlaying = false
            animationView?.currentFrame = 0
            return
        }
        isPlaying = true
        startPlayback()
    }

    /// 停止播放并回到首帧。回退静态图时为空操作。
    public func stop() {
        isPlaying = false
        playbackGeneration += 1
        if let view = animationView {
            view.stop()
            view.currentFrame = 0
        }
    }

    private var isDark: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private func loadEmote() {
        teardownContent()
        let dark = isDark
        if let cached = Self.cachedEmoteEntry(for: emoteKey, dark: dark) {
            currentEmote = cached
            let view = LottieAnimationView(animation: cached.animation)
            view.contentMode = .scaleAspectFit
            view.backgroundColor = .clear
            view.clipsToBounds = false
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
            animationView = view
            if isPlaying && UIAccessibility.isReduceMotionEnabled == false {
                startPlayback()
            } else {
                view.currentFrame = 0
            }
            return
        }
        currentEmote = nil
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = false
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.image = BearyEmoteImages.image(for: emoteKey, dark: dark)
        addSubview(imageView)
        fallbackImageView = imageView
    }

    private func teardownContent() {
        playbackGeneration += 1
        animationView?.removeFromSuperview()
        animationView = nil
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        currentEmote = nil
    }

    private func startPlayback() {
        guard let view = animationView, let cached = currentEmote else { return }
        if UIAccessibility.isReduceMotionEnabled {
            view.currentFrame = 0
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

    private static func cachedEmoteEntry(for key: String, dark: Bool) -> CachedEmote? {
        let cacheKey = dark ? "\(key)#dark" : "\(key)#light"
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
        cache[cacheKey] = value
        cacheOrder.removeAll(where: { $0 == cacheKey })
        cacheOrder.append(cacheKey)
        while cacheOrder.count > cacheLimit {
            guard let oldest = cacheOrder.first else { break }
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
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
        return CachedEmote(animation: animation, loopStart: loopStart, loopEnd: loopEnd, endFrame: endFrame)
    }
}

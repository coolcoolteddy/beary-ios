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

    private static var cache: [String: CachedEmote] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 16

    public init(key: String, animated: Bool) {
        self.emoteKey = key
        self.isPlaying = animated && UIAccessibility.isReduceMotionEnabled == false
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        loadEmote()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        animationView?.frame = bounds
        fallbackImageView?.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
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
        if let hit = cachedHit(for: cacheKey) {
            return hit
        }
        guard let loaded = loadEmoteFromBundle(for: key, dark: dark) else { return nil }
        store(loaded, for: cacheKey)
        return loaded
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
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let animation = LottieAnimation.filepath(url.path) else { return nil }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opValue = document["op"] as? NSNumber else { return nil }
        let endFrame = CGFloat(opValue.doubleValue)
        guard endFrame > 0 else { return nil }
        // markers 缺失时的兜底：loop_start 缺失则从 0 循环，loop_end 缺失则循环到 op。
        var loopStart: CGFloat = 0
        var loopEnd: CGFloat = endFrame
        if let markers = document["markers"] as? [[String: Any]] {
            if let startMarker = markers.first(where: { ($0["cm"] as? String) == "loop_start" }),
               let startValue = startMarker["tm"] as? NSNumber {
                loopStart = CGFloat(startValue.doubleValue)
            }
            if let endMarker = markers.first(where: { ($0["cm"] as? String) == "loop_end" }),
               let endValue = endMarker["tm"] as? NSNumber {
                loopEnd = CGFloat(endValue.doubleValue)
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
        return CachedEmote(animation: animation, loopStart: loopStart, loopEnd: loopEnd, endFrame: endFrame)
    }
}

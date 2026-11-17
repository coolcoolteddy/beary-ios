import UIKit
import Lottie

/// 皇冠动态标：卡片作者行（19pt）与个人页名字旁（23pt）共用。
///
/// 动画源：LottieCrown/crown.json（浅色黑线）与 crown_dark.json（深色白线），
/// 32×32、30fps、60 帧 2 秒循环；星光贴在皇冠旁边（close 版）。
/// 宝石橙 #FF9500 已在 JSON 内着色，视图不做任何模板染色（tint 会吃掉宝石色）；
/// 回退静态图亦走 crown.imageset 原图渲染（不走 alwaysTemplate）。
///
/// 未复用 BearyEmoteView 的原因：其减动效静态帧取循环段末帧（op-1），而皇冠
/// 规矩要求减动效时停在第 0 帧（即静态皇冠）；且其回退 lookup 不识 crown key。
/// 动画加载失败 → 静态皇冠图；两者皆无 → hasCrown=false，调用方隐藏、不留空位。
/// 尺寸由调用方约束（19/23pt），内部动画与回退图均铺满容器、scaleAspectFit。
/// 文件仅 7KB，初始化时同步解析（不走 BearyEmoteView 的后台解析那套）。
public final class BearyCrownView: UIView {

    /// 皇冠是否可用（动画或静态图任一在位）。调用方以此代替旧的 image == nil 守卫。
    public private(set) var hasCrown = false

    private var animationView: LottieAnimationView?
    private var fallbackImageView: UIImageView?
    private var reduceMotionObserver: NSObjectProtocol?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let observer = reduceMotionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 显示时调用：减动效停 0 帧，否则从 0 帧起循环播放。
    public func start() {
        applyPlayback()
    }

    /// 隐藏 / 复用时调用：停播（不拆视图，下次 start 从 0 帧重播同一动画）。
    public func stop() {
        animationView?.stop()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        load()
        applyPlayback()
    }

    private func setup() {
        load()
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPlayback()
        }
    }

    private func load() {
        animationView?.removeFromSuperview()
        animationView = nil
        fallbackImageView?.removeFromSuperview()
        fallbackImageView = nil
        hasCrown = false
        if let animation = currentAnimation() {
            let view = LottieAnimationView(animation: animation)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.contentMode = .scaleAspectFit
            view.loopMode = .loop
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            animationView = view
            hasCrown = true
        } else if let image = UIImage(named: "crown") {
            let view = UIImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.contentMode = .scaleAspectFit
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            fallbackImageView = view
            hasCrown = true
        }
    }

    private func applyPlayback() {
        guard let view = animationView else { return }
        if UIAccessibility.isReduceMotionEnabled {
            view.stop()
            view.currentFrame = 0
        } else if !isHidden {
            let endFrame = view.animation?.endFrame ?? 60
            view.play(fromFrame: 0, toFrame: endFrame, loopMode: .loop, completion: nil)
        } else {
            view.stop()
        }
    }

    private func currentAnimation() -> LottieAnimation? {
        let dark = traitCollection.userInterfaceStyle == .dark
        let name = dark ? "crown_dark" : "crown"
        guard let path = Bundle.main.path(forResource: name, ofType: "json") else { return nil }
        return LottieAnimation.filepath(path)
    }
}

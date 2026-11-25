import UIKit

/// 截屏 logo 容器（Threads 同款做法，见 Bluesky GrowthHack.tsx 与
/// expo-privacy-sensitive 的 iOS 实现）：内容画进 isSecureTextEntry 的
/// UITextField 内部容器图层，底下垫一张官方 logo。盖住 logo 的不是内容
/// 本身，而是密码框容器这条不透明的条——本容器就是条（宽 93、高 40，见
/// stripWidth），条的底色跟容器背后那块页面底色完全一致（读父视图的
/// backgroundColor），屏幕上只看到内容、看不出条的边；截屏时系统把密码框
/// 那层整个抹掉，条连同内容一起消失，截图里该位置露出底下的 logo。
/// 条比内容宽：logo 可以比内容宽（横版 logo 可见内容 76.8×24，内容 62 宽，
/// 条左右各出约 15.5pt），按压与摇头只动内容、条不动，logo 始终被条盖住。
/// 内容本身的点按／按压／动效／无障碍一律不动——内容仍是容器的正常
/// subview，点按走正常命中测试，状态切换动画也照常跑；只在截屏渲染那
/// 一刻，系统把密码框图层子树抹掉。
/// 密码框内部结构取不到时（iOS 内部实现变了）退回普通渲染：内容直接贴
/// 本容器、logo 不加——屏幕外观与交互不变，只是截屏不再换 logo。
final class BearyScreenshotLogoView: UIView {
    /// 条宽：logo 可见内容 76.8 ＋ 两侧各一个 sm 边距 = 92.8，取整 93。
    /// 调用方按此值定本容器宽（见 BearyProfileViewController）。
    static let stripWidth: CGFloat = 93
    /// LogoHorizontal 实测（2026-11-25，v6 预览压扁的教训）：文件 310×110 px，
    /// 内容框 288×90 px（在 (11,11)–(299,101)，四边各约 11px 透明边）。
    /// 目标是内容框正好落到 76.8×24（高 = 容器高 − 2×sm = 24，宽 = 24 × 288/90）：
    /// 整图必须等比放，scale = 76.8/288，image view = 82.7×29.3，居中放条里，
    /// contentMode 用 .scaleAspectFit。绝不能把整图缩进 76.8×24 的框——
    /// 那会竖向压约 12%（v6 预览就是这么错的，Li 看出压扁了）；也不能按原图
    /// 比例 310/110 直接算框宽（得 67.6，可见内容只剩 62.8×19.6）。
    private static let imagePixelWidth: CGFloat = 310
    private static let imagePixelHeight: CGFloat = 110
    private static let contentPixelWidth: CGFloat = 288
    private static let contentPixelHeight: CGFloat = 90
    /// 密码框本体：只用来取内部容器图层，不进视图层级、不参与触摸与读屏。
    private let secureField = UITextField()
    /// 密码框内部容器（Expo 实现同款取法）：内容真正挂在这里。
    /// 为空 = 取不到内部结构，走普通渲染退路。
    private var secureContainer: UIView?
    /// 垫在内容底下的官方 logo（浅色／深色随 imageset 走）。
    private let logoImageView: UIImageView
    private var contentView: UIView?

    init(logoImageName: String, content: UIView) {
        self.logoImageView = UIImageView(image: UIImage(named: logoImageName))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.isUserInteractionEnabled = false
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        if let container = secureField.layer.sublayers?.first?.delegate as? UIView {
            secureContainer = container
            container.isUserInteractionEnabled = true
            container.clipsToBounds = false
            // 条的底色不在这里定：容器还没进视图层级，背后底色未知；见
            // layoutSubviews，按父视图（headerView）的 backgroundColor 取。
            addSubview(logoImageView)
            addSubview(container)
        }
        setContent(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 内容居中放在条里、高贴满条；宽由调用方定（按钮定宽），不跟条走。
    /// 点按／按压／动效／无障碍都在内容上，一律不动。取到密码框结构时宿主
    /// 是条；退路时宿主是本容器，效果与贴满一致。
    /// 内容自身的 translatesAutoresizingMaskIntoConstraints 由调用方定，
    /// 此处只负责把内容钉到宿主上。
    func setContent(_ view: UIView) {
        contentView?.removeFromSuperview()
        contentView = view
        if let strip = secureContainer {
            strip.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: strip.topAnchor),
                view.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
                view.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
            ])
        } else {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
            ])
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let strip = secureContainer,
              let image = logoImageView.image,
              bounds.height > BearySpace.sm * 2,
              image.size.height > 0 else {
            secureContainer?.frame = bounds
            return
        }
        // logo 居中：内容框高 = 容器高 − 两侧各一个 sm 边距（40 高时 24），
        // 宽按内容框比例 288/90（76.8）；整图等比放，image view = 82.7×29.3，
        // 可见内容正好 76.8×24、不变形（见 v7 预览，4 倍放大核过比例正常）。
        // 大字号下容器变高、图跟着变宽时以条宽为上限收住，不让图宽出条。
        let contentHeight = bounds.height - BearySpace.sm * 2
        let contentWidth = contentHeight * Self.contentPixelWidth / Self.contentPixelHeight
        var imageWidth = contentWidth * Self.imagePixelWidth / Self.contentPixelWidth
        imageWidth = min(imageWidth, bounds.width)
        let imageHeight = imageWidth * Self.imagePixelHeight / Self.imagePixelWidth
        logoImageView.frame = CGRect(
            x: (bounds.width - imageWidth) / 2,
            y: (bounds.height - imageHeight) / 2,
            width: imageWidth,
            height: imageHeight
        )
        // 条 = 密码框容器本身，贴满本容器（93×40）。底色跟容器背后那块页面
        // 底色走（读父视图 headerView 的 backgroundColor，浅色／深色／氛围色
        // 都跟上，屏幕上看不出条的边）；截屏时系统把密码框那层整个抹掉，条连
        // 同内容一起消失，底下的 logo 露出来。条不跟内容动：按压 0.95 与拒绝
        // 摇头 ±8pt 都只动内容，条不动，logo 始终被条盖住。
        strip.frame = bounds
        strip.backgroundColor = superview?.backgroundColor ?? BearyColors.bg
    }
}

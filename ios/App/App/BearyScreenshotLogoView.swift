import UIKit

/// 截屏 logo 容器（Threads 同款做法，见 Bluesky GrowthHack.tsx 与
/// expo-privacy-sensitive 的 iOS 实现）：内容画进 isSecureTextEntry 的
/// UITextField 内部容器图层，底下垫一张官方 logo。盖住 logo 的不是内容
/// 本身，而是密码框容器这条不透明的条——本容器就是条（宽 = 内容定宽，
/// 由调用方把容器宽锚到内容宽上，高 40），条的底色跟容器背后那块页面
/// 底色完全一致（读父视图的 backgroundColor），屏幕上只看到内容、看不出
/// 条的边；截屏时系统把密码框那层整个抹掉，条连同内容一起消失，截图里
/// 该位置露出底下的 logo。
/// logo 比内容窄（横版 logo 可见内容 76.8×24，内容定宽默认约 98），
/// 右对齐内容右缘、完全落在条内；按压与摇头只动内容、条不动，logo 始终
/// 被条盖住。
/// 内容本身的点按／按压／动效／无障碍一律不动——内容仍是容器的正常
/// subview，点按走正常命中测试，状态切换动画也照常跑；只在截屏渲染那
/// 一刻，系统把密码框图层子树抹掉。
/// 密码框内部结构取不到时（iOS 内部实现变了）退回普通渲染：内容直接贴
/// 本容器、logo 不加——屏幕外观与交互不变，只是截屏不再换 logo。
final class BearyScreenshotLogoView: UIView {
    /// LogoHorizontal 实测（2026-11-25，v6 预览压扁的教训）：文件 310×110 px，
    /// 内容框 288×90 px（在 (11,11)–(299,101)，四边各约 11px 透明边）。
    /// 目标是内容框正好落到 76.8×24（高 = 容器高 − 2×sm = 24，宽 = 24 × 288/90）：
    /// 整图必须等比放，scale = 76.8/288，image view = 82.7×29.3，竖直居中
    /// 放条里、水平按右对齐算（见 layoutSubviews），contentMode 用
    /// .scaleAspectFit。绝不能把整图缩进 76.8×24 的框——
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

    /// 内容居中放在条里、高贴满条；宽由调用方定（按钮定宽），条宽由调用方
    /// 锚到内容宽上，所以内容正好贴满条。点按／按压／动效／无障碍都在内容
    /// 上，一律不动。取到密码框结构时宿主是条；退路时宿主是本容器，效果
    /// 与贴满一致。
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
        // logo 右对齐：内容框右缘 = 按钮右缘（按钮贴满条，条右缘距页眉边 16，
        // 与名字左缘 16 对称；v7 居中放时右缘只剩约 9pt，看着偏右。跟 Bluesky
        // 的做法一致：logo 在按钮框内右对齐。视觉以 v8 预览为准）。
        // 按钮右缘取内容视图当前 frame（Auto Layout 已在本次布局前定好）；
        // 未布局时退回居中（v7 位置），下一轮布局会按按钮右缘重算。
        // 按压 0.95 与拒绝摇头 ±8pt 是按钮的 transform，不触发布局，logo 不跟动。
        let contentHeight = bounds.height - BearySpace.sm * 2
        let contentWidth = contentHeight * Self.contentPixelWidth / Self.contentPixelHeight
        var imageWidth = contentWidth * Self.imagePixelWidth / Self.contentPixelWidth
        imageWidth = min(imageWidth, bounds.width)
        let imageHeight = imageWidth * Self.imagePixelHeight / Self.imagePixelWidth
        // 大字号下 image view 被条宽封顶时，实际内容框按等比收小，右对齐仍按
        // 收小后的内容框算（默认字号下无封顶，内容框正好 76.8×24）。
        let actualContentWidth = imageWidth * Self.contentPixelWidth / Self.imagePixelWidth
        let contentRight: CGFloat
        if let content = contentView, content.frame.width > 0 {
            contentRight = content.frame.maxX
        } else {
            contentRight = (bounds.width + actualContentWidth) / 2
        }
        // 内容框在 image view 内居中：image view 比内容框每侧各宽
        // (imageWidth − actualContentWidth) / 2 的透明边。
        let imageX = contentRight + (imageWidth - actualContentWidth) / 2 - imageWidth
        logoImageView.frame = CGRect(
            x: imageX,
            y: (bounds.height - imageHeight) / 2,
            width: imageWidth,
            height: imageHeight
        )
        // 条 = 密码框容器本身，贴满本容器（宽 = 按钮定宽，高 40）。底色跟容器背后那块页面
        // 底色走（读父视图 headerView 的 backgroundColor，浅色／深色／氛围色
        // 都跟上，屏幕上看不出条的边）；截屏时系统把密码框那层整个抹掉，条连
        // 同内容一起消失，底下的 logo 露出来。条不跟内容动：按压 0.95 与拒绝
        // 摇头 ±8pt 都只动内容，条不动，logo 始终被条盖住。
        strip.frame = bounds
        strip.backgroundColor = superview?.backgroundColor ?? BearyColors.bg
    }
}

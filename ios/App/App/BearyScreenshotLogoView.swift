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
    /// 放条里、水平按右对齐算（见 init 的约束），contentMode 用
    /// .scaleAspectFit。绝不能把整图缩进 76.8×24 的框——
    /// 那会竖向压约 12%（v6 预览就是这么错的，Li 看出压扁了）；也不能按原图
    /// 比例 310/110 直接算框宽（得 67.6，可见内容只剩 62.8×19.6）。
    /// LogoHorizontal 在条里的固定尺寸（推导见文件头注释：文件 310×110、
    /// 内容框 288×90，目标内容框 76.8×24，整图等比放得 82.7×29.3）。
    /// 固定值，不随按钮高缩放——旧代码按 bounds 高现算，首布局按钮未配好时
    /// 算错位且不再纠正。
    private static let logoImageWidth: CGFloat = 82.7
    private static let logoImageHeight: CGFloat = 29.3
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
        // 位置错了也画不出去：logo 与条都钉在容器内，容器裁剪，绝不压到
        // 左侧私信钮（2026-11-25 截屏 logo 漏出事故：手算 frame 依赖按钮
        // 先配好，首布局按钮未配好时 logo 落在 maxX≈15、偏左约 84pt 且不再纠正）。
        clipsToBounds = true
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.isUserInteractionEnabled = false
        logoImageView.translatesAutoresizingMaskIntoConstraints = false
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        if let container = secureField.layer.sublayers?.first?.delegate as? UIView {
            secureContainer = container
            container.isUserInteractionEnabled = true
            container.clipsToBounds = false
            container.translatesAutoresizingMaskIntoConstraints = false
            // 条的底色不在这里定：容器还没进视图层级，背后底色未知；见
            // layoutSubviews，按父视图（headerView）的 backgroundColor 取。
            addSubview(logoImageView)
            addSubview(container)
            // 条贴满本容器、logo 右对齐钉死：位置一律走 Auto Layout，不再
            // 在 layoutSubviews 里按内容 frame 手算——手算依赖按钮先配好，
            // 首布局时按钮未配好（无标题／图标／定宽）会把 logo 算到容器外。
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                logoImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                logoImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
                logoImageView.widthAnchor.constraint(equalToConstant: Self.logoImageWidth),
                logoImageView.heightAnchor.constraint(equalToConstant: Self.logoImageHeight),
            ])
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
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 只剩条底色：跟容器背后那块页面底色走（读父视图 headerView 的
        // backgroundColor，浅色／深色／氛围色都跟上，屏幕上看不出条的边）；
        // 截屏时系统把密码框那层整个抹掉，条连同内容一起消失，底下的 logo
        // 露出来。条与 logo 的位置一律走 Auto Layout（见 init），这里不再
        // 算 frame——手算 frame 依赖按钮先配好，首布局时按钮未配好会把 logo
        // 算错位且再也不纠正；条 frame 也改走约束贴满容器，不再 strip.frame = bounds。
        secureContainer?.backgroundColor = superview?.backgroundColor ?? BearyColors.bg
    }
}

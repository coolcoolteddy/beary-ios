import UIKit

/// 截屏 logo 容器（Threads 同款做法，见 Bluesky GrowthHack.tsx 与
/// expo-privacy-sensitive 的 iOS 实现）：内容画进 isSecureTextEntry 的
/// UITextField 内部容器图层，底下垫一张官方 logo。盖住 logo 的不是内容
/// 本身，而是密码框容器这条不透明的条——条的底色跟容器背后那块页面底色
/// 完全一致（读父视图的 backgroundColor），屏幕上只看到内容、看不出条的
/// 边；截屏时系统把密码框那层整个抹掉，条连同内容一起消失，截图里该位置
/// 露出底下的 logo。条比内容宽：logo 可以比内容宽（横版 logo 框宽 67.6，
/// 内容 62 宽，条左右各出约 2.8pt），按压与摇头只动内容、条不动，logo
/// 始终被条盖住。
/// 内容本身的点按／按压／动效／无障碍一律不动——内容仍是容器的正常
/// subview，点按走正常命中测试，状态切换动画也照常跑；只在截屏渲染那
/// 一刻，系统把密码框图层子树抹掉。
/// 密码框内部结构取不到时（iOS 内部实现变了）退回普通渲染：内容直接贴
/// 本容器、logo 不加——屏幕外观与交互不变，只是截屏不再换 logo。
final class BearyScreenshotLogoView: UIView {
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

    /// 内容居中放在条里：宽跟本容器（按钮定宽）走、高贴满条；点按／按压／
    /// 动效／无障碍都在内容上，一律不动。取到密码框结构时宿主是条（条比本
    /// 容器宽，内容不贴满条、只居中）；退路时宿主是本容器，效果与贴满一致。
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
                view.widthAnchor.constraint(equalTo: widthAnchor),
            ])
        } else {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        // logo 居中、高 = 容器高 − 两侧各一个 sm 边距，宽按原图比例。
        // LogoHorizontal 文件 310×110，内容框 288×90（四周各 11px 透明边），
        // 原图比例 310/110：高 24 时框宽 67.6、可见内容约 62.8×19.6，比 v5
        // 小版（框宽 46）大近五成，字清楚（见预览 v6 的 4 倍放大核对）。
        let logoHeight = bounds.height - BearySpace.sm * 2
        let logoWidth = logoHeight * image.size.width / image.size.height
        logoImageView.frame = CGRect(
            x: (bounds.width - logoWidth) / 2,
            y: (bounds.height - logoHeight) / 2,
            width: logoWidth,
            height: logoHeight
        )
        // 条 = 密码框容器本身：宽 = logo 框宽、居中在容器上（左右各出约
        // 2.8pt：私信钮在容器左缘外 8pt，净空约 5.2pt，不盖私信钮；右缘离页
        // 眉边还有 13pt 以上），高 = 容器高。底色跟容器背后那块页面底色走
        // （读父视图 headerView 的 backgroundColor，浅色／深色／氛围色都跟
        // 上，屏幕上看不出条的边）；截屏时系统把密码框那层整个抹掉，条连同
        // 内容一起消失，底下的 logo 露出来。条不跟内容动：按压 0.95 与拒绝
        // 摇头 ±8pt 都只动内容，条不动，logo 始终被条盖住。
        strip.frame = CGRect(
            x: (bounds.width - logoWidth) / 2,
            y: 0,
            width: logoWidth,
            height: bounds.height
        )
        strip.backgroundColor = superview?.backgroundColor ?? BearyColors.bg
    }
}

import UIKit

/// 截屏 logo 容器（Threads 同款做法，见 Bluesky GrowthHack.tsx 与
/// expo-privacy-sensitive 的 iOS 实现）：内容画进 isSecureTextEntry 的
/// UITextField 内部容器图层，底下垫一张官方 logo；屏幕上只看到内容
/// （内容不透明，把 logo 全盖住），截屏时系统把密码框那层抹掉，
/// 截图里该位置露出底下的 logo。
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
            container.backgroundColor = .clear
            addSubview(logoImageView)
            addSubview(container)
        }
        setContent(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 内容贴满容器（取到密码框结构时）或贴满本视图（退路时）。
    /// 内容自身的 translatesAutoresizingMaskIntoConstraints 由调用方定，
    /// 此处只负责把四边钉到宿主上。
    func setContent(_ view: UIView) {
        contentView?.removeFromSuperview()
        contentView = view
        let host = secureContainer ?? self
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        secureContainer?.frame = bounds
        // logo 居中、高 = 内容高 − 两侧各一个 sm 边距，宽按原图比例；
        // 比内容小一圈，按压缩放（0.95）与拒绝摇头（±8pt）都盖得住。
        guard secureContainer != nil,
              let image = logoImageView.image,
              bounds.height > BearySpace.sm * 2,
              image.size.height > 0 else {
            return
        }
        let logoHeight = bounds.height - BearySpace.sm * 2
        let logoWidth = logoHeight * image.size.width / image.size.height
        logoImageView.frame = CGRect(
            x: (bounds.width - logoWidth) / 2,
            y: (bounds.height - logoHeight) / 2,
            width: logoWidth,
            height: logoHeight
        )
    }
}

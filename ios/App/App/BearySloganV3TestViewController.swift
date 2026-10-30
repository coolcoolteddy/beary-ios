import UIKit
import Lottie

/// TEST ONLY — 标语 v3 lottie-ios 真机测试页（测试分支专属，正式接 veil 时必须删掉本文件及其 SceneDelegate 接线）。
///
/// 只播文字，不放熊图：本页不引用任何图片资源、无 logo 视图，
/// 验的效果即最终 veil“文字单独替换原熊图”的效果。
/// 入口：BearyChromeViewController.viewDidAppear 首次呈现（全屏 modal）。
/// 出口：点“进入主页” dismiss，回到正常主页；动画播完也不会卡住本页；
/// 动画资源缺失时显示失败文案＋按钮，绝不空白卡死。
/// 减动效：系统减动效开时不自动播，显示停留帧（53 帧完整句）；“减动效预览”钮随时可看停留帧。
final class BearySloganV3TestViewController: UIViewController {

    private var animationView: LottieAnimationView?
    private var statusLabel: UILabel!
    private var themeLabel: UILabel!
    private var playedOnce = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let banner = UILabel()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.text = "TEST · 标语 v3 真机测试（测试包专属，正式版无此页）"
        banner.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        banner.textColor = BearyColors.gray
        banner.textAlignment = .center
        banner.numberOfLines = 0
        view.addSubview(banner)

        themeLabel = UILabel()
        themeLabel.translatesAutoresizingMaskIntoConstraints = false
        themeLabel.font = UIFont.systemFont(ofSize: 13)
        themeLabel.textColor = BearyColors.gray
        themeLabel.textAlignment = .center
        themeLabel.numberOfLines = 0
        view.addSubview(themeLabel)

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        statusLabel = UILabel()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textColor = BearyColors.ink
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)

        let replayButton = BearyButton.make(style: .primaryPill(.ink), title: "重播")
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        replayButton.addTarget(self, action: #selector(didTapReplay), for: .touchUpInside)
        view.addSubview(replayButton)

        let holdButton = BearyButton.make(style: .secondaryOutline(.regular), title: "减动效预览（停留帧）")
        holdButton.translatesAutoresizingMaskIntoConstraints = false
        holdButton.addTarget(self, action: #selector(didTapHold), for: .touchUpInside)
        view.addSubview(holdButton)

        let enterButton = BearyButton.make(style: .secondaryOutline(.regular), title: "进入主页")
        enterButton.translatesAutoresizingMaskIntoConstraints = false
        enterButton.addTarget(self, action: #selector(didTapEnter), for: .touchUpInside)
        view.addSubview(enterButton)

        let checklist = UILabel()
        checklist.translatesAutoresizingMaskIntoConstraints = false
        checklist.text = "验点：逐笔描出是否顺 / 笔尖是否跟随 / 停留帧是否完整 / 退场是否散开无残笔 / 浅深两版"
        checklist.font = UIFont.systemFont(ofSize: 12)
        checklist.textColor = BearyColors.gray
        checklist.textAlignment = .center
        checklist.numberOfLines = 0
        view.addSubview(checklist)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            themeLabel.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            themeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            themeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            container.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
            container.heightAnchor.constraint(equalTo: container.widthAnchor, multiplier: 360.0 / 2135.0),
            statusLabel.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            replayButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 24),
            replayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            replayButton.widthAnchor.constraint(equalToConstant: 200),
            replayButton.heightAnchor.constraint(equalToConstant: 44),
            holdButton.topAnchor.constraint(equalTo: replayButton.bottomAnchor, constant: 12),
            holdButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            holdButton.widthAnchor.constraint(equalToConstant: 240),
            holdButton.heightAnchor.constraint(equalToConstant: 44),
            enterButton.topAnchor.constraint(equalTo: holdButton.bottomAnchor, constant: 12),
            enterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            enterButton.widthAnchor.constraint(equalToConstant: 200),
            enterButton.heightAnchor.constraint(equalToConstant: 44),
            checklist.topAnchor.constraint(equalTo: enterButton.bottomAnchor, constant: 24),
            checklist.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            checklist.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        loadAnimation(into: container)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !playedOnce {
            playedOnce = true
            play()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        // 主题切换：重载对应浅深 JSON，停在完整句，点重播再播（不自动重播，避免验点被打断）。
        if let container = animationView?.superview {
            loadAnimation(into: container)
            showHoldFrame()
            statusLabel.text = "主题已切换，已重载对应版本，点“重播”再播"
        }
    }

    private func currentResourceName() -> String {
        let dark = traitCollection.userInterfaceStyle == .dark
        return dark ? "keep_v3_dark" : "keep_v3_light"
    }

    private func loadAnimation(into container: UIView) {
        animationView?.removeFromSuperview()
        animationView = nil
        let name = currentResourceName()
        themeLabel.text = "当前版本：" + name + ".json（跟随系统浅深）"
        // TEST FIX：旧代码把“path 为空”和“Lottie 解析失败”混成同一条
        // “bundle 里找不到”报错，截图根本分不清是哪一支。本次分开报，
        // 且解析失败时带上文件字节数，证明文件到底在不在 bundle 里。
        guard let path = Bundle.main.path(forResource: name, ofType: "json") else {
            statusLabel.text = "动画加载失败：bundle 里找不到 " + name + ".json（path 为空）"
            return
        }
        guard let animation = LottieAnimation.filepath(path) else {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
            statusLabel.text = "动画加载失败：已找到 " + name + ".json（" + String(size) + " 字节）但 Lottie 解析失败"
            return
        }
        let animationView = LottieAnimationView(animation: animation)
        animationView.translatesAutoresizingMaskIntoConstraints = false
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .playOnce
        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.animationView = animationView
        statusLabel.text = "已加载，等待播放…"
    }

    private func play() {
        guard let animationView = animationView else { return }
        if UIAccessibility.isReduceMotionEnabled {
            showHoldFrame()
            statusLabel.text = "减动效已开：直接显示停留帧（53 帧完整句），不播动画"
            return
        }
        statusLabel.text = "播放中：入场描出 → 停留 → 退场散开（共 89 帧，约 3 秒）"
        animationView.play(fromFrame: 0, toFrame: 89, loopMode: .playOnce) { [weak self] _ in
            self?.statusLabel.text = "播完：退场已散干净（末帧空白），点“重播”再看一遍"
        }
    }

    private func showHoldFrame() {
        guard let animationView = animationView else { return }
        animationView.stop()
        animationView.currentFrame = 53
        statusLabel.text = "停留帧（53 帧）：完整句 Keep your days here."
    }

    @objc private func didTapReplay() {
        play()
    }

    @objc private func didTapHold() {
        showHoldFrame()
    }

    @objc private func didTapEnter() {
        dismiss(animated: true, completion: nil)
    }
}

import UIKit

// ===== BearyEmotePickerSheet 统一回应 Sheet（B 批卡片合并）=====
// 来源二合一：首页 BearyFeedEmoteSheetViewController ＋个人主页
// BearyProfileEmoteSheetViewController。两边共用同一选择器；可选列表
// 用保序熊脸列表 BearyEmoteKeys.bearFaces（all 原顺序去掉 8 个物件）。统一参数一律取
// 首页口径（任务定版）：动态 4 列（宽 - 54）/ 4 × 72、行距 10、槽位 46、
// 按压高亮（faint 底）、遮罩 0.45、抓手顶距 10、iPad ≥821 宽屏分支
// （全圆角 22 + 1px line 边框 + 底部偏移 24 的浮起卡片；移动端顶部圆角
// 22、无边框、贴底）。个人主页侧收敛点：遮罩 0.6→0.45、抓手顶距 12→10、
// 行距 6→10、槽位 44→46、固定高 480→min(540, 70% 高) 动态高、补宽屏分支、
// 补按压高亮、关闭走减动效口径。两页原调用点改为本 Sheet，各自旧实现已删。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - G21：回应 40 key 共享表（首页与个人主页回应 sheet 共用，改一处即两处）

enum BearyEmoteKeys {
    static let all: [String] = ["agree", "happy", "applause", "candle", "love", "comfort", "confused", "cheer", "determined", "facepalm", "flower", "sleepy", "goodnight", "hug", "cry", "idea", "kiss", "thinking", "letter", "listening", "lonely", "wink", "nope", "paperplane", "shy", "pat", "peek", "surprised", "proud", "shrug", "sorry", "angry", "sprout", "tea", "speechless", "thanks", "umbrella", "zap", "wave", "wish"]
    /// 非熊脸 key（物件／道具，图里没有熊脸；已逐张验过静态图）：
    /// candle 蜡烛、flower 花、letter 信、paperplane 纸飞机、sprout 苗、tea 茶杯、
    /// umbrella 雨伞、wish 星星。其余均为熊脸（含带小配饰的，如 zap 的闪电、wave 的挥手）。
    /// 新增物件 key 时必须同步加进这里，否则会漏进熊脸墙。
    static let nonBearFaceKeys: Set<String> = ["candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish"]
    /// 熊脸 key 集 = 全部回应 key 减去非熊脸 key；个人页小熊回应墙只显示这些。
    static let bearFaceKeys: Set<String> = Set(all).subtracting(nonBearFaceKeys)
    /// 选择器用的保序熊脸列表 = all 原顺序去掉非熊脸（32 项）；不要直接用
    /// bearFaceKeys（Set 迭代顺序不定，会打乱选择器原有顺序）。回应选择器
    /// 与墙共用同一口径：只留熊脸。
    static let bearFaces: [String] = all.filter { !nonBearFaceKeys.contains($0) }
}

final class BearyEmotePickerSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {

    var onPick: ((String) -> Void)?

    /// 本 Sheet 专属过渡（遮罩渐变与弹窗滑入解耦）；强持有，transitioningDelegate 弱引用。
    private let sheetTransition = BearyEmoteSheetTransition()

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = sheetTransition
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetBottomConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrimView.backgroundColor = BearySheetChrome.scrimColor
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface
        sheetView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheetView.clipsToBounds = true
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)
        // 5-23：下滑关闭（与草稿箱 handlePan 同口径，见 sheetPanGesture）。
        let sheetPan = UIPanGestureRecognizer(target: self, action: #selector(sheetPanGesture(_:)))
        sheetPan.delegate = self
        sheetView.addGestureRecognizer(sheetPan)
        grabView.backgroundColor = BearyColors.line
        grabView.layer.cornerRadius = 2
        grabView.clipsToBounds = true
        grabView.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(grabView)
        titleLabel.text = "贴一只小熊"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(titleLabel)
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.clipsToBounds = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        closeButton.accessibilityLabel = "关闭"
        sheetView.addSubview(closeButton)
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 4, left: 18, bottom: 20, right: 18)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = BearyColors.surface
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collection.delaysContentTouches = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyEmotePickerSheetCell.self, forCellWithReuseIdentifier: "bearyEmotePickerSheetCell")
        sheetView.addSubview(collection)
        let heightConstraint = sheetView.heightAnchor.constraint(equalToConstant: 480)
        sheetHeightConstraint = heightConstraint
        let bottomConstraint = sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        sheetBottomConstraint = bottomConstraint
        let widthLimit = sheetView.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let widthFull = sheetView.widthAnchor.constraint(equalTo: view.widthAnchor)
        widthFull.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: view.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            sheetView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sheetView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            widthLimit,
            widthFull,
            heightConstraint,
            grabView.topAnchor.constraint(equalTo: sheetView.topAnchor, constant: 10),
            grabView.centerXAnchor.constraint(equalTo: sheetView.centerXAnchor),
            grabView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabView.heightAnchor.constraint(equalToConstant: 4),
            titleLabel.topAnchor.constraint(equalTo: grabView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor, constant: 18),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -18),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let target = min(540, view.bounds.height * 0.7)
        if target > 0, sheetHeightConstraint?.constant != target {
            sheetHeightConstraint?.constant = target
        }
        updateSheetChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSheetChrome()
    }

    /// D-11：与详情 sheet 一致的宽屏形态（宽 ≥821）：全圆角 22 + 1px line 边框
    /// + 底部偏移 24 的浮起卡片；移动端保持顶部圆角 22、无边框、贴底。
    private func updateSheetChrome() {
        let isWide = view.bounds.width >= 821
        if isWide {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 1
            sheetView.layer.bearyDynamicBorderColor = BearyColors.line
            sheetBottomConstraint?.constant = -24
        } else {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            sheetView.layer.borderWidth = 0
            sheetBottomConstraint?.constant = 0
        }
    }

    @objc private func closeTapped() {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        dismiss(animated: reduceMotion == false, completion: nil)
    }

    /// 5-23 下滑关闭的起手门：只在头部区（抓手/标题/关闭行，y < 70）
    /// 起手，列表区滑动仍归 collectionView，不抢滚动。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === sheetView else { return true }
        let point = gestureRecognizer.location(in: sheetView)
        return point.y < 70
    }

    /// 5-23：下滑关闭，与草稿箱 handlePan 同口径——下滑跟手（只动
    /// transform，不改约束）、超过 80pt 或快速下滑（速度 > 600）时走
    /// closeTapped，否则 0.20s 弹回原位，减动效直接落位；取消/失败同样弹回。
    /// 2026-10-30 抓手批：核对过，列表区不盖住抓手行（列表顶约 y58–60，
    /// 抓手在 y10–14），且 pan 是手势而非覆盖视图，不会吞列表点按；
    /// 故此处只补上滑统一口径（阻尼微移后回弹，不扩高、不关闭），
    /// 门控 y<70 与阈值 80/600 均不动。
    @objc private func sheetPanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            let offset = BearySheetDrag.offset(for: translation.y)
            sheetView.transform = CGAffineTransform(translationX: 0, y: offset)
            // 审计第 14 项：遮罩跟手变淡，与游客提示同口径（共用映射）。
            scrimView.alpha = BearySheetDrag.scrimAlpha(forDragOffset: offset, sheetHeight: sheetView.bounds.height)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if translation.y > 80 || velocity > 600 {
                closeTapped()
            } else {
                let restore = {
                    self.sheetView.transform = .identity
                    self.scrimView.alpha = 1
                }
                if UIAccessibility.isReduceMotionEnabled {
                    restore()
                } else {
                    UIView.animate(withDuration: 0.20, animations: restore)
                }
            }
        case .cancelled, .failed:
            let restore = {
                self.sheetView.transform = .identity
                self.scrimView.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                restore()
            } else {
                UIView.animate(withDuration: 0.20, animations: restore)
            }
        default:
            break
        }
    }

    /// 过渡动画用：遮罩 alpha（色值走 BearySheetChrome.scrimColor，含 0.45，动画只动 view alpha 0↔1）。
    func transitionSetScrimAlpha(_ alpha: CGFloat) {
        scrimView.alpha = alpha
    }

    /// 过渡动画用：弹窗下滑位移（约束不动，只动 transform；归位即 identity）。
    func transitionSetSheetOffset(_ offsetY: CGFloat) {
        sheetView.transform = offsetY == 0 ? .identity : CGAffineTransform(translationX: 0, y: offsetY)
    }

    /// 过渡动画用：弹窗当前高（布局后实测；宽屏浮起卡片同样适用）。
    func transitionSheetHeight() -> CGFloat {
        view.layoutIfNeeded()
        return sheetView.bounds.height
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return BearyEmoteKeys.bearFaces.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyEmotePickerSheetCell", for: indexPath) as? BearyEmotePickerSheetCell else {
            return UICollectionViewCell()
        }
        let key = BearyEmoteKeys.bearFaces[indexPath.item]
        cell.configure(key: key)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        return CGSize(width: width, height: 72)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let pickedKey = BearyEmoteKeys.bearFaces[indexPath.item]
        BearySoundPlayer.play(.emoteChirp)
        onPick?(pickedKey)
    }
}

// MARK: - 回应 Sheet 过渡：遮罩与弹窗解耦
/// 旧默认过渡把整个 presented view（含已满暗的遮罩）一起滑上来，看着像遮罩
/// 跟着弹窗升起；此处只给回应 Sheet 用（不走共用底座，不拖坏其他弹窗）：
/// 弹窗仍从下方滑入，遮罩 0.25s 淡入（与滑入解耦，2026-10-28 Li 令）；关闭时反向渐变淡出。
/// 减动效下直接落终态；非动画 present/dismiss 不走本过渡。
final class BearyEmoteSheetTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {

    private var presenting = true

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.presenting = false
        return self
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        if UIAccessibility.isReduceMotionEnabled { return 0 }
        return 0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let sheet = transitionContext.viewController(forKey: key) as? BearyEmotePickerSheetViewController else {
            transitionContext.completeTransition(false)
            return
        }
        if presenting {
            guard let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            transitionContext.containerView.addSubview(toView)
            toView.frame = transitionContext.containerView.bounds
            let height = sheet.transitionSheetHeight()
            sheet.transitionSetScrimAlpha(0)
            sheet.transitionSetSheetOffset(height)
            if UIAccessibility.isReduceMotionEnabled {
                sheet.transitionSetScrimAlpha(1)
                sheet.transitionSetSheetOffset(0)
                transitionContext.completeTransition(true)
                return
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                sheet.transitionSetSheetOffset(0)
            }, completion: { _ in transitionContext.completeTransition(true) })
            // 遮罩出现时 0.25s 淡入（与弹窗滑入解耦）。
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                sheet.transitionSetScrimAlpha(1)
            })
            return
        }
        let height = sheet.transitionSheetHeight()
        if UIAccessibility.isReduceMotionEnabled {
            transitionContext.completeTransition(true)
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            sheet.transitionSetSheetOffset(height)
        }, completion: { _ in transitionContext.completeTransition(true) })
        // 第 30 项：关闭时遮罩 0.25s 单独淡出（与打开同口径；此前与面板下滑合写在 0.3s 块里）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
            sheet.transitionSetScrimAlpha(0)
        })
    }
}

final class BearyEmotePickerSheetCell: UICollectionViewCell {

    private let emoteSlot = UIView()
    /// 1-6：按压高亮底片——只盖 46 槽位、圆角 12，画在槽位之后、熊图之下；
    /// 原整格 faint 底（格宽约 96.5、槽位仅 46）按压面远大于熊图，已撤。
    private let highlightView = UIView()
    private var emoteView: BearyEmoteView?
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.backgroundColor = .clear
        highlightView.layer.cornerRadius = 12
        highlightView.layer.masksToBounds = true
        contentView.addSubview(highlightView)
        emoteSlot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emoteSlot)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textAlignment = .center
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor),
            highlightView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            highlightView.widthAnchor.constraint(equalToConstant: 46),
            highlightView.heightAnchor.constraint(equalToConstant: 46),
            emoteSlot.topAnchor.constraint(equalTo: contentView.topAnchor),
            emoteSlot.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emoteSlot.widthAnchor.constraint(equalToConstant: 46),
            emoteSlot.heightAnchor.constraint(equalToConstant: 46),
            nameLabel.topAnchor.constraint(equalTo: emoteSlot.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        emoteView?.stop()
    }

    /// U9：回应 sheet cell 按压态（faint 底），首页与个人主页统一都有。
    /// 1-6：高亮只画在 46 槽位圆角底片上，不再铺满整格。
    override var isHighlighted: Bool {
        didSet {
            highlightView.backgroundColor = isHighlighted ? BearyColors.faint : .clear
        }
    }

    /// G21：dark 死参数已从签名去掉（深浅由播放器内部处理）。
    func configure(key: String) {
        let name = BearyText.moodNames[key] ?? key
        if let current = emoteView, current.emoteKey == key {
            current.play()
        } else {
            emoteView?.stop()
            emoteView?.removeFromSuperview()
            let next = BearyEmoteView(key: key, animated: true)
            next.translatesAutoresizingMaskIntoConstraints = false
            emoteSlot.addSubview(next)
            NSLayoutConstraint.activate([
                next.topAnchor.constraint(equalTo: emoteSlot.topAnchor),
                next.bottomAnchor.constraint(equalTo: emoteSlot.bottomAnchor),
                next.leadingAnchor.constraint(equalTo: emoteSlot.leadingAnchor),
                next.trailingAnchor.constraint(equalTo: emoteSlot.trailingAnchor),
            ])
            emoteView = next
        }
        nameLabel.font = UIFont.systemFont(ofSize: 11)
        nameLabel.textColor = BearyColors.gray
        nameLabel.text = name
    }
}

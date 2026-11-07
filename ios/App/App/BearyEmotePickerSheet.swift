import UIKit

// ===== BearyEmotePickerSheet 统一回应 Sheet（B 批卡片合并）=====
// 来源二合一：首页 BearyFeedEmoteSheetViewController ＋个人主页
// BearyProfileEmoteSheetViewController。两边共用同一选择器；可选列表
// 用保序熊脸列表 BearyEmoteKeys.bearFaces（all 原顺序去掉 8 个物件）。统一参数一律取
// 首页口径（任务定版）：动态 4 列（宽 - 54）/ 4 × 72、行距 10、槽位 46、
// 按压高亮（surface2 底）、遮罩 0.45、抓手顶距 10、iPad ≥821 宽屏分支
// （全圆角 20 + 1px line 边框 + 底部偏移 24 的浮起卡片；移动端顶部圆角
// 20、无边框、贴底）。个人主页侧收敛点：遮罩 0.6→0.45、抓手顶距 12→10、
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

// MARK: - 视觉批 2-2：表情选择器首行“最近使用”
// 本机记忆，不走后端：UserDefaults 里只存一份有序 key 列表，首位即最近一次
// 使用（点选即把该 key 移到首位），最多 8 个；读时过滤掉已不在熊脸列表里的
// 旧 key（如资产调整后），不做时间戳字段——顺序本身就是最近使用时间倒序。
private enum BearyEmoteRecentStore {
    static let defaultsKey = "beary.recentEmoteKeys"
    static let maxCount = 8

    static func load() -> [String] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return Array(stored.filter { BearyEmoteKeys.bearFaces.contains($0) }.prefix(maxCount))
    }

    static func record(_ key: String) {
        guard BearyEmoteKeys.bearFaces.contains(key) else { return }
        var list = load().filter { $0 != key }
        list.insert(key, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxCount)), forKey: defaultsKey)
    }
}

final class BearyEmotePickerSheetViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {

    var onPick: ((String) -> Void)?

    /// 本 Sheet 专属过渡（遮罩渐变与弹窗滑入解耦）；强持有，transitioningDelegate 弱引用。
    private let sheetTransition = BearyEmoteSheetTransition()
    /// #722 修红：焦点返回用的原焦点元素（init 时记、消失时还）；#722 原支只写了
    /// 读写两处、漏了声明本身（通知页同款写法：private weak var，见该文件 2654 行）。
    private weak var previousFocusedElement: AnyObject?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
        transitioningDelegate = sheetTransition
        // 打开前先记焦点：present 后当前焦点即被 Sheet 夺走，此时再记就晚了。
        // 调用方均为“创建后立即 present”（首页/个人页/详情/盲盒四处），init 时
        // 焦点仍在原入口控件上。
        if #available(iOS 17.0, *) {
            previousFocusedElement = UIAccessibility.focusedElement(using: nil) as? AnyObject
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let scrimView = UIView()
    private let sheetView = UIView()
    private let grabView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = BearyHit44Button(type: .system)
    /// 审计 D-7：手势门控按布局后实测帧划分，需持有 collection 引用（见 gestureRecognizerShouldBegin）。
    private var emoteCollectionView: UICollectionView?
    /// 视觉批 2-2：本次打开时读到的最近使用列表（倒序、最多 8 个）；空时不建
    /// 最近节，collection 退回单节全量网格，不留空行占位。
    private var recentEmoteKeys: [String] = BearyEmoteRecentStore.load()
    /// 最近节存在时为第 0 节，全量网格顺延为第 1 节；无最近记录时只有全量一节。
    private var hasRecentSection: Bool { !recentEmoteKeys.isEmpty }
    private func emoteKeys(forSection section: Int) -> [String] {
        if hasRecentSection, section == 0 { return recentEmoteKeys }
        return BearyEmoteKeys.bearFaces
    }
    private var sheetHeightConstraint: NSLayoutConstraint?
    private var sheetBottomConstraint: NSLayoutConstraint?
    /// VoiceOver 焦点返回：与通知弹层同口径（BearyNotificationsViewController），
    /// init 时记下 Sheet 外当前焦点元素（通常为触发回应的入口控件）；关闭后
    /// 把焦点还回去。weak 持有：触发控件是列表 cell 内元素，复用/离屏后失效
    /// 即放弃返回，不强留。取焦点 API 以 iOS 17 起可用作守门，旧系统无显式
    /// 返回、走系统默认行为。

    override func viewDidLoad() {
        super.viewDidLoad()
        // 无障碍模态范围显式声明：VoiceOver 在 Sheet 打开期间不扫读下层。
        // 注：本 Sheet 是 .overFullScreen presented VC，系统模态呈现本身在
        // 多数情况下已给 VoiceOver 一定 containment，此处为显式声明＋焦点
        // 返回，真机仍需验 containment 是否如预期（见 PR 描述）。
        view.accessibilityViewIsModal = true
        view.backgroundColor = .clear
        scrimView.backgroundColor = BearySheetChrome.scrimColor
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        let scrimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        scrimView.addGestureRecognizer(scrimTap)
        view.addSubview(scrimView)
        sheetView.backgroundColor = BearyColors.surface3
        sheetView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // 2026-11-02 定版第 2 组：回应 Sheet 补 raised 阴影（0.12 / 8 / (0, 2)），此前无阴影。
        // 阴影挂本层：clipsToBounds 会裁掉 bounds 外的阴影，故不裁剪；子视图均内缩，
        // 圆角处无溢出。圆角 20 本身不动（第 1 组范围）。
        BearyShadow.applyRaised(to: sheetView.layer)
        sheetView.clipsToBounds = false
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
        // 审计 D-13：标题跟系统字号（原 15pt 固定）；标题长高时下方列表顶约束同步下移，门控见 gestureRecognizerShouldBegin。
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetView.addSubview(titleLabel)
        closeButton.setImage(BearyFeedIconCache.image(named: "icon_close", pointSize: 15), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.surface2
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
        collection.backgroundColor = BearyColors.surface3
        // 116 后扫查：与广场/个人页同口径——关掉 delaysContentTouches，滚动容器里的点按立即响应，不等滚动判定。
        collection.delaysContentTouches = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(BearyEmotePickerSheetCell.self, forCellWithReuseIdentifier: "bearyEmotePickerSheetCell")
        collection.register(BearyEmotePickerSectionHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "bearyEmotePickerSectionHeader")
        emoteCollectionView = collection
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
            closeButton.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: sheetView.safeAreaLayoutGuide.bottomAnchor),
            collection.leadingAnchor.constraint(equalTo: sheetView.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: sheetView.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // VoiceOver：Sheet 出现即聚焦标题。下一 runloop 再发，等布局与过渡
        // 落位后再取标题；若期间已关闭（view 已离线）则不发。未开 VoiceOver
        // 时 post 为空操作。
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.view.window != nil else { return }
            UIAccessibility.post(notification: .screenChanged, argument: strongSelf.titleLabel)
        }
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
        // 审计 D-13：系统字号档变化时行高需重算（sizeForItemAt 按实际文字高度计），
        // 只刷布局，不重建 cell、不改列数与顺序。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            emoteCollectionView?.collectionViewLayout.invalidateLayout()
        }
    }

    /// D-11：与详情 sheet 一致的宽屏形态（宽 ≥821）：全圆角 20 + 底部偏移 24 的浮起卡片；
    /// 移动端保持顶部圆角 20、无边框、贴底。
    /// 审计 2026-11-02 弹窗组：注释原写 22 与代码（topCornerRadius=20）漂移，
    /// 只改注释统一为 20，不改代码数值（圆角属样式 token）。
    private func updateSheetChrome() {
        let isWide = view.bounds.width >= 821
        if isWide {
            sheetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            sheetView.layer.borderWidth = 0
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

    /// VoiceOver 双指 scrub（无障碍退出手势）：走原关闭请求 closeTapped，与
    /// 遮罩点按、关闭钮同一口径。本 Sheet 无未保存草稿与在途操作（点选即
    /// 时回调 onPick、由调用方关闭），故无需另设“未保存/操作在途”门控；
    /// 焦点返回由 viewDidDisappear 统一处理。
    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    /// 审计 D-7：下滑关闭的起手门——不再用固定 y < 70（原门控盖住首行上缘约 8pt：
    /// 抓手顶 10 + 高 4 → 标题顶 +14 → 列表顶 = 标题底 +12，首行上缘约 y=62）。
    /// 改按布局后实测帧划分：关闭钮（含 BearyHit44Button 向外扩的 6pt 热区）与
    /// 列表区一律不接手，只在列表顶以上的头部区（抓手/标题行）起手；标题随
    /// 系统字号长高时列表顶同步下移，门控同步跟随，不再错位。
    /// 关闭距离 80pt 与速度 600 阈值不动（见 sheetPanGesture）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === sheetView else { return true }
        let point = gestureRecognizer.location(in: sheetView)
        if closeButton.frame.insetBy(dx: -6, dy: -6).contains(point) { return false }
        if let collection = emoteCollectionView {
            return point.y < collection.frame.minY
        }
        return point.y < titleLabel.frame.maxY + 12
    }

    /// 5-23：下滑关闭，与草稿箱 handlePan 同口径——下滑跟手（只动
    /// transform，不改约束）、超过 80pt 或快速下滑（速度 > 600）时走
    /// closeTapped，否则统一弹簧（0.30s／damping 0.7＋松手速度）弹回原位，减动效直接落位；取消/失败同样弹回。
    /// 2026-10-30 抓手批：核对过，列表区不盖住抓手行（列表顶约 y58–60，
    /// 抓手在 y10–14），且 pan 是手势而非覆盖视图，不会吞列表点按；
    /// 故此处只补上滑统一口径（阻尼微移后回弹，不扩高、不关闭），
    /// 阈值 80/600 不动；门控已由审计 D-7 改为实测帧划分（见 gestureRecognizerShouldBegin）。
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
                    let offset = BearySheetDrag.offset(for: translation.y)
                    UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: offset), options: [], animations: restore)
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
                UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: restore)
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

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        return hasRecentSection ? 2 : 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return emoteKeys(forSection: section).count
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              hasRecentSection, indexPath.section == 0,
              let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "bearyEmotePickerSectionHeader", for: indexPath) as? BearyEmotePickerSectionHeaderView else {
            return UICollectionReusableView()
        }
        header.configure(title: "最近使用")
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        guard hasRecentSection, section == 0 else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: 28)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "bearyEmotePickerSheetCell", for: indexPath) as? BearyEmotePickerSheetCell else {
            return UICollectionViewCell()
        }
        let key = emoteKeys(forSection: indexPath.section)[indexPath.item]
        cell.configure(key: key)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let totalSpacing: CGFloat = 18 * 2 + 6 * 3
        let width = max(44, (collectionView.bounds.width - totalSpacing) / 4)
        // 审计 D-13：行高按实际文字高度计——名称用与 cell 一致的缩放 11pt 字、
        // 格宽减左右各 2 内边距量取，允许多行；默认字号下 46 + 4 + 单行高 + 8
        // 仍为 72，与原固定高一致；放大后名称换行，行高随之长高，不裁字。
        // 列数（4 列）与排列顺序不动；字号档变化时 traitCollectionDidChange 刷布局重算。
        let key = emoteKeys(forSection: indexPath.section)[indexPath.item]
        let name = BearyText.moodNames[key] ?? key
        let nameFont = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        let nameWidth = max(width - 4, 0)
        let nameHeight = (name as NSString).boundingRect(
            with: CGSize(width: nameWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [NSAttributedString.Key.font: nameFont],
            context: nil
        ).height.rounded(.up)
        let height = max(72, 46 + 4 + nameHeight + 8)
        return CGSize(width: width, height: height)
    }

    /// 审计 2026-11-02 弹窗组：回应 Sheet 防重复点选——点选后立即禁用选项，
    /// 挡住 0.25s 关闭窗口内的二次点选；关闭完成（视图离线）后恢复，
    /// 本 Sheet 单次呈现单例，恢复仅为防御（调用方 dismiss 后实例即丢弃）。
    /// 内容区超大字号：列表本身就是 collectionView，内容超高时内部滚动，
    /// 行高已按实际文字高度计（D-13），无需另改。
    private var didPickEmote = false

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !didPickEmote else { return }
        didPickEmote = true
        collectionView.isUserInteractionEnabled = false
        let pickedKey = emoteKeys(forSection: indexPath.section)[indexPath.item]
        // 视觉批 2-2：最近行与全量区点选走同一回调前先记最近使用——不另写回应逻辑。
        BearyEmoteRecentStore.record(pickedKey)
        BearySoundPlayer.play(.emoteChirp)
        onPick?(pickedKey)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 关闭完成后再恢复选项（单例防御；正常关闭后实例即丢弃）。
        didPickEmote = false
        emoteCollectionView?.isUserInteractionEnabled = true
        // VoiceOver 焦点返回：仅真正被 dismiss 时还（被上层弹窗盖住时
        // isBeingDismissed 为 false，不抢焦点）。关闭钮/遮罩/下滑/退出手势
        // 与点选后调用方关闭五路皆汇到此处，无需各路重复发。
        if isBeingDismissed, let element = previousFocusedElement {
            UIAccessibility.post(notification: .layoutChanged, argument: element)
            previousFocusedElement = nil
        }
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
        // 入场仍 0.25s；退场走拖拽收尾统一弹簧 0.30s。
        return presenting ? 0.25 : 0.30
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
        UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
            sheet.transitionSetSheetOffset(height)
        }, completion: { _ in transitionContext.completeTransition(true) })
        // 第 30 项：关闭时遮罩 0.25s 单独淡出（与打开同口径；此前与面板下滑合写在 0.3s 块里）。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
            sheet.transitionSetScrimAlpha(0)
        })
    }
}

// MARK: - 视觉批 2-2：最近使用节标题
/// 只在最近节存在时出现（referenceSizeForHeaderInSection 其余情况回 .zero，
/// 故最近行为空时不留占位）。样式沿用搜索页“最近搜索”标题口径：13 半粗
/// scaled、灰字、左 inset 18 与网格 sectionInset 左边对齐；不新增图标与按钮。
final class BearyEmotePickerSectionHeaderView: UICollectionReusableView {

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.gray
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        titleLabel.text = title
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
        // 审计 D-13：放大后名称允许换行（行高见 sizeForItemAt 的实测计算）。
        nameLabel.numberOfLines = 0
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

    /// U9：回应 sheet cell 按压态（surface2 底），首页与个人主页统一都有。
    /// 1-6：高亮只画在 46 槽位圆角底片上，不再铺满整格。
    override var isHighlighted: Bool {
        didSet {
            highlightView.backgroundColor = isHighlighted ? BearyColors.surface2 : .clear
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
        // 审计 D-13：名称跟系统字号（原 11pt 固定），与 sizeForItemAt 量取用同一缩放字。
        nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.gray
        nameLabel.text = name
    }
}

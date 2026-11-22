// 九宫格：单篇照片 3×3 网格；点格进现有灯箱（BearyEntryImageViewerViewController）。
// 入口唯一门控在 BearyNineGridPresenter（Plus 专属，2026-11-03 Li 定版）。
// 网格 cell 复用照片页同款 BearyProfilePhotoCell（圆角 12、surface2 底、失败格可重试）。

import UIKit

final class BearyNineGridViewController: UIViewController {

    private let imageKeys: [String]
    private let liveVideos: [String: String]?
    private var lastImageViewerAt: Date?

    init(imageKeys: [String], liveVideos: [String: String]?) {
        self.imageKeys = imageKeys
        self.liveVideos = liveVideos
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "九宫格"
        return labelValue
    }()

    private lazy var collectionView: UICollectionView = {
        let layoutValue = UICollectionViewFlowLayout()
        layoutValue.minimumInteritemSpacing = 8
        layoutValue.minimumLineSpacing = 8
        layoutValue.sectionInset = UIEdgeInsets(top: 16, left: BearySpace.lg, bottom: 20, right: BearySpace.lg)
        let collectionValue = UICollectionView(frame: .zero, collectionViewLayout: layoutValue)
        collectionValue.translatesAutoresizingMaskIntoConstraints = false
        collectionValue.backgroundColor = BearyColors.bg
        collectionValue.delaysContentTouches = false
        collectionValue.delegate = self
        collectionValue.dataSource = self
        collectionValue.register(BearyProfilePhotoCell.self, forCellWithReuseIdentifier: "BearyProfilePhotoCell")
        return collectionValue
    }()

    private var collectionViewWidthConstraint: NSLayoutConstraint?

    /// 左缘返回控制器强持有（transitioningDelegate 是弱引用；打开方是静态
    /// BearyNineGridPresenter、无实例可代持，改由本页持有到 dismiss 完成）。
    fileprivate var edgeDismiss: BearyEdgeDismissController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(collectionView)
        collectionViewWidthConstraint = collectionView.widthAnchor.constraint(equalToConstant: view.bounds.width)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: topBarView.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -52),
            collectionView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            collectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            collectionViewWidthConstraint!,
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 顶栏高钉死 44（defaultHigh）：常规字号下定值，大字号时标题的 required
        // 上下不等式把下限抬高、栏随字长高；照片页 #115 同款实证，无定值时顶栏
        // 会被 solver 撑满整页。
        let topBarHeight = topBarView.heightAnchor.constraint(equalToConstant: 44)
        topBarHeight.priority = .defaultHigh
        topBarHeight.isActive = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGridWidth()
    }

    /// 网格宽按实宽定——仅 iPad 且宽 ≥821 时 600 居中、其余全宽，与全站 iPad 口径一致；
    /// 只在目标宽变化时改约束并失效布局，不反复触发（照片页同款）。
    private func updateGridWidth() {
        let targetWidth: CGFloat = BearyDesktop.isWide(view.bounds.width) ? 600 : view.bounds.width
        guard collectionViewWidthConstraint?.constant != targetWidth else { return }
        collectionViewWidthConstraint?.constant = targetWidth
        collectionView.collectionViewLayout.invalidateLayout()
    }

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

extension BearyNineGridViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        imageKeys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyProfilePhotoCell", for: indexPath) as? BearyProfilePhotoCell else {
            return UICollectionViewCell()
        }
        cell.configure(imageKey: imageKeys[indexPath.item], index: indexPath.item + 1)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let widthValue = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        let side = floor((widthValue - BearySpace.lg * 2 - 8 * 2) / 3)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        // 失败格点按只重试本格图片，不进灯箱（照片页同款）。
        if let photoCell = collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell, photoCell.isFailed {
            photoCell.retryLoading()
            return
        }
        guard presentedViewController == nil else { return }
        let now = Date()
        if let last = lastImageViewerAt, now.timeIntervalSince(last) < 0.8 { return }
        lastImageViewerAt = now
        let viewer = BearyEntryImageViewerViewController(imageKeys: imageKeys, liveVideos: liveVideos, startIndex: indexPath.item)
        viewer.initialThumbnail = (collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell)?.displayedThumbnail
        viewer.originFrameInWindow = collectionView.cellForItem(at: indexPath).map { $0.convert($0.bounds, to: nil) }
        // C3：关场回当前照片——按下标找网格里对应的格；在视口内才给
        // 矩形与焦点视图，格不在视口内时返回 nil、走淡出兜底（照片页同款）。
        viewer.dismissOriginProvider = { [weak self] index in
            guard let self = self, index >= 0, index < self.imageKeys.count else { return nil }
            let path = IndexPath(item: index, section: 0)
            guard let cell = self.collectionView.cellForItem(at: path) else { return nil }
            let frame = cell.convert(cell.bounds, to: nil)
            return (frame: frame, element: cell)
        }
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: BearyMotion.animated(true), completion: nil)
    }
}

/// 九宫格入口唯一门控与打开点：卡片、时间线、个人页、详情四处共用。
enum BearyNineGridPresenter {

    /// 门控走统一门 BearyPlusGate（现在全开）；未开通时走景深背景同款 Plus 专属
    /// 提示口径，不开网格。图片上限 9 张与图片条一致。
    /// r22 A6：未登录先走登录门（登录态未知时不弹登录页，改网络 toast，与卡片
    /// onRequireLogin 汇点同款）；A7：非 Plus 拒绝只摇触发入口，不摇整页。
    static func present(from viewController: UIViewController, anchorView: UIView? = nil, imageKeys: [String], liveVideos: [String: String]?) {
        if SessionManager.shared.isLoggedIn == false {
            if SessionManager.shared.authUnknown {
                BearyToast.show(in: viewController.view, message: "网络不稳定，请稍后再试")
            } else {
                viewController.present(BearyLoginSheet.make(), animated: BearyMotion.animated(true), completion: nil)
            }
            return
        }
        guard BearyPlusGate.canUsePlusFeature(user: SessionManager.shared.currentUser) else {
            if let anchorView {
                playDenyShake(on: anchorView)
            }
            BearyToast.show(in: viewController.view, message: "仅 Plus 会员可使用九宫格版式")
            return
        }
        let keys = Array(imageKeys.filter { !$0.isEmpty }.prefix(9))
        guard !keys.isEmpty else { return }
        // 2026-11-14 九宫格入口点按无反应修：此前要求 presentedViewController
        // == nil 才 present，任一已弹出页（没盖住按钮的底部弹窗、灯箱正在收起
        // 的动画在途）都会让这次点按静默丢掉、零反馈。改为沿 presented 链走到
        // 最顶层再 present，点按必有反应；链上已有九宫格时不再叠加。
        var top = viewController
        while let presented = top.presentedViewController {
            if presented is BearyNineGridViewController { return }
            top = presented
        }
        let grid = BearyNineGridViewController(imageKeys: keys, liveVideos: liveVideos)
        grid.modalPresentationStyle = .fullScreen
        // 第 22 轮 A4：左缘返回——与返回按钮走同一 dismiss 路径；进出走
        // EdgeDismiss 自带的右滑 slide（全站全屏页同款原生返回口径）。
        let edgeDismiss = BearyEdgeDismissController()
        edgeDismiss.attach(to: grid)
        grid.transitioningDelegate = edgeDismiss
        grid.edgeDismiss = edgeDismiss
        top.present(grid, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 非 Plus 拒绝动效：0.38s 摇头＋warning 震动＋拒绝音效（与详情 playDenyShake 同口径；
    /// 减动效时只跳视觉抖动），只摇触发入口。
    private static func playDenyShake(on view: UIView) {
        BearyIconMotion.playDenyShake(on: view, key: "bearyNineGridDenyShake")
    }
}

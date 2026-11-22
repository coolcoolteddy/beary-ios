// 九宫格直显（2026-11-22 Li 定，取代 2026-11-12 旧形态）：选了九宫格格式的
// 日记，卡片／详情／时间线直接以正文＋九宫格（3×3）排版显示，不再是横向
// 图片条，也不再经「九宫格」按钮进单独网格页（BearyNineGridViewController
// 已删）。本视图只负责 inline 网格本身：格复用照片页同款
// BearyProfilePhotoCell（缩略图加载、失败占位＋点按重试、读屏名），点格经
// onImageTapped 交宿主走各页既有灯箱路径（卡片 onImageTapped／onTapImages、
// 详情／时间线直开 BearyEntryImageViewerViewController）；实况不在格内播，
// 进灯箱后播（与旧网格页同款）。

import UIKit

final class BearyInlineNineGridView: UIView {

    /// 格间距（与图片条、旧网格页同款 8）。
    static let spacing: CGFloat = 8
    /// 列数固定 3。
    static let columns = 3
    /// 单篇图上限（与图片条同款 9）。
    static let maxImages = 9

    /// 给定内容宽与图数，算网格高（估算行高与实际布局同一公式）：
    /// 边长 floor((宽 − 间距×2)/3)，高 = 行数×边长 ＋ (行数−1)×间距；无图为 0。
    static func height(forWidth width: CGFloat, count: Int) -> CGFloat {
        let n = min(max(count, 0), maxImages)
        guard n > 0, width > 0 else { return 0 }
        let side = floor((width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let rows = (n + columns - 1) / columns
        return CGFloat(rows) * side + CGFloat(rows - 1) * spacing
    }

    /// 点格回调（下标、格在窗口中的框、格当前缩略图），与图片条点图同款签名。
    var onImageTapped: ((Int, CGRect?, UIImage?) -> Void)?

    private var keys: [String] = []
    private var lastTapAt: Date?

    private lazy var collectionView: UICollectionView = {
        let layoutValue = UICollectionViewFlowLayout()
        layoutValue.minimumInteritemSpacing = Self.spacing
        layoutValue.minimumLineSpacing = Self.spacing
        layoutValue.sectionInset = .zero
        let collectionValue = UICollectionView(frame: .zero, collectionViewLayout: layoutValue)
        collectionValue.translatesAutoresizingMaskIntoConstraints = false
        collectionValue.backgroundColor = .clear
        collectionValue.showsVerticalScrollIndicator = false
        collectionValue.showsHorizontalScrollIndicator = false
        collectionValue.isScrollEnabled = false
        // 图片条同款：滚动容器里的点按立即响应，不等滚动判定。
        collectionValue.delaysContentTouches = false
        collectionValue.delegate = self
        collectionValue.dataSource = self
        collectionValue.register(BearyProfilePhotoCell.self, forCellWithReuseIdentifier: "BearyProfilePhotoCell")
        return collectionValue
    }()

    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        let height = collectionView.heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 配图（空即整块隐藏，不留空位；超 9 张只取前 9 张，与图片条同款）。
    func configure(keys: [String]) {
        let next = Array(keys.filter { !$0.isEmpty }.prefix(Self.maxImages))
        self.keys = next
        isHidden = next.isEmpty
        collectionView.reloadData()
        updateHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHeight()
    }

    /// 高度由实宽定：宽未定（布局前）时先 0，布局后按公式重算；值不变不重布局。
    private func updateHeight() {
        let target = Self.height(forWidth: bounds.width, count: keys.count)
        guard heightConstraint?.constant != target else { return }
        heightConstraint?.constant = target
        collectionView.collectionViewLayout.invalidateLayout()
    }
}

extension BearyInlineNineGridView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        keys.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyProfilePhotoCell", for: indexPath) as? BearyProfilePhotoCell else {
            return UICollectionViewCell()
        }
        cell.configure(imageKey: keys[indexPath.item], index: indexPath.item + 1)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let widthValue = collectionView.bounds.width > 0 ? collectionView.bounds.width : bounds.width
        let side = floor((widthValue - Self.spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns))
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        // 失败格点按只重试本格图片，不进灯箱（旧网格页同款）。
        if let photoCell = collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell, photoCell.isFailed {
            photoCell.retryLoading()
            return
        }
        // 旧网格页同款连点守卫：0.8 秒内重复点按只进一次灯箱。
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) < 0.8 { return }
        lastTapAt = now
        guard indexPath.item >= 0, indexPath.item < keys.count else { return }
        let cell = collectionView.cellForItem(at: indexPath) as? BearyProfilePhotoCell
        onImageTapped?(indexPath.item, cell.map { $0.convert($0.bounds, to: nil) }, cell?.displayedThumbnail)
    }
}

import UIKit

// MARK: - 通用图片裁剪器（B 批合并）
//
// 由编辑器与编辑资料两处旧裁剪器合并而来，行为逐项对齐原实现，不改产品行为：
// - 编辑器旧实现（写死方形窗）：调用方传 aspectRatio: 1。
// - 编辑资料旧实现（aspectRatio 参数）：
//   头像传 1，封面传本页预览比例（封面预览宽 / 180，布局未出时按内容列宽推算，
//   兜底 2；该比例计算仍在调用方，不在本文件内改动）。
// 通用窗算法（滚动区内留 16pt 边距、按 aspectRatio 取最大窗并居中）在
// aspectRatio == 1 时恰好退化为旧编辑器方形窗：边长 = 滚动区短边 - 32，
// 故编辑器裁剪结果与原来一致；setupImageZoom 按裁剪窗尺寸算盖满缩放，
// 方形时与旧编辑器按边长算的结果一致。
// 其余原有行为全部保留：UIScrollView 手势（双指缩放、拖动、回弹）、
// 白色裁剪框、半透明遮罩镂空（四块遮罩 + 白框在上）、顶栏取消/确认、
// 恒黑底、提示文案“双指缩放，拖动调整”、确认按窗在图内的实际位置裁
// （convert 计入缩放变换，先把原图方向归一化再按像素裁）。
// 回调语义：确认且裁剪成功时 onConfirm 回传裁剪图，调用方负责后续流程
// （编辑器：替换原项与上传；编辑资料：压缩、替换预览与待保存标记）；
// 取消不回调，调用方状态全程不动；确认时无论裁剪是否成功都 dismiss。

final class BearyImageCropViewController: UIViewController, UIScrollViewDelegate {

    /// 确认回传裁剪图（调用方负责后续流程；取消不回调）。
    var onConfirm: ((UIImage) -> Void)?

    private let sourceImage: UIImage
    private let aspectRatio: CGFloat
    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let hintLabel = UILabel()
    private var dimViews: [UIView] = []
    private let cropBorderView = UIView()
    /// 裁剪窗（view 坐标；每布局重算，确认时以它为准）。
    private var cropRect = CGRect.zero
    private var didSetupZoom = false
    private var lastZoomBounds = CGSize.zero

    init(image: UIImage, aspectRatio: CGFloat) {
        self.sourceImage = image
        self.aspectRatio = aspectRatio > 0 ? aspectRatio : 1
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        topBar.backgroundColor = UIColor.black
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(UIColor.white, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(self.didTapCancel), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        titleLabel.text = "裁剪"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = UIColor.white
        titleLabel.textAlignment = .center
        confirmButton.setTitle("确认", for: .normal)
        confirmButton.setTitleColor(BearyColors.orange, for: .normal)
        confirmButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        confirmButton.addTarget(self, action: #selector(self.didTapConfirm), for: .touchUpInside)
        confirmButton.bearyAddPressFeedback()
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = UIColor.black
        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit
        hintLabel.text = "双指缩放，拖动调整"
        hintLabel.font = UIFont.systemFont(ofSize: 13)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.textAlignment = .center
        cropBorderView.layer.borderWidth = 1
        cropBorderView.layer.borderColor = UIColor.white.cgColor
        cropBorderView.isUserInteractionEnabled = false
        for v in [topBar, scrollView, hintLabel, cancelButton, titleLabel, confirmButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(topBar)
        topBar.addSubview(cancelButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(confirmButton)
        view.addSubview(scrollView)
        scrollView.addSubview(imageView)
        view.addSubview(hintLabel)
        // 遮罩四块先加、白框最后加（白框须在遮罩之上；两者均按帧定位，不走约束）。
        for _ in 0..<4 {
            let dim = UIView()
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            dim.isUserInteractionEnabled = false
            view.addSubview(dim)
            dimViews.append(dim)
        }
        view.addSubview(cropBorderView)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            confirmButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            hintLabel.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCropWindow()
        // 首帧与旋转后（滚动区尺寸变了）都重算缩放、回到盖满居中。
        if !didSetupZoom || scrollView.bounds.size != lastZoomBounds {
            didSetupZoom = true
            setupImageZoom()
        }
    }

    /// 裁剪窗：按 aspectRatio（宽/高），在滚动区内留 16pt 边距的前提下
    /// 取最大窗并居中；遮罩四块 + 白框按窗定位。
    /// aspectRatio == 1 时窗为边长 = 滚动区短边 - 32 的正方形，与旧编辑器一致。
    private func layoutCropWindow() {
        let bounds = scrollView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let maxWidth = max(bounds.width - 32, 0)
        let maxHeight = max(bounds.height - 32, 0)
        var windowWidth = maxWidth
        var windowHeight = windowWidth / aspectRatio
        if windowHeight > maxHeight {
            windowHeight = maxHeight
            windowWidth = windowHeight * aspectRatio
        }
        let rectInScroll = CGRect(x: (bounds.width - windowWidth) / 2, y: (bounds.height - windowHeight) / 2, width: windowWidth, height: windowHeight)
        let origin = scrollView.frame.origin
        cropRect = CGRect(x: origin.x + rectInScroll.minX, y: origin.y + rectInScroll.minY, width: windowWidth, height: windowHeight)
        cropBorderView.frame = cropRect
        if dimViews.count == 4 {
            let scrollFrame = scrollView.frame
            dimViews[0].frame = CGRect(x: scrollFrame.minX, y: scrollFrame.minY, width: scrollFrame.width, height: cropRect.minY - scrollFrame.minY)
            dimViews[1].frame = CGRect(x: scrollFrame.minX, y: cropRect.maxY, width: scrollFrame.width, height: scrollFrame.maxY - cropRect.maxY)
            dimViews[2].frame = CGRect(x: scrollFrame.minX, y: cropRect.minY, width: cropRect.minX - scrollFrame.minX, height: cropRect.height)
            dimViews[3].frame = CGRect(x: cropRect.maxX, y: cropRect.minY, width: scrollFrame.maxX - cropRect.maxX, height: cropRect.height)
        }
    }

    /// 图按滚动区等比适配；最小缩放 = 刚好盖满裁剪窗（窗内永不露底），初始即该缩放并居中。
    private func setupImageZoom() {
        let bounds = scrollView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let imageSize = sourceImage.size
        guard imageSize.width > 0 && imageSize.height > 0 else { return }
        lastZoomBounds = bounds.size
        let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        let windowWidth = cropRect.width > 0 ? cropRect.width : bounds.width
        let windowHeight = cropRect.height > 0 ? cropRect.height : bounds.height
        let coverScale = max(windowWidth / fitted.width, windowHeight / fitted.height)
        scrollView.minimumZoomScale = coverScale
        scrollView.maximumZoomScale = max(coverScale * 4, coverScale + 1)
        scrollView.zoomScale = coverScale
        let offsetX = max((scrollView.contentSize.width - bounds.width) / 2, 0)
        let offsetY = max((scrollView.contentSize.height - bounds.height) / 2, 0)
        scrollView.contentOffset = CGPoint(x: offsetX, y: offsetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 内容小于滚动区时居中（否则缩放后图会贴一边）；center 不受缩放变换影响。
        let boundsSize = scrollView.bounds.size
        let offsetX = max((boundsSize.width - scrollView.contentSize.width) * 0.5, 0)
        let offsetY = max((boundsSize.height - scrollView.contentSize.height) * 0.5, 0)
        imageView.center = CGPoint(x: scrollView.contentSize.width * 0.5 + offsetX, y: scrollView.contentSize.height * 0.5 + offsetY)
    }

    @objc private func didTapConfirm() {
        if let cropped = croppedImage() {
            onConfirm?(cropped)
        }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func didTapCancel() {
        // 取消不回调：调用方 pending/预览/移除钮状态全程不动。
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 按窗裁：窗（view 坐标）→ 滚动区坐标 → 图视图坐标（convert 计入缩放变换）
    /// → 点坐标 → 像素坐标；先把原图方向归一化再裁，避免朝向图的像素坐标错位。
    private func croppedImage() -> UIImage? {
        guard cropRect.width > 0 && cropRect.height > 0 else { return nil }
        guard imageView.bounds.width > 0 && imageView.bounds.height > 0 else { return nil }
        let rectInScroll = scrollView.convert(cropRect, from: view)
        let rectInImageView = imageView.convert(rectInScroll, from: scrollView)
        // 方向归一化：按 size 重绘，原朝向 baked 进像素，cgImage 尺寸即 size×scale。
        let format = UIGraphicsImageRendererFormat()
        format.scale = sourceImage.scale
        let normalized = UIGraphicsImageRenderer(size: sourceImage.size, format: format).image { _ in
            self.sourceImage.draw(in: CGRect(origin: .zero, size: self.sourceImage.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        let scaleX = normalized.size.width / imageView.bounds.width
        let scaleY = normalized.size.height / imageView.bounds.height
        var pixelRect = CGRect(
            x: rectInImageView.minX * scaleX,
            y: rectInImageView.minY * scaleY,
            width: rectInImageView.width * scaleX,
            height: rectInImageView.height * scaleY
        )
        pixelRect = pixelRect.integral
        pixelRect = pixelRect.intersection(CGRect(origin: .zero, size: normalized.size))
        guard pixelRect.width > 0 && pixelRect.height > 0 else { return nil }
        // cgImage 按像素裁：点坐标须乘 scale（size 是 pt，cgImage 是像素）。
        let cgRect = CGRect(
            x: pixelRect.minX * normalized.scale,
            y: pixelRect.minY * normalized.scale,
            width: pixelRect.width * normalized.scale,
            height: pixelRect.height * normalized.scale
        )
        guard let croppedCG = cgImage.cropping(to: cgRect) else { return nil }
        return UIImage(cgImage: croppedCG, scale: normalized.scale, orientation: .up)
    }
}

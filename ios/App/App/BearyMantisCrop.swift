import UIKit
import Mantis

// MARK: - Mantis 裁剪接入（Mantis-spm 3.1.1，iOS 15+）
//
// 两处调用方（编辑资料头像/封面、编辑器选图）共用。行为与旧
// BearyImageCropViewController 一致：
// - 固定比例：头像/编辑器 1:1、封面按本页预览比例，比例切换钮不出现
//   （presetFixedRatioType = .alwaysUsingOnePresetFixedRatio）。
// - 旋转拨盘隐藏（旧裁剪器没有旋转），只保留双指缩放＋拖动。
// - 确认先退场再回调（#952 同款口径）：回调里若弹提示（编辑资料图超限）
//   不会被仍呈现的裁剪页吞掉；取消不回调、不碰调用方状态。
// - 裁剪失败留在页内、toast 重试（旧裁剪页同款口径），不退场。
// - 大图走 Mantis 自带的大图模式（maxImagePixelCount）：超限图显示用降采样、
//   裁剪走 CIImage 管线、出图仍保留原分辨率；只是库内防护，不宣称修掉
//   正在诊断的裁剪页黑屏问题。
// - 旧 BearyImageCropViewController.swift 保留在工程内作兜底（仍编译、
//   不再被调用方使用），Mantis 若出问题可切回。
// 版本口径：钉在 3.1.1（upToNextMajorVersion，不会滑到要求 iOS 17 的
// 未来 4.x）；3.1.1 的 Package.swift 声明 iOS 15，与本 App 部署目标
// 15.0 一致，无须抬部署目标、无须 iOS 版本分流。

enum BearyMantisCrop {

    /// 按固定比例建一个 Mantis 裁剪页（fullScreen，与旧裁剪页一致）。
    static func makeCropViewController(image: UIImage, aspectRatio: CGFloat) -> Mantis.CropViewController {
        var config = Mantis.Config()
        config.presetFixedRatioType = .alwaysUsingOnePresetFixedRatio(ratio: Double(aspectRatio > 0 ? aspectRatio : 1))
        config.cropViewConfig.showAttachedRotationControlView = false
        config.cropViewConfig.maxImagePixelCount = 4096 * 4096
        let cropViewController = Mantis.cropViewController(image: image, config: config)
        cropViewController.modalPresentationStyle = .fullScreen
        return cropViewController
    }
}

/// Mantis 裁剪回调转接：delegate 是 weak，调用方须强持有本对象直到
/// 回调跑完（见两处 presentCropEditor 的 mantisCropHandler 属性），
/// 回调结束由 onFinished 清掉持有。
final class BearyMantisCropHandler: NSObject, CropViewControllerDelegate {

    private let onCrop: (UIImage) -> Void
    private let onFinished: () -> Void

    init(onCrop: @escaping (UIImage) -> Void, onFinished: @escaping () -> Void) {
        self.onCrop = onCrop
        self.onFinished = onFinished
    }

    func cropViewControllerDidCrop(_ cropViewController: Mantis.CropViewController, cropped: UIImage, transformation: Transformation, cropInfo: CropInfo) {
        cropViewController.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.onCrop(cropped)
            strongSelf.onFinished()
        }
    }

    func cropViewControllerDidCancel(_ cropViewController: Mantis.CropViewController, original: UIImage) {
        cropViewController.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.onFinished()
        }
    }

    func cropViewControllerDidFailToCrop(_ cropViewController: Mantis.CropViewController, original: UIImage) {
        BearyToast.show(in: cropViewController.view, message: "裁剪失败，请重试")
    }
}

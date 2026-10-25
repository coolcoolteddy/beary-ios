import AVFoundation
import UIKit

/// 相机拍摄失败原因。调用方按原因提示用户；`.cancelled` 表示用户主动取消，
/// 调用方一般直接忽略、不弹提示。
enum BearyCameraFailure {
    case cameraUnavailable
    case permissionDenied
    case permissionRestricted
    case cancelled
}

/// 编辑器拍摄入口的 helper（只封装拍摄流程，不碰编辑器 UI）。
///
/// 流程：先查 `UIImagePickerController.isSourceTypeAvailable(.camera)`，
/// 再查相机权限（`AVCaptureDevice` 视频权限）；任一不可用时不弹系统框，
/// 直接走 `completion` 的失败分支，由调用方提示（例如 toast 或去设置引导）。
/// 拍完回传原图 `UIImage`，调用方走现有管线处理：
/// `BearyImagePrep.jpegData` / `thumbData` 压缩 → `BearyAPI.shared.uploadImage`
/// 上传（与相册 `PHPicker` 选图后的 `startUpload` 同款参数：全图 1600 / 0.85、
/// 缩略图 480）。本 helper 不做压缩、不上传、不写草稿。
/// Info.plist 的 `NSCameraUsageDescription` 文案已存在，本文件不用改 plist。
/// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，
/// 不用 if-let 简写。无 SF Symbol、无 UIGlassEffect、无新增颜色。
/// 注意：pbxproj 注册由总协调统一做；调用方无需持有本实例，
/// 本类在拍摄期间自持（完成/取消后自动释放）。
final class BearyCameraPicker: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    private static var activePickers: [BearyCameraPicker] = []

    private var completion: ((Result<UIImage, BearyCameraFailure>) -> Void)?

    /// 从调用方控制器弹出相机。`completion` 成功时为拍到的原图，
    /// 失败时为原因（调用方负责提示；`.cancelled` 一般忽略）。
    static func present(from presenter: UIViewController, completion: @escaping (Result<UIImage, BearyCameraFailure>) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            completion(.failure(.cameraUnavailable))
            return
        }
        let picker = BearyCameraPicker()
        picker.completion = completion
        activePickers.append(picker)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            picker.showPicker(from: presenter)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        picker.showPicker(from: presenter)
                    } else {
                        picker.finish(with: .failure(.permissionDenied))
                    }
                }
            }
        case .denied:
            picker.finish(with: .failure(.permissionDenied))
        case .restricted:
            picker.finish(with: .failure(.permissionRestricted))
        @unknown default:
            picker.finish(with: .failure(.permissionDenied))
        }
    }

    private func showPicker(from presenter: UIViewController) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            finish(with: .failure(.cameraUnavailable))
            return
        }
        let cameraPicker = UIImagePickerController()
        cameraPicker.sourceType = .camera
        cameraPicker.cameraCaptureMode = .photo
        cameraPicker.allowsEditing = false
        cameraPicker.delegate = self
        presenter.present(cameraPicker, animated: true)
    }

    private func finish(with result: Result<UIImage, BearyCameraFailure>) {
        if let handler = completion {
            completion = nil
            handler(result)
        }
        if let index = BearyCameraPicker.activePickers.firstIndex(where: { $0 === self }) {
            BearyCameraPicker.activePickers.remove(at: index)
        }
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let strongSelf = self else { return }
            if let photo = info[.originalImage] as? UIImage {
                strongSelf.finish(with: .success(photo))
            } else {
                strongSelf.finish(with: .failure(.cameraUnavailable))
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.finish(with: .failure(.cancelled))
        }
    }
}

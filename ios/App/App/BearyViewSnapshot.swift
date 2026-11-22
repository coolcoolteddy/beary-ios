import UIKit

// ===== 视图快照：把 UIView 渲成 UIImage 的共享样板 =====
// 三处视图导出共用：个人页壁纸快照（layer.render）、封面快照与 ID 卡存图
// （drawHierarchy）。scale 与渲染方式由调用方传；ID 卡的 3x 与存相册仍各留自己。
// 其余 UIGraphicsImageRenderer 调用都是图片加工（占位图、缩放、方向修正、
// 表情 chip 缩放等），不是视图导出，不走这里。
enum BearyViewSnapshot {

    enum RenderMethod {
        case drawHierarchy(afterScreenUpdates: Bool = true)
        case layer
    }

    static func image(of view: UIView, scale: CGFloat, bounds: CGRect? = nil, method: RenderMethod = .drawHierarchy(), opaque: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        let renderer = UIGraphicsImageRenderer(bounds: bounds ?? view.bounds, format: format)
        return renderer.image { context in
            switch method {
            case .drawHierarchy(let afterScreenUpdates):
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates)
            case .layer:
                view.layer.render(in: context.cgContext)
            }
        }
    }
}

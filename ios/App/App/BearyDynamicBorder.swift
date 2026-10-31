import UIKit
import ObjectiveC

// ===== 动态色边框集中重刷（115 批 1a）=====
// 根因：CALayer.borderColor 是 CGColor，赋值时即按当前 trait 解析固化，
// 深浅切换时系统只重解 UIColor（backgroundColor / textColor / tintColor），
// 不重解已赋给 layer 的 CGColor；此前全仓 114 处 `.layer.borderColor = 色.cgColor`
// 只有少数组件在各自 traitCollectionDidChange 里重赋，其余深浅切换后仍停留在旧主题色
// （line 浅 #dbdbdb / 深 #3a3a40、ink、blue 等动态色皆然；固定色橙/红/绿/白/clear 不受影响，
// 但同口径走本属性亦无害）。
// 修法（集中重刷，不单点修）：
// - 唯一写入口 `layer.bearyDynamicBorderColor`：写时先记下 UIColor、再按当前 trait 解析赋 CGColor；
// - 首次写时装上 UIView.traitCollectionDidChange 的集中重刷：色貌变化时，
//   每个视图按自身 trait 重新解析自己 layer 上记下的那支色重赋（状态色如选中 ink / 未选 line
//   以最后一次写的值为准，状态不被冲掉；已有各组件自带重刷与本机制同值重赋，无冲突）。
// - 子类 override 若调 super.traitCollectionDidChange（全仓现状皆如此），集中重刷经 super 走到；
//   不 override 的视图由 UIKit 直接调 UIView 的实现，同样走到。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

private var bearyDynamicBorderColorKey: UInt8 = 0

extension CALayer {
    /// 动态边框色的唯一写入口：记下 UIColor，borderColor 按当前 trait 解析。
    /// 读回记下的 UIColor（nil = 未走本入口，如旧代码残留或系统默认值）。
    var bearyDynamicBorderColor: UIColor? {
        get {
            return objc_getAssociatedObject(self, &bearyDynamicBorderColorKey) as? UIColor
        }
        set {
            BearyDynamicBorder.install()
            if let color = newValue {
                objc_setAssociatedObject(self, &bearyDynamicBorderColorKey, color, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                borderColor = color.cgColor
            } else {
                objc_setAssociatedObject(self, &bearyDynamicBorderColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                borderColor = nil
            }
        }
    }
}

enum BearyDynamicBorder {
    private static var installed = false

    /// 幂等安装：把 UIView.traitCollectionDidChange 与集中重刷实现对换一次。
    /// 对换后，原实现仍经 beary_traitCollectionDidChange 内的同名调用走到（见下），
    /// 不丢系统行为；重复调用直接返回，不二次对换。
    static func install() {
        guard installed == false else { return }
        installed = true
        guard let original = class_getInstanceMethod(UIView.self, #selector(UIView.traitCollectionDidChange(_:))),
              let swizzled = class_getInstanceMethod(UIView.self, #selector(UIView.beary_traitCollectionDidChange(_:))) else {
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
}

extension UIView {
    /// 集中重刷实现（与 UIView.traitCollectionDidChange 对换后生效）：
    /// 先走原实现，再在色貌变化时按新 trait 重解本视图 layer 上记下的边框色。
    /// 仅重刷本视图自己的 layer；子视图各有自己的 trait 回调，不在此遍历。
    @objc func beary_traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // 对换后，此调用即原 UIView 实现（非递归）。
        self.beary_traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            if let color = layer.bearyDynamicBorderColor {
                layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
            }
        }
    }
}

import UIKit

// ===== 引导共享小工厂 =====
// 注册后引导介绍页与 ID 卡表单页共用的小工厂: spacer 与黑按钮。
// 两处原先各写一套逐字相同 (黑按钮只差按压反馈接线), 抽到这里;
// 按压反馈由调用方以闭包传入, 各保自己的 touchDown／touchUp 接线。
// 黑色主按钮与 BearyButton 工厂的 surface2 灰底主钮不同。
// 标签类工厂字号行高各不同, 不硬合; 表单校验、生日 picker、城市级联不动。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调, 不用 async/await, 不用 if-let 简写。

enum BearyOnboardingFactory {

    static func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// 黑色主按钮 (ink 底、白字、buttonFont、圆角 12、高 52)。
    static func makeBlackButton(title: String, addPressFeedback: ((UIButton) -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = BearyOnboardingPalette.ink
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = BearyDynamicType.buttonFont()
        button.setTitle(title, for: .normal)
        button.layer.cornerRadius = 12
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        addPressFeedback?(button)
        return button
    }
}

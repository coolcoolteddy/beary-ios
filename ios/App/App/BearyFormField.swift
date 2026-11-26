import UIKit

// 表单输入行共享工厂：编辑资料 ×3／登录 ×3／邀请 ×1，共 7 处同形构造收口。
//
// 7 处原来各写一份：16pt 字＋墨色＋灰占位＋无边框＋不自动纠错＋delegate＋
// 敲键回调，约 8 行；口径还各定各的（字体缩放 capped vs scaled、键盘、
// 大小写、return 键、textContentType、清除钮、accessory 视图）。
// 本工厂一次写好，7 处共用。
//
// 各留的差异（不硬合）：占位文案（登录三处无占位，传 nil）、字号缩放
// 口径（scaling 参数：邀请页 capped，其余 scaled，各保现行行为）、
// 键盘／大小写／return 键／textContentType／清除钮／accessory 视图
// （各传现行值）；字段容器与回调里的校验逻辑各不相同，不动。
// borderStyle = .none 是 UITextField 默认值，编辑资料原来显式写、
// 其余四处不写，工厂里统一写明，行为 7 处都不变。
// translatesAutoresizingMaskIntoConstraints = false：编辑资料原来显式写；
// 登录／邀请的字段由 BearyInputContainer 在 init 里统一关掉，工厂里
// 再写一次是同一值，行为不变。
enum BearyFormField {
    /// 字号缩放口径：邀请页走 capped（固定高度容器防撑破），其余走 scaled。
    enum Scaling {
        case capped
        case scaled
    }

    /// 配好一个表单输入行：字号＋墨色＋灰占位＋无边框＋不自动纠错＋
    /// 键盘／大小写／return 键／textContentType／清除钮／accessory＋delegate＋敲键回调。
    /// - placeholder 为 nil 时不设占位（登录三处无占位）。
    /// - changeAction 为 nil 时不挂敲键回调（编辑资料名字／handle 两处无回调）。
    static func configure(
        _ field: UITextField,
        placeholder: String?,
        pointSize: CGFloat = 16,
        scaling: Scaling = .scaled,
        keyboardType: UIKeyboardType = .default,
        autocapitalizationType: UITextAutocapitalizationType = .sentences,
        returnKeyType: UIReturnKeyType = .default,
        textContentType: UITextContentType? = nil,
        clearButtonMode: UITextField.ViewMode = .never,
        inputAccessoryView: UIView? = nil,
        delegate: UITextFieldDelegate? = nil,
        changeTarget: Any? = nil,
        changeAction: Selector? = nil
    ) {
        let font: UIFont
        switch scaling {
        case .capped:
            font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: pointSize))
        case .scaled:
            font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: pointSize))
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = font
        field.adjustsFontForContentSizeCategory = true
        field.textColor = BearyColors.ink
        if let placeholder {
            // 占位色走 BearyColors.gray（与各页原 attributedPlaceholder 同口径）。
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: BearyColors.gray,
                .font: font,
            ])
        }
        field.borderStyle = .none
        field.keyboardType = keyboardType
        field.autocapitalizationType = autocapitalizationType
        field.autocorrectionType = .no
        field.textContentType = textContentType
        field.returnKeyType = returnKeyType
        field.clearButtonMode = clearButtonMode
        field.inputAccessoryView = inputAccessoryView
        field.delegate = delegate
        if let changeAction {
            field.addTarget(changeTarget, action: changeAction, for: .editingChanged)
        }
    }
}

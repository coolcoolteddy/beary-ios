import UIKit

// 搜索输入框共享工厂：主搜索／@选人／私信内搜索三处同形构造收口。
//
// 三处原来各写一份：字号＋自适应字号＋墨色＋灰占位＋return 键＋delegate＋
// 敲键回调，约 8 行；口径还各定各的（字号 16 vs 15、capped vs scaled、
// @选人漏了 autocorrectionType = .no）。本工厂一次写好，三处共用。
//
// 各留的差异（不硬合）：占位文案、字号（pointSize 参数）、缩放口径
// （scaling 参数：主搜索 capped、其余 scaled，各保现行行为）；
// 搜索框容器与回调里的查询逻辑各不相同，不动。
// contentVerticalAlignment = .center 本就是 UITextField 默认值，
// @选人原来显式写、另两处不写，工厂里统一写明，行为三处都不变。
enum BearySearchField {
    /// 字号缩放口径：主搜索走 capped（固定高度容器防撑破），其余走 scaled。
    enum Scaling {
        case capped
        case scaled
    }

    /// 配好一个搜索输入框：字号＋灰占位＋return 键＋不自动纠错＋delegate＋敲键回调。
    static func configure(
        _ field: UITextField,
        placeholder: String,
        pointSize: CGFloat,
        scaling: Scaling,
        delegate: UITextFieldDelegate?,
        changeTarget: Any?,
        changeAction: Selector
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
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: BearyColors.gray,
            .font: font,
        ])
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.contentVerticalAlignment = .center
        field.delegate = delegate
        field.addTarget(changeTarget, action: changeAction, for: .editingChanged)
    }
}

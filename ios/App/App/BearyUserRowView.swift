import UIKit

// MARK: - BearyUserRowView：用户行共享组件
//
// 三处同形（好友行 BearyFriendCell、搜索用户行 makeUserRow、拉黑行
// BearyBlockedUserCell）共用布局与字号：头像 44（leading 16）、名字
// cardTitleFont／ink／1 行、handle scaledFont(13)／gray／1 行，名字
// top +14、leading 71，handle top = 名字 bottom +1、leading 71、
// bottom ≤ -14。各留自己的尾部控件（好友 ⋯ 钮、搜索 chevron、拉黑
// 「解除拉黑」钮）与 label 类（搜索的 BearyRoundedMarkLabel 作参数传入）。
// @选人行（BearyComposerPickers）是另一套行规（leading 68、top 12、
// gap 2、行高 ≥64），只作参数化参考、不硬合：数值收在 Layout 里，
// 默认值即三处现行值。
// 本组件只进 App target（同 BearyAvatarView 前例：测试 target 不用它，
// 依赖的 BearyAvatarView／BearyDynamicType 不在 BearyCoreTests 内）。
final class BearyUserRowView: UIView {

    /// 行规数值；默认值即三处现行值。
    struct Layout {
        var avatarSize: CGFloat = 44
        var avatarLeading: CGFloat = 16
        var textLeading: CGFloat = 71
        var textTop: CGFloat = 14
        var textGap: CGFloat = 1
        var textBottom: CGFloat = 14
        var trailingGap: CGFloat = 8
        var trailingInset: CGFloat = 16
    }

    /// 头像上下锚定：三处现行口径各不相同，各留原样——
    /// 好友行居中（centerY＋上下 ≥14），搜索行顶锚＋底 ≤-14，
    /// 拉黑行顶锚＋底 -14 定死（行高 ≥72 另在 cell 里）。
    enum AvatarPin {
        case centered
        case topFlexible
        case topExact
    }

    let avatarView = BearyAvatarView()
    let nameLabel: UILabel
    let handleLabel: UILabel
    /// 尾部控件（调用方自建自有；本组件只负责居中＋右 -16，自身尺寸调用方定）。
    let trailingView: UIView?

    init(nameLabel: UILabel = UILabel(), handleLabel: UILabel = UILabel(), trailingView: UIView? = nil, avatarPin: AvatarPin = .topFlexible, layout: Layout = Layout()) {
        self.nameLabel = nameLabel
        self.handleLabel = handleLabel
        self.trailingView = trailingView
        super.init(frame: .zero)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1
        addSubview(avatarView)
        addSubview(nameLabel)
        addSubview(handleLabel)
        if let trailingView = trailingView {
            trailingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(trailingView)
        }
        var constraints: [NSLayoutConstraint] = [
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.avatarLeading),
            avatarView.widthAnchor.constraint(equalToConstant: layout.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: layout.avatarSize),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: layout.textTop),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.textLeading),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: layout.textGap),
            handleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.textLeading),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -layout.textBottom),
        ]
        switch avatarPin {
        case .centered:
            constraints += [
                avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
                avatarView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: layout.textTop),
                avatarView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -layout.textBottom),
            ]
        case .topFlexible:
            constraints += [
                avatarView.topAnchor.constraint(equalTo: topAnchor, constant: layout.textTop),
                avatarView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -layout.textBottom),
            ]
        case .topExact:
            constraints += [
                avatarView.topAnchor.constraint(equalTo: topAnchor, constant: layout.textTop),
                avatarView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -layout.textBottom),
            ]
        }
        if let trailingView = trailingView {
            constraints += [
                trailingView.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailingView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layout.trailingInset),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingView.leadingAnchor, constant: -layout.trailingGap),
                handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingView.leadingAnchor, constant: -layout.trailingGap),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

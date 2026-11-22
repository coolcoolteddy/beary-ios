import UIKit

// ===== BearyTopBar 全屏页共用顶栏（第九遍扫查第 2 条）=====
// 返回钮＋居中标题＋钉安全区顶，各页共用、各留自己的标题文本与返回动作。
// 收掉的重复：返回钮 9 行逐字相同 ×5 文件（景深背景／九宫格／Plus／照片／
// 个人页 modal 顶栏的 .system 变体见下方 makeBackButton）＋标题 17 bold
// 居中＋钉位四行（安全区顶／左右贴边）。
// 高度口径（Li 2026-11-22 定）：简单全屏页统一 ≥44，用 `.minimum(44)`
// （≥44 required ＋ ==44 defaultHigh——常规字号下定值，大字号时标题的
// required 上下不等式把下限抬高、栏随字长高，见九宫格与照片页原注释）；
//  设置子页壳 52–88 另有自己的 BearySettingsSubpageTopBar
// （见 BearySettingsSubpages.swift），不走这里。
// 不收：引导页顶栏（32pt 图标＋「返回上一页」＋点状进度＋跳过钮，
// 结构不同）、个人页 modal 顶栏整条（另有分享／更多钮、动高 0↔44、
// iPad 600 居中——它只用 makeBackButton 收返回钮本体）。
final class BearyTopBar: UIView {

    /// 顶栏高度口径：简单全屏页一律 `.minimum(44)`（Li 2026-11-22 定）。
    enum Height {
        /// 钉死：== required。简单页不用（统一走 .minimum(44)），仅留作通用口径。
        case fixed(CGFloat)
        /// 最小高：≥ required ＋ == defaultHigh（九宫格／照片：44）——
        /// 常规字号下定值，大字号时标题的 required 上下不等式把下限
        /// 抬高、栏随字长高；无定值时顶栏会被 solver 撑满整页。
        case minimum(CGFloat)
    }

    /// 标题左限位。
    enum TitleLeading {
        /// ≥ 返回钮 trailing ＋ constant（景深背景／Plus／照片／标签：8）。
        case afterBackButton(CGFloat)
        /// ≥ 顶栏 leading ＋ constant（九宫格：52）。
        case fromBarLeading(CGFloat)
    }

    /// 标题 label（照片页标题交叉淡变直接用它；其余页只读 `title`）。
    let titleLabel: UILabel

    /// 标题文本（标签页在 init 时传 `"#" + tag`、照片页初始为空、之后改写）。
    var title: String? {
        get { titleLabel.text }
        set { titleLabel.text = newValue }
    }

    private let backButton: UIButton
    private let onBack: () -> Void

    init(
        title: String?,
        height: Height = .fixed(44),
        backgroundColor: UIColor = BearyColors.bg,
        backButtonType: UIButton.ButtonType = .custom,
        titleLeading: TitleLeading = .afterBackButton(BearySpace.sm),
        titleTrailing: CGFloat = -52,
        titleVerticalInset: CGFloat? = nil,
        titleNumberOfLines: Int = 1,
        onBack: @escaping () -> Void
    ) {
        self.onBack = onBack
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.numberOfLines = titleNumberOfLines
        labelValue.text = title
        self.titleLabel = labelValue
        self.backButton = Self.buildBackButton(type: backButtonType)
        super.init(frame: .zero)
        self.backgroundColor = backgroundColor
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        addSubview(backButton)
        addSubview(titleLabel)
        var constraints: [NSLayoutConstraint] = [
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BearySpace.lg),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: titleTrailing),
        ]
        switch titleLeading {
        case .afterBackButton(let constant):
            constraints.append(titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: constant))
        case .fromBarLeading(let constant):
            constraints.append(titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: constant))
        }
        if let inset = titleVerticalInset {
            constraints.append(titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: inset))
            constraints.append(titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset))
        }
        switch height {
        case .fixed(let value):
            constraints.append(heightAnchor.constraint(equalToConstant: value))
        case .minimum(let value):
            constraints.append(heightAnchor.constraint(greaterThanOrEqualToConstant: value))
            let fixedHeight = heightAnchor.constraint(equalToConstant: value)
            fixedHeight.priority = .defaultHigh
            constraints.append(fixedHeight)
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// 钉到父视图安全区顶（top／leading／trailing）；调用方随后把内容区
    /// 顶锚到 `topBar.bottomAnchor`。高度约束在 init 时已建。
    func pinToTop(of parent: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// 返回钮本体（×5 `.custom` ＋ ×2 `.system` 同形）：icon_back 24pt＋
    /// 墨色＋「返回」＋按压反馈。个人页 modal 顶栏只用这个工厂（它的顶栏
    /// 另有分享／更多钮与动高，不走整条 BearyTopBar）。
    static func makeBackButton(type: UIButton.ButtonType = .custom, target: Any?, action: Selector) -> UIButton {
        let buttonValue = buildBackButton(type: type)
        buttonValue.addTarget(target, action: action, for: .touchUpInside)
        return buttonValue
    }

    private static func buildBackButton(type: UIButton.ButtonType) -> UIButton {
        let buttonValue = UIButton(type: type)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }

    @objc private func backTapped() {
        onBack()
    }
}

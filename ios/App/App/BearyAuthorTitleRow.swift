import UIKit

/// 卡片与详情作者标题行六件套共享 helper（可复用资源第十七批第 1 项）。
///
/// 两页作者行是同一套搭建（名字＋皇冠＋垫片＋时间＋限时 pill＋心情）：
/// 间距 6、.firstBaseline、.fill，连「姓名→皇冠间距 6」注释都逐字相同。
/// 唯一差别是名字视图：卡片是 UILabel，详情是可点 UIButton——以参数传入，
/// 点按动作各留在调用方；其余五件与行栈、皇冠容器、垫片、时间文案
/// （已共享 `BearyVisibilityText.publishedRelativeString`，不动）全部共用。
///
/// 118 闪退口径（详情）：本行必须是 lazy 创建——皇冠容器高 == 名字视图高
/// 的约束要求两端已有共同祖先；调用方须先把 stack 入栈，再调
/// `installConstraints`（卡片／详情原来也是这个顺序）。
final class BearyAuthorTitleRow {

    /// 名字视图：卡片传 nameLabel，详情传 nameButton（点按动作各留在调用方）。
    let nameView: UIView

    let crownView: BearyCrownView = {
        let v = BearyCrownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// 皇冠容器：作者行是 .firstBaseline 栈，纯 UIView 的基线就是底边，
    /// 皇冠直接进栈时底边钉在名字基线上，中心比名字大写字母中心高约
    /// (19 − capHeight)/2 ≈ 3.6pt，即肉眼可见的“偏上”。容器与名字等高、
    /// 底边钉基线，皇冠在容器内居中后中心即落在 cap 中心附近（SF 度量下
    /// label 高度中心与 cap 中心差 <0.3pt），且等高约束随动态字号自动跟随。
    /// 隐藏时容器与皇冠同藏，不留 19pt 空位。
    let crownWrapView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    /// 标题行弹性垫片：横向 hugging/compression 均为最低（1），独吞标题行全部
    /// 剩余宽度，使徽章/皇冠紧贴名字、日期留在右缘；空间不足时垫片先缩到 0，
    /// 再由名字（defaultLow）截断。空 UILabel 自带基线，不破坏 firstBaseline 对齐。
    let titleSpacerLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        return lb
    }()

    let timeLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    /// 限时 pill（作者行时间后；13 semibold 蓝档，存活“限时”虚线边／到期“私密”实线边）。
    let limitedPillView = BearyLimitedPillView()

    let moodLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        lb.adjustsFontForContentSizeCategory = true
        lb.textColor = BearyColors.gray
        lb.numberOfLines = 1
        return lb
    }()

    private(set) lazy var moodStack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [moodLabel])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        st.spacing = moodSpacing
        st.alignment = .center
        st.isHidden = true
        return st
    }()

    private let moodSpacing: CGFloat

    /// 作者行六件套：名＋皇冠＋垫片＋时间＋限时 pill＋心情。
    lazy var stack: UIStackView = {
        let st = UIStackView(arrangedSubviews: [nameView, crownWrapView, titleSpacerLabel, timeLabel, limitedPillView, moodStack])
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .horizontal
        // 姓名→皇冠间距 6（2026-11-05 ChatGPT 间距跟进；徽章已下线摘掉，
        // 皇冠直接贴名字；整行统一间距，名字→皇冠、皇冠→时间等同值）。
        st.spacing = 6
        // 标题行对齐（Li 2026-10-27 定：两页统一按文字基线对齐）：feed 与
        // profile 均为 .firstBaseline（网页口径 display:flex;align-items:baseline，
        // 16.5 名与 14 时间、天气、心情按基线对齐）。
        st.alignment = .firstBaseline
        st.distribution = .fill
        return st
    }()

    /// 旧心情播放器视图（心情已缀正文末尾，作者行心情位一律隐藏；只留清除口径）。
    var moodEmoteView: BearyEmoteView?

    /// - Parameters:
    ///   - nameView: 名字视图（卡片 nameLabel／详情 nameButton）。
    ///   - moodSpacing: 心情栈间距（卡片 feed 3／profile 4，详情 3）。
    init(nameView: UIView, moodSpacing: CGFloat) {
        self.nameView = nameView
        self.moodSpacing = moodSpacing
    }

    /// 行内抗压／抱紧＋皇冠居中与 19pt 尺寸（容器与名字等高）。
    /// 须在 stack 入栈后调用（皇冠容器高 == 名字视图高要求两端已有共同祖先）。
    /// - Parameter crownPriority: 皇冠三处尺寸约束优先级（卡片 profile 用
    ///   required，其余 999；皇冠自身高恒为 required，与两页原口径一致）。
    func installConstraints(crownPriority: UILayoutPriority) {
        nameView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleSpacerLabel.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        titleSpacerLabel.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        crownView.setContentCompressionResistancePriority(.required, for: .horizontal)
        crownWrapView.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 皇冠在等高容器内居中（容器底边钉基线，中心即 cap 中心）。
        crownWrapView.addSubview(crownView)
        let crownWrapWidth = crownWrapView.widthAnchor.constraint(equalToConstant: 19)
        crownWrapWidth.priority = crownPriority
        let crownWrapHeight = crownWrapView.heightAnchor.constraint(equalTo: nameView.heightAnchor)
        crownWrapHeight.priority = crownPriority
        let crownWidth = crownView.widthAnchor.constraint(equalToConstant: 19)
        crownWidth.priority = crownPriority
        NSLayoutConstraint.activate([
            crownView.centerXAnchor.constraint(equalTo: crownWrapView.centerXAnchor),
            crownView.centerYAnchor.constraint(equalTo: crownWrapView.centerYAnchor),
            crownWrapWidth,
            crownWrapHeight,
            crownWidth,
            crownView.heightAnchor.constraint(equalToConstant: 19),
        ])
        moodStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// 皇冠显隐唯一入口：容器与皇冠同藏同显，容器留在栈内时不留 19pt 空位。
    func setCrownHidden(_ hidden: Bool) {
        crownWrapView.isHidden = hidden
        crownView.isHidden = hidden
        if hidden { crownView.stop() } else { crownView.start() }
    }

    /// 作者行心情位一律隐藏（心情缀正文末尾）；旧播放器视图一并摘掉。
    /// 卡片 refreshMoodView／详情 renderHeaderMeta／卡片 prepareForReuse 同款。
    func clearMood() {
        moodStack.isHidden = true
        moodLabel.text = nil
        moodEmoteView?.removeFromSuperview()
        moodEmoteView = nil
    }
}

/// 作者头像簇共享 helper：40pt 圆角容器内首字母＋图＋重试钮。
///
/// 容器本身各留调用方（卡片是 avatarContainer UIView，详情是 avatarButton）；
/// 簇内三视图、40／44 两尺寸与加载调用走这里。
/// 图底色作参数：卡片 imageView 底透明（容器 line 底透出）、详情 imageView 底 line。
final class BearyAuthorAvatar {

    /// 头像边长（卡片／详情同款 40pt）。
    static let size: CGFloat = 40
    /// 重试钮边长（卡片／详情同款 44pt）。
    static let retrySize: CGFloat = 44

    let initialLabel: UILabel = {
        let lb = UILabel()
        lb.translatesAutoresizingMaskIntoConstraints = false
        lb.font = UIFont.boldSystemFont(ofSize: 16)
        lb.textColor = BearyColors.gray
        lb.textAlignment = .center
        return lb
    }()

    let imageView: UIImageView

    let retryButton: BearyFeedRetryButton

    /// - Parameters:
    ///   - container: 头像容器（卡片 avatarContainer／详情 avatarButton）。
    ///   - retryTarget: 重试钮 target（卡片 self／详情 self）。
    ///   - retryAction: 重试钮 action（卡片 feedRetryTapped／详情 detailImageRetryTapped）。
    ///   - imageBackground: 图底色（卡片透明、详情 line）。
    init(container: UIView, retryTarget: Any?, retryAction: Selector, imageBackground: UIColor) {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 20
        iv.backgroundColor = imageBackground
        imageView = iv
        retryButton = bearyFeedRetryButton(target: retryTarget, action: retryAction)
        container.addSubview(initialLabel)
        container.addSubview(imageView)
        container.addSubview(retryButton)
        NSLayoutConstraint.activate([
            initialLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            retryButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: Self.retrySize),
            retryButton.heightAnchor.constraint(equalToConstant: Self.retrySize),
        ])
    }

    /// 头像加载（Feed 口径：失败亮重试钮；默认按 40pt×屏幕倍率下采样）。
    func load(url: URL?, downsampleToWidth: CGFloat? = nil) {
        bearyFeedLoadImage(into: imageView, url: url, retryButton: retryButton, downsampleToWidth: downsampleToWidth ?? Self.size * UIScreen.main.scale)
    }

    /// 清图：取消在途加载、藏重试钮、清重试 URL（首字母文案／显隐各留调用方）。
    func clear() {
        imageView.bearySetImage(url: nil, placeholder: nil)
        retryButton.isHidden = true
        retryButton.retryURL = nil
    }
}

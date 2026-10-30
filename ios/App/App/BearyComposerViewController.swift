import UIKit
import PhotosUI

// ===== beary 原生编辑器（第二阶段 + 主线闭环第一块 + 网页对齐批）=====
// 只负责写日记：正文 + 心情 + 天气 + @ + 引用 + 图片（上限 9 张）。
// 编辑模式复用同一界面：正文/心情/天气/图片/引用/@ 可改，
// 不走新日记草稿流（不读不写 beary_draft_v3、不复用新篇 client_req）。
// iCity：新建默认私密（顶栏可见性钮，编辑模式隐藏），限时行在工具栏上方固定一行。
// C1 段落顺序：正文 → 已选 Chip 行 → 图片预览 → 状态行 → 引用；
// A3：规则框已移出内容栈，锚在工具栏上方（不随正文滚动，键盘顶起工具栏时跟走）；
// 工具栏贴键盘上方（始终可见，不随正文滚动），心情/天气/@ 改工具栏上方选择条
// （同一时刻只展开一条，点工具栏钮切换、点 Chip 行打开对应条）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。
// 文案一律中文；深浅色一律用 BearyColors 的动态色（含语义红 red 与图片上深色衬底 scrim）。
// 网络数据一律不用 force unwrap；图片移除只动本地与 key 列表，不调服务端；
// C11：删图无确认，删后 10 秒内可撤销（缓冲提交后才删本地文件，见 deleteImageItemWithUndo）。

/// 64 包反馈修（第 14 项）+ 编辑器批修正：正文段落 lineHeightMultiple=1.7
/// 会把系统 caret 拉到行片段高（约 32pt），比 16pt 字大一圈；64 包的“居中收敛”
/// 仍不对准——TextKit 下 1.7 倍行高的额外高度按比例撑在 ascent/descent 上，
/// 字形基线在行片段内并不居中（基线 = 片段顶 + ascender × 倍数），居中 caret
/// 会比字形偏上约 4pt、底部也够不着字形底。故 caret 改按基线锚定：
/// 高 = ascender − descender，顶 = 基线 − ascender（即片段顶 + ascender × (倍数 − 1)），
/// 宽与 x 不动；选区手柄不走 caretRect，不受影响。倍数优先取编辑器设定的固定值
/// （见 fixedLineHeightMultiple）：光标处属性 lookup 在输入法提交文本上不可靠——
/// 提交文本可能不带段落样式，且 UITextView 会把 typingAttributes 同步成光标处属性，
/// 两路同时失效就会回退到居中旧口径、光标偏上约 4pt（99 包真机实测正是此状）；
/// 未设定固定值时才走光标处 lookup（已填文本取该处属性、空文本取 typingAttributes），
/// 取不到时回退居中旧口径；
/// 字体取 typingAttributes 优先（attributedText 回填后 textView.font 可能取不到，
/// 此时旧守卫会直接返回 32pt 高 caret，正是对不准的另一半原因）。
private final class BearyBodyTextView: UITextView {
    /// 正文编辑器恒定的行高倍数，由 Composer 在 buildTextArea 里与 typingAttributes
    /// 用同一个 bodyParagraph 一并设定；本类只用于正文编辑器，倍数恒定。
    var fixedLineHeightMultiple: CGFloat?
    private func caretFont() -> UIFont? {
        if let typed = typingAttributes[.font] as? UIFont {
            return typed
        }
        return font
    }

    private func lineHeightMultiple(at position: UITextPosition) -> CGFloat? {
        let offset = self.offset(from: beginningOfDocument, to: position)
        let text = attributedText ?? NSAttributedString()
        if text.length > 0 {
            let index = min(max(offset - 1, 0), text.length - 1)
            if let style = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
               style.lineHeightMultiple > 0 {
                return style.lineHeightMultiple
            }
        }
        if let style = typingAttributes[.paragraphStyle] as? NSParagraphStyle,
           style.lineHeightMultiple > 0 {
            return style.lineHeightMultiple
        }
        return nil
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        // 打字光标下移修：不再用系统 caret 高度与行高之差守门是否锚定——空行/拼音
        // 组合中系统 caret 约 19pt 时旧守卫不通过、落字后约 32pt 时才通过，落字瞬间
        // 高位→低位切换即光标下掉一截；只要倍数 > 1 就无条件按基线锚定，三态基线一致。
        guard rect.height > 0, let caretFont = caretFont(), caretFont.lineHeight > 0 else { return rect }
        let multiple = fixedLineHeightMultiple ?? lineHeightMultiple(at: position)
        if let multiple = multiple, multiple > 1.0 {
            let height = caretFont.ascender - caretFont.descender
            guard height > 0 else { return rect }
            rect.origin.y = rect.origin.y + caretFont.ascender * (multiple - 1)
            rect.size.height = height
            return rect
        }
        let centerY = rect.midY
        rect.origin.y = centerY - caretFont.lineHeight / 2
        rect.size.height = caretFont.lineHeight
        return rect
    }
}

final class BearyComposerViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate {

    // MARK: - 公开接口

    /// 发布成功，传新日记 id。
    var onPublished: ((String) -> Void)?
    /// 编辑保存成功：传更新后的完整 Entry（内容/图片/心情/天气/引用均为编辑器终态，
    /// 引用已清时 quoteId 与 quote 均为 nil）。调用方据此定向刷新各面（不整表刷新）。
    var onUpdated: ((Entry) -> Void)?
    /// 关闭编辑器（保留草稿或丢弃后均走这里；编辑模式取消也走这里，不删原日记）。
    var onCancelled: (() -> Void)?
    /// 发布时未登录走这里，不发请求。
    var onRequireLogin: (() -> Void)?

    // MARK: - 编辑模式

    /// 非 nil 即编辑模式：回填正文/心情/天气/图片/@；引用可改可删。
    private var editingEntry: Entry?
    private var isEditMode: Bool { editingEntry != nil }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    init(entry: Entry) {
        self.editingEntry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 心情顺序（硬编码，勿用 moodNames.keys.sorted()，会打乱原顺序）

    private let moodOrder: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
        "candle", "flower", "letter", "paperplane", "sprout", "tea", "umbrella", "wish",
    ]

    /// 天气顺序：与 BearyText.weatherNames 字面顺序一致（勿用字典 keys 排序，会打乱顺序）。
    private let weatherOrder: [String] = [
        "sun", "cloud", "cloudy", "rain", "snow", "fog", "thunder", "wind", "night",
    ]

    /// 引用 lite 卡状态：展示用字段（作者/头像/图片/是否公开供 lite 卡用），不存整条 Entry。
    /// imgDims 只供 lite 卡图片条按原图比例定宽（面板选篇时取 Entry.imgDims；编辑锁定
    /// 的 Quote 结构本身无尺寸字段，故为 nil，走 118 兜底宽，不另发明尺寸来源）。
    private struct SelectedQuote {
        let entryId: String
        let content: String
        let createdAt: Int?
        let authorName: String?
        let authorAvatar: String?
        let images: [String]
        /// 补缺 P3-41：此处存“上次已知有效可见性”（过期即私密），非服务端 is_public 原值；
        /// 新选与恢复校验以 BearyEphemeral.isEffectivelyPublic 写入；编辑态锁定来自服务端直传
        /// Quote（无 ephemeral_until 字段，无法算有效态）暂留原值，见 lockedQuote 处注释。
        let isPublic: Bool?
        /// iCity：旧送达时间字段已废（面板选篇行不再挂 pill）；保留字段仅作解码兼容。
        let publishAt: Int?
        let imgDims: [String: [Int]]?
        /// 已删态：原日记已删时只剩 id，恢复时不按正常 lite 卡显示，见 refreshQuoteSection。
        /// 发布时已删引用不传 quoteId（服务端会拒），只作展示态保留到用户清除或发布。
        let isDeleted: Bool
    }

    private static let maxLength = 2000
    private static let maxImages = 9

    // MARK: - 状态

    private var selectedMood: String?
    private var selectedWeather: String?
    /// 新建模式的 @ 对象（编辑模式经 selectedRecipient 改选，见 refreshRecipientRow 编辑分支）。
    private var selectedRecipient: SearchUser?
    /// 通知对方：iCity @ 提醒无按篇开关——选人面板的开关值不再用于发布，
    /// 仅作面板初值占位保留，不触发重渲染、不进请求。
    private var notifyRecipient = true
    /// 新建模式的引用（编辑模式不用它，引用锁定，见 lockedQuote）。
    private var selectedQuote: SelectedQuote?
    /// 编辑模式原 @ 展示名（未动时回填展示；改选/清除后以 selectedRecipient/editMentionCleared 为准）。
    private var lockedRecipientName: String?
    /// 编辑模式原 @ 用户 id（未动时 PUT 省略 mentioned_user_id，服务端保留原值）。
    private var lockedMentionedUserId: Int?
    /// 编辑模式已清除 @（且未重新选人）：PUT 显式清 mentioned_user_id。
    private var editMentionCleared = false
    /// iCity：新建编辑器可见性初值硬编码私密（false），不读 UserDefaults、不记住上次选择。
    private var selectedVisibilityPublished = false
    /// 编辑模式的引用：初始为原值，可改可删（网页 PUT 同款：body 带新 quote_id；
    /// 删为空时 updateEntry 省略 quote_id，服务端按 null 写，旧引用即清掉）。
    private var lockedQuote: SelectedQuote?
    /// 编辑回填补拉单篇只做一次（quote 体缺失时）：避免已删引用（gone 只有 id、无正文）
    /// 补拉后仍无正文时反复请求。
    private var editQuoteFetchAttempted = false
    /// 引用 qp-mode 进出时保存/恢复的外层滚动位置（网页 qpPrevScroll 的 sheet 滚动等价；
    /// 正文 UITextView 关滚动、随内容生长，故无 textarea 内部滚动需要另存）。
    private var quotePanelSavedScrollOffset = CGPoint.zero
    private var quotePanelSavedScrollValid = false
    /// C1：工具栏上方选择条：同一时刻最多展开一条（心情/天气/写给），nil=全部收起。
    /// 旧附加栏三态（天气行独立开关／曾打开标记／工具压制标记／附加栏展开态）随双重入口删除而整组拆除，不再有“附加栏撑着显示天气行”的
    /// 压制状态机；天气 Lottie 显隐只看本值 + quotePanelOpen（见 updateWeatherPlayback）。
    private enum ToolStrip {
        case mood, weather, recipient
    }
    private var activeToolStrip: ToolStrip?
    /// C11：删图撤销缓冲（单槽，只留最近一次删除）：项本身不改字段（key/localFile/
    /// uploading/failed 原样保留），本地文件在提交前不删；10 秒内点撤销即按原位恢复。
    private struct PendingRemovedImage {
        let item: ComposerImageItem
        let index: Int
    }
    private var pendingRemovedImage: PendingRemovedImage?
    private var pendingUndoTimer: Timer?
    /// C11：撤销保留时长（秒）。到期未撤销即彻底删除：本地文件删除、key 丢弃（不调
    /// 服务端，与旧直接删除同款孤 key 口径），撤销入口随之消失。
    private static let imageUndoSeconds: TimeInterval = 10
    /// 草稿 pill / 写给选人钮的 present 在途标记（与 presentedViewController 守卫并用，防连点叠页）。
    private var isDraftBoxPresenting = false
    private var isRecipientPickerPresenting = false
    /// 图片编码走的后台串行队列（主线程只更新 UI）。
    /// 草稿整库读写不另起队列：一律走 BearyDraftStore.ioQueue（与草稿箱的
    /// saveAsync/deleteAsync 同一串行队列），旧读回写不再跨队列交错、不会把已删
    /// 草稿复活；写盘本身已是原子替换。
    private let imagePrepQueue = DispatchQueue(label: "beary.composer.imagePrep", qos: .userInitiated)
    private var draftClientReq: String?
    /// 当前正在写的草稿篇 id（v3 多槽键）：恢复/从箱打开时取该篇 draftId，
    /// 首次保存时生成；发布成功与丢弃只删这一篇，不碰其他篇。
    private var currentDraftId: String?
    /// 审计 P1-9：箱内删“正在写”草稿时被清掉的 draftId（onDeleteCurrentDraft 处记下），
    /// 供箱内撤销恢复时比对——只绑回正是这一篇的恢复，防串篇；新篇接管/重开/发布重置时清掉。
    private var clearedCurrentDraftId: String?
    private var isPublishing = false
    private var didAutoFocus = false
    private var draftTimer: Timer?
    private var editTimer: Timer?
    private var imageItems: [ComposerImageItem] = []
    /// 心情条单项：按钮 + 44 圆环 + 环内熊图 + 环内缺图回退名 + 下方名。
    private var moodItems: [(key: String, button: UIButton, ringView: UIView, emoteView: BearyEmoteView, fallbackLabel: UILabel, nameLabel: UILabel)] = []
    /// A2-4/B6-1 播放控制上次状态：面板可见性；一致时 updateMoodPlayback
    /// 直接返回，避免选择条刷新重复调用把动画反复从 0 重播。
    /// （2026-10-29 第 25 项：全播口径下选中态不再影响播放，选中心情缓存已删。）
    private var moodPlaybackPanelVisible: Bool?
    private var weatherButtons: [(key: String, button: UIButton)] = []
    /// Gemini 第一批（天气 Lottie 后台空转修）：94 接线时 9 个天气 Lottie 以
    /// animated:true 建在按钮 imageView 上，却无任何登记；refreshWeatherRowVisibility
    /// 只改 isHidden（隐藏不停播），updateMoodPlayback 只遍历 moodItems，天气行
    /// 收起/引用面板打开时 9 只仍在后台循环。登记只含 9 个天气项（“无”钮无 Lottie），
    /// 播放权统一交给 updateWeatherPlayback（心情 updateMoodPlayback 同款口径）。
    private var weatherEmoteViews: [(key: String, emoteView: BearyEmoteView)] = []
    /// 天气播放控制上次状态（心情 moodPlaybackPanelVisible/Selected 同款缓存）：
    /// 一致时直接返回，避免每次选择条刷新都把选中动画从 0 帧重播。
    private var weatherPlaybackVisible: Bool?
    private var weatherPlaybackSelected: String?
    /// 草稿保存级别：nil=未显示；2=草稿已保存；1=文字已保存，图片未保存；0=保存失败（红字）。
    private var draftStatusLevel: Int?
    /// 引用内嵌面板状态：当前 tab（timeline/liked/saved）与每 tab 缓存、加载序号。
    private var quotePanelOpen = false
    private var quotePanelTab = "timeline"
    private var quotePanelCache: [String: [Entry]] = [:]
    private var quotePanelSeq = 0
    private var quotePanelLoading = false
    private var quotePanelFailed = false

    // MARK: - 视图（段落顺序即网页版顺序，见文件头注释）

    private let topBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let publishButton = UIButton(type: .system)
    private let publishRingView = UIImageView()
    private let topSeparator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()
    /// A4-App：编辑器标题输入框（App 端，不依赖卡片渲染子项）。上限 30 字为建议值，
    /// Li 未填数字时先用它，可改（见 maxTitleLength）；空标题不做占位决定。
    /// R1：新建空标题仍省略不传（trimmedTitle() 为 nil）；编辑已有标题的日记
    /// 清空标题时 PUT 显式传空串（performUpdate 传 trimmedTitle() ?? ""），
    /// 后端按显式空串清为 NULL。标题以 titleField 文本为准（trimmedTitle()
    /// 归一化），不另设镜像状态。
    private static let maxTitleLength = 30
    private let titleField = UITextField()
    private let textView = BearyBodyTextView()
    /// 正文区高度约束（正式修法：随内容动态走，下限 140、上限由 updateTextViewHeight 按 sheet 封顶算）。
    private var textViewHeightConstraint: NSLayoutConstraint?
    /// 当前键盘高度（applyKeyboard 算出，编辑器批第 5 项）：updateTextViewHeight 的封顶
    /// 须再减它，否则正文帧底伸到键盘下方、末行被盖且内层滚到头也露不出来；
    /// 键盘收起/移出屏时为 0，WillChangeFrame 路径同值幂等。
    private var currentKeyboardHeight: CGFloat = 0
    /// 2026-10-29 第 28 项：键盘弹出前保存的滚动位置（收起时恢复原位）与
    /// 键盘可见跟踪（帧变化通知不重复保存，避免覆盖弹出时刻的原位）。
    private var keyboardSavedContentOffset: CGPoint?
    private var keyboardVisible = false
    /// S10：textViewDidChange 高度缓存（contentSize 高度作判据）；高度不变时跳过
    /// updateTextViewHeight + updatePreferredContentSize 的重算。注意不用换行符
    /// 计行：长段落视觉折行不产生换行符，用换行符判会漏掉折行导致编辑器不跟长。
    private var lastTextViewContentHeight: CGFloat?
    private let placeholderLabel = UILabel()
    // 图片预览（无标题、无 + 块；空时整条隐藏，添加走工具栏图片钮）
    private let imageScrollView = UIScrollView()
    private let imageStackView = UIStackView()
    // C1：工具栏贴键盘上方（见 buildLayout：底锚 keyboardLayoutGuide.topAnchor），
    // 不随正文滚动；选择条（toolStripStack）贴在它上方，引用面板打开时两者同藏，
    // scrollView 底锚随之在工具栏/选择条/整页三档切换（见 updateScrollBottomAnchoring）。
    private let toolbarContainer = UIView()
    private let toolStripStack = UIStackView()
    /// 工具栏上方固定一行限时行（新建模式可见，编辑模式隐藏、高度归零）。
    private let visibilityBar = UIView()
    /// 限时日记行（visibilityBar 唯一内容；编辑模式随整行隐藏）。
    private let ephemeralRow = UIView()
    /// 限时行开关：v6 起为自绘控件（BearyLimitedSwitch，见文件末尾），
    /// 圆钮内嵌限时图标、轨道黑/白随深浅反转；对外只用 isOn/isEnabled/valueChanged，与 UISwitch 旧调用点同口径。
    private let ephemeralSwitch = BearyLimitedSwitch()
    private let ephemeralTitleLabel = UILabel()
    private let ephemeralSubtitleLabel = UILabel()
    private var visibilityBarHeightConstraint: NSLayoutConstraint?
    private var scrollBottomToVisibilityConstraint: NSLayoutConstraint?
    private var scrollBottomToToolbarConstraint: NSLayoutConstraint?
    private var scrollBottomToStripConstraint: NSLayoutConstraint?
    private var scrollBottomToViewConstraint: NSLayoutConstraint?
    /// 2026-10-29 第 27 项：回应面板（心情条）改锚小熊按钮本体——条底贴工具栏顶
    /// （触发按钮行正上方），不再随 toolStripStack 锚在限时行上方；
    /// 限时行底锚随心情条开关在工具栏顶 / 心情条顶之间切换。
    private var visibilityBarBottomToToolbarConstraint: NSLayoutConstraint?
    private var visibilityBarBottomToMoodStripConstraint: NSLayoutConstraint?
    /// 关闭退场 B 修法：工具栏底锚两档——编辑态钉键盘顶（默认激活），
    /// 真正被 dismiss 时换钉自身 safeArea 底（初始不激活），簇随页滑走；
    /// 被其他 modal 盖住时的 viewWillDisappear 不换（见 viewWillDisappear 的 isBeingDismissed 判定）。
    private var toolbarBottomToKeyboardConstraint: NSLayoutConstraint?
    private var toolbarBottomToSafeAreaConstraint: NSLayoutConstraint?
    private var toolbarReanchoredForDismiss = false
    /// 补缺 P2-20（天气条独立锚点）：限时行天气档底锚（行底贴天气条顶）。
    private var visibilityBarBottomToWeatherConstraint: NSLayoutConstraint?
    /// 92 包整页列宽：窄屏贴边、宽 ≥821 时三件居中（顶栏/滚动区 640、工具栏 608，
    /// 与旧居中卡几何一致：卡 640、工具栏卡内边距 16）。只换外层水平约束，
    /// 不碰内容栈/心情/天气/引用/草稿/键盘逻辑；状态变化时才切换，避免每轮布局重算。
    private var topBarLeadingConstraint: NSLayoutConstraint?
    private var topBarTrailingConstraint: NSLayoutConstraint?
    private var toolbarLeadingConstraint: NSLayoutConstraint?
    private var toolbarTrailingConstraint: NSLayoutConstraint?
    private var scrollLeadingConstraint: NSLayoutConstraint?
    private var scrollTrailingConstraint: NSLayoutConstraint?
    private var topBarCenterXConstraint: NSLayoutConstraint?
    private var topBarWidthConstraint: NSLayoutConstraint?
    private var toolbarCenterXConstraint: NSLayoutConstraint?
    private var toolbarWidthConstraint: NSLayoutConstraint?
    private var scrollCenterXConstraint: NSLayoutConstraint?
    private var scrollWidthConstraint: NSLayoutConstraint?
    private var isColumnCentered = false
    /// 清单第 15 项：发布钮 / 草稿 pill 的显式宽度约束（点赞钮同款修法，见各自刷新函数）。
    private var publishWidthConstraint: NSLayoutConstraint?
    /// 5-21：发布中 spinner 位宽（发布中态 title 左边距）：spinner 图 18 + 与标题间隙 6。
    /// 赋值点（refreshPublishBusyState）与宽度重算注释（refreshPublishButtonWidth）两处同引本常量，
    /// 不再各自写死 24；宽度重算本身仍读 live 的 titleEdgeInsets（常态 6 / 发布中态本常量）。
    private static let publishSpinnerTitleInset: CGFloat = 24
    private var draftPillWidthConstraint: NSLayoutConstraint?
    private let toolbarSeparator = UIView()
    private let imageToolButton = BearyHit44Button(type: .system)
    private let moodToolButton = BearyHit44Button(type: .system)
    private let weatherToolButton = BearyHit44Button(type: .system)
    private let recipientToolButton = BearyHit44Button(type: .system)
    private let quoteToolButton = BearyHit44Button(type: .system)
    private let draftPillButton = UIButton(type: .system)
    /// 顶栏可见性钮（2026-10-30）：锁＝私密、地球＝公开，点按切换；取代正文区分段，
    /// 为唯一可见性入口；编辑模式隐藏（编辑不改可见性），限时开时锁死公开。
    private let visibilityButton = UIButton(type: .system)
    // 编辑器改版（2026-10-29）：心情/天气尖角弹出框（取代旧选择条）+ 框外收起层。
    private let moodCallout = BearyCalloutPickerView()
    private let weatherCallout = BearyCalloutPickerView()
    private let calloutDismissView = BearyCalloutDismissView()
    private enum CalloutKind { case mood, weather }
    private var activeCallout: CalloutKind?
    private var calloutTransitionGeneration = 0
    private static let calloutTransitionDuration: TimeInterval = 0.20
    private static let calloutTransitionOffset: CGFloat = 6
    private static let calloutHeight: CGFloat = 78
    // C1：已选中项轻量 Chip 行（正文下方）：心情/天气/写给各一枚，点 chip 打开对应选择条。
    private let selectedChipsRow = UIStackView()
    /// 审计 P1-3：Chip 行首行（心情/天气/写给单行态）；写给换行时脱离本行、改作
    /// selectedChipsRow 的第二行（见 layoutSelectedChips），不另建容器。
    private let selectedChipsFirstRow = UIStackView()
    /// 审计 P1-3：写给当前是否在独立第二行；viewDidLayoutSubviews 宽变化时
    /// 凭此 + 宽门限决定是否重算，避免移行触发布局 → 再移行的循环。
    private var selectedChipsRecipientOnSecondRow = false
    private var selectedChipsLastLayoutWidth: CGFloat = -1
    /// 审计 P1-8：选择条转场代次——每次 refreshToolStrip 显隐变化即 +1；旧转场
    /// 的 completion 凭代次过期作废，不再碰视图，快速连点只收敛到最后状态。
    private var toolStripTransitionGeneration = 0
    private let moodChipButton = BearyHit44Button(type: .system)
    private let weatherChipButton = BearyHit44Button(type: .system)
    private let recipientChipButton = BearyHit44Button(type: .system)
    // C11：删图撤销条（图片条下方）：文案 + 撤销钮，10 秒到期自动消失并提交删除。
    private let imageUndoBar = UIView()
    private let imageUndoLabel = UILabel()
    private let imageUndoButton = BearyHit44Button(type: .system)
    // 天气（图标 + 名 chip，首项“无”，选中墨色边框）
    private let weatherScrollView = UIScrollView()
    private let weatherStackView = UIStackView()
    // 状态行：编辑倒计时 + 草稿状态 + 字数圆环
    private let statusRow = UIStackView()
    private let editTimerLabel = UILabel()
    private let draftStatusGroup = UIStackView()
    private let draftStatusIcon = UIImageView()
    private let draftStatusLabel = UILabel()
    private let charRingView = UIView()
    private let charCountLabel = UILabel()
    /// C1：字数圆环组（数字已隐藏，只留圆环；见 buildToolbarRow）。
    private let charGroupStack = UIStackView()
    private var charTrackLayer: CAShapeLayer?
    private var charProgressLayer: CAShapeLayer?
    // @（pick 钮内的“@ 谁”钮 / chip；无按篇通知行）
    private let recipientSection = UIStackView()
    private let recipientLine = UIStackView()
    private let recipientPickButton = BearyComposerDashedPickButton()
    private let recipientChipView = UIView()
    private let recipientChipAvatar = UIImageView()
    private let recipientChipFallback = UILabel()
    private let recipientChipName = UILabel()
    private let recipientClearButton = BearyHit44Button(type: .system)
    private let notifyGroup = UIStackView()
    private let notifyCheckButton = BearyHit44Button(type: .system)
    private let notifyLabel = UILabel()
    // 心情：熊图条本身即选择条（标题行已删，选中名改由正文下方 Chip 行承载）。
    private let moodScrollView = UIScrollView()
    private let moodStackView = UIStackView()
    // 引用（lite 卡）+ 内嵌展开面板
    // C1：正文中部“引用一篇日记”全宽大按钮已删，引用唯一入口改工具栏引用钮；
    // 无引用时 quoteSection 只剩隐藏的 lite 卡与已删行，栈自动塌掉不留空位。
    private let quoteSection = UIStackView()
    /// 2-4+8-10（fixall-composer）：引用区复用共享 BearyQuoteCardView，自绘卡已删；
    /// 字号 13.5 / 图高 42 / 圆角 8 / 左 3pt 线随共享卡走。移除钮不进卡内，叠加在外层 wrap 上，
    /// 故卡本身点按不进详情（onTapped/onRetryTapped 均不接，见 buildQuoteSection）。
    private let quoteCardWrap = UIView()
    private let quoteCard = BearyQuoteCardView()
    private let quoteCardRemoveButton = BearyHit44Button(type: .system)
    /// 引用已删态行：灰字“引用的日记已删除”+ 右端“移除”钮（lite 卡隐藏时仍可清除引用，
    /// 否则已删引用会堵住引用入口，用户无法再选引用）。
    private let quoteDeletedRow = UIStackView()
    private let quoteDeletedLabel = UILabel()
    private let quoteDeletedRemoveButton = UIButton(type: .system)
    private let quotePanel = UIView()
    private let quoteTabBarContainer = UIView()
    private let quoteTabStack = UIStackView()
    private var quoteTabButtons: [UIButton] = []
    private let quotePanelSpinner = BearyRefreshIconView()
    /// 录屏批 (f)：加载态光转圈太空，加一句说明（与转圈同显同隐，见 loadQuotePanelTab）。
    private let quotePanelLoadingLabel = UILabel()
    private let quotePanelEmptyLabel = UILabel()
    private let quotePanelRetryButton = UIButton(type: .system)
    private let quotePanelRows = UIStackView()
    /// 录屏批 (b)：引用页标题保存/恢复——打开面板时标题改“选择引用”，关闭时
    /// 还原打开前的标题（“新日记”/“编辑日记”/“加载日记…”均按原样回，不硬编码）。
    private var quotePanelSavedTitle: String?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[Diag] composer-viewDidLoad-enter")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("viewDidLoad-enter")
        // 玻璃批：view 自身即 modal 卡片，底改 clear，玻璃背板钉满 bounds 垫在最底层（index 0），
        // 后续 build* 加的子视图自然在其上；呈现层文件不动。
        view.backgroundColor = UIColor.clear
        let glassBacking = BearyGlass.effectView(tint: BearyGlass.neutralTint)
        glassBacking.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(glassBacking, at: 0)
        NSLayoutConstraint.activate([
            glassBacking.topAnchor.constraint(equalTo: view.topAnchor),
            glassBacking.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            glassBacking.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glassBacking.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildLayout()
        buildTopBar()
        buildTitleField()
        buildTextArea()
        buildSelectedChipsRow()
        buildImageRow()
        buildImageUndoBar()
        buildToolbarRow()
        buildCallouts()
        buildWeatherRow()
        buildStatusRow()
        buildRecipientRow()
        buildMoodRow()
        buildQuoteSection()
        buildQuotePanel()
        if isEditMode {
            setupEditContent()
        } else {
            restoreDraft()
        }
        updateCountLabel()
        updatePublishState()
        refreshToolStrip()
        updateDraftPillCount()
        // 首帧高度预先算好（D-12 编辑器部分）：viewDidLoad 末尾即按内容栈 fitting
        // 定一次 preferredContentSize，呈现层首帧不再以 0 占位走 80%/88% 满高封顶；
        // 此时 view.bounds 可能仍为 0，updatePreferredContentSize 内用屏宽估算兜底，
        // viewDidLayoutSubviews 后再按真实宽纠正一次。
        updatePreferredContentSize()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NSLog("[Diag] composer-viewDidLoad-exit")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("viewDidLoad-exit")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 深浅切换时 CGColor 只在赋值时解析一次，必须重赋：心情环描边、
        // 天气 chip 描边、通知复选框描边、草稿 pill 描边、字数圆环轨道色
        // 全走已有刷新函数重算（心情熊图深浅变体由播放器内部切换，不重建条）。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshMoodButtons()
            refreshWeatherButtons()
            // 审计 16 项：深浅切换时心情 chip 的 emote 深浅变体须重取（浅色线条稿
            // 不可在深色底上冒充），走 refreshSelectedChips 重算图标与换行。
            refreshSelectedChips()
            refreshNotifyCheck()
            notifyCheckButton.layer.borderColor = BearyColors.line.cgColor
            draftPillButton.layer.borderColor = BearyColors.line.cgColor
            charTrackLayer?.strokeColor = BearyColors.line.cgColor
            updateCountLabel()
        }
    }

    // 看门狗修法（2026-10-27，74 包 .ips 定案）：布局轮次里重算 preferred 会与呈现层
    // 容器布局成环——测量值每轮漂移 >0.5pt 时 0.5pt 门限防不住，主线程转圈 10 秒触发
    // 系统 scene-update 看门狗杀进程。故只在宽变化时重算；天气开关/附加栏/图片/
    // 正文/引用等各入口都直接调 updatePreferredContentSize，不走这里，不会丢更新。
    // 首帧：viewDidLoad 已算一次，首个非 0 宽布局再纠正一次（lastLayoutWidth 初值 -1）。
    private var lastLayoutWidth: CGFloat = -1
    // 临时诊断（天气条 10/28，定根因后删除）：上一次已记录的布局后条带签名，
    // 用于 postLayout mark 只在条带状态/几何变化时记一次，避免每次布局都刷屏。
    private var lastPostLayoutStripSig: String = ""
    // 临时诊断（天气条 10/28 第二批，定根因后删除）：上一次已记录的“晴”钮展开详情签名，
    // 与 postLayout mark 同频（仅签名变化时记第一时点），避免每布局刷屏。
    private var lastWeatherDetailSig: String = ""

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 草稿 pill 宽度兜底（2026-10-29，同上）：每次布局后按当前标题重算一次宽度
        // 约束常量，约束若在某次布局中被打破也能在下次布局恢复；同值重设不触发重排。
        refreshDraftPillWidth()
        // 编辑器改版（2026-10-29）：弹出框打开时，尖角跟随工具栏图标中心；
        // 放宽门之前（键盘只动工具栏纵向时宽门会早退，但锚点仍需每轮重算；
        // 仅改尖角图层路径与收起层穿透区，不触发布局环）。
        if activeCallout != nil {
            updateCalloutArrowPositions()
        }
        // 审计 P1-3：宽变化（旋转/分屏/居中列切换）时重算 Chip 行换行；同宽不重算，
        // 移行本身触发布局也不会再进本分支，不成环。宽门限 0.5pt 与 sheet 高同款。
        if selectedChipsRow.bounds.width > 0,
           abs(selectedChipsRow.bounds.width - selectedChipsLastLayoutWidth) > 0.5 {
            layoutSelectedChips()
        }
        // 临时诊断（82 包追加，定根因后删除）：入口每调一次记一次，不节流。
        DiagFile.mark("composer-layout")
        // 临时诊断（天气条 10/28，定根因后删除）：布局后实测帧。refreshToolStrip 里的
        // weather-diag 是布局前的值（开日志恒为上一关闭态、关日志恒为上一打开态），
        // 本 mark 在 viewDidLayoutSubviews（布局已完成）后记，只在条带签名变化时记，
        // 用于钉死打开态到底是 370×40 还是塌掉。
        let stripSig = "\(String(describing: activeToolStrip))|\(quotePanelOpen)|\(weatherScrollView.isHidden)|\(weatherScrollView.frame)|\(toolStripStack.frame)|\(weatherScrollView.contentSize)|\(weatherEmoteViews.count)|\(weatherStackView.arrangedSubviews.first?.frame ?? .zero)"
        if stripSig != lastPostLayoutStripSig {
            lastPostLayoutStripSig = stripSig
            DiagFile.mark("weather-diag postLayout weatherHidden=\(weatherScrollView.isHidden) weatherFrame=\(weatherScrollView.frame) stackFrame=\(toolStripStack.frame) contentSize=\(weatherScrollView.contentSize) btnCount=\(weatherEmoteViews.count) firstBtnFrame=\(weatherStackView.arrangedSubviews.first?.frame ?? .zero)")
        }
        // 临时诊断（天气条 10/28 第二批，定根因后删除）：“晴”钮两时点全量状态。
        // 展开口径与 updateWeatherPlayback 的 rowVisible 一致；对象取 weatherButtons[1]
        //（[0] 为无图标的“无”，[1] 为首个带图标钮“晴”），对应播放器按 key 映射，不硬编码。
        // 第一时点：条带展开后的布局完成时，与 postLayout mark 同频（仅签名变化时记）。
        // 第二时点：attachCachedEmote 完成后的下一次布局完成时（一次性标志取后即清零，
        // 每布局都取、避免条带关闭后残留旧标志）；含当前动画帧与静态帧，其余字段与第一时点相同。
        if weatherButtons.count > 1 {
            let sunKey = weatherButtons[1].key
            let sunEmoteView = weatherEmoteViews.first(where: { $0.key == sunKey })?.emoteView
            let postAttach = sunEmoteView?.diagTakeAttachPending() ?? false
            let stripExpanded = activeToolStrip == .weather && !quotePanelOpen && !weatherScrollView.isHidden
            if stripExpanded, (postAttach || stripSig != lastWeatherDetailSig) {
                lastWeatherDetailSig = stripSig
                let sunButton = weatherButtons[1].button
                let imageViewDesc: String
                if let iv = sunButton.imageView {
                    imageViewDesc = "frame=\(iv.frame) bounds=\(iv.bounds) hidden=\(iv.isHidden) alpha=\(iv.alpha) clips=\(iv.clipsToBounds) imageIsNil=\(iv.image == nil)"
                } else {
                    imageViewDesc = "nil"
                }
                let emoteDesc: String
                let contentDesc: String
                var frameSuffix = ""
                if let emoteView = sunEmoteView {
                    emoteDesc = "frame=\(emoteView.frame) bounds=\(emoteView.bounds) hidden=\(emoteView.isHidden) alpha=\(emoteView.alpha) windowIsNil=\(emoteView.window == nil) superviewIsImageView=\(emoteView.superview === sunButton.imageView)"
                    let state = emoteView.diagContentState()
                    contentDesc = "kind=\(state.kind) frame=\(state.frame) imageIsNil=\(String(describing: state.imageIsNil)) currentFrame=\(String(describing: state.currentFrame))"
                    if postAttach {
                        frameSuffix = " currentFrame=\(String(describing: state.currentFrame)) staticFrame=\(String(describing: state.staticFrame))"
                    }
                } else {
                    emoteDesc = "nil"
                    contentDesc = "nil"
                }
                let tag = postAttach ? "postAttach-detail" : "expanded-detail"
                DiagFile.mark("weather-diag \(tag) scrollFrame=\(weatherScrollView.frame) scrollBounds=\(weatherScrollView.bounds) scrollContentSize=\(weatherScrollView.contentSize) scrollContentOffset=\(weatherScrollView.contentOffset) scrollHidden=\(weatherScrollView.isHidden) scrollAlpha=\(weatherScrollView.alpha) stackFrame=\(weatherStackView.frame) stackBounds=\(weatherStackView.bounds) stackHidden=\(weatherStackView.isHidden) stackAlpha=\(weatherStackView.alpha) btnFrame=\(sunButton.frame) btnBounds=\(sunButton.bounds) btnHidden=\(sunButton.isHidden) btnAlpha=\(sunButton.alpha) btnClips=\(sunButton.clipsToBounds) btnImageIsNil=\(sunButton.currentImage == nil) imageView[\(imageViewDesc)] emote[\(emoteDesc)] content[\(contentDesc)]\(frameSuffix)")
            }
        }
        let w = view.bounds.width
        guard w > 0, w != lastLayoutWidth else {
            // 临时诊断（86 包，定根因后删除）：布局方法出口（宽门挡住的早退路径）。
            DiagFile.mark("composer-layout-exit")
            return
        }
        lastLayoutWidth = w
        updateColumnConstraints()
        // P1-18：宽变化时先同步正文区高度再算 sheet 高（updateTextViewHeight 自带
        // 0.5pt 防抖门限，高度不变不赋值，不会与布局轮次成环）。
        updateTextViewHeight()
        updatePreferredContentSize()
        // 临时诊断（86 包，定根因后删除）：布局方法出口。
        DiagFile.mark("composer-layout-exit")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // B 修法配套：退场换锚后若页面又出现（仅非交互式退场取消的理论路径），
        // 把底锚换回键盘顶，编辑态布局不受影响；正常首次出现时旗标为 false，无动作。
        if toolbarReanchoredForDismiss {
            toolbarReanchoredForDismiss = false
            toolbarBottomToKeyboardConstraint?.isActive = true
            toolbarBottomToSafeAreaConstraint?.isActive = false
        }
        // 临时诊断（86 包，定根因后删除）。
        DiagFile.mark("composer-willAppear")
        // B5-3 配套：viewWillDisappear 失效了编辑倒计时，回到页面时重起，
        // 否则从选图/弹窗回来后倒计时永久停摆；startEditTimer 本身幂等
        // （先 invalidate 旧计时器，非编辑态直接隐藏 label 返回）。
        if isEditMode {
            startEditTimer()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // B 修法：只在真正被 dismiss 时换锚（isBeingDismissed 判定）；
        // 被选图/草稿箱等 modal 盖住时 isBeingDismissed 为 false，不换、不动编辑态布局。
        if isBeingDismissed {
            reanchorToolbarForDismiss()
        }
        // B5-3：重复计时器（编辑倒计时 1s）在页面关闭/被 modal 盖住时即失效，
        // 不再只靠 deinit——否则切出后到点仍走 onCancelled 关编辑器。
        // draftTimer 是 0.4s 一次性防抖，到点自释，不在这里失效（否则会丢
        // 一笔待保存的草稿）；deinit 仍保留作兜底。
        editTimer?.invalidate()
        editTimer = nil
    }

    /// 关闭退场 B 修法：退场开始时把工具栏底锚从键盘顶换成自身 safeArea 底，
    /// 整簇（工具栏行、限时行、展开的写给行、弹出框均锚在工具栏上）
    /// 钉回视图自身、随页滑走，不再被键盘 0.25s 收 vs 页面 0.5s 滑的时钟差落在屏底。
    /// 无跳变口径：换锚后的布局沿退场转场协调器同步播（与页面滑走同一时钟），
    /// 工具栏在视图内平滑滑到底边、随页出屏；无协调器（非动画退场，含减动效路径）
    /// 则立即落终值，视图本就瞬时消失，无可见跳变。编辑态（键盘立着时）仍钉键盘顶，本函数只在 dismiss 时跑。
    private func reanchorToolbarForDismiss() {
        guard !toolbarReanchoredForDismiss else { return }
        guard let keyboardConstraint = toolbarBottomToKeyboardConstraint,
              let safeAreaConstraint = toolbarBottomToSafeAreaConstraint else { return }
        toolbarReanchoredForDismiss = true
        keyboardConstraint.isActive = false
        safeAreaConstraint.isActive = true
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.view.layoutIfNeeded() }, completion: nil)
        } else {
            view.layoutIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("[Diag] composer-viewDidAppear")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("viewDidAppear")
        // 打开即聚焦正文：编辑器唯一目的就是写，首屏就绪后直接可打字；只做一次，
        // 从选图/弹窗回来不抢焦点；有草稿时光标置末尾，接着写。
        // 与草稿恢复/图片续传无冲突：恢复在 viewDidLoad 已完成，续传是后台任务。
        if !didAutoFocus {
            didAutoFocus = true
            if !textView.text.isEmpty {
                textView.selectedRange = NSRange(location: textView.text.count, length: 0)
            }
            textView.becomeFirstResponder()
        }
        // 87 包修法：转场里被跳过的 setNeedsLayout 在此补一次，让高度 settle；
        // 此时转场已完成，单次布局请求不重入，宽门仍兜底。
        view.superview?.setNeedsLayout()
    }

    deinit {
        draftTimer?.invalidate()
        editTimer?.invalidate()
        pendingUndoTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 布局（内容栈顺序即 E6 网页顺序；隐藏的 arranged 子项自动塌掉）

    private func buildLayout() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 52 批收键盘：滚动拖动即收（keyboardDismissMode）+ 点空白处收（下方 tap 手势，cancelsTouchesInView=false
        // 不吞控件点按；正文区点按由手势代理放行给 textView 聚焦，不走收键盘）。打开即自动聚焦（viewDidAppear）不动。
        scrollView.keyboardDismissMode = .onDrag
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardTap))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        scrollView.addGestureRecognizer(dismissTap)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        view.addSubview(topBar)
        view.addSubview(toolbarContainer)
        view.addSubview(visibilityBar)
        view.addSubview(toolStripStack)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(contentStack)
        // C1：正文从顶栏下方直接开始（scrollView 顶锚顶栏）；工具栏贴键盘上方，
        // 选择条贴工具栏上方；scrollView 底锚三档切换（见 updateScrollBottomAnchoring），初始锚工具栏。
        scrollBottomToToolbarConstraint = scrollView.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor)
        scrollBottomToVisibilityConstraint = scrollView.bottomAnchor.constraint(equalTo: visibilityBar.topAnchor)
        scrollBottomToStripConstraint = scrollView.bottomAnchor.constraint(equalTo: toolStripStack.topAnchor)
        scrollBottomToViewConstraint = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        // B 修法：工具栏底锚两档在此建好（键盘档激活、自身档待命），见声明注释。
        toolbarBottomToKeyboardConstraint = toolbarContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        toolbarBottomToSafeAreaConstraint = toolbarContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        toolbarBottomToKeyboardConstraint?.isActive = true
        toolbarBottomToSafeAreaConstraint?.isActive = false
        visibilityBarBottomToToolbarConstraint = visibilityBar.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor)
        visibilityBarBottomToMoodStripConstraint = visibilityBar.bottomAnchor.constraint(equalTo: moodScrollView.topAnchor)
        visibilityBarBottomToToolbarConstraint?.isActive = true
        visibilityBarBottomToMoodStripConstraint?.isActive = false
        scrollBottomToToolbarConstraint?.isActive = isEditMode
        scrollBottomToVisibilityConstraint?.isActive = !isEditMode
        // 限时行：工具栏上方固定行（visibilityBar 唯一内容）；新建默认私密，
        // 编辑模式整行隐藏（高度 0，选择条底锚随之回到工具栏顶）。
        visibilityBar.translatesAutoresizingMaskIntoConstraints = false
        // 限时行：两行文案 + 开关；开 = 强制公开且可见性钮锁定，
        // 关 = 回私密且可见性钮恢复可选。草稿模型不存限时态，重进编辑器默认关 + 私密。
        ephemeralRow.translatesAutoresizingMaskIntoConstraints = false
        ephemeralSwitch.translatesAutoresizingMaskIntoConstraints = false
        ephemeralSwitch.isOn = false
        ephemeralSwitch.addTarget(self, action: #selector(didToggleEphemeral), for: .valueChanged)
        ephemeralTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        ephemeralTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        ephemeralTitleLabel.textColor = BearyColors.ink
        ephemeralTitleLabel.text = "限时日记"
        ephemeralSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        ephemeralSubtitleLabel.font = UIFont.systemFont(ofSize: 12)
        ephemeralSubtitleLabel.textColor = BearyColors.gray
        ephemeralSubtitleLabel.text = "公开 24 小时后自动转私密"
        let ephemeralLabels = UIStackView(arrangedSubviews: [ephemeralTitleLabel, ephemeralSubtitleLabel])
        ephemeralLabels.translatesAutoresizingMaskIntoConstraints = false
        ephemeralLabels.axis = .vertical
        ephemeralLabels.spacing = 1
        ephemeralRow.addSubview(ephemeralLabels)
        ephemeralRow.addSubview(ephemeralSwitch)
        visibilityBar.addSubview(ephemeralRow)
        visibilityBarHeightConstraint = visibilityBar.heightAnchor.constraint(equalToConstant: isEditMode ? 0 : 48)
        visibilityBar.isHidden = isEditMode
        NSLayoutConstraint.activate([
            ephemeralRow.leadingAnchor.constraint(equalTo: visibilityBar.leadingAnchor, constant: 16),
            ephemeralRow.trailingAnchor.constraint(equalTo: visibilityBar.trailingAnchor, constant: -16),
            ephemeralRow.topAnchor.constraint(equalTo: visibilityBar.topAnchor),
            ephemeralRow.bottomAnchor.constraint(equalTo: visibilityBar.bottomAnchor),
            ephemeralLabels.leadingAnchor.constraint(equalTo: ephemeralRow.leadingAnchor),
            ephemeralLabels.centerYAnchor.constraint(equalTo: ephemeralRow.centerYAnchor),
            ephemeralSwitch.leadingAnchor.constraint(greaterThanOrEqualTo: ephemeralLabels.trailingAnchor, constant: 8),
            ephemeralSwitch.trailingAnchor.constraint(equalTo: ephemeralRow.trailingAnchor),
            ephemeralSwitch.centerYAnchor.constraint(equalTo: ephemeralRow.centerYAnchor),
            visibilityBarHeightConstraint!,
        ])
        // 选择条：竖栈，现只剩写给区（心情条第 27 项、天气条补缺 P2-20 已先后脱离栈）；
        // 全藏时栈高为 0，不占位。左右与工具栏同宽（跟随居中 608）。
        toolStripStack.axis = .vertical
        toolStripStack.spacing = 0
        toolStripStack.alignment = .fill
        toolStripStack.translatesAutoresizingMaskIntoConstraints = false
        // 92 包整页列宽：贴边约束与居中约束二选一，由 updateColumnConstraints 按宽切换
        //（个人主页同款：lazy 式成对约束、状态变化时才切换）。居中约束初始不激活。
        topBarLeadingConstraint = topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        topBarTrailingConstraint = topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        toolbarLeadingConstraint = toolbarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        toolbarTrailingConstraint = toolbarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        scrollLeadingConstraint = scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        scrollTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        topBarCenterXConstraint = topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        topBarWidthConstraint = topBar.widthAnchor.constraint(equalToConstant: 640)
        toolbarCenterXConstraint = toolbarContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        toolbarWidthConstraint = toolbarContainer.widthAnchor.constraint(equalToConstant: 608)
        scrollCenterXConstraint = scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        scrollWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: 640)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarLeadingConstraint!,
            topBarTrailingConstraint!,
            // v6：顶栏高 60，发布钮 36 居中后底部到分界线净留白 12（见 buildTopBar）。
            topBar.heightAnchor.constraint(equalToConstant: 60),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            toolbarBottomToKeyboardConstraint!,
            visibilityBar.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            visibilityBar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            // 2026-10-29 第 27 项：限时行底锚两档（见声明注释）；此处只激活 toolbar 档，
            // mood 档由创建处设为不激活、refreshToolStrip 按心情条开关切换——两档同
            // 时激活会互斥（行底不能既贴工具栏顶又贴心情条顶）。
            visibilityBarBottomToToolbarConstraint!,
            toolStripStack.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolStripStack.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolStripStack.bottomAnchor.constraint(equalTo: visibilityBar.topAnchor),
            toolbarLeadingConstraint!,
            toolbarTrailingConstraint!,
            scrollLeadingConstraint!,
            scrollTrailingConstraint!,
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    /// 92 包整页列宽：宽 ≥821 时顶栏/滚动区 640 居中、工具栏 608 居中（与旧居中卡几何一致），
    /// 窄屏恢复贴边；只在跨阈值时切换一次，分屏/旋转由 viewDidLayoutSubviews 的宽门驱动。
    private func updateColumnConstraints() {
        let centered = view.bounds.width >= 821
        guard centered != isColumnCentered else { return }
        isColumnCentered = centered
        topBarLeadingConstraint?.isActive = !centered
        topBarTrailingConstraint?.isActive = !centered
        toolbarLeadingConstraint?.isActive = !centered
        toolbarTrailingConstraint?.isActive = !centered
        scrollLeadingConstraint?.isActive = !centered
        scrollTrailingConstraint?.isActive = !centered
        topBarCenterXConstraint?.isActive = centered
        topBarWidthConstraint?.isActive = centered
        toolbarCenterXConstraint?.isActive = centered
        toolbarWidthConstraint?.isActive = centered
        scrollCenterXConstraint?.isActive = centered
        scrollWidthConstraint?.isActive = centered
    }

    /// 92 包注：编辑器已改整页，下述“呈现层取宽/取高”不再适用于编辑器（仅邀请弹窗仍走
    /// 旧呈现层）；iPad 列宽现由本文件 updateColumnConstraints 定，preferredContentSize
    /// 不再决定外框尺寸，仅保留计算。
    /// L9 已确认：iPad 640 宽不在 preferredContentSize 里定——呈现层 BearyCenteredModal 的
    /// frameOfPresentedViewInContainerView 已写死 min(640, 容器宽 - 80) 居中，preferredContentSize
    /// 只被呈现层取高（宽由呈现层框定）；故本文件不另在呈现层定宽，宽口径以呈现层为准。
    /// Sheet 高跟随内容：preferredContentSize.height = 顶栏 60（v6）+ 内容栈 fitting 高。
    /// 呈现层（SceneDelegate 的底 sheet / 居中卡片，本文件不动它）把 preferred 当整页高、
    /// 再与 88%/80% 封顶取小，故只给栈高会少 60（v6 顶栏高）、短内容仍需内滚 60；顶栏必须计入。
    /// 量取口径：contentStack.systemLayoutSizeFitting（给定当前宽、纵向压缩），
    /// 栈内隐藏的 arranged 子项自动塌掉，正文/已选 Chip 行/图片/状态行/
    /// 引用（lite 卡）/引用面板各区当前可见高度全计入；栈边距由 fitting 自带。
    /// A3：规则框已移出内容栈、浮在工具栏上方，不再计入栈高（它盖在滚动区
    /// 底部，不另占 sheet 高）。
    /// 变化小于 0.5pt 不赋值，避免改 preferred → 容器重布局 → viewDidLayoutSubviews 的循环。
    private func updatePreferredContentSize() {
        guard isViewLoaded else { return }
        // 首帧前 view.bounds 可能仍为 0：按窗口宽估算呈现宽（居中卡 min(640, 窗口宽-80)、
        // 底 sheet 即窗口宽），先算出非 0 的首帧高，不以占位满高上屏；布局落定后再纠正。
        let fittingWidth: CGFloat
        if view.bounds.width > 0 {
            fittingWidth = view.bounds.width
        } else {
            // S8：本分支 view.bounds 已知为 0，故不以它作中间回退；窗口宽为准，
            // 未挂窗时回退屏宽。阈值 821 / 居中 640 不动。
            let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
            fittingWidth = screenWidth >= 821 ? min(640, screenWidth - 80) : screenWidth
        }
        guard fittingWidth > 0 else { return }
        // 钉住的工具栏不在内容栈里：sheet 高须另加它（面板打开时它隐藏，计 0）。
        // 高度取容器 fitting（内容驱动：分隔线 1 + 间距 12 + 工具行 + 底 6），不硬编码；
        // 容器本身无高度约束，fitting 不会被自身约束带偏。
        let toolbarHeight: CGFloat
        if toolbarContainer.isHidden {
            toolbarHeight = 0
        } else {
            toolbarHeight = toolbarContainer.systemLayoutSizeFitting(
                CGSize(width: max(fittingWidth - 32, 0), height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        // qp-mode 整编形态：网页 qp-mode 高度——手机端 86vh，≥821px 桌面端
        // min(620px, 82vh)（beary.html:602/606；居中卡呈现层另有 80% 封顶，
        // 实际取小，属呈现层口径，本文件不动呈现层）。
        if quotePanelOpen {
            // S8：视口以窗口为准（未挂窗回退屏）；桌面判断用窗口宽，不用呈现宽
            // （居中卡本身只有 640，会误判为窄屏）。阈值 821 / 620 不动。
            let viewportHeight = view.window?.bounds.height ?? UIScreen.main.bounds.height
            let windowWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
            let target = windowWidth >= 821 ? min(620, viewportHeight * 0.82) : viewportHeight * 0.86
            guard abs(preferredContentSize.height - target) > 0.5 else { return }
            preferredContentSize = CGSize(width: fittingWidth, height: target)
            setNeedsLayoutUnlessPresenting()
            return
        }
        let targetSize = CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height)
        let fitted = contentStack.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let total = fitted.height + 60 + toolbarHeight
        // 临时诊断（82 包追加，定根因后删除）：total 每轮都记，看是否漂移。
        DiagFile.mark("composer-prefSize total=\(String(format: "%.1f", total))")
        guard abs(preferredContentSize.height - total) > 0.5 else {
            // 临时诊断（86 包，定根因后删除）：方法出口（0.5pt 门限挡住的早退路径）。
            DiagFile.mark("composer-prefSize-exit")
            return
        }
        preferredContentSize = CGSize(width: fittingWidth, height: total)
        setNeedsLayoutUnlessPresenting()
        // 临时诊断（86 包，定根因后删除）：方法出口。
        DiagFile.mark("composer-prefSize-exit")
    }

    /// 87 包修法：转场进行中只改 preferredContentSize，不同步触发 superview 布局。
    /// 转场里 setNeedsLayout 会重入呈现层布局（天气看门狗事故同源）；且此时 sheet
    /// 容器布局本就从 preferredContentSize 读高，不会丢高度；转场结束后 viewDidAppear
    /// 补一次 setNeedsLayout 让高度 settle。判定用 UIKit 现成的 isBeingPresented，
    /// 不新增状态（呈现控制器类是 SceneDelegate.swift 文件私有的，跨文件读 flag
    /// 要改可见性，反而更重）。
    private func setNeedsLayoutUnlessPresenting() {
        if isBeingPresented {
            // 临时诊断（87 包，定根因后删除）：证明转场里确实走了跳过分支。
            DiagFile.mark("composer-prefSize-skipTrans")
        } else {
            view.superview?.setNeedsLayout()
        }
    }

    private func buildTopBar() {
        // 玻璃批：顶栏实色 surface 底会盖住 view 的玻璃背板，改 clear 让玻璃透出来；分隔线不动。
        topBar.backgroundColor = UIColor.clear
        topSeparator.backgroundColor = BearyColors.line
        // v6-1：左侧“取消”文字 → plain X 叉叉：无文字、无圆圈外框、无底色，
        // icon_close 24pt 墨色（深色反白走 ink 动态色）、44pt 热区；VoiceOver 仍读“取消”。
        // 双态行为不变：引用面板打开时本钮是“返回”（只退面板），见 setQuotePanelOpen
        // 改 accessibilityLabel、didTapCancel 仍按 quotePanelOpen 分支。
        cancelButton.setTitle(nil, for: .normal)
        cancelButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 24), for: .normal)
        cancelButton.tintColor = BearyColors.ink
        cancelButton.accessibilityLabel = "取消"
        cancelButton.contentEdgeInsets = .zero
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        titleLabel.text = isEditMode ? "编辑日记" : "新日记"
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        // v6-2：标题靠左对齐、紧贴叉叉右侧 8pt，不再居中（v3 左右钮之间居中口径已推翻，不实施）。
        titleLabel.textAlignment = .left
        // L10：标题允许截断（单行尾部省略），不与左右钮重叠见下方不等式。
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        // 发布：墨底白字 pill + 发送图标（网页 obtn p）；禁用时按网页口径：无底灰字。
        publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
        publishButton.titleLabel?.font = UIFont.systemFont(ofSize: 14)
        publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 22), for: .normal)
        publishButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        // v6-4：发布钮高 44 → 36、pill 圆角随高取半 18；顶栏高 60 居中后底部到分界线净留白 12。其余样式与行为不动。
        publishButton.layer.cornerRadius = 18
        publishButton.layer.masksToBounds = true
        publishButton.addTarget(self, action: #selector(didTapPublish), for: .touchUpInside)
        // 发布中 spinner：平时停在发送图标位，发布/保存中时替下发送图标转圈（E3-4）。
        publishRingView.translatesAutoresizingMaskIntoConstraints = false
        publishRingView.image = BearyIconImages.image(named: "icon_refresh", pointSize: 18)
        publishRingView.tintColor = BearyColors.gray
        publishRingView.contentMode = .scaleAspectFit
        publishRingView.isHidden = true
        publishRingView.isUserInteractionEnabled = false
        publishButton.addSubview(publishRingView)
        NSLayoutConstraint.activate([
            publishRingView.leadingAnchor.constraint(equalTo: publishButton.leadingAnchor, constant: 12),
            publishRingView.centerYAnchor.constraint(equalTo: publishButton.centerYAnchor),
            publishRingView.widthAnchor.constraint(equalToConstant: 18),
            publishRingView.heightAnchor.constraint(equalToConstant: 18),
        ])
        for v in [cancelButton, titleLabel, publishButton, topSeparator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(v)
        }
        // v6-3：草稿 pill 文字 → 纯图标：官方 icon_diary 书本形 24pt 墨色（深色反白），
        // 无文字、无数量角标、44pt 热区，位置仍在发布钮左边；行为全保留（点开草稿箱、
        // 编辑态点它 toast 拦截、引用面板打开时随发布钮同藏、iPad 动作表单锚点仍为本钮，
        // 见 didTapDraftBox 与 setQuotePanelOpen）；数量只在草稿箱内可见，不再画在钮上。
        draftPillButton.setTitle(nil, for: .normal)
        draftPillButton.setAttributedTitle(nil, for: .normal)
        draftPillButton.setImage(BearyIconImages.image(named: "icon_diary", pointSize: 24), for: .normal)
        draftPillButton.tintColor = BearyColors.ink
        draftPillButton.accessibilityLabel = "草稿"
        draftPillButton.titleEdgeInsets = .zero
        draftPillButton.contentEdgeInsets = .zero
        draftPillButton.layer.cornerRadius = 0
        draftPillButton.layer.masksToBounds = false
        draftPillButton.layer.borderWidth = 0
        draftPillButton.addTarget(self, action: #selector(didTapDraftBox), for: .touchUpInside)
        draftPillButton.bearyAddPressFeedback()
        draftPillButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(draftPillButton)
        // 顶栏可见性钮：纯图标 24pt 墨色、44pt 热区，紧贴发布钮左侧（间距 8，与现行顶栏钮间距一致）；
        // 编辑模式隐藏（编辑不改可见性），图标随 selectedVisibilityPublished 走（见 refreshVisibilityButton）。
        visibilityButton.setImage(BearyIconImages.image(named: "icon_lock", pointSize: 24), for: .normal)
        visibilityButton.tintColor = BearyColors.ink
        visibilityButton.accessibilityLabel = "可见性"
        visibilityButton.addTarget(self, action: #selector(didTapVisibilityButton), for: .touchUpInside)
        visibilityButton.bearyAddPressFeedback()
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.isHidden = isEditMode
        topBar.addSubview(visibilityButton)
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
            // v6-2：标题靠左——左侧钉死叉叉右侧 8pt，右侧仍离草稿钮 8pt 不等式，窄屏先截断标题。
            titleLabel.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: draftPillButton.leadingAnchor, constant: -8),
            visibilityButton.trailingAnchor.constraint(equalTo: publishButton.leadingAnchor, constant: -8),
            visibilityButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalToConstant: 44),
            visibilityButton.heightAnchor.constraint(equalToConstant: 44),
            draftPillButton.trailingAnchor.constraint(equalTo: isEditMode ? publishButton.leadingAnchor : visibilityButton.leadingAnchor, constant: -8),
            draftPillButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            draftPillButton.heightAnchor.constraint(equalToConstant: 44),
            publishButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            publishButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            publishButton.heightAnchor.constraint(equalToConstant: 36),
            topSeparator.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            // 8-4 例外：编辑器顶栏分隔线保持 0.5pt（iOS 细线惯例），不收进 1pt 行间分隔档。
            topSeparator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        // 清单第 15 项：发布钮显式宽度约束（初值由 refreshPublishButtonWidth 按当前标题算出，
        // 此后标题/图标/边距每次变化都经 refreshPublishBusyState 重算，见该函数末尾）。
        let publishWidth = publishButton.widthAnchor.constraint(equalToConstant: 0)
        publishWidth.isActive = true
        publishWidthConstraint = publishWidth
        refreshPublishButtonWidth()
        refreshPublishAppearance()
        // 清单第 15 项：草稿 pill 显式宽度约束（随 pill 从工具栏搬到顶栏，口径不变；
        // 初值按当前“草稿”标题算出，此后计数每次变化都经 setDraftPillCount 重算）。
        let draftPillWidth = draftPillButton.widthAnchor.constraint(equalToConstant: 0)
        draftPillWidth.isActive = true
        draftPillWidthConstraint = draftPillWidth
        refreshDraftPillWidth()
        refreshVisibilityButton()
        // 草稿 pill 抗压钉死（2026-10-29）：99 包真机上 pill 在工具栏右端完全不渲染，
        // 静态排查已排除隐藏/移除/宽度为 0/溢出；剩余疑似布局引擎在某次布局中压没了它，
        // 故把水平抗压提到 required，让标题先截断而不是 pill 被压没。
        draftPillButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// 发布钮显式宽度（点赞钮同款修法）：UIButton 固有宽不含 titleEdgeInsets，
    /// 前沿自由的按钮按固有宽给帧时，标题会被左边距吃掉尾部（常态 6pt、发布中态 24pt，
    /// 后者会把“发布中…”裁成残字）。宽度按实测字宽重算：左右 content 边距 +
    /// 图宽 + 左右 title 边距 + 字宽；发布中态图为 nil、title 左边距取 publishSpinnerTitleInset 已含 spinner 位。
    private func refreshPublishButtonWidth() {
        let title = publishButton.title(for: .normal) ?? ""
        let titleWidth = ceil((title as NSString).size(withAttributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]).width)
        let imageWidth = publishButton.image(for: .normal)?.size.width ?? 0
        publishWidthConstraint?.constant = publishButton.contentEdgeInsets.left + imageWidth + publishButton.titleEdgeInsets.left + titleWidth + publishButton.titleEdgeInsets.right + publishButton.contentEdgeInsets.right
    }

    /// 发布钮外观跟随启用态（updatePublishState 只改 isEnabled，这里同步颜色/底色）。
    private func refreshPublishAppearance() {
        // U13：空正文时视觉置灰（与真禁用同外观），但按钮仍可点按以便给提示。
        if publishButton.isEnabled && trimmedContent().isEmpty {
            publishButton.backgroundColor = UIColor.clear
            publishButton.setTitleColor(BearyColors.gray, for: .normal)
            publishButton.tintColor = BearyColors.gray
            return
        }
        if publishButton.isEnabled {
            publishButton.backgroundColor = BearyColors.ink
            // 底是 ink、字须取反色 bg：深色下 ink 近白，白字面量会糊在底上看不见。
            publishButton.setTitleColor(BearyColors.bg, for: .normal)
            publishButton.tintColor = BearyColors.bg
        } else {
            publishButton.backgroundColor = UIColor.clear
            publishButton.setTitleColor(BearyColors.gray, for: .normal)
            publishButton.tintColor = BearyColors.gray
        }
    }

    // MARK: - A4-App 标题输入（正文上方；只做编辑器输入与透传，不做卡片渲染）

    private func buildTitleField() {
        titleField.delegate = self
        titleField.font = UIFont.boldSystemFont(ofSize: 16)
        titleField.textColor = BearyColors.ink
        titleField.attributedPlaceholder = NSAttributedString(string: "标题", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.boldSystemFont(ofSize: 16),
        ])
        titleField.returnKeyType = .next
        titleField.addTarget(self, action: #selector(titleFieldChanged), for: .editingChanged)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleField)
        contentStack.setCustomSpacing(8, after: titleField)
    }

    /// 标题归一化：先去掉拼音组合串（marked range，与正文 committedContent() 同款
    /// offset 切除，只作快照读取、不改 titleField、不调 unmarkText，组词中的输入法
    /// 状态不受影响），再 trim；trim 后空串按 nil（新建发布/草稿均按“无标题”处理，
    /// 不发空串；仅编辑 PUT 调用方在传参时把 nil 转为空串，见 performUpdate 的 R1 注释）。
    private func trimmedTitle() -> String? {
        let full = titleField.text ?? ""
        var committed = full
        if let marked = titleField.markedTextRange {
            let startOffset = titleField.offset(from: titleField.beginningOfDocument, to: marked.start)
            let endOffset = titleField.offset(from: titleField.beginningOfDocument, to: marked.end)
            if startOffset >= 0, endOffset <= full.count, startOffset <= endOffset {
                let start = committed.index(committed.startIndex, offsetBy: startOffset)
                let end = committed.index(committed.startIndex, offsetBy: endOffset)
                committed.removeSubrange(start..<end)
            }
        }
        let trimmed = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @objc private func titleFieldChanged() {
        scheduleDraftSave()
        // 2026-10-30 标题打字守卫：打字中标题被系统滚动顶出可视区顶部时，
        // 按留白口径拉回；在视野内时 scrollFocusedFieldIntoView 自身 no-op。
        if titleField.isFirstResponder {
            scrollFocusedFieldIntoView(animated: true)
        }
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField == titleField else { return true }
        let current = textField.text ?? ""
        guard let swiftRange = Range(range, in: current) else { return true }
        let next = current.replacingCharacters(in: swiftRange, with: string)
        // 30 字上限（建议值，可改）：按字符数计，超限的本次输入整体不采纳。
        return next.count <= Self.maxTitleLength
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField == titleField else { return true }
        textView.becomeFirstResponder()
        return true
    }

    private func buildTextArea() {
        textView.delegate = self
        textView.font = UIFont.systemFont(ofSize: 16)
        textView.textColor = BearyColors.ink
        // 无框正文：透明底。正式修法（2026-10-26，微信输入法×编辑器隔离结论）：
        // 根因是正文区自身滚动关闭——isScrollEnabled=false 时微信输入法打不上字，
        // 改 true 后真机已证实能打，故自身滚动保持开启，绝不能改回去。
        // typingAttributes 恢复段落样式 lineHeightMultiple=1.7（网页版行高）：
        // 之前去掉段落样式只证明了它单独不是根因；段落样式×可滚动这个组合此前
        // 从未在真机验过，组合待真机复验。
        // 已填入的正文行高仍由 applyBodyLineHeight() 套 1.7（见 setupEditContent/restoreDraft）。
        // 编辑器批：倍数抽成局部量，placeholder 基线偏移与 caret 锚定同用它（见下）。
        let bodyLineMultiple: CGFloat = 1.7
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineHeightMultiple = bodyLineMultiple
        textView.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraph]
        // caret 锚定同用该倍数（见 BearyBodyTextView.fixedLineHeightMultiple）：光标处
        // 属性 lookup 在输入法提交文本上不可靠，固定倍数优先，防回退居中致光标偏上。
        textView.fixedLineHeightMultiple = bodyLineMultiple
        textView.backgroundColor = UIColor.clear
        textView.layer.cornerRadius = 0
        textView.isScrollEnabled = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        placeholderLabel.text = "记录今天…"
        placeholderLabel.font = UIFont.systemFont(ofSize: 16)
        placeholderLabel.textColor = BearyColors.alpha(BearyColors.gray, 0.7)
        textView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textView)
        textView.addSubview(placeholderLabel)
        let textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 140)
        textViewHeightConstraint = textHeightConstraint
        NSLayoutConstraint.activate([
            // 自身滚动开启后 textView 无内在高度：先给下限 140（正式修法前原值），
            // 实际高度由 updateTextViewHeight() 随 contentSize 动态更新（下限 140、上限按 sheet 封顶算）。
            textHeightConstraint,
            // 编辑器批同款（基线对齐）：1.7 倍行高把首行基线推到片段顶 + ascender × 倍数，
            // 占位 label 若贴顶 0，其基线会比打出来的字高 ascender × (倍数 − 1)，
            // 空态占位与落字位置对不上；占位顶下移该量，让两者基线重合。
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: UIFont.systemFont(ofSize: 16).ascender * (bodyLineMultiple - 1)),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
        ])
        contentStack.setCustomSpacing(12, after: textView)
    }

    /// 正文区动态高度：随内容撑高（下限 140），上限按 sheet 可用高度封顶，
    /// 让工具栏始终可见、超长只在区内滚动。
    /// 封顶依据（不拍脑袋）：呈现层封顶见 SceneDelegate.configureComposerPresentation
    /// （宽 ≥821 居中卡）与 BearyCenteredModal.frameOfPresentedViewInContainerView
    /// （卡高 = 容器高 × 0.80）；窄屏底 sheet 为容器高 × 0.88（同函数注释）。
    /// 容器高取 view.window bounds（未挂窗时回退屏高），窗口宽阈值 821 与呈现层分流一致。
    private func updateTextViewHeight() {
        guard isViewLoaded, let heightConstraint = textViewHeightConstraint else { return }
        // 宽度：布局前 bounds 可能为 0，走 updatePreferredContentSize 同款窗口宽估算
        // （未挂窗回退屏宽）；前两支已处理 textView/view 的实宽，本支 view 宽已知为 0。
        let width: CGFloat
        if textView.bounds.width > 0 {
            width = textView.bounds.width
        } else if view.bounds.width > 0 {
            width = view.bounds.width
        } else {
            let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
            width = screenWidth >= 821 ? min(640, screenWidth - 80) : screenWidth
        }
        guard width > 0 else { return }
        let contentHeight = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // 栈内除正文外的高度：当前栈 fitting 高减去当前正文约束高（间距已含在 fitting 内）。
        let fittingWidth = view.bounds.width > 0 ? view.bounds.width : width
        let stackHeight = contentStack.systemLayoutSizeFitting(
            CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let othersHeight = stackHeight - heightConstraint.constant
        // 钉住的工具栏不在内容栈里：同 updatePreferredContentSize 口径另加（隐藏计 0）。
        let toolbarHeight: CGFloat
        if toolbarContainer.isHidden {
            toolbarHeight = 0
        } else {
            toolbarHeight = toolbarContainer.systemLayoutSizeFitting(
                CGSize(width: max(fittingWidth - 32, 0), height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        let containerHeight = view.window?.bounds.height ?? UIScreen.main.bounds.height
        // S8：桌面判断用窗口宽（同上，居中卡呈现宽 640 不能作判断依据；未挂窗回退屏宽）。
        let windowWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
        let sheetCap = containerHeight * (windowWidth >= 821 ? 0.80 : 0.88)
        // 顶栏 60（v6）同 updatePreferredContentSize 口径；封顶不足 140 时仍保下限，
        // 此时 sheet 走呈现层封顶、外层滚动兜底，与正式修法前行为一致。
        // 编辑器批第 5 项：封顶再减当前键盘高（收起时为 0）。不减时正文帧底伸到键盘
        // 下方，末行被盖；内层已滚到头时外层 pan 被饿死，即“被盖住 + 手动上滑也滑不动”。
        // 下限仍保 140（不足时外层滚动兜底，口径不变）。
        let cap = sheetCap - 60 - toolbarHeight - othersHeight - currentKeyboardHeight
        let target = min(max(contentHeight, 140), max(140, cap))
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
    }

    /// 已填入的正文套 1.7 行高（只换呈现属性，不改文字与光标语义；空文本只留 typingAttributes）。
    private func applyBodyLineHeight() {
        let current = textView.text ?? ""
        guard !current.isEmpty else { return }
        let savedRange = textView.selectedRange
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.7
        let styled = NSAttributedString(string: current, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
        textView.attributedText = styled
        let maxLocation = styled.length
        let location = min(savedRange.location, maxLocation)
        let length = min(savedRange.length, maxLocation - location)
        textView.selectedRange = NSRange(location: location, length: length)
    }

    // MARK: - 心情（网页 mood-strip：54 宽单项，44 圆环 + 熊图 35 + 10.5 名；
    // 选中：圆环橙 12% 底 + 橙色描边、名变橙；选中名改由正文下方 Chip 行显示）

    private func buildMoodRow() {
        // C1：心情条本身即工具栏上方选择条（单行横滑），标题行已删，选中名走 Chip 行。
        moodScrollView.showsHorizontalScrollIndicator = false
        moodStackView.axis = .horizontal
        moodStackView.spacing = 4
        moodStackView.alignment = .top
        moodScrollView.translatesAutoresizingMaskIntoConstraints = false
        moodStackView.translatesAutoresizingMaskIntoConstraints = false
        moodScrollView.addSubview(moodStackView)
        moodScrollView.isHidden = true
        // 2026-10-29 第 27 项：心情条（回应面板）不再进 toolStripStack（栈底锚限时行
        // 上方）；改为独立浮条，底贴工具栏顶——即小熊
        // 按钮本体正上方，以触发按钮行为锚点；左右与工具栏同宽；其余行为不变
        //（横滑、选中、播放门、Chip 行均走原逻辑）。buildToolbarRow 已先跑，
        // toolbarContainer 已入 view，约束可直接激活。
        view.addSubview(moodScrollView)
        NSLayoutConstraint.activate([
            moodScrollView.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            moodScrollView.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            moodScrollView.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor),
        ])
        NSLayoutConstraint.activate([
            // 滚动区高内容驱动：单项高 = 顶余 8 + 圆环 44 + gap 4 + 名字行高，约 67–68。
            // 顶余 8 的原因：选中双环外扩 4.5pt 到环外、表情涂鸦（如嗯嗯的对勾）
            // 也会画到环外（BearyEmoteView 全链 clipsToBounds=false），而 moodScrollView
            // 默认裁剪——环若顶到按钮顶边，环顶与涂鸦顶都会被滚动区顶边横切。
            moodScrollView.heightAnchor.constraint(equalTo: moodStackView.heightAnchor),
            moodStackView.topAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.topAnchor),
            moodStackView.bottomAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.bottomAnchor),
            moodStackView.leadingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.leadingAnchor),
            moodStackView.trailingAnchor.constraint(equalTo: moodScrollView.contentLayoutGuide.trailingAnchor),
        ])
        for key in moodOrder {
            let name = BearyText.moodNames[key] ?? key
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            let ringView = UIView()
            ringView.translatesAutoresizingMaskIntoConstraints = false
            // 编辑器批第 3 项：环必须禁交互——UIView 默认可交互，盖在按钮上会吞点按
            // （publishRingView 与天气 Lottie 已有同款显式 false，心情条漏了）；
            // 不禁时点熊只命中环/动画视图、按钮收不到 touchUpInside，即“心情无法选择”
            // （名字 label 默认不交互，故只有点名字才偶然成功）。
            ringView.isUserInteractionEnabled = false
            ringView.backgroundColor = BearyColors.faint
            ringView.layer.cornerRadius = 22
            ringView.layer.masksToBounds = true
            // D-G4：网页选中态无描边，环外是两层 box-shadow（2px bg + 2.5px 橙）；
            // 此处不设描边，选中双环由 refreshMoodButtons 的形层画（见 moodRingAnnulus）。
            ringView.layer.borderWidth = 0
            // A2-4 启动源修法：建条时不自动播。原 animated:true 使 40 只在
            // 选择条收起时条虽 isHidden、视图仍在 window 内，didMoveToWindow 拦不住起播；
            // 播放权交给 updateMoodPlayback（见 activeToolStrip 门）。
            // E4：建条时也不解析（deferred），点开心情条时 updateMoodPlayback
            // 调 ensureLoaded 才加载；未点开时只显示静态回退图。
            let emoteView = BearyEmoteView(key: key, animated: false, deferred: true)
            emoteView.translatesAutoresizingMaskIntoConstraints = false
            // 同上：BearyEmoteView 类内未禁交互，35×35 盖在环中央，同样吞点按。
            emoteView.isUserInteractionEnabled = false
            let fallbackLabel = UILabel()
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            fallbackLabel.text = name
            fallbackLabel.font = UIFont.systemFont(ofSize: 11)
            fallbackLabel.textColor = BearyColors.gray
            fallbackLabel.textAlignment = .center
            fallbackLabel.numberOfLines = 2
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.text = name
            nameLabel.font = UIFont.systemFont(ofSize: 10.5)
            nameLabel.textColor = BearyColors.gray
            nameLabel.textAlignment = .center
            button.addSubview(ringView)
            button.addSubview(nameLabel)
            ringView.addSubview(emoteView)
            ringView.addSubview(fallbackLabel)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 54),
                // 心情条顶部余量（见上）：环顶离按钮顶边 8pt，选中外环与涂鸦不再被切。
                ringView.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
                ringView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                ringView.widthAnchor.constraint(equalToConstant: 44),
                ringView.heightAnchor.constraint(equalToConstant: 44),
                emoteView.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
                emoteView.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
                emoteView.widthAnchor.constraint(equalToConstant: 35),
                emoteView.heightAnchor.constraint(equalToConstant: 35),
                fallbackLabel.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
                fallbackLabel.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
                fallbackLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ringView.leadingAnchor, constant: 4),
                fallbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: ringView.trailingAnchor, constant: -4),
                nameLabel.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 4),
                nameLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                nameLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                nameLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.addTarget(self, action: #selector(didTapMood(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            moodItems.append((key: key, button: button, ringView: ringView, emoteView: emoteView, fallbackLabel: fallbackLabel, nameLabel: nameLabel))
            moodStackView.addArrangedSubview(button)
        }
        refreshMoodButtons()
    }

    /// 深浅切换时播放器内部自动换变体，这里只保证环内图可见、不重建条、不丢选中态。
    private func refreshMoodImages() {
        for item in moodItems {
            item.emoteView.isHidden = false
            item.fallbackLabel.isHidden = true
        }
    }

    /// A2-4 + B6-1 心情播放控制（2026-10-29 第 25 项改动态口径）：面板隐藏时全部
    /// stop；面板可见时全部播 Lottie（与列表里表情同一套 BearyEmoteView 资源与
    /// 播放口径，不再只播选中 1 只、其余冻结静态帧）。已在播的不重播
    /// （isPlayingNow 门，避免选心情时全部重画描线）；“40 个 CADisplayLink”
    /// 未在代码中证实（Lottie 走 CoreAnimation，非每只一个 CADisplayLink），
    /// 故不按此数施工，只按实际并发播放修；48MB 缓存预算数值不动。
    /// C1：心情播放门改看选择条（旧心情区 isHidden 已随标题行删除）：
    /// 仅心情条展开且引用面板未打开时播，其余一律停播。
    private func updateMoodPlayback() {
        let panelVisible = activeToolStrip == .mood && !quotePanelOpen
        // E4：点开心情条时才加载对应动画（ensureLoaded 幂等，未点开不解析）；
        // 放在早退门之前，首开即加载，不依赖选中态变化。
        if panelVisible {
            for item in moodItems {
                item.emoteView.ensureLoaded()
            }
        }
        if moodPlaybackPanelVisible == panelVisible {
            return
        }
        moodPlaybackPanelVisible = panelVisible
        for item in moodItems {
            if !panelVisible {
                item.emoteView.stop()
            } else if !item.emoteView.isPlayingNow {
                item.emoteView.play()
            }
        }
    }

    // MARK: - 天气（图标 + 名 chip；选中墨色边框、无底；首项“无”；再点已选项不取消）

    private func buildWeatherRow() {
        weatherScrollView.showsHorizontalScrollIndicator = false
        // 2026-10-29 第 20 项：横滑条内小 chip 点按易被 scroll 误判为滑动而取消，
        // 致“选项点不了”；关掉触摸延迟，点按立即响应（诊断日志代码不动）。
        weatherScrollView.delaysContentTouches = false
        weatherStackView.axis = .horizontal
        weatherStackView.spacing = 8
        weatherStackView.alignment = .center
        weatherScrollView.translatesAutoresizingMaskIntoConstraints = false
        weatherStackView.translatesAutoresizingMaskIntoConstraints = false
        // 补缺 P2-20：天气条改独立条（心情条第 27 项同款锚点）：底贴工具栏顶、即触发行正上方，
        // 不再进 toolStripStack（栈在限时行上方、高度纯内容驱动，天气条是唯一仍走栈内打开路径的条，
        // 与限时行几何（新建 48／编辑 0）耦合，是“点天气钮选择器出不来”的结构嫌疑）；限时行另增天气档锚点。
        view.addSubview(weatherScrollView)
        weatherScrollView.addSubview(weatherStackView)
        weatherScrollView.isHidden = true
        visibilityBarBottomToWeatherConstraint = visibilityBar.bottomAnchor.constraint(equalTo: weatherScrollView.topAnchor)
        visibilityBarBottomToWeatherConstraint?.isActive = false
        let weatherHeightEquality = weatherScrollView.heightAnchor.constraint(equalTo: weatherStackView.heightAnchor, constant: 12)
        weatherHeightEquality.priority = .defaultHigh
        NSLayoutConstraint.activate([
            // 天气行内容驱动约 40 = chip 高 + 上 10 + 下 2（左右与工具栏同宽）。
            // 塌高兜底：等式降档 + 40 下限，保证条带永不塌到 0（诊断曾怀疑打开态塌掉）。
            weatherHeightEquality,
            weatherScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            weatherScrollView.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            weatherScrollView.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            weatherScrollView.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            weatherStackView.topAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.topAnchor, constant: 10),
            weatherStackView.bottomAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.bottomAnchor, constant: -2),
            weatherStackView.leadingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.leadingAnchor),
            weatherStackView.trailingAnchor.constraint(equalTo: weatherScrollView.contentLayoutGuide.trailingAnchor),
        ])
        // 首项“无”：key 为空串即未选。
        let noneButton = makeWeatherButton(key: "", title: "无", iconName: nil)
        weatherButtons.append((key: "", button: noneButton))
        weatherStackView.addArrangedSubview(noneButton)
        for key in weatherOrder {
            let name = BearyText.weatherNames[key] ?? key
            let button = makeWeatherButton(key: key, title: name, iconName: "icon_wx_\(key)")
            weatherButtons.append((key: key, button: button))
            weatherStackView.addArrangedSubview(button)
        }
        refreshWeatherButtons()
    }

    /// 天气 key → Lottie 资源 key：选择器 key 与 Lottie 包基本同名，唯 night 对应 moon。
    private static func weatherLottieKey(for weatherKey: String) -> String {
        weatherKey == "night" ? "moon" : weatherKey
    }

    /// 天气 Lottie 占位图：16×16 全透明，仅占住按钮 imageView 槽位（布局与原来 16pt 静态图一致），
    /// 真正内容由按钮内独立 16×16 图标容器里的 BearyEmoteView 画；加载失败时它回退 wx 静态图，永不留白。
    private static let weatherPlaceholderImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in }
    }()

    private func makeWeatherButton(key: String, title: String, iconName: String?) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        // 内边距先定：图标槽位左锚取它（见下），避免两处 12 硬编码脱节。
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        if let name = iconName {
            let staticImage = BearyIconImages.image(named: name, pointSize: 16)
            button.setImage(Self.weatherPlaceholderImage, for: .normal)
            button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: 0)
            // 天气 Lottie：独立 16×16 图标容器（心情条同款显式约束宿主）。
            // 100 包根因修法：此前容器锚定 UIButton 内部 imageView（#147 由
            // imageView.addSubview 改为锚 imageView 的兄弟容器），但 imageView
            // 的帧由 UIButton 手工布局、不走 Auto Layout——建钮时帧恒为 0，
            // 约束驱动的容器跟随不到它后来的真实槽位，全仓仅此一处锚内部
            // imageView，而心情条 35pt 环锚点 + 显式尺寸同款结构正常显示；
            // Lottie JSON（LottieWeather/，Resources 已含）与 icon_wx_* 静态图
            // （Assets.xcassets，CI 资产校验通过）均已排除，剩下的唯一几何
            // 依赖就是这一锚点。故容器改锚按钮本体：横向取 contentEdgeInsets
            // 左（横滑栈内按钮恒为内在宽，组左缘即该值，与占位图槽位像素
            // 一致）、纵向取按钮中心（与占位图纵向居中一致），尺寸显式 16。
            // 占位图仍占住槽位，按钮内在尺寸/点按范围与原来一致；容器本身
            // 不拦截点按；减动效时播放器内置静态帧不播；加载失败时播放器
            // 内回退 wx 静态图（与原来一致，仍在容器内显示）。
            // E4：建钮时不解析（deferred，静态图先行），点开天气条时
            // updateWeatherPlayback 调 ensureLoaded 才加载；69 批播放管控本身不动。
            let lottie = BearyEmoteView(key: Self.weatherLottieKey(for: key), animated: true, fallbackImage: staticImage, deferred: true)
            weatherEmoteViews.append((key: key, emoteView: lottie))
            let iconHost = UIView()
            iconHost.isUserInteractionEnabled = false
            iconHost.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(iconHost)
            lottie.isUserInteractionEnabled = false
            lottie.translatesAutoresizingMaskIntoConstraints = false
            iconHost.addSubview(lottie)
            NSLayoutConstraint.activate([
                iconHost.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: button.contentEdgeInsets.left),
                iconHost.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconHost.widthAnchor.constraint(equalToConstant: 16),
                iconHost.heightAnchor.constraint(equalToConstant: 16),
                lottie.leadingAnchor.constraint(equalTo: iconHost.leadingAnchor),
                lottie.trailingAnchor.constraint(equalTo: iconHost.trailingAnchor),
                lottie.topAnchor.constraint(equalTo: iconHost.topAnchor),
                lottie.bottomAnchor.constraint(equalTo: iconHost.bottomAnchor),
            ])
        }
        button.layer.cornerRadius = 999
        button.layer.masksToBounds = true
        button.layer.borderWidth = 1.5
        button.accessibilityLabel = title
        button.addTarget(self, action: #selector(didTapWeather(_:)), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }

    private func refreshWeatherButtons() {
        for pair in weatherButtons {
            let button = pair.button
            let isNoneButton = pair.key.isEmpty
            let isSelected = isNoneButton ? (selectedWeather == nil) : (pair.key == selectedWeather)
            button.backgroundColor = UIColor.clear
            button.setTitleColor(BearyColors.ink, for: .normal)
            button.tintColor = BearyColors.ink
            if isSelected {
                button.layer.borderColor = BearyColors.ink.cgColor
            } else {
                button.layer.borderColor = BearyColors.line.cgColor
            }
        }
        // 工具栏天气钮图标随选中天气变（网页 syncWxBtn 同款）：未选回通用天气图标，
        // 已选换该天气图标；两态均为墨色（网页未选时按钮色继承 .icon-btn 的墨色，
        // 仅已选时显式置墨，故未选态原灰色亦为 D-G7 之差，一并改墨）。
        if let weather = selectedWeather {
            if let icon = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.ink
        } else {
            if let icon = BearyIconImages.image(named: "icon_weather_tool", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.ink
        }
    }

    /// Gemini 第一批：天气播放控制（心情 updateMoodPlayback 同款口径）。
    /// C1：行隐藏改看选择条（选择条收起/引用面板打开）时 9 只全部冻结静态帧，
    /// 不再后台循环；行可见时仅当前选中的 1 只播，其余 8 只冻结静态帧。
    /// 94 接线的“9 项全循环”计划至此作废（Li 点“按这个分批修”即点头改）。
    /// 减动效、深浅切换、失败回退 wx 静态图的既有兜底不动：play() 在减动效下
    /// 本就只置静态帧不播；深浅变体由播放器 trait 切换内处理；加载失败回退
    /// 的是 PNG 图，play/showStaticFrame 对它均为空操作。
    private func updateWeatherPlayback() {
        let rowVisible = activeToolStrip == .weather && !quotePanelOpen
        // E4：点开天气条时才加载对应动画（ensureLoaded 幂等）；69 批“行可见时
        // 仅选中 1 只播、其余冻结静态帧”的播放管控在下面原样不动。
        if rowVisible {
            for item in weatherEmoteViews {
                item.emoteView.ensureLoaded()
            }
        }
        if weatherPlaybackVisible == rowVisible && weatherPlaybackSelected == selectedWeather {
            return
        }
        weatherPlaybackVisible = rowVisible
        weatherPlaybackSelected = selectedWeather
        for item in weatherEmoteViews {
            if !rowVisible {
                item.emoteView.showStaticFrame()
            } else if item.key == selectedWeather {
                item.emoteView.play()
            } else {
                item.emoteView.showStaticFrame()
            }
        }
    }

    @objc private func didTapWeather(_ sender: UIButton) {
        var tappedKey: String?
        for pair in weatherButtons {
            if pair.button == sender {
                tappedKey = pair.key
            }
        }
        guard let key = tappedKey else { return }
        // 网页口径：点某项即选中该项（含“无”=清空），再点已选项不取消。
        if key.isEmpty {
            selectedWeather = nil
        } else {
            selectedWeather = key
        }
        refreshWeatherButtons()
        updateWeatherPlayback()
        refreshSelectedChips()
        // 天气在草稿 v3 字段里，改动即走防抖保存，杀 App 后可恢复。
        scheduleDraftSave()
    }

    // MARK: - @（网页 addr-row：@ 图标 + “@ 谁”钮 / chip；只选一人、不可 @ 自己；
    // @ 提醒无按篇开关；编辑模式可改选可清除，见 refreshRecipientRow 编辑分支）

    private func buildRecipientRow() {
        recipientSection.axis = .vertical
        recipientSection.spacing = 8
        recipientSection.alignment = .fill
        recipientLine.axis = .horizontal
        recipientLine.spacing = 8
        recipientLine.alignment = .center
        // D-G8：网页 @ 在 pick 钮内（addr-pick 内含 15px @ 图 + gap 6），已选 chip 内无 @；
        // App 原行首独立 @ 图（pill 外）删除，@ 改放进 pick 钮。
        // 未选：虚线边框 pill 钮（网页 addr-pick：1.5px dashed line、圆角 999；
        // 虚线由 BearyComposerDashedPickButton 的 CAShapeLayer 画，路径圆角取半高即 pill）。
        recipientPickButton.setImage(BearyIconImages.image(named: "icon_at", pointSize: 15), for: .normal)
        recipientPickButton.tintColor = BearyColors.gray
        recipientPickButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
        recipientPickButton.setTitle("@ 谁", for: .normal)
        recipientPickButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        recipientPickButton.setTitleColor(BearyColors.gray, for: .normal)
        recipientPickButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        recipientPickButton.layer.cornerRadius = 999
        recipientPickButton.addTarget(self, action: #selector(didTapPickRecipient), for: .touchUpInside)
        recipientPickButton.bearyAddPressFeedback()
        // 已选 chip：橙 13% 底 + 22 头像/首字母 + “@名” + ×。
        // D-G8：网页 addr-chip 底是 color-mix（橙 13% + surface），深色下 surface
        // 为 #26262c；App 原 13% 透明橙叠在纯黑页底上偏暗。改按当前主题把橙与
        // surface 混色（浅色 surface 为白，与原效果一致；仅深色变亮）。
        recipientChipView.backgroundColor = UIColor { trait in
            let orange = BearyColors.orange.resolvedColor(with: trait)
            let surface = BearyColors.surface.resolvedColor(with: trait)
            var oR: CGFloat = 0, oG: CGFloat = 0, oB: CGFloat = 0, oA: CGFloat = 0
            var sR: CGFloat = 0, sG: CGFloat = 0, sB: CGFloat = 0, sA: CGFloat = 0
            orange.getRed(&oR, green: &oG, blue: &oB, alpha: &oA)
            surface.getRed(&sR, green: &sG, blue: &sB, alpha: &sA)
            return UIColor(red: 0.13 * oR + 0.87 * sR, green: 0.13 * oG + 0.87 * sG, blue: 0.13 * oB + 0.87 * sB, alpha: 1)
        }
        recipientChipView.layer.cornerRadius = 15
        recipientChipView.layer.masksToBounds = true
        recipientChipAvatar.contentMode = .scaleAspectFill
        recipientChipAvatar.clipsToBounds = true
        recipientChipAvatar.layer.cornerRadius = 11
        recipientChipAvatar.layer.masksToBounds = true
        recipientChipFallback.font = UIFont.boldSystemFont(ofSize: 12)
        recipientChipFallback.textColor = UIColor.white
        recipientChipFallback.backgroundColor = BearyColors.orange
        recipientChipFallback.textAlignment = .center
        recipientChipFallback.layer.cornerRadius = 11
        recipientChipFallback.layer.masksToBounds = true
        recipientChipName.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        recipientChipName.textColor = BearyColors.ink
        // I6：写给 chip 清除改用 icon_close 资产（不再用文字 ×）。
        // D-G8：网页 .addr-x 图标 11px（钮框仍 18），原 12 改 11。
        recipientClearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 11), for: .normal)
        recipientClearButton.tintColor = BearyColors.gray
        recipientClearButton.backgroundColor = BearyColors.alpha(BearyColors.ink, 0.10)
        recipientClearButton.layer.cornerRadius = 9
        recipientClearButton.layer.masksToBounds = true
        recipientClearButton.addTarget(self, action: #selector(didTapClearRecipient), for: .touchUpInside)
        recipientClearButton.bearyAddPressFeedback()
        notifyCheckButton.layer.cornerRadius = 6
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1.5
        notifyCheckButton.layer.borderColor = BearyColors.line.cgColor
        notifyCheckButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        notifyCheckButton.addTarget(self, action: #selector(didTapNotifyCheck), for: .touchUpInside)
        notifyCheckButton.bearyAddPressFeedback()
        notifyLabel.text = "通知对方"
        notifyLabel.font = UIFont.systemFont(ofSize: 13)
        notifyLabel.textColor = BearyColors.ink
        notifyGroup.axis = .horizontal
        notifyGroup.spacing = 6
        notifyGroup.alignment = .center
        notifyGroup.addArrangedSubview(notifyCheckButton)
        notifyGroup.addArrangedSubview(notifyLabel)
        recipientSection.translatesAutoresizingMaskIntoConstraints = false
        recipientLine.translatesAutoresizingMaskIntoConstraints = false
        recipientPickButton.translatesAutoresizingMaskIntoConstraints = false
        recipientChipView.translatesAutoresizingMaskIntoConstraints = false
        recipientChipAvatar.translatesAutoresizingMaskIntoConstraints = false
        recipientChipFallback.translatesAutoresizingMaskIntoConstraints = false
        recipientChipName.translatesAutoresizingMaskIntoConstraints = false
        recipientClearButton.translatesAutoresizingMaskIntoConstraints = false
        notifyCheckButton.translatesAutoresizingMaskIntoConstraints = false
        toolStripStack.addArrangedSubview(recipientSection)
        recipientSection.isHidden = true
        recipientSection.addArrangedSubview(recipientLine)
        recipientSection.addArrangedSubview(notifyGroup)
        recipientLine.addArrangedSubview(recipientPickButton)
        recipientLine.addArrangedSubview(recipientChipView)
        recipientChipView.addSubview(recipientChipAvatar)
        recipientChipView.addSubview(recipientChipFallback)
        recipientChipView.addSubview(recipientChipName)
        recipientChipView.addSubview(recipientClearButton)
        NSLayoutConstraint.activate([
            recipientChipAvatar.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 4),
            recipientChipAvatar.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientChipAvatar.widthAnchor.constraint(equalToConstant: 22),
            recipientChipAvatar.heightAnchor.constraint(equalToConstant: 22),
            recipientChipFallback.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 4),
            recipientChipFallback.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientChipFallback.widthAnchor.constraint(equalToConstant: 22),
            recipientChipFallback.heightAnchor.constraint(equalToConstant: 22),
            recipientChipName.leadingAnchor.constraint(equalTo: recipientChipView.leadingAnchor, constant: 33),
            recipientChipName.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientClearButton.leadingAnchor.constraint(equalTo: recipientChipName.trailingAnchor, constant: 7),
            recipientClearButton.trailingAnchor.constraint(equalTo: recipientChipView.trailingAnchor, constant: -4),
            recipientClearButton.centerYAnchor.constraint(equalTo: recipientChipView.centerYAnchor),
            recipientClearButton.widthAnchor.constraint(equalToConstant: 18),
            recipientClearButton.heightAnchor.constraint(equalToConstant: 18),
            recipientChipView.heightAnchor.constraint(equalToConstant: 30),
            notifyCheckButton.widthAnchor.constraint(equalToConstant: 16),
            notifyCheckButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        refreshRecipientRow()
    }

    /// @ 行状态：新建未选 → @ + “@ 谁”钮；新建已选 → chip + ×；
    /// 编辑模式 → 可改选可清除：已清除且未重选 → “@ 谁”钮；已改选 → 新 chip + ×；
    /// 未动 → 原 @ chip + ×；编辑且无 @ → “@ 谁”钮。@ 提醒无按篇开关，通知行一律隐藏。
    private func refreshRecipientRow() {
        if isEditMode {
            notifyGroup.isHidden = true
            if editMentionCleared, selectedRecipient == nil {
                recipientPickButton.isHidden = false
                recipientChipView.isHidden = true
            } else if let user = selectedRecipient {
                let name: String
                if let display = user.displayName {
                    name = display
                } else if let handle = user.handle {
                    name = handle
                } else {
                    name = "用户"
                }
                recipientPickButton.isHidden = true
                recipientChipView.isHidden = false
                if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
                    recipientChipAvatar.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 22 * UIScreen.main.scale)
                    recipientChipAvatar.isHidden = false
                    recipientChipFallback.isHidden = true
                } else {
                    recipientChipAvatar.isHidden = true
                    recipientChipFallback.isHidden = false
                    recipientChipFallback.text = String(name.prefix(1)).uppercased()
                }
                recipientChipName.text = "@" + name
                recipientClearButton.isHidden = false
            } else if let name = lockedRecipientName {
                recipientPickButton.isHidden = true
                recipientChipView.isHidden = false
                recipientChipAvatar.isHidden = true
                recipientChipFallback.isHidden = false
                recipientChipFallback.text = String(name.prefix(1)).uppercased()
                recipientChipName.text = "@" + name
                recipientClearButton.isHidden = false
            } else {
                recipientPickButton.isHidden = false
                recipientChipView.isHidden = true
            }
            refreshSelectedChips()
            return
        }
        if let user = selectedRecipient {
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                name = "用户"
            }
            recipientPickButton.isHidden = true
            recipientChipView.isHidden = false
            if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
                recipientChipAvatar.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 22 * UIScreen.main.scale)
                recipientChipAvatar.isHidden = false
                recipientChipFallback.isHidden = true
            } else {
                recipientChipAvatar.isHidden = true
                recipientChipFallback.isHidden = false
                recipientChipFallback.text = String(name.prefix(1)).uppercased()
            }
            recipientChipName.text = "@" + name
            recipientClearButton.isHidden = false
            // iCity：@ 提醒无按篇开关，选择条内不显示通知行。
            notifyGroup.isHidden = true
        } else {
            recipientPickButton.isHidden = false
            recipientChipView.isHidden = true
            notifyGroup.isHidden = true
        }
        refreshNotifyCheck()
        refreshSelectedChips()
    }

    /// 通知复选框只改本地状态与自身外观，不重建行（网页版同款规矩）。
    private func refreshNotifyCheck() {
        if notifyRecipient {
            notifyCheckButton.backgroundColor = BearyColors.ink
            // I6：通知复选改用 icon_check 资产；底是 ink、对勾须取反色 bg（深色下 ink 近白）。
            notifyCheckButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 14), for: .normal)
            notifyCheckButton.tintColor = BearyColors.bg
        } else {
            notifyCheckButton.backgroundColor = UIColor.clear
            notifyCheckButton.setImage(nil, for: .normal)
        }
    }

    @objc private func didTapPickRecipient() {
        // iCity：编辑模式也可改选 @（旧“编辑锁定”已废）；不可 @ 自己由选人器自过滤。
        // presented 守卫 + 在途标记（E4-3）：连点不叠开两个选人器。
        if presentedViewController != nil || isRecipientPickerPresenting { return }
        isRecipientPickerPresenting = true
        let picker = BearyRecipientPickerViewController()
        picker.notifyRecipient = self.notifyRecipient
        picker.onPick = { [weak self] user, notify in
            guard let self = self else { return }
            self.selectedRecipient = user
            // iCity：@ 提醒无按篇开关——面板回传的开关值忽略，不进发布请求。
            _ = notify
            self.editMentionCleared = false
            self.refreshRecipientRow()
            self.refreshToolStrip()
            // 网页选人即 saveDraftQuiet 立即落盘，不走防抖（500ms 内杀 App 会丢改动）。
            self.saveDraftNow()
        }
        present(picker, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.isRecipientPickerPresenting = false
        }
    }

    @objc private func didTapClearRecipient() {
        // iCity：编辑模式可清除 @——已改选过则清改选，否则记 editMentionCleared（PUT 显式清）。
        if isEditMode, selectedRecipient == nil {
            editMentionCleared = true
        } else {
            selectedRecipient = nil
        }
        refreshRecipientRow()
        refreshToolStrip()
        saveDraftNow()
    }

    @objc private func didTapNotifyCheck() {
        if isEditMode { return }
        notifyRecipient.toggle()
        refreshNotifyCheck()
        saveDraftNow()
    }

    // MARK: - 引用 lite 卡（网页 diaryCardLite：头像 40 + 名 + 正文 + 图片 +
    // 外层 ×（fixall-composer：卡已复用共享卡，× 在 wrap 层）；
    // 编辑模式引用可改可删，× 同样显示）

    private func buildQuoteSection() {
        quoteSection.axis = .vertical
        quoteSection.spacing = 0
        // 2-4+8-10：引用区复用共享 BearyQuoteCardView，自绘卡（圆角 14 单线框、
        // 正文 16.5、日期 14、图条高 118）已删；字号 13.5 / 图高 42 / 圆角 8 /
        // 左 3pt 线 / faint 底随共享卡走。头像/名不加回（lite 卡去头像名口径不变）。
        // 移除钮作为外层叠加：放在 wrap 层、不进共享卡内部；编辑模式引用仍可删
        // （PUT 清 quote_id，见 didTapRemoveQuote），引用面板入口在编辑态仍锁定
        // （见工具栏守卫），不动。位置注意：共享卡日期在行内右上角，若 × 叠在卡内
        // 右上（原自绘卡 top 8 / right 8）会压住日期尾字，故卡右缩 36（钮宽 28 + 间隙 8），
        // × 落在卡右侧条带、仍顶右对齐，卡内日期/正文/图条零遮挡。
        // 编辑器内引用卡不导航：卡本身交互关闭（onTapped/onRetryTapped 均不接），
        // 移除钮是 wrap 的兄弟视图，故关卡交互不影响移除点按。
        quoteCard.isUserInteractionEnabled = false
        quoteCardRemoveButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 15), for: .normal)
        quoteCardRemoveButton.tintColor = BearyColors.gray
        quoteCardRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        quoteCardRemoveButton.bearyAddPressFeedback()
        for v in [quoteSection, quoteCardWrap, quoteCard, quoteCardRemoveButton, quoteDeletedRow, quoteDeletedLabel, quoteDeletedRemoveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        // 已删态行（恢复用）：灰字 + “移除”钮，默认隐藏；见 refreshQuoteSection。
        quoteDeletedRow.axis = .horizontal
        quoteDeletedRow.spacing = 8
        quoteDeletedRow.alignment = .center
        quoteDeletedRow.isLayoutMarginsRelativeArrangement = true
        quoteDeletedRow.layoutMargins = UIEdgeInsets(top: 16, left: 2, bottom: 14, right: 2)
        quoteDeletedLabel.text = "引用的日记已删除"
        quoteDeletedLabel.font = UIFont.systemFont(ofSize: 13)
        quoteDeletedLabel.textColor = BearyColors.gray
        quoteDeletedRemoveButton.setTitle("移除", for: .normal)
        quoteDeletedRemoveButton.setTitleColor(BearyColors.blue, for: .normal)
        quoteDeletedRemoveButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        quoteDeletedRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        quoteDeletedRemoveButton.bearyAddPressFeedback()
        quoteDeletedRow.addArrangedSubview(quoteDeletedLabel)
        let deletedSpacer = UIView()
        quoteDeletedRow.addArrangedSubview(deletedSpacer)
        quoteDeletedRow.addArrangedSubview(quoteDeletedRemoveButton)
        quoteDeletedRow.isHidden = true
        contentStack.addArrangedSubview(quoteSection)
        quoteSection.addArrangedSubview(quoteCardWrap)
        quoteSection.addArrangedSubview(quoteDeletedRow)
        quoteCardWrap.addSubview(quoteCard)
        quoteCardWrap.addSubview(quoteCardRemoveButton)
        NSLayoutConstraint.activate([
            quoteCard.topAnchor.constraint(equalTo: quoteCardWrap.topAnchor),
            quoteCard.leadingAnchor.constraint(equalTo: quoteCardWrap.leadingAnchor),
            // 卡右缩 36 给外层移除钮留条带（见上注：卡内叠 × 会压日期），钮仍顶右。
            quoteCard.trailingAnchor.constraint(equalTo: quoteCardWrap.trailingAnchor, constant: -36),
            quoteCard.bottomAnchor.constraint(equalTo: quoteCardWrap.bottomAnchor),
            quoteCardRemoveButton.topAnchor.constraint(equalTo: quoteCardWrap.topAnchor, constant: 8),
            quoteCardRemoveButton.trailingAnchor.constraint(equalTo: quoteCardWrap.trailingAnchor, constant: -8),
            quoteCardRemoveButton.widthAnchor.constraint(equalToConstant: 28),
            quoteCardRemoveButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        refreshQuoteSection()
        contentStack.setCustomSpacing(0, after: quoteSection)
    }

    /// 引用区状态：stack 内的隐藏项自动塌掉（UIStackView 口径），无需改约束。
    /// 新建未选 → 挑按钮；新建已选 → 共享卡 + 右上 15px ×（网页 quoteChipX 口径，点即清除引用）；
    /// 编辑 → 锁定的共享卡（面板入口锁定，× 仍可删）或都不显示。
    /// 共享卡口径变化（相对原自绘卡）：正文 13.5 且最多 3 行（原不限行 16.5）、
    /// 图条 42（原 118）、日期走共享卡 feedTimeString（原 BearyText.timeString）。
    /// iCity：私密引用在将公开的宿主里挂“仅你可见”角标（viewer 即作者本人时）。
    private func refreshQuoteSection() {
        let quote = isEditMode ? lockedQuote : selectedQuote
        // C6：编辑模式引用可改可删（有引用露共享卡 + ×，无引用则本区塌掉）；
        // 引用改走工具栏引用钮；@ 改走工具栏 @ 钮。
        guard let shown = quote else {
            quoteCardWrap.isHidden = true
            quoteDeletedRow.isHidden = true
            updatePreferredContentSize()
            return
        }
        if shown.isDeleted {
            // 已删态：不画共享卡（无作者/正文/图片可信），只留灰字行 + “移除”钮；
            // 已删引用仍占槽位（清除后才可经工具栏引用钮再选）。
            quoteCardWrap.isHidden = true
            quoteDeletedRow.isHidden = false
            updatePreferredContentSize()
            return
        }
        quoteDeletedRow.isHidden = true
        quoteCardWrap.isHidden = false
        // allowThumbs: true 沿用旧编辑器行为——已选引用在本地草稿预览中恒出图；
        // 列表侧的 isPublic/本人门控不适用于编辑器预览（预览不出公开发布）。
        // 仅你可见角标：被引私密 + 宿主将公开（新建看可见性钮状态，编辑看原可见性）。
        // 补缺 P3-42：编辑态宿主可见性走有效态（过期即私密），原 editingEntry?.isPublic 原始值。
        let hostWillBePublic = isEditMode ? (editingEntry.map { BearyEphemeral.isEffectivelyPublic($0) } == true) : selectedVisibilityPublished
        quoteCard.configure(authorName: shown.authorName ?? "", authorAvatar: shown.authorAvatar, content: shown.content, images: shown.images, dims: shown.imgDims, createdAt: shown.createdAt, allowThumbs: true, showOnlyYouBadge: shown.isPublic != true && hostWillBePublic)
        updatePreferredContentSize()
    }

    /// C1：引用唯一入口为工具栏引用钮（见 didTapQuoteTool）；正文中部挑钮已删。

    /// lite 卡右上 × / 已删行“移除”：清除已选引用（网页 quoteChipX 口径；C6：编辑模式
    /// 同样可删，PUT 时 lockedQuote 为空即清旧引用；新建模式清除后立即落盘）。
    @objc private func didTapRemoveQuote() {
        if isEditMode {
            lockedQuote = nil
        } else {
            selectedQuote = nil
            saveDraftNow()
        }
        refreshQuoteSection()
    }

    // MARK: - 引用面板 qp-mode（网页 qpEnterMode/qpExitMode 同款整编形态：
    // 打开时只留面板、发布钮隐藏、取消变“返回”只退面板、进出保存/恢复滚动位置）

    private func buildQuotePanel() {
        quotePanel.translatesAutoresizingMaskIntoConstraints = false
        // 自定义 tab 条（网页 qp-seg-in）：容器 padding 3、faint 底、圆角 999；
        // 钮 13.5/600、padding 6/16；选中墨字 + surface 底（网页滑块指示的静态等价），未选灰字无底。
        // R7(a)：tab 条此前无显式高度、高度全靠钮固有高撑开，任一固有高异常即帧
        // 塌陷成 0 高不可见；现给容器显式高度 36（padding 3×2 + 钮高 30，钮上下
        // 内边距 6×2 + 13.5 字高，栈 fill 拉满不裁字）。faint 为不透明实色
        // （alpha 1），不是透明/玻璃，选中态文字仍为深色 ink，排除渲染不可见。
        quoteTabBarContainer.translatesAutoresizingMaskIntoConstraints = false
        quoteTabBarContainer.backgroundColor = BearyColors.faint
        quoteTabBarContainer.layer.cornerRadius = 999
        quoteTabBarContainer.layer.masksToBounds = true
        quoteTabStack.translatesAutoresizingMaskIntoConstraints = false
        quoteTabStack.axis = .horizontal
        quoteTabStack.spacing = 0
        quoteTabStack.alignment = .fill
        let tabTitles = ["我的日记", "赞过的", "收藏的"]
        for title in tabTitles {
            let tabButton = UIButton(type: .system)
            tabButton.translatesAutoresizingMaskIntoConstraints = false
            tabButton.setTitle(title, for: .normal)
            tabButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
            tabButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
            tabButton.layer.cornerRadius = 999
            tabButton.layer.masksToBounds = true
            tabButton.addTarget(self, action: #selector(didTapQuoteTab(_:)), for: .touchUpInside)
            tabButton.bearyAddPressFeedback()
            quoteTabButtons.append(tabButton)
            quoteTabStack.addArrangedSubview(tabButton)
        }
        refreshQuoteTabs()
        quotePanelSpinner.translatesAutoresizingMaskIntoConstraints = false
        quotePanelLoadingLabel.translatesAutoresizingMaskIntoConstraints = false
        quotePanelLoadingLabel.font = UIFont.systemFont(ofSize: 13)
        quotePanelLoadingLabel.textColor = BearyColors.gray
        quotePanelLoadingLabel.textAlignment = .center
        quotePanelLoadingLabel.text = "正在加载可引用的日记…"
        quotePanelLoadingLabel.isHidden = true
        quotePanelEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        quotePanelEmptyLabel.font = UIFont.systemFont(ofSize: 15)
        quotePanelEmptyLabel.textColor = BearyColors.gray
        quotePanelEmptyLabel.textAlignment = .center
        quotePanelEmptyLabel.text = "还没有可引用的日记"
        quotePanelEmptyLabel.isHidden = true
        quotePanelRetryButton.translatesAutoresizingMaskIntoConstraints = false
        quotePanelRetryButton.setTitle("加载失败，重试", for: .normal)
        quotePanelRetryButton.setTitleColor(BearyColors.blue, for: .normal)
        quotePanelRetryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        quotePanelRetryButton.isHidden = true
        quotePanelRetryButton.addTarget(self, action: #selector(didTapQuotePanelRetry), for: .touchUpInside)
        quotePanelRetryButton.bearyAddPressFeedback()
        quotePanelRows.translatesAutoresizingMaskIntoConstraints = false
        quotePanelRows.axis = .vertical
        quotePanelRows.spacing = 0
        contentStack.addArrangedSubview(quotePanel)
        quotePanel.addSubview(quoteTabBarContainer)
        quoteTabBarContainer.addSubview(quoteTabStack)
        quotePanel.addSubview(quotePanelSpinner)
        quotePanel.addSubview(quotePanelLoadingLabel)
        quotePanel.addSubview(quotePanelEmptyLabel)
        quotePanel.addSubview(quotePanelRetryButton)
        quotePanel.addSubview(quotePanelRows)
        NSLayoutConstraint.activate([
            // 2026-10-29 第 26 项：列表顶贴导航栏、无顶隙——tab 条顶距面板顶 0
            //（原 10）、行顶距 tab 条底 0（原 4）；左右 16 仍由 contentStack 边距提供，
            // 容器在面板内居中（网页 qp-seg justify-content:center）。
            quoteTabBarContainer.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 0),
            // R7(a)：tab 条显式高度，不再只靠钮固有高撑开。
            quoteTabBarContainer.heightAnchor.constraint(equalToConstant: 36),
            quoteTabBarContainer.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quoteTabBarContainer.leadingAnchor.constraint(greaterThanOrEqualTo: quotePanel.leadingAnchor),
            quoteTabBarContainer.trailingAnchor.constraint(lessThanOrEqualTo: quotePanel.trailingAnchor),
            quoteTabStack.topAnchor.constraint(equalTo: quoteTabBarContainer.topAnchor, constant: 3),
            quoteTabStack.bottomAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: -3),
            quoteTabStack.leadingAnchor.constraint(equalTo: quoteTabBarContainer.leadingAnchor, constant: 3),
            quoteTabStack.trailingAnchor.constraint(equalTo: quoteTabBarContainer.trailingAnchor, constant: -3),
            quotePanelSpinner.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelSpinner.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelSpinner.widthAnchor.constraint(equalToConstant: 20),
            quotePanelSpinner.heightAnchor.constraint(equalToConstant: 20),
            quotePanelLoadingLabel.topAnchor.constraint(equalTo: quotePanelSpinner.bottomAnchor, constant: 8),
            quotePanelLoadingLabel.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelLoadingLabel.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelEmptyLabel.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelEmptyLabel.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelEmptyLabel.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelRetryButton.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 16),
            quotePanelRetryButton.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelRows.topAnchor.constraint(equalTo: quoteTabBarContainer.bottomAnchor, constant: 0),
            quotePanelRows.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelRows.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelRows.bottomAnchor.constraint(equalTo: quotePanel.bottomAnchor),
        ])
        // 2026-10-29 第 26 项：面板背板改回页面底色 bg（不再是内缩的灰色容器；
        // 原 surface 底在深色下呈 #26262c 灰框，与页底黑底形成方框感）。
        // tab 条 faint 底在 bg 面板上仍有区分，选中钮 surface 底在 faint 条上亦可见。
        quotePanel.backgroundColor = BearyColors.bg
        quotePanel.isHidden = true
        contentStack.setCustomSpacing(16, after: quotePanel)
    }

    /// 自定义 tab 选中态：选中墨字 + surface 底，未选灰字无底（与旧系统分段控件的
    /// 选中序号语义一一对应，tab 值仍走 quotePanelTab）。
    /// R7(a) 复核：选中态文字为深色 ink（非灰/非透明），在 faint 实色条上可读。
    /// D-G17：网页选中滑块带阴影（0 1px 6px 黑 12% + 0 0 0 1px 黑 4%）；
    /// App 选中钮补同值阴影（单层 shadow 画不出双层，故 1px 环用同色描边近似，
    /// 描边在内侧 1px）；选中态须关 masksToBounds 否则阴影被裁，未选恢复。
    private func refreshQuoteTabs() {
        for tabIndex in 0..<quoteTabButtons.count {
            let tabButton = quoteTabButtons[tabIndex]
            let isSelected = (tabIndex == 0 && quotePanelTab == "timeline") || (tabIndex == 1 && quotePanelTab == "liked") || (tabIndex == 2 && quotePanelTab == "saved")
            tabButton.backgroundColor = isSelected ? BearyColors.surface : UIColor.clear
            tabButton.setTitleColor(isSelected ? BearyColors.ink : BearyColors.gray, for: .normal)
            if isSelected {
                tabButton.layer.masksToBounds = false
                tabButton.layer.shadowColor = UIColor.black.cgColor
                tabButton.layer.shadowOpacity = 0.12
                tabButton.layer.shadowRadius = 6
                tabButton.layer.shadowOffset = CGSize(width: 0, height: 1)
                tabButton.layer.borderWidth = 1
                tabButton.layer.borderColor = UIColor.black.withAlphaComponent(0.04).cgColor
            } else {
                tabButton.layer.masksToBounds = true
                tabButton.layer.shadowOpacity = 0
                tabButton.layer.borderWidth = 0
            }
        }
    }

    /// 引用面板 qp-mode 整编形态（网页 qpEnterMode/qpExitMode 同款）：
    /// 打开时只留面板：正文/图片条/工具栏/附加栏/天气/状态行/写给/心情/引用区/规则框
    /// 全部隐藏，发布钮隐藏、取消变“返回”；关闭时只退面板，不走整编取消流程，
    /// 并恢复打开前保存的外层滚动位置。编辑模式同样可用（C6），不再早退。
    private func setQuotePanelOpen(_ open: Bool) {
        if open == quotePanelOpen {
            return
        }
        quotePanelOpen = open
        if open {
            // 审计 P2-24：面板新开时入场键集清零（本轮打开内换 tab 不重播，关闭重开再播）。
            quotePanelAnimatedRowKeys.removeAll()
            quotePanelSavedScrollOffset = scrollView.contentOffset
            quotePanelSavedScrollValid = true
            view.endEditing(true)
            // A4-App：引用面板整编态下标题框与正文同藏，关闭时同恢复。
            titleField.isHidden = true
            textView.isHidden = true
            imageScrollView.isHidden = true
            toolbarContainer.isHidden = true
            toolStripStack.isHidden = true
            weatherScrollView.isHidden = true
            selectedChipsRow.isHidden = true
            imageUndoBar.isHidden = true
            statusRow.isHidden = true
            updateScrollBottomAnchoring()
            updateMoodPlayback()
            updateWeatherPlayback()
            refreshImageUndoBar()
            quoteSection.isHidden = true
            // 间隙修复（只动布局）：滚动归零不影响开头已保存的恢复偏移；面板前各区栈间距显式置 0，
            // 否则隐藏区塌掉后残留 customSpacing 会在面板上方留空隙；tab 条显式可见后先落一次布局，
            // 再显示面板，首帧即按无间隙高度算。
            scrollView.contentOffset = CGPoint.zero
            // 2026-10-29 第 26 项：补漏——titleField 的 8 间距此前打开时未置 0
            //（其余四处已在间隙修复中置 0），隐藏区塌掉后残留间距会在面板上方留空隙。
            contentStack.setCustomSpacing(0, after: titleField)
            contentStack.setCustomSpacing(0, after: textView)
            contentStack.setCustomSpacing(0, after: imageScrollView)
            contentStack.setCustomSpacing(0, after: statusRow)
            contentStack.setCustomSpacing(0, after: quoteSection)
            quoteTabBarContainer.isHidden = false
            view.layoutIfNeeded()
            quotePanel.isHidden = false
            // 录屏批 (b)：面板标题不再沿用“新日记”/“编辑日记”，打开前先存原标题。
            quotePanelSavedTitle = titleLabel.text
            titleLabel.text = "选择引用"
            // v6-1：取消钮已无文字，双态只改 VoiceOver 语义：面板打开时读“返回”，点它仍只退面板（didTapCancel 分支不变）。
            cancelButton.accessibilityLabel = "返回"
            publishButton.isHidden = true
            // 编辑器改版：引用面板打开时顶栏草稿 pill 随发布钮同藏（旧时工具栏整体藏，pill 在其中）；
            // 可见性钮同藏（与发布钮同组，关闭时按编辑模式恢复）。
            draftPillButton.isHidden = true
            visibilityButton.isHidden = true
            // 弹出框若开着也一并收起，不让它浮在面板上。
            hideCallout(animated: false)
            refreshQuoteTabs()
            // 录屏批 (e)：原顺序先 layout 再显示面板，转圈在 load 里起在面板布局
            // 落定之前，首帧会落在面板收起态位置（编辑器中央一闪）再跳到面板里；
            // 此处面板已显示，再落一次布局，帧 settle 后才起转圈，转圈首帧即在面板内。
            view.layoutIfNeeded()
            loadQuotePanelTab()
            // M6：面板打开带透明度过渡（高度随 preferredContentSize 由呈现层跟进；减动效直设终值）。
            if UIAccessibility.isReduceMotionEnabled {
                quotePanel.alpha = 1
            } else {
                quotePanel.alpha = 0
                UIView.animate(withDuration: 0.25) { self.quotePanel.alpha = 1 }
            }
        } else {
            // M6：关闭先 0.2s 淡出再恢复各区（减动效直接恢复）；恢复后重算 sheet 高。
            let applyClose = {
                self.quotePanel.isHidden = true
                // 录屏批 (b/e)：关闭即停转圈、藏加载文案（在途请求的回包另有面板守卫，
                // 不会把转圈顶回已关闭的面板），标题还原打开前存的那句。
                self.quotePanelSpinner.stopSpinning()
                self.quotePanelLoadingLabel.isHidden = true
                if let savedTitle = self.quotePanelSavedTitle {
                    self.titleLabel.text = savedTitle
                    self.quotePanelSavedTitle = nil
                } else {
                    self.titleLabel.text = self.isEditMode ? "编辑日记" : "新日记"
                }
                self.titleField.isHidden = false
                self.textView.isHidden = false
                self.toolbarContainer.isHidden = false
                self.selectedChipsRow.isHidden = false
                self.statusRow.isHidden = false
                self.quoteSection.isHidden = false
                self.cancelButton.accessibilityLabel = "取消"
                self.publishButton.isHidden = false
                self.draftPillButton.isHidden = false
                self.visibilityButton.isHidden = self.isEditMode
                // 间隙修复的关闭恢复：把打开时置 0 的栈间距按 build 时原值还原（其余区同 build 原值）。
                self.contentStack.setCustomSpacing(8, after: self.titleField)
                self.contentStack.setCustomSpacing(12, after: self.textView)
                self.contentStack.setCustomSpacing(4, after: self.imageScrollView)
                self.contentStack.setCustomSpacing(8, after: self.statusRow)
                self.contentStack.setCustomSpacing(0, after: self.quoteSection)
                // 各区显隐按正常态重算（选择条、@ 行、引用区）。
                self.refreshToolStrip()
                self.refreshRecipientRow()
                self.refreshQuoteSection()
                self.refreshImageStripVisibility()
                self.refreshImageUndoBar()
                if self.quotePanelSavedScrollValid {
                    self.quotePanelSavedScrollValid = false
                    self.view.layoutIfNeeded()
                    self.scrollView.setContentOffset(self.quotePanelSavedScrollOffset, animated: false)
                }
                self.updatePreferredContentSize()
            }
            if UIAccessibility.isReduceMotionEnabled {
                applyClose()
            } else {
                UIView.animate(withDuration: 0.2, animations: {
                    self.quotePanel.alpha = 0
                }, completion: { _ in
                    applyClose()
                    self.quotePanel.alpha = 1
                })
            }
        }
        updatePreferredContentSize()
    }

    /// C1：scrollView 底锚三档切换——引用面板打开时锚整页底（工具栏与选择条都藏，
    /// 不留空隙）；选择条展开时锚选择条顶（条不盖住正文尾部）；其余时锚工具栏顶。
    /// 改锚只发生在这两处：选择条刷新（refreshToolStrip）与引用面板开关。
    private func updateScrollBottomAnchoring() {
        // 2026-10-29 第 27 项：心情条开时滚动区底锚限时行顶——行此时在条上方，
        // 故滚动区停在行顶即停在条顶之上（编辑模式行高 0，顶 = 条顶，同值）；
        // 其余选择条仍锚栈顶（栈在行上方）。
        let moodOpen = activeToolStrip == .mood && !quotePanelOpen
        let weatherOpen = activeToolStrip == .weather && !quotePanelOpen
        let otherStripOpen = activeToolStrip != nil && activeToolStrip != .mood && activeToolStrip != .weather && !quotePanelOpen
        scrollBottomToToolbarConstraint?.isActive = !quotePanelOpen && !moodOpen && !weatherOpen && !otherStripOpen && isEditMode
        scrollBottomToVisibilityConstraint?.isActive = !quotePanelOpen && (moodOpen || weatherOpen || (!otherStripOpen && !isEditMode))
        scrollBottomToStripConstraint?.isActive = otherStripOpen
        scrollBottomToViewConstraint?.isActive = quotePanelOpen
    }

    @objc private func didTapVisibilityButton() {
        selectedVisibilityPublished.toggle()
        refreshVisibilityButton()
    }

    /// 顶栏可见性钮图标：锁＝私密、地球＝公开，随 selectedVisibilityPublished 走；
    /// 可用态另由限时锁（didToggleEphemeral／restoreVisibility）与发布冻结
    ///（refreshPublishingInputFreeze）管，本函数不动 isEnabled。
    private func refreshVisibilityButton() {
        let published = selectedVisibilityPublished
        visibilityButton.setImage(BearyIconImages.image(named: published ? "icon_globe" : "icon_lock", pointSize: 24), for: .normal)
        visibilityButton.accessibilityValue = published ? "公开" : "私密"
    }

    @objc private func didToggleEphemeral() {
        if ephemeralSwitch.isOn {
            // 限时即公开：可见性定公开且钮锁死，改不了私密（限时 + 私密本身无意义）。
            selectedVisibilityPublished = true
            visibilityButton.isEnabled = false
        } else {
            selectedVisibilityPublished = false
            visibilityButton.isEnabled = true
        }
        refreshVisibilityButton()
    }

    @objc private func didTapQuoteTab(_ sender: UIButton) {
        var tappedIndex = 0
        for tabIndex in 0..<quoteTabButtons.count {
            if quoteTabButtons[tabIndex] == sender {
                tappedIndex = tabIndex
            }
        }
        switch tappedIndex {
        case 1: quotePanelTab = "liked"
        case 2: quotePanelTab = "saved"
        default: quotePanelTab = "timeline"
        }
        refreshQuoteTabs()
        loadQuotePanelTab()
    }

    @objc private func didTapQuotePanelRetry() {
        quotePanelCache.removeValue(forKey: quotePanelTab)
        loadQuotePanelTab()
    }

    private func quotePanelScope() -> BearyAPI.Scope {
        switch quotePanelTab {
        case "liked": return .liked
        case "saved": return .saved
        default: return .timeline
        }
    }

    private func loadQuotePanelTab() {
        // 录屏批 (e)：面板已关时不启动加载指示（关闭淡出中误点 tab/重试也不起转圈，
        // 转圈只活在打开的面板里）；缓存分支也要停转圈——旧代码缓存返回时不 stop，
        // 上一次未缓存加载的转圈会残留到缓存行上。
        guard quotePanelOpen else {
            quotePanelSpinner.stopSpinning()
            quotePanelLoadingLabel.isHidden = true
            return
        }
        if let cached = quotePanelCache[quotePanelTab] {
            quotePanelLoading = false
            quotePanelFailed = false
            quotePanelSpinner.stopSpinning()
            quotePanelLoadingLabel.isHidden = true
            renderQuotePanelRows(entries: cached)
            return
        }
        quotePanelLoading = true
        quotePanelFailed = false
        quotePanelSpinner.startSpinning()
        quotePanelLoadingLabel.isHidden = false
        quotePanelEmptyLabel.isHidden = true
        quotePanelRetryButton.isHidden = true
        for arranged in quotePanelRows.arrangedSubviews {
            quotePanelRows.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        quotePanelSeq += 1
        let seq = quotePanelSeq
        let tab = quotePanelTab
        BearyAPI.shared.fetchEntries(scope: quotePanelScope(), limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, seq == self.quotePanelSeq, tab == self.quotePanelTab else { return }
                self.quotePanelSpinner.stopSpinning()
                self.quotePanelLoadingLabel.isHidden = true
                self.quotePanelLoading = false
                switch result {
                case .success(let list):
                    // 网页 qpLoad 同款：排除正在编的那篇自身（编辑模式）；新建模式无自身可排。
                    var entries = list.entries ?? []
                    if let selfId = self.editingEntry?.id, !selfId.isEmpty {
                        entries = entries.filter { $0.id != selfId }
                    }
                    self.quotePanelCache[tab] = entries
                    self.quotePanelFailed = false
                    // 面板已关闭时只缓存不渲染（回包晚到不顶回已关闭的面板）。
                    if self.quotePanelOpen {
                        self.renderQuotePanelRows(entries: entries)
                    }
                case .failure:
                    self.quotePanelFailed = true
                    self.quotePanelRetryButton.isHidden = false
                }
            }
        }
    }

    /// 面板行空态文案按 tab 分三句（网页 QP_EMPTY 同款：我的/赞过的/收藏的）。
    private func quotePanelEmptyText() -> String {
        switch quotePanelTab {
        case "liked": return "还没有赞过的日记"
        case "saved": return "还没有收藏的日记"
        default: return "还没有可引用的日记"
        }
    }

    /// 面板行：完整 lite 卡（网页 diaryCardLite 同款：头像 40 + 名 + 日期 + 全文 +
    /// 118 图片条 + 天气图标；名截断优先；Plus 皇冠已按清单取消显示；iCity：无 pill）。
    private func renderQuotePanelRows(entries: [Entry]) {
        for arranged in quotePanelRows.arrangedSubviews {
            quotePanelRows.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        quotePanelRowEntries = []
        quotePanelRowButtons = []
        // 录屏批 (e/f)：行渲染即加载结束，转圈与加载文案到此为止，不留残影。
        quotePanelSpinner.stopSpinning()
        quotePanelLoadingLabel.isHidden = true
        quotePanelEmptyLabel.text = quotePanelEmptyText()
        quotePanelEmptyLabel.isHidden = !entries.isEmpty
        quotePanelRetryButton.isHidden = !quotePanelFailed
        for entry in entries {
            // 审计 P0-2：选择引用加卡片同款 viewer 门控——赞过/收藏 tab 里翻回私密的
            // 他人日记不得出全文：只显占位行、不可选（作者本人或有效公开才出全文行）。
            // 占位文案与审计 P3-27 统一口径“该日记已设为私密”。
            let viewerId = SessionManager.shared.currentUser?.id
            let quoteIsAuthor = entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId)
            if !quoteIsAuthor && !BearyEphemeral.isEffectivelyPublic(entry) {
                let lockedButton = UIButton(type: .custom)
                lockedButton.translatesAutoresizingMaskIntoConstraints = false
                lockedButton.isEnabled = false
                let lockedLabel = UILabel()
                lockedLabel.translatesAutoresizingMaskIntoConstraints = false
                lockedLabel.font = UIFont.systemFont(ofSize: 15)
                lockedLabel.textColor = BearyColors.gray
                lockedLabel.text = "该日记已设为私密"
                let lockedSeparator = UIView()
                lockedSeparator.translatesAutoresizingMaskIntoConstraints = false
                lockedSeparator.backgroundColor = BearyColors.line
                lockedButton.addSubview(lockedLabel)
                lockedButton.addSubview(lockedSeparator)
                NSLayoutConstraint.activate([
                    lockedLabel.topAnchor.constraint(equalTo: lockedButton.topAnchor, constant: 16),
                    lockedLabel.leadingAnchor.constraint(equalTo: lockedButton.leadingAnchor, constant: 16),
                    lockedLabel.trailingAnchor.constraint(equalTo: lockedButton.trailingAnchor, constant: -16),
                    lockedSeparator.topAnchor.constraint(equalTo: lockedLabel.bottomAnchor, constant: 16),
                    lockedSeparator.leadingAnchor.constraint(equalTo: lockedButton.leadingAnchor, constant: 16),
                    lockedSeparator.trailingAnchor.constraint(equalTo: lockedButton.trailingAnchor, constant: -16),
                    lockedSeparator.heightAnchor.constraint(equalToConstant: 2),
                    lockedSeparator.bottomAnchor.constraint(equalTo: lockedButton.bottomAnchor),
                ])
                quotePanelRows.addArrangedSubview(lockedButton)
                // 平行映射保持对齐（占位行无点按目标，绝不触发选择；入场动画同行）。
                quotePanelRowEntries.append(entry)
                quotePanelRowButtons.append(lockedButton)
                continue
            }
            let rowButton = UIButton(type: .custom)
            rowButton.translatesAutoresizingMaskIntoConstraints = false
            let authorName = entry.authorName ?? "用户"
            let avatarView = UIImageView()
            avatarView.translatesAutoresizingMaskIntoConstraints = false
            avatarView.contentMode = .scaleAspectFill
            avatarView.clipsToBounds = true
            avatarView.layer.cornerRadius = 20
            avatarView.layer.masksToBounds = true
            let avatarFallback = UILabel()
            avatarFallback.translatesAutoresizingMaskIntoConstraints = false
            avatarFallback.font = UIFont.boldSystemFont(ofSize: 16)
            avatarFallback.textColor = BearyColors.gray
            avatarFallback.backgroundColor = BearyColors.faint
            avatarFallback.textAlignment = .center
            avatarFallback.layer.cornerRadius = 20
            avatarFallback.layer.masksToBounds = true
            if let avatarPath = entry.authorAvatar, let url = BearyImageURLs.avatarURL(avatarPath) {
                avatarView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 40 * UIScreen.main.scale)
                avatarView.isHidden = false
                avatarFallback.isHidden = true
            } else {
                avatarView.isHidden = true
                avatarFallback.isHidden = false
                avatarFallback.text = String(authorName.prefix(1)).uppercased()
            }
            // 头行：名（截断优先）+ 皇冠 + 日期 + 天气，横向 stack（iCity：无 pill）。
            let headerStack = UIStackView()
            headerStack.translatesAutoresizingMaskIntoConstraints = false
            headerStack.axis = .horizontal
            headerStack.spacing = 8
            headerStack.alignment = .center
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
            nameLabel.textColor = BearyColors.ink
            nameLabel.numberOfLines = 1
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.text = authorName
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerStack.addArrangedSubview(nameLabel)
            // 崩溃 2（21:38 引用面板 mutuallyExclusiveConstraints）：此前这里建一个
            // isHidden=true 的皇冠图，加进横向 headerStack 后再激活 required 宽 19。
            // UIStackView 给隐藏 arranged 子项激活 required 的 'UISV-hiding' 宽 0 约束，
            // 再激活宽 19 即与系统约束互斥抛错（栈帧：直接 activate ← renderQuotePanelRows，
            // 无 UIStackView 帧，因冲突约束在 addArrangedSubview 时已激活）。
            // 皇冠按清单本就一律隐藏（零像素贡献），故直接不建该视图——资产与
            // authorPlus 数据不动，只删这个永不显示的视图；显式尺寸 + 隐藏入栈
            // 的组合今后也不许再出现（要藏就别入栈，要入栈就别给 required 尺寸）。
            // 22:44 订正：皇冠删后 71 包仍同栈崩，证实真因不在皇冠——是下方
            // separator 只创建未挂载（见 rowButton.addSubview(separator) 处注释）。
            let dateLabel = UILabel()
            dateLabel.translatesAutoresizingMaskIntoConstraints = false
            dateLabel.font = UIFont.systemFont(ofSize: 13)
            dateLabel.textColor = BearyColors.gray
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            if let ms = entry.createdAt {
                dateLabel.text = quoteRowDate(ms: ms)
            } else {
                dateLabel.text = nil
            }
            headerStack.addArrangedSubview(dateLabel)
            if let weather = entry.weather {
                let weatherView = UIImageView()
                weatherView.translatesAutoresizingMaskIntoConstraints = false
                weatherView.image = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 15)
                weatherView.tintColor = BearyColors.gray
                weatherView.contentMode = .scaleAspectFit
                weatherView.setContentCompressionResistancePriority(.required, for: .horizontal)
                headerStack.addArrangedSubview(weatherView)
                NSLayoutConstraint.activate([
                    weatherView.widthAnchor.constraint(equalToConstant: 15),
                    weatherView.heightAnchor.constraint(equalToConstant: 15),
                ])
            }
            // iCity：选篇行不再挂倒计时 pill（送达模型已废）；私密与公开行均无 pill。
            let contentLabel = UILabel()
            contentLabel.translatesAutoresizingMaskIntoConstraints = false
            contentLabel.numberOfLines = 0
            contentLabel.font = UIFont.systemFont(ofSize: 16.5)
            contentLabel.textColor = BearyColors.ink
            let panelParagraph = NSMutableParagraphStyle()
            panelParagraph.lineHeightMultiple = 1.75
            contentLabel.attributedText = NSAttributedString(string: entry.content ?? "", attributes: [.font: UIFont.systemFont(ofSize: 16.5), .foregroundColor: BearyColors.ink, .paragraphStyle: panelParagraph])
            let separator = UIView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.backgroundColor = BearyColors.line
            rowButton.addSubview(avatarView)
            rowButton.addSubview(avatarFallback)
            rowButton.addSubview(headerStack)
            rowButton.addSubview(contentLabel)
            // 22:44 引用闪退真因：separator 此前只创建未挂载，约束却锚向 rowButton 子树，
            // 无公共祖先致 activate 在首行当场抛错（与条目内容、Plus、天气、图片全无关）；
            // 必须先挂载再激活，否则每渲染必崩。
            rowButton.addSubview(separator)
            var lastBottomAnchor: NSLayoutYAxisAnchor = contentLabel.bottomAnchor
            var lastBottomConstant: CGFloat = 14
            let entryImages = entry.images ?? []
            if !entryImages.isEmpty {
                let imagesScrollView = UIScrollView()
                imagesScrollView.translatesAutoresizingMaskIntoConstraints = false
                imagesScrollView.showsHorizontalScrollIndicator = false
                let imagesStack = UIStackView()
                imagesStack.translatesAutoresizingMaskIntoConstraints = false
                imagesStack.axis = .horizontal
                imagesStack.spacing = 8
                imagesStack.alignment = .center
                rowButton.addSubview(imagesScrollView)
                imagesScrollView.addSubview(imagesStack)
                for key in entryImages {
                    let imageView = UIImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.contentMode = .scaleAspectFill
                    imageView.clipsToBounds = true
                    imageView.layer.cornerRadius = 10
                    imageView.layer.masksToBounds = true
                    if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                        // B3-2：面板行图与引用条同规格（高 118、宽 65–262），取上限 262。
                        imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 262 * UIScreen.main.scale)
                    }
                    imagesStack.addArrangedSubview(imageView)
                    // 高 118、宽按原图比例（网页 stripW 口径：65–262 夹取）；无尺寸时兜底 153。
                    var thumbWidth: CGFloat = 153
                    if let dims = entry.imgDims, let pair = dims[key], pair.count >= 2, pair[0] > 0, pair[1] > 0 {
                        thumbWidth = min(262, max(65, round(118 * CGFloat(pair[0]) / CGFloat(pair[1]))))
                    }
                    imageView.widthAnchor.constraint(equalToConstant: thumbWidth).isActive = true
                    imageView.heightAnchor.constraint(equalToConstant: 118).isActive = true
                }
                NSLayoutConstraint.activate([
                    imagesScrollView.topAnchor.constraint(equalTo: contentLabel.bottomAnchor, constant: 10),
                    imagesScrollView.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                    imagesScrollView.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                    imagesScrollView.heightAnchor.constraint(equalToConstant: 118),
                    imagesStack.topAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.topAnchor),
                    imagesStack.bottomAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.bottomAnchor),
                    imagesStack.leadingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.leadingAnchor),
                    imagesStack.trailingAnchor.constraint(equalTo: imagesScrollView.contentLayoutGuide.trailingAnchor),
                    imagesStack.heightAnchor.constraint(equalTo: imagesScrollView.frameLayoutGuide.heightAnchor),
                ])
                lastBottomAnchor = imagesScrollView.bottomAnchor
                lastBottomConstant = 14
            }
            NSLayoutConstraint.activate([
                avatarView.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                avatarView.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 2),
                avatarView.widthAnchor.constraint(equalToConstant: 40),
                avatarView.heightAnchor.constraint(equalToConstant: 40),
                avatarFallback.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                avatarFallback.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 2),
                avatarFallback.widthAnchor.constraint(equalToConstant: 40),
                avatarFallback.heightAnchor.constraint(equalToConstant: 40),
                headerStack.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                headerStack.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                headerStack.trailingAnchor.constraint(lessThanOrEqualTo: rowButton.trailingAnchor, constant: -2),
                contentLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
                contentLabel.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                contentLabel.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                separator.topAnchor.constraint(equalTo: lastBottomAnchor, constant: lastBottomConstant),
                // R7(c)：分隔线 leading 与正文左边缘对齐：正文/头行 leading 均为 54
                //（头像 40 + 左距 2 + 间距 12），此前分隔线从头像左边缘（2）起。
                separator.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                separator.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                // 2026-10-29 第 26 项：行间分隔线按详情页口径用 2pt（原 1pt）；
                // leading/trailing 不动（行内内容：头像、名字、时间、正文一字不动）。
                separator.heightAnchor.constraint(equalToConstant: 2),
                separator.bottomAnchor.constraint(equalTo: rowButton.bottomAnchor),
            ])
            rowButton.addTarget(self, action: #selector(didTapQuotePanelRow(_:)), for: .touchUpInside)
            rowButton.bearyAddPressHaptic()
            rowButton.accessibilityLabel = entry.content ?? ""
            quotePanelRows.addArrangedSubview(rowButton)
            // 行与日记的并行映射：渲染时同步重建，点行时按按钮身份取对应日记。
            quotePanelRowEntries.append(entry)
            quotePanelRowButtons.append(rowButton)
        }
        // M6：行入场错峰淡入（减动效跳过；审计 P2-24：只播新 key 行——换 tab
        // 重建时已播过的行不重播，错峰序号按本轮新行动，不按绝对行号）。
        if UIAccessibility.isReduceMotionEnabled == false {
            var animIndex = 0
            for (index, button) in quotePanelRowButtons.enumerated() {
                let key = index < quotePanelRowEntries.count ? (quotePanelRowEntries[index].id ?? "row-\(index)") : "row-\(index)"
                guard !quotePanelAnimatedRowKeys.contains(key) else { continue }
                quotePanelAnimatedRowKeys.insert(key)
                button.alpha = 0
                UIView.animate(withDuration: 0.25, delay: Double(animIndex) * 0.03, options: [], animations: {
                    button.alpha = 1
                }, completion: nil)
                animIndex += 1
            }
        }
        updatePreferredContentSize()
    }

    /// 面板行与日记的并行映射（行按钮按顺序与 entries 对应，渲染时同步重建）。
    private var quotePanelRowEntries: [Entry] = []
    private var quotePanelRowButtons: [UIButton] = []
    /// 审计 P2-24：引用面板已播入场行的键集（搜索页 lastResultRowKeys 同口径）——
    /// 换 tab 重建时只播新 key 行，已播行不重播；面板每次打开时清空（见 setQuotePanelOpen）。
    private var quotePanelAnimatedRowKeys: Set<String> = []

    @objc private func didTapQuotePanelRow(_ sender: UIButton) {
        var picked: Entry?
        for index in 0..<quotePanelRowButtons.count {
            if index < quotePanelRowEntries.count && quotePanelRowButtons[index] == sender {
                picked = quotePanelRowEntries[index]
            }
        }
        guard let entry = picked, let entryId = entry.id, let content = entry.content else { return }
        let quote = SelectedQuote(entryId: entryId, content: content, createdAt: entry.createdAt, authorName: entry.authorName, authorAvatar: entry.authorAvatar, images: entry.images ?? [], isPublic: BearyEphemeral.isEffectivelyPublic(entry), publishAt: entry.publishAt, imgDims: entry.imgDims, isDeleted: false)
        if isEditMode {
            lockedQuote = quote
        } else {
            selectedQuote = quote
            // 网页选篇后 saveDraftQuiet 立即落盘，不走防抖。
            saveDraftNow()
        }
        setQuotePanelOpen(false)
        refreshQuoteSection()
    }

    /// 面板行日期：M月d日 HH:mm（与网页 fmtDate 同款）。
    private func quoteRowDate(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - 图片预览（网页 img-preview：无标题、无 + 块，空时整条隐藏）

    private func buildImageRow() {
        imageScrollView.showsHorizontalScrollIndicator = false
        imageStackView.axis = .horizontal
        imageStackView.spacing = 8
        imageStackView.alignment = .center
        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        imageStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(imageScrollView)
        imageScrollView.addSubview(imageStackView)
        NSLayoutConstraint.activate([
            // C11：条高 96 = 单项 84 + 下 padding 12（顶 0）。
            imageScrollView.heightAnchor.constraint(equalToConstant: 96),
            imageStackView.topAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.topAnchor),
            imageStackView.bottomAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            imageStackView.leadingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.leadingAnchor),
            imageStackView.trailingAnchor.constraint(equalTo: imageScrollView.contentLayoutGuide.trailingAnchor),
        ])
        refreshImageStripVisibility()
        contentStack.setCustomSpacing(4, after: imageScrollView)
    }

    /// 图片条显隐：有图才显示（网页 img-preview 空时 display:none）。
    private func refreshImageStripVisibility() {
        imageScrollView.isHidden = imageItems.isEmpty
    }

    // MARK: - 工具栏（C1：左 [图片][心情][天气][@][引用]、右 [字数圆环]；
    // 草稿 pill 已随编辑器改版（2026-10-29）移到顶栏发布钮左边，不再在此处；
    // 容器贴键盘上方、不在内容栈里，见 buildLayout；本函数只布容器内部，
    // 分隔线 + 工具行约束不变，工具行左右仍与内容栈边距同宽 16）

    private func buildToolbarRow() {
        toolbarSeparator.backgroundColor = BearyColors.line
        let toolRow = UIStackView()
        toolRow.axis = .horizontal
        toolRow.spacing = 20
        toolRow.alignment = .center
        imageToolButton.setImage(BearyIconImages.image(named: "icon_image", pointSize: 24), for: .normal)
        // P1-26：工具栏图标钮按功能命名（图标本身无文字，VoiceOver 否则无读法）。
        imageToolButton.accessibilityLabel = "添加图片"
        // D-G7：网页 .icon-btn 默认墨色（editor-tools 的 .nb 灰规则不适用这三个钮），工具钮灰改墨。
        imageToolButton.tintColor = BearyColors.ink
        imageToolButton.addTarget(self, action: #selector(didTapAddImage), for: .touchUpInside)
        imageToolButton.bearyAddPressFeedback()
        moodToolButton.setImage(BearyIconImages.image(named: "icon_mood", pointSize: 24), for: .normal)
        moodToolButton.accessibilityLabel = "选择心情"
        moodToolButton.tintColor = BearyColors.ink
        moodToolButton.addTarget(self, action: #selector(didTapMoodTool), for: .touchUpInside)
        moodToolButton.bearyAddPressFeedback()
        // 天气钮图标随选中天气变（见 refreshWeatherButtons 的 syncWxBtn 同款同步）。
        weatherToolButton.setImage(BearyIconImages.image(named: "icon_weather_tool", pointSize: 24), for: .normal)
        weatherToolButton.accessibilityLabel = "选择天气"
        weatherToolButton.tintColor = BearyColors.ink
        weatherToolButton.addTarget(self, action: #selector(didTapWeatherTool), for: .touchUpInside)
        weatherToolButton.bearyAddPressFeedback()
        recipientToolButton.setImage(BearyIconImages.image(named: "icon_at", pointSize: 24), for: .normal)
        recipientToolButton.accessibilityLabel = "@ 谁"
        recipientToolButton.tintColor = BearyColors.ink
        recipientToolButton.addTarget(self, action: #selector(didTapRecipientTool), for: .touchUpInside)
        recipientToolButton.bearyAddPressFeedback()
        quoteToolButton.setImage(BearyIconImages.image(named: "icon_quote", pointSize: 24), for: .normal)
        quoteToolButton.accessibilityLabel = "引用一篇日记"
        quoteToolButton.tintColor = BearyColors.ink
        quoteToolButton.addTarget(self, action: #selector(didTapQuoteTool), for: .touchUpInside)
        quoteToolButton.bearyAddPressFeedback()
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarSeparator.translatesAutoresizingMaskIntoConstraints = false
        toolRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [imageToolButton, moodToolButton, weatherToolButton, recipientToolButton, quoteToolButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        // 容器已由 buildLayout 加到 view 顶栏下方（固定），这里不再进内容栈。
        toolbarContainer.addSubview(toolbarSeparator)
        toolbarContainer.addSubview(toolRow)
        toolRow.addArrangedSubview(imageToolButton)
        toolRow.addArrangedSubview(moodToolButton)
        toolRow.addArrangedSubview(weatherToolButton)
        toolRow.addArrangedSubview(recipientToolButton)
        toolRow.addArrangedSubview(quoteToolButton)
        // v6-5：字数圆环并进左侧图标组——不再被 spacer 顶到右端，与图片／心情／天气／@／引用
        // 同组、同 20pt 间距（toolRow.spacing）；数字已隐藏，只留圆环。
        // v6-6：正文区草稿保存文案组（draftStatusGroup，图标＋文案＋级别逻辑全在 buildStatusRow/
        // updateDraftStatusLabel）挪到工具栏右端（spacer 之后）；窄屏下文案先截断（见下压缩优先级），
        // 不挤图标与字数。组本身在 buildStatusRow 里才配好轴向与子项，此处只定它在工具栏里的位置。
        charGroupStack.axis = .horizontal
        charGroupStack.spacing = 6
        charGroupStack.alignment = .center
        charGroupStack.translatesAutoresizingMaskIntoConstraints = false
        charRingView.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.isHidden = true  // 数字已隐藏，只留圆环（updateCountLabel 内亦恒置 true，防首帧闪数字）。
        charGroupStack.addArrangedSubview(charRingView)
        charGroupStack.addArrangedSubview(charCountLabel)
        toolRow.addArrangedSubview(charGroupStack)
        let spacer = UIView()
        toolRow.addArrangedSubview(spacer)
        toolRow.addArrangedSubview(draftStatusGroup)
        NSLayoutConstraint.activate([
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolbarSeparator.heightAnchor.constraint(equalToConstant: 1),
            toolRow.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor, constant: 12),
            toolRow.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolRow.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor, constant: -6),
        ])
        // 编辑模式：无草稿流，但 pill 可见（DF-3：网页 openDraftBox 在 editingId 时
        // 直接 return，pill 可见但点开无动作；didTapDraftBox 编辑态已直接 return，
        // 故这里不再隐藏 pill）；引用钮保留（C6：编辑模式引用可改可删）。
        // 工具栏已不在内容栈里，不再设栈间距（旧 setCustomSpacing 已删）。
    }

    /// 草稿 pill 计数：v3 多槽篇数。0 篇时计数段隐藏（只留“草稿”二字），
    /// pill 本体不隐藏——它是草稿箱的唯一入口，空箱也要能点开新建。
    /// 草稿 pill 计数：整库读走后台队列，主线程只写标题（saveDraftNow 的完成回调
    /// 已带回计数时直接用 setDraftPillCount，不再多读一次整库）。
    private func updateDraftPillCount() {
        if isEditMode { return }
        // 整库读走 BearyDraftStore.ioQueue（与写同一串行队列，读不到写一半的库）。
        // 审计三轮第 2 项：入队前捕获账号，执行中不重读全局账号，排队期间切号不串桶。
        let pillAccountId = BearyDraftStore.currentAccountId
        BearyDraftStore.ioQueue.async { [weak self] in
            let count = BearyDraftStore.loadAll(forAccount: pillAccountId).count
            DispatchQueue.main.async {
                self?.setDraftPillCount(count)
            }
        }
    }

    /// v6-3：草稿钮已是纯图标，计数不再画在钮上（只在草稿箱内可见）；
    /// 本函数保留调用链（计数读取仍走 updateDraftPillCount），只把显式宽度钉死 44，
    /// 不再设任何标题/富文本标题，避免文字重新出现在图标旁。
    private func setDraftPillCount(_ count: Int) {
        if isEditMode { return }
        refreshDraftPillWidth()
    }

    /// 草稿钮显式宽度（v6 纯图标版）：固定 44，与图标热区一致；旧“按标题算宽”
    /// 口径随文字 pill 一并作废（标题算宽曾把 pill 压成“...”的历史教训不再适用）。
    private func refreshDraftPillWidth() {
        draftPillWidthConstraint?.constant = 44
    }

    /// C1：引用唯一入口（工具栏引用钮）开关 qp-mode 面板（C6：编辑模式也可改引用，不再早退）。
    @objc private func didTapQuoteTool() {
        // 编辑器改版：弹出框打开时点其他工具钮，先收起框再走各自处理。
        hideCallout(animated: false)
        // P1-14：冻结之外的第二道守卫（按钮禁用本已拦点按，防其他调用路径）。
        if isPublishing {
            showToast(message: isEditMode ? "保存中…" : "发布中…")
            return
        }
        setQuotePanelOpen(!quotePanelOpen)
    }

    // MARK: - C1 选择条与已选 Chip 行（替代旧附加选项栏）

    /// 工具栏钮：再点已展开的条即收起，点另一条直接切换；引用面板打开时不切换。
    private func setToolStrip(_ strip: ToolStrip?) {
        if quotePanelOpen {
            showToast(message: "请先关闭引用面板")
            return
        }
        let oldStrip = activeToolStrip
        activeToolStrip = (activeToolStrip == strip) ? nil : strip
        DiagFile.mark("weather-diag setToolStrip \(String(describing: oldStrip)) -> \(String(describing: activeToolStrip))")
        refreshToolStrip()
    }

    /// Chip 行点按：只打开对应条（不做收起切换，Chip 本身就是“已选”指示）。
    private func openToolStrip(_ strip: ToolStrip) {
        if quotePanelOpen { return }
        // 编辑器改版：同一时刻只开一个选择器——开写给条时若弹出框开着，先收起框
        //（旧时切条即关上一条，弹出框不走 activeToolStrip，故此处显式收）。
        hideCallout(animated: false)
        activeToolStrip = strip
        refreshToolStrip()
    }

    /// 审计 P1-8：选择条转场常量——0.20s 落在 0.18–0.22s 区间内，
    /// 透明度 + 6pt 小幅位移（入场自下 6pt 升至原位，出场沉至 6pt 后淡出）。
    private static let toolStripTransitionDuration: TimeInterval = 0.20
    private static let toolStripTransitionOffset: CGFloat = 6

    /// 选择条显隐总口：同一时刻只显一条；面板打开时整栈隐藏（播放门另见
    /// updateMoodPlayback/updateWeatherPlayback 的 quotePanelOpen 条件）。
    /// 审计 P1-8：显隐不再瞬切——入场先现身再淡入位移归位，出场先淡出位移、
    /// 动画跑完才 isHidden（播放门按 activeToolStrip 已在出场前停播，不依赖
    /// isHidden 时点）。快速连点：新转场 beginFromCurrentState 从当前呈现值
    /// 接管、代次 +1 使旧 completion 作废，只收敛到最后状态；减动效与未挂窗
    /// （首帧）直接置终值，不播动画。引用面板打开时的瞬藏走 setQuotePanelOpen
    /// 专属路径（面板盖住条带、无可见转场），此处不动它。
    private func refreshToolStrip() {
        // 编辑器改版（2026-10-29）：心情/天气旧条已由尖角弹出框取代，旧条永久隐藏；
        // 限时行底锚恒贴工具栏顶（心情/天气档不再激活）；栈内只剩写给区。
        // 旧条视图与天气诊断 mark 行原样保留（诊断代码不动），仅不再由本函数显隐。
        let stackHidden = quotePanelOpen || activeToolStrip != .recipient
        let moodHidden = true
        let weatherHidden = true
        visibilityBarBottomToToolbarConstraint?.isActive = true
        visibilityBarBottomToMoodStripConstraint?.isActive = false
        visibilityBarBottomToWeatherConstraint?.isActive = false
        // iCity：编辑模式 @ 可新增——无 @ 时条内仍有“@ 谁”钮，不再整区隐藏；
        // 其余态按条开关显隐。
        recipientSection.isHidden = activeToolStrip != .recipient
        updateMoodPlayback()
        updateWeatherPlayback()
        updateScrollBottomAnchoring()
        refreshSelectedChips()
        if UIAccessibility.isReduceMotionEnabled || view.window == nil {
            toolStripTransitionGeneration += 1
            toolStripStack.isHidden = stackHidden
            moodScrollView.isHidden = moodHidden
            weatherScrollView.isHidden = weatherHidden
            toolStripStack.alpha = 1
            moodScrollView.alpha = 1
            weatherScrollView.alpha = 1
            toolStripStack.transform = .identity
            moodScrollView.transform = .identity
            weatherScrollView.transform = .identity
            updatePreferredContentSize()
            DiagFile.mark("weather-diag refreshToolStrip weatherHidden=\(weatherScrollView.isHidden) weatherFrame=\(weatherScrollView.frame) stackFrame=\(toolStripStack.frame)")
            return
        }
        toolStripTransitionGeneration += 1
        let generation = toolStripTransitionGeneration
        let offset = Self.toolStripTransitionOffset
        var exitingViews: [UIView] = []
        var needsAnimation = false
        for (stripView, shouldHide) in [
            (toolStripStack, stackHidden),
            (moodScrollView, moodHidden),
            (weatherScrollView, weatherHidden),
        ] as [(UIView, Bool)] {
            if shouldHide {
                if !stripView.isHidden {
                    // 出场：留在层级里淡出位移，completion 才隐藏（见下）。
                    exitingViews.append(stripView)
                    needsAnimation = true
                }
            } else if stripView.isHidden {
                // 入场：先现身于淡入起点，再播到终值。
                stripView.isHidden = false
                stripView.alpha = 0
                stripView.transform = CGAffineTransform(translationX: 0, y: offset)
                needsAnimation = true
            } else if stripView.alpha < 1 || stripView.transform != .identity {
                // 曾被出场中断又改回显示：从当前呈现值播回终值，不瞬切。
                needsAnimation = true
            }
        }
        if !needsAnimation {
            view.layoutIfNeeded()
            updatePreferredContentSize()
            DiagFile.mark("weather-diag refreshToolStrip weatherHidden=\(weatherScrollView.isHidden) weatherFrame=\(weatherScrollView.frame) stackFrame=\(toolStripStack.frame)")
            return
        }
        UIView.animate(
            withDuration: Self.toolStripTransitionDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: {
                for stripView in exitingViews {
                    stripView.alpha = 0
                    stripView.transform = CGAffineTransform(translationX: 0, y: offset)
                }
                for stripView in [self.toolStripStack, self.moodScrollView, self.weatherScrollView]
                where !exitingViews.contains(where: { $0 === stripView }) && !stripView.isHidden {
                    stripView.alpha = 1
                    stripView.transform = .identity
                }
                // 限时行与滚动底锚的约束切换随同一转场走，不瞬跳。
                self.view.layoutIfNeeded()
            },
            completion: { [weak self] finished in
                guard let self = self, finished, generation == self.toolStripTransitionGeneration else { return }
                // 只有跑完且未被更新转场取代的出场才真正隐藏；隐藏后复位，
                // 下次入场仍从淡入起点起播，不残留淡出态。
                for stripView in exitingViews {
                    stripView.isHidden = true
                    stripView.alpha = 1
                    stripView.transform = .identity
                }
                // 出场条带占高在动画结束时才塌掉，sheet 高随之重算。
                self.updatePreferredContentSize()
            }
        )
        // 入场条带在转场期间已可见占高，sheet 高先按含条带算；出场条带
        // 的塌高由 completion 里的重算接管。
        updatePreferredContentSize()
        DiagFile.mark("weather-diag refreshToolStrip weatherHidden=\(weatherScrollView.isHidden) weatherFrame=\(weatherScrollView.frame) stackFrame=\(toolStripStack.frame)")
    }

    // MARK: - 编辑器改版（2026-10-29）：心情/天气尖角弹出框

    /// 弹出框搭建：框体与框外收起层常驻 view（隐藏时 isHidden），约束一次激活；
    /// 框左右与工具栏同宽（iPad 居中 608 列下自动跟随），框底贴工具栏顶 8pt 上方；
    /// 框是覆盖层（不推限时行、不改 sheet 高），打开时短暂盖住限时行，点框外即收起。
    private func buildCallouts() {
        moodCallout.translatesAutoresizingMaskIntoConstraints = false
        weatherCallout.translatesAutoresizingMaskIntoConstraints = false
        calloutDismissView.translatesAutoresizingMaskIntoConstraints = false
        moodCallout.isHidden = true
        weatherCallout.isHidden = true
        calloutDismissView.isHidden = true
        calloutDismissView.onTapOutside = { [weak self] in self?.hideCallout(animated: true) }
        moodCallout.configure(
            options: moodOrder.map { key in
                BearyCalloutPickerView.Option(key: key, accessibilityLabel: "心情：" + (BearyText.moodNames[key] ?? key))
            },
            onSelect: { [weak self] key in self?.didSelectMoodFromCallout(key) },
            imageProvider: { [weak self] key, dark in self?.calloutMoodImage(for: key, dark: dark) }
        )
        // v6-8：天气框首位补“无”（清除）选项，键为 "none"，图为虚线圆圈＋icon_plus 旋转 45 度
        //（见 weatherNoneImage；大小与其它天气图标一致 40pt、同色墨色模板）；心情框（40 项）不动。
        // 选中态口径：弹出框既有实现对任何选项均无选中修饰（configure 只设图、不标选中），
        // 故“无”选中时亦无修饰，不新发明——与已选天气在框内同样无修饰保持一致。
        weatherCallout.configure(
            options: [BearyCalloutPickerView.Option(key: "none", accessibilityLabel: "无")] + weatherOrder.map { key in
                BearyCalloutPickerView.Option(key: key, accessibilityLabel: "天气：" + (BearyText.weatherNames[key] ?? key))
            },
            onSelect: { [weak self] key in self?.didSelectWeatherFromCallout(key) },
            imageProvider: { [weak self] key, _ in
                if key == "none" { return self?.weatherNoneImage() }
                return BearyIconImages.image(named: "icon_wx_\(key)", pointSize: 40)
            }
        )
        // 收起层先加、框后加：框在收起层之上，框内点按不触发框外收起。
        view.addSubview(calloutDismissView)
        view.addSubview(moodCallout)
        view.addSubview(weatherCallout)
        NSLayoutConstraint.activate([
            calloutDismissView.topAnchor.constraint(equalTo: view.topAnchor),
            calloutDismissView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            calloutDismissView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            calloutDismissView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            moodCallout.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            moodCallout.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            moodCallout.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: -8),
            moodCallout.heightAnchor.constraint(equalToConstant: Self.calloutHeight),
            weatherCallout.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            weatherCallout.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            weatherCallout.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: -8),
            weatherCallout.heightAnchor.constraint(equalToConstant: Self.calloutHeight),
        ])
    }

    /// 弹出框心情图：官方 emote 静态 PNG 按 44pt 重绘（与已选 chip 的 16pt 同款做法）；
    /// 深色走 _dark 资产，缺失时 BearyEmoteImages 按 C3 上报并返回 nil（不回退浅色版）。
    private func calloutMoodImage(for key: String, dark: Bool) -> UIImage? {
        guard let base = BearyEmoteImages.image(for: key, dark: dark) else { return nil }
        let size = CGSize(width: 44, height: 44)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 工具栏钮：再点已打开的框即收起，点另一框直接切换（与旧 setToolStrip 同口径）。
    private func toggleCallout(_ kind: CalloutKind) {
        if activeCallout == kind {
            hideCallout(animated: true)
        } else {
            showCallout(kind)
        }
    }

    /// Chip 行点按：只打开对应框（不做收起切换，Chip 本身就是“已选”指示；
    /// 与旧 openToolStrip 同口径）。
    private func showCallout(_ kind: CalloutKind) {
        if quotePanelOpen { return }
        if activeCallout == kind { return }
        // 同一时刻只开一个选择器：写给条若开着，先关条再开框（旧时切条即关上一条）。
        if activeToolStrip == .recipient {
            activeToolStrip = nil
            refreshToolStrip()
        }
        calloutTransitionGeneration += 1
        activeCallout = kind
        let target = kind == .mood ? moodCallout : weatherCallout
        let other = kind == .mood ? weatherCallout : moodCallout
        other.isHidden = true
        other.alpha = 1
        other.transform = .identity
        calloutDismissView.isHidden = false
        target.isHidden = false
        view.layoutIfNeeded()
        updateCalloutArrowPositions()
        if UIAccessibility.isReduceMotionEnabled || view.window == nil {
            target.alpha = 1
            target.transform = .identity
            return
        }
        target.alpha = 0
        target.transform = CGAffineTransform(translationX: 0, y: Self.calloutTransitionOffset)
        UIView.animate(
            withDuration: Self.calloutTransitionDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: {
                target.alpha = 1
                target.transform = .identity
            }
        )
    }

    private func hideCallout(animated: Bool) {
        guard let kind = activeCallout else { return }
        activeCallout = nil
        calloutTransitionGeneration += 1
        let generation = calloutTransitionGeneration
        let target = kind == .mood ? moodCallout : weatherCallout
        if !animated || UIAccessibility.isReduceMotionEnabled || view.window == nil {
            target.isHidden = true
            target.alpha = 1
            target.transform = .identity
            calloutDismissView.isHidden = true
            return
        }
        UIView.animate(
            withDuration: Self.calloutTransitionDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: {
                target.alpha = 0
                target.transform = CGAffineTransform(translationX: 0, y: Self.calloutTransitionOffset)
            },
            completion: { [weak self] finished in
                guard let self = self, finished, generation == self.calloutTransitionGeneration else { return }
                target.isHidden = true
                target.alpha = 1
                target.transform = .identity
                self.calloutDismissView.isHidden = true
            }
        )
    }

    /// 尖角跟随触发图标中心：图标中心转到框坐标系；收起层穿透区同步为工具栏帧
    /// （工具栏按钮仍可点按，其余区域点按收起）。iPad 居中列下框与工具栏同宽同列，
    /// 换算自动对齐，不另算居中偏移。
    private func updateCalloutArrowPositions() {
        guard let kind = activeCallout else { return }
        let callout = kind == .mood ? moodCallout : weatherCallout
        let anchor = kind == .mood ? moodToolButton : weatherToolButton
        let center = anchor.convert(CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: callout)
        callout.arrowCenterX = center.x
        calloutDismissView.passthroughRects = [toolbarContainer.convert(toolbarContainer.bounds, to: calloutDismissView)]
    }

    /// 弹出框点选心情：沿用旧条口径（再点已选项取消）；点选即收起。
    private func didSelectMoodFromCallout(_ key: String) {
        if selectedMood == key {
            selectedMood = nil
        } else {
            selectedMood = key
        }
        refreshMoodButtons()
        updateMoodPlayback()
        scheduleDraftSave()
        hideCallout(animated: true)
    }

    /// 弹出框点选天气：沿用旧条口径（点即选中、再点不取消）；点选即收起。
    /// v6-8：点首位“无”即清除已选天气（weather 置空），工具栏天气钮经
    /// refreshWeatherButtons 回到无天气态（通用天气图标），chip 行同步隐藏天气 chip。
    private func didSelectWeatherFromCallout(_ key: String) {
        selectedWeather = (key == "none") ? nil : key
        refreshWeatherButtons()
        updateWeatherPlayback()
        refreshSelectedChips()
        scheduleDraftSave()
        hideCallout(animated: true)
    }

    /// v6-8“无”选项图（40pt，与其它天气图标同尺寸）：虚线圆圈＋圆里的卡片“贴一只小熊”
    /// 加号资产 icon_plus 旋转 45 度（实线叉形）；整图黑底色绘后转 alwaysTemplate，
    /// 由弹出框按钮 tint（墨色、深色模板反白）着色，与其它天气模板图同口径。
    private func weatherNoneImage() -> UIImage? {
        let size: CGFloat = 40
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(2)
            cg.setLineDash(phase: 0, lengths: [4, 3])
            cg.strokeEllipse(in: CGRect(x: 4, y: 4, width: 32, height: 32))
            cg.setLineDash(phase: 0, lengths: [])
            if let plus = UIImage(named: "icon_plus") {
                cg.saveGState()
                cg.translateBy(x: size / 2, y: size / 2)
                cg.rotate(by: .pi / 4)
                plus.draw(in: CGRect(x: -11, y: -11, width: 22, height: 22))
                cg.restoreGState()
            }
        }
        return drawn.withRenderingMode(.alwaysTemplate)
    }

    /// 审计 16 项：心情 chip 图标——官方 emote 静态 PNG 按 16pt 重绘。
    /// UIButton.setImage 不缩放，原图 72pt 会撑爆 chip；重绘保留原色（不用
    /// BearyIconImages 的 alwaysTemplate，线条稿深浅变体靠 _dark 资产本身）。
    /// 深色资产缺失时 BearyEmoteImages 已按 C3 上报并返回 nil，此处不另找替代、
    /// 不回退浅色版、不混 SF Symbol，chip 只剩值文本、无障碍仍读完整表述。
    private func selectedMoodChipIcon(for key: String) -> UIImage? {
        let dark = traitCollection.userInterfaceStyle == .dark
        guard let base = BearyEmoteImages.image(for: key, dark: dark) else { return nil }
        let size = CGSize(width: 16, height: 16)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 已选 Chip 行：只显示已选项（心情/天气/写给各一枚），无已选时整行塌掉；
    /// 间距随显隐切换（隐藏时置 0，否则隐藏行仍残留 8pt 空隙，见面板间隙修复同款）。
    /// 审计 16 项：心情／天气去“心情 ·”“天气 ·”前缀，改官方图标＋值（心情走
    /// emote 静态图、天气走 icon_wx_*，40 只深浅与 9 个天气资产已核齐全、无缺款）；
    /// 写给改“写给 昵称”。图标只是视觉辅助：accessibilityLabel 一律保留完整表述
    /// （“心情：开心”“天气：晴”“写给：昵称”），不只靠图标传达信息。
    /// 图标计入按钮 intrinsicContentSize，P1-3 换行总宽自动含图标宽。
    private func refreshSelectedChips() {
        if let mood = selectedMood, let name = BearyText.moodNames[mood] {
            moodChipButton.isHidden = false
            moodChipButton.setTitle(name, for: .normal)
            let icon = selectedMoodChipIcon(for: mood)
            if icon == nil {
                NSLog("[BearyComposer] selected mood chip icon missing key=%@", mood)
            }
            moodChipButton.setImage(icon, for: .normal)
            moodChipButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: icon == nil ? 0 : 5, bottom: 0, right: 0)
            moodChipButton.accessibilityLabel = "心情：" + name
        } else {
            moodChipButton.isHidden = true
            moodChipButton.setImage(nil, for: .normal)
        }
        if let weather = selectedWeather, let name = BearyText.weatherNames[weather] {
            weatherChipButton.isHidden = false
            weatherChipButton.setTitle(name, for: .normal)
            let icon = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 16)
            if icon == nil {
                NSLog("[BearyComposer] selected weather chip icon missing key=%@", weather)
            }
            weatherChipButton.setImage(icon, for: .normal)
            weatherChipButton.tintColor = BearyColors.ink
            weatherChipButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: icon == nil ? 0 : 5, bottom: 0, right: 0)
            weatherChipButton.accessibilityLabel = "天气：" + name
        } else {
            weatherChipButton.isHidden = true
            weatherChipButton.setImage(nil, for: .normal)
        }
        let recipientName: String?
        if let user = selectedRecipient {
            if let display = user.displayName {
                recipientName = display
            } else if let handle = user.handle {
                recipientName = handle
            } else {
                recipientName = "用户"
            }
        } else if isEditMode, editMentionCleared {
            recipientName = nil
        } else {
            recipientName = lockedRecipientName
        }
        if let name = recipientName {
            recipientChipButton.isHidden = false
            // 审计 16 项：写给 chip 由“@昵称”改“写给 昵称”（纯文本，不另加图标）。
            recipientChipButton.setTitle("写给 " + name, for: .normal)
            recipientChipButton.accessibilityLabel = "写给：" + name
        } else {
            recipientChipButton.isHidden = true
        }
        let anyChipVisible = !moodChipButton.isHidden || !weatherChipButton.isHidden || !recipientChipButton.isHidden
        contentStack.setCustomSpacing(anyChipVisible ? 8 : 0, after: selectedChipsRow)
        // 审计 P1-3：显隐/文案变化后即重算换行（宽变化另由 viewDidLayoutSubviews 驱动）。
        layoutSelectedChips()
    }

    /// 审计 P1-3：三 chip 收缩优先级与换行。
    /// 单行态：心情/天气自然宽（hugging + 抗压缩双 required，文字不缩小、不截断），
    /// 写给占剩余（hugging/compression 双 low：有富余则伸满、空间紧则先缩），
    /// 写给标题单行尾截断、字号固定 13（adjustsFontSizeToFitWidth 关，不缩字）。
    /// 空间不足（单行总宽 > 行宽）且写给与心情/天气同显时：写给脱离首行、
    /// 独立成第二行（满宽、尾截断），心情/天气保持自然宽不动——不缩小全部文字。
    /// 写给单独出现时不换行（满宽即剩余，超长只尾截断）。
    /// 只在换行态真正变化时移视图；同态重算不碰层级，不触发布局环。
    private func layoutSelectedChips() {
        guard isViewLoaded else { return }
        // 行宽：布局后取实测宽；首帧布局前行宽为 0 时按内容栈边距（左右各 16）
        // 从视图/屏幕宽估算，与 updatePreferredContentSize 首帧估算同口径。
        let available: CGFloat
        if selectedChipsRow.bounds.width > 0 {
            available = selectedChipsRow.bounds.width
        } else if view.bounds.width > 0 {
            available = view.bounds.width - 32
        } else {
            let screenWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
            available = screenWidth - 32
        }
        guard available > 0 else { return }
        selectedChipsLastLayoutWidth = available
        let moodVisible = !moodChipButton.isHidden
        let weatherVisible = !weatherChipButton.isHidden
        let recipientVisible = !recipientChipButton.isHidden
        guard recipientVisible, moodVisible || weatherVisible else {
            // 写给单独出现或未出现：单行态即是终态（未出现时首行只剩隐藏项，塌高为 0）。
            if selectedChipsRecipientOnSecondRow {
                selectedChipsRow.removeArrangedSubview(recipientChipButton)
                selectedChipsFirstRow.addArrangedSubview(recipientChipButton)
                selectedChipsRecipientOnSecondRow = false
            }
            return
        }
        // UIButton intrinsicContentSize 已含 contentEdgeInsets 与标题宽，即自然宽。
        var singleLineWidth: CGFloat = 0
        var visibleCount = 0
        for button in [moodChipButton, weatherChipButton, recipientChipButton] where !button.isHidden {
            singleLineWidth += button.intrinsicContentSize.width
            visibleCount += 1
        }
        if visibleCount > 1 {
            singleLineWidth += CGFloat(visibleCount - 1) * selectedChipsFirstRow.spacing
        }
        let wrapRecipient = singleLineWidth > available
        guard wrapRecipient != selectedChipsRecipientOnSecondRow else { return }
        selectedChipsRecipientOnSecondRow = wrapRecipient
        if wrapRecipient {
            selectedChipsFirstRow.removeArrangedSubview(recipientChipButton)
            selectedChipsRow.addArrangedSubview(recipientChipButton)
        } else {
            selectedChipsRow.removeArrangedSubview(recipientChipButton)
            selectedChipsFirstRow.addArrangedSubview(recipientChipButton)
        }
    }

    private func buildSelectedChipsRow() {
        // 外层改竖栈：首行 +（换行时）写给第二行；单行态第二行不存在，竖栈不增高。
        selectedChipsRow.axis = .vertical
        selectedChipsRow.spacing = 8
        selectedChipsRow.alignment = .fill
        selectedChipsRow.translatesAutoresizingMaskIntoConstraints = false
        selectedChipsFirstRow.axis = .horizontal
        selectedChipsFirstRow.spacing = 8
        selectedChipsFirstRow.alignment = .center
        selectedChipsFirstRow.translatesAutoresizingMaskIntoConstraints = false
        selectedChipsRow.addArrangedSubview(selectedChipsFirstRow)
        let chips: [(button: BearyHit44Button, action: Selector)] = [
            (moodChipButton, #selector(didTapMoodChip)),
            (weatherChipButton, #selector(didTapWeatherChip)),
            (recipientChipButton, #selector(didTapRecipientChip)),
        ]
        for chip in chips {
            chip.button.titleLabel?.font = UIFont.systemFont(ofSize: 13)
            chip.button.titleLabel?.numberOfLines = 1
            chip.button.titleLabel?.lineBreakMode = .byTruncatingTail
            chip.button.titleLabel?.adjustsFontSizeToFitWidth = false
            chip.button.setTitleColor(BearyColors.ink, for: .normal)
            chip.button.backgroundColor = BearyColors.faint
            chip.button.layer.cornerRadius = 999
            chip.button.layer.masksToBounds = true
            chip.button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
            chip.button.addTarget(self, action: chip.action, for: .touchUpInside)
            chip.button.bearyAddPressFeedback()
            chip.button.isHidden = true
            chip.button.translatesAutoresizingMaskIntoConstraints = false
            selectedChipsFirstRow.addArrangedSubview(chip.button)
        }
        // 审计 P1-3：心情/天气自然宽不让步；写给低优先级，占剩余、紧时先缩先截断。
        moodChipButton.setContentHuggingPriority(.required, for: .horizontal)
        moodChipButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        weatherChipButton.setContentHuggingPriority(.required, for: .horizontal)
        weatherChipButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        recipientChipButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recipientChipButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(selectedChipsRow)
        contentStack.setCustomSpacing(0, after: selectedChipsRow)
    }

    /// C11：删图撤销条（图片条下方）：文案 + 撤销钮；显隐与间距由 refreshImageUndoBar 管。
    private func buildImageUndoBar() {
        imageUndoBar.backgroundColor = BearyColors.faint
        imageUndoBar.layer.cornerRadius = 12
        imageUndoBar.layer.masksToBounds = true
        imageUndoLabel.text = "图片已删除"
        imageUndoLabel.font = UIFont.systemFont(ofSize: 13)
        imageUndoLabel.textColor = BearyColors.ink
        imageUndoButton.setTitle("撤销", for: .normal)
        imageUndoButton.setTitleColor(BearyColors.blue, for: .normal)
        imageUndoButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        imageUndoButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        imageUndoButton.addTarget(self, action: #selector(didTapUndoRemovedImage), for: .touchUpInside)
        imageUndoButton.bearyAddPressFeedback()
        imageUndoBar.translatesAutoresizingMaskIntoConstraints = false
        imageUndoLabel.translatesAutoresizingMaskIntoConstraints = false
        imageUndoButton.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(imageUndoBar)
        imageUndoBar.addSubview(imageUndoLabel)
        imageUndoBar.addSubview(imageUndoButton)
        NSLayoutConstraint.activate([
            imageUndoLabel.leadingAnchor.constraint(equalTo: imageUndoBar.leadingAnchor, constant: 14),
            imageUndoLabel.topAnchor.constraint(equalTo: imageUndoBar.topAnchor, constant: 10),
            imageUndoLabel.bottomAnchor.constraint(equalTo: imageUndoBar.bottomAnchor, constant: -10),
            imageUndoButton.trailingAnchor.constraint(equalTo: imageUndoBar.trailingAnchor, constant: -14),
            imageUndoButton.centerYAnchor.constraint(equalTo: imageUndoBar.centerYAnchor),
            imageUndoButton.leadingAnchor.constraint(greaterThanOrEqualTo: imageUndoLabel.trailingAnchor, constant: 8),
        ])
        imageUndoBar.isHidden = true
        contentStack.setCustomSpacing(0, after: imageUndoBar)
    }

    @objc private func didTapMoodTool() {
        toggleCallout(.mood)
    }

    @objc private func didTapWeatherTool() {
        DiagFile.mark("weather-diag didTapWeatherTool")
        toggleCallout(.weather)
    }

    @objc private func didTapRecipientTool() {
        // A2：工具栏 @ 直连选人面板，跳过 @ 选择条（选择条仍由正文下方 @ chip
        // 打开，供已选态清除/重选；@ 提醒无按篇开关）。
        // 引用面板打开时工具栏本身已藏，此处不再走 setToolStrip 的面板守卫。
        // 编辑器改版：弹出框打开时点其他工具钮，先收起框再走各自处理。
        hideCallout(animated: false)
        didTapPickRecipient()
    }

    @objc private func didTapMoodChip() {
        showCallout(.mood)
    }

    @objc private func didTapWeatherChip() {
        showCallout(.weather)
    }

    @objc private func didTapRecipientChip() {
        openToolStrip(.recipient)
    }

    // MARK: - 状态行（编辑倒计时 + 草稿状态；字数圆环已移入工具栏右端）

    private func buildStatusRow() {
        editTimerLabel.font = UIFont.boldSystemFont(ofSize: 12)
        editTimerLabel.textColor = BearyColors.gray
        editTimerLabel.isHidden = true
        draftStatusLabel.font = UIFont.systemFont(ofSize: 12.5)
        draftStatusLabel.textColor = BearyColors.blue
        // v6-6：文案在工具栏右端窄屏受压时先截断，不挤左侧图标组与字数（字数默认 750，高于此处的 749）。
        draftStatusLabel.numberOfLines = 1
        draftStatusLabel.lineBreakMode = .byTruncatingTail
        draftStatusLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        // 草稿状态组：lvl2 时图标 + 文案 gap 5（网页 draft-status：15×15 对勾 + gap 5，蓝色继承）。
        draftStatusIcon.image = BearyIconImages.image(named: "icon_check", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.blue
        draftStatusIcon.contentMode = .scaleAspectFit
        draftStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        draftStatusGroup.axis = .horizontal
        draftStatusGroup.spacing = 5
        draftStatusGroup.alignment = .center
        draftStatusGroup.translatesAutoresizingMaskIntoConstraints = false
        draftStatusGroup.addArrangedSubview(draftStatusIcon)
        draftStatusGroup.addArrangedSubview(draftStatusLabel)
        draftStatusGroup.isHidden = true
        charCountLabel.font = UIFont.systemFont(ofSize: 12)
        charCountLabel.textColor = BearyColors.gray
        charRingView.translatesAutoresizingMaskIntoConstraints = false
        statusRow.axis = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .center
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusRow)
        statusRow.addArrangedSubview(editTimerLabel)
        let spacer = UIView()
        statusRow.addArrangedSubview(spacer)
        // v6-6：草稿保存文案组已挪到工具栏右端（buildToolbarRow），不再进状态行；
        // 状态行只留编辑倒计时。组内图标／文案／级别逻辑（updateDraftStatusLabel）一字不动。
        // C1：字数圆环已移入工具栏左图标组 charGroupStack（数字已隐藏，只留圆环），
        // 圆环尺寸与形层仍在此处创建（视图归属不影响形层）。
        NSLayoutConstraint.activate([
            draftStatusIcon.widthAnchor.constraint(equalToConstant: 15),
            draftStatusIcon.heightAnchor.constraint(equalToConstant: 15),
            charRingView.widthAnchor.constraint(equalToConstant: 18),
            charRingView.heightAnchor.constraint(equalToConstant: 18),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        // 圆环：18 框、r 7.5、线宽 2.5，从顶部顺时针画（网页 cc-ring 同款）。
        let center = CGPoint(x: 9, y: 9)
        let path = UIBezierPath(arcCenter: center, radius: 7.5, startAngle: -CGFloat.pi / 2, endAngle: CGFloat.pi * 3 / 2, clockwise: true)
        let track = CAShapeLayer()
        track.path = path.cgPath
        track.fillColor = UIColor.clear.cgColor
        track.strokeColor = BearyColors.line.cgColor
        track.lineWidth = 2.5
        let progress = CAShapeLayer()
        progress.path = path.cgPath
        progress.fillColor = UIColor.clear.cgColor
        progress.strokeColor = BearyColors.blue.cgColor
        progress.lineWidth = 2.5
        progress.lineCap = .round
        progress.strokeEnd = 0
        charRingView.layer.addSublayer(track)
        charRingView.layer.addSublayer(progress)
        charTrackLayer = track
        charProgressLayer = progress
        contentStack.setCustomSpacing(8, after: statusRow)
    }

    /// 草稿状态文案跟随保存级别：2 草稿已保存 / 1 文字已保存，图片未保存 / 0 失败红字。
    /// 编辑模式不显示（网页编辑态同款：状态行只留倒计时与字数）。
    private func updateDraftStatusLabel() {
        if isEditMode {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            return
        }
        guard let level = draftStatusLevel else {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            BearyIconMotion.stopSpin(on: draftStatusIcon, key: "bearyDraftSavingSpin")
            return
        }
        draftStatusGroup.isHidden = false
        // D-G14：落盘后停掉保存中转圈、换回对勾图；仅 lvl2 显示图标（lvl1/失败态网页均无图标）。
        BearyIconMotion.stopSpin(on: draftStatusIcon, key: "bearyDraftSavingSpin")
        draftStatusIcon.image = BearyIconImages.image(named: "icon_check", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.blue
        draftStatusIcon.isHidden = level != 2
        if level == 2 {
            draftStatusLabel.text = "草稿已保存"
            draftStatusLabel.textColor = BearyColors.blue
        } else if level == 1 {
            draftStatusLabel.text = "文字已保存，图片未保存"
            draftStatusLabel.textColor = BearyColors.blue
        } else {
            draftStatusLabel.text = "草稿保存失败"
            draftStatusLabel.textColor = BearyColors.red
        }
    }

    // MARK: - 编辑倒计时（从 editDeadline 算剩余，网页 edit-timer 口径“剩 M:SS”）

    private func startEditTimer() {
        editTimer?.invalidate()
        guard isEditMode, let deadline = editingEntry?.editDeadline else {
            editTimerLabel.isHidden = true
            return
        }
        editTimerLabel.isHidden = false
        let tickBlock: () -> Void = { [weak self] in
            guard let self = self else { return }
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let remain = max(0, Int(ceil(Double(deadline - nowMs) / 1000.0)))
            if remain <= 0 {
                // C4：到 0 显示“编辑已结束”并关闭编辑器（走现有取消/关闭路径
                // onCancelled，不弹放弃确认；本轮新选图的本地文件按取消路径清理）。
                // 注意：编辑态 onCancelled 在容器侧目前仅 dismiss，列表刷新需容器侧
                // 接线（本文件不碰 SceneDelegate，见交回说明）。
                self.editTimerLabel.text = "编辑已结束"
                self.editTimer?.invalidate()
                self.editTimer = nil
                self.deleteEditLocalFiles()
                // B 修法：计时自动关闭退场前先收起弹出框（无动画）。
                self.hideCallout(animated: false)
                self.onCancelled?()
                return
            }
            self.editTimerLabel.text = "剩 \(remain / 60):\(String(format: "%02d", remain % 60))"
        }
        tickBlock()
        editTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tickBlock() }
    }


    // MARK: - 正文与字数

    func textViewDidChange(_ textView: UITextView) {
        updateCountLabel()
        updatePublishState()
        scheduleDraftSave()
        // S10：contentSize 高度不变时跳过高度重算（同行内敲字不触发布局）；
        // 折行、增删、旋转都会改变 contentSize 高度，变化时正常重算并更新缓存。
        // 高度计算公式与下限不动（见 updateTextViewHeight）。
        let contentHeight = textView.contentSize.height
        guard contentHeight != lastTextViewContentHeight else { return }
        lastTextViewContentHeight = contentHeight
        // 高度先定，fitting 再按新高算 sheet 高。
        updateTextViewHeight()
        updatePreferredContentSize()
    }

    /// 已落字正文：全文去掉拼音组合串（marked range）后的部分。只作快照读取，
    /// 不改 textView、不调 unmarkText，组词中的输入法状态不受影响；
    /// 拼音未落字时这段就是空/只有已落字，发布与存草稿不会带出未落字拼音。
    private func committedContent() -> String {
        let full = textView.text ?? ""
        guard let marked = textView.markedTextRange else { return full }
        let startOffset = textView.offset(from: textView.beginningOfDocument, to: marked.start)
        let endOffset = textView.offset(from: textView.beginningOfDocument, to: marked.end)
        guard startOffset >= 0, endOffset <= full.count, startOffset <= endOffset else { return full }
        var result = full
        let start = result.index(result.startIndex, offsetBy: startOffset)
        let end = result.index(result.startIndex, offsetBy: endOffset)
        result.removeSubrange(start..<end)
        return result
    }

    /// P1-15：正文取数统一走已落字口径——trimmedContent 即 trim 后的已落字正文，
    /// 与 committedTextCount()（字数显示）同为排除 marked 的口径；发布 2000 上限
    /// 判定、空判定、草稿落盘均以它为准（发布侧 trim 沿用 D-G5，不再把首尾空白算进上限）。
    private func trimmedContent() -> String {
        return committedContent().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 落字数：拼音组合串（marked text，如未落字的 "nihao"）不计入字数——
    /// 组合串是输入法中间态，不是正文；textView.text 在组词期间已含组合串，
    /// 直接 count 会把 5 个字母算成字（录屏里 "nihao" 显示 6/2000 即 1 落字 + 5 字母）。
    /// 落字后 marked 为空，计数自然回到落字数（"你好" = 2）。占位显隐仍按全文
    /// （含组合串）算：组词中占位就该藏，不因落字数为 0 而复现。
    private func committedTextCount() -> Int {
        let fullCount = textView.text.count
        guard let marked = textView.markedTextRange,
              let markedText = textView.text(in: marked) else {
            return fullCount
        }
        return max(0, fullCount - markedText.count)
    }

    /// 字数：圆环进度（数字已隐藏，只留圆环）；空时圆环隐藏，超字红环。
    private func updateCountLabel() {
        let count = committedTextCount()
        placeholderLabel.isHidden = !textView.text.isEmpty
        if count == 0 {
            charRingView.isHidden = true
            charCountLabel.isHidden = true
            return
        }
        charRingView.isHidden = false
        charCountLabel.isHidden = true
        let ratio = min(1.0, CGFloat(count) / CGFloat(BearyComposerViewController.maxLength))
        charProgressLayer?.strokeEnd = ratio
        if count > BearyComposerViewController.maxLength {
            charProgressLayer?.strokeColor = BearyColors.red.cgColor
        } else {
            charProgressLayer?.strokeColor = BearyColors.blue.cgColor
        }
    }

    private func hasUploadingImage() -> Bool {
        for item in imageItems {
            if item.uploading {
                return true
            }
        }
        return false
    }

    private func updatePublishState() {
        // C11：超长时发布钮保持可用（不禁用），点发布时 toast 报当前字数；上传中仍禁用。
        // U13：空正文不再真禁用（禁用钮收不到点按、零反馈）——改视觉置灰 + 点按给“先写点什么”
        // 轻提示（见 didTapPublish）；超长时保持可用的口径不动。
        publishButton.isEnabled = !isPublishing && !hasUploadingImage()
        refreshPublishAppearance()
        refreshPublishBusyState()
        refreshPublishingInputFreeze()
    }

    /// D 批：发布/保存请求在途时冻结编辑输入（发布钮本身由上方的 updatePublishState
    /// 单独管禁用，本函数不动它）：正文不可改；心情/天气（含工具栏天气钮与附加栏
    /// 开关，这两处是心情/天气行的入口）与图片（添加钮 + 每项移除/裁剪钮 + 条内
    /// 点按重试走容器手势，一并关容器交互）不可点。挂在 updatePublishState 里，
    /// 故 performPublish/performUpdate 的成功与失败分支只要走原有的
    /// isPublishing = false + updatePublishState() 即恢复，无需各分支另写恢复。
    /// 取消路径不动：进行中点取消仍走原有“发布中…”提示，不关编辑器、不碰草稿；
    /// 请求结束后的取消直接关（决议第 4 项 B），草稿按原规则保留；本函数不碰
    /// 发布成功后的清草稿逻辑（clearDraftAndFiles 仍只在 performPublish 成功分支里调）。
    /// 恢复时直接置回可用：上述控件在别处没有其他禁用逻辑（grep 无其他 isEnabled/
    /// isEditable 赋值），不会误解开本应禁用的项。
    private func refreshPublishingInputFreeze() {
        let frozen = isPublishing
        textView.isEditable = !frozen
        titleField.isEnabled = !frozen
        // 100 包编辑器面修法：发布在途时可见性钮亦冻结——此前冻结清单
        // 漏了它，在途点钮只改旗标不改已发送值（performPublish 已在请求
        // 前捕获 publishVisibility），视觉上“切成功了”实则无效；解冻时
        // 仍受限时锁制约（限时开时钮本就禁用，不得由解冻误解开）。
        visibilityButton.isEnabled = !frozen && !ephemeralSwitch.isOn
        // 同款：限时开关本身亦随冻结禁用，否则在途拨动限时会连带改段
        // 与旗标，同样只改视觉不改已发送值；它在别处无禁用逻辑，解冻
        // 直接恢复可用。
        ephemeralSwitch.isEnabled = !frozen
        // P1-14：冻结清单补齐全部入口——草稿 pill、引用钮、三枚已选 Chip、
        // @ pick/清除、引用卡 ×（含已删行“移除”）；其余入口见下。
        draftPillButton.isEnabled = !frozen
        quoteToolButton.isEnabled = !frozen
        moodChipButton.isEnabled = !frozen
        weatherChipButton.isEnabled = !frozen
        recipientChipButton.isEnabled = !frozen
        recipientPickButton.isEnabled = !frozen
        recipientClearButton.isEnabled = !frozen
        // 例外：通知复选框编辑态本就禁用（refreshRecipientRow 的编辑锁定），
        // 冻结恢复时不得误解开；新建态才随冻结恢复。
        notifyCheckButton.isEnabled = !frozen && !isEditMode
        quoteCardRemoveButton.isEnabled = !frozen
        quoteDeletedRemoveButton.isEnabled = !frozen
        for item in moodItems {
            item.button.isEnabled = !frozen
        }
        for pair in weatherButtons {
            pair.button.isEnabled = !frozen
        }
        weatherToolButton.isEnabled = !frozen
        moodToolButton.isEnabled = !frozen
        recipientToolButton.isEnabled = !frozen
        imageUndoButton.isEnabled = !frozen
        imageToolButton.isEnabled = !frozen
        for item in imageItems {
            item.removeButton.isEnabled = !frozen
            item.container.isUserInteractionEnabled = !frozen
        }
    }

    /// 发布/保存中态（E3-4）：标题改“发布中…”/“保存中…”+ 发送图标位转 spinner；
    /// 非发布中时恢复标题与发送图标。按钮本身在发布中保持禁用（防重发）。
    private func refreshPublishBusyState() {
        if isPublishing {
            publishButton.setTitle(isEditMode ? "保存中…" : "发布中…", for: .normal)
            publishButton.setImage(nil, for: .normal)
            publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: Self.publishSpinnerTitleInset, bottom: 0, right: 0)
            publishRingView.isHidden = false
            BearyIconMotion.startSpin(on: publishRingView, duration: 0.9, key: "bearyPublishSpin")
        } else {
            publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
            publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 22), for: .normal)
            publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            publishRingView.isHidden = true
            BearyIconMotion.stopSpin(on: publishRingView, key: "bearyPublishSpin")
        }
        // 标题/图标/边距三处每次变化都重算显式宽度（标题只在这里与 buildTopBar 改，
        // 故此处是唯一需要跟进的运行时更新点；updatePublishState 每次都走这里）。
        refreshPublishButtonWidth()
    }

    // MARK: - 心情（选中态；选中名改由正文下方 Chip 行显示）

    private func refreshMoodButtons() {
        refreshMoodImages()
        for item in moodItems {
            let isSelected = (item.key == selectedMood)
            if isSelected {
                item.ringView.backgroundColor = BearyColors.orange.withAlphaComponent(0.12)
                item.ringView.layer.borderColor = UIColor.clear.cgColor
                item.ringView.layer.borderWidth = 0
                item.nameLabel.textColor = BearyColors.orange
            } else {
                item.ringView.backgroundColor = BearyColors.faint
                item.ringView.layer.borderColor = UIColor.clear.cgColor
                item.ringView.layer.borderWidth = 0
                item.nameLabel.textColor = BearyColors.gray
            }
            // D-G4：选中双环（网页 .mood-it.on .ring 的 box-shadow 等价）：
            // 内环 bg 2px + 外环橙 2.5px（总外扩 4.5px），用 even-odd 圆环形层画，
            // 尺寸钉死 44（环约束即 44，与布局时序无关，布局前刷新也不塌）。
            setMoodRingShadow(item.ringView, selected: isSelected)
        }
        // C1：选中名不再由心情标题行承载（标题行已删），改由正文下方 Chip 行显示。
        refreshSelectedChips()
    }

    /// D-G4：心情选中双环。网页 `.mood-it.on .ring` 的 box-shadow 是
    /// `0 0 0 2px bg, 0 0 0 4.5px orange`（环外先 2px 底色、再 2.5px 橙）；
    /// 单层 CALayer shadow 画不出双环，故用两层 even-odd 圆环形层：
    /// bg 环（22→24）+ 橙环（24→26.5），插到环视图图层最底层（熊图之下）。
    /// 深浅切换走 traitCollectionDidChange → refreshMoodButtons 重建，底色跟随主题。
    private func setMoodRingShadow(_ ringView: UIView, selected: Bool) {
        if let sublayers = ringView.layer.sublayers {
            for layer in sublayers where layer.name == "moodRingBg" || layer.name == "moodRingOrange" {
                layer.removeFromSuperlayer()
            }
        }
        if !selected {
            ringView.layer.masksToBounds = true
            return
        }
        // 形层须露到环外，关掉裁剪（环内熊图 35 < 环 44，不会溢出）。
        ringView.layer.masksToBounds = false
        let bgLayer = CAShapeLayer()
        bgLayer.name = "moodRingBg"
        bgLayer.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let bgPath = CGMutablePath()
        bgPath.addEllipse(in: CGRect(x: -2, y: -2, width: 48, height: 48))
        bgPath.addEllipse(in: CGRect(x: 0, y: 0, width: 44, height: 44))
        bgLayer.path = bgPath
        bgLayer.fillRule = .evenOdd
        bgLayer.fillColor = BearyColors.bg.resolvedColor(with: traitCollection).cgColor
        let orangeLayer = CAShapeLayer()
        orangeLayer.name = "moodRingOrange"
        orangeLayer.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let orangePath = CGMutablePath()
        orangePath.addEllipse(in: CGRect(x: -4.5, y: -4.5, width: 53, height: 53))
        orangePath.addEllipse(in: CGRect(x: -2, y: -2, width: 48, height: 48))
        orangeLayer.path = orangePath
        orangeLayer.fillRule = .evenOdd
        orangeLayer.fillColor = BearyColors.orange.cgColor
        ringView.layer.insertSublayer(bgLayer, at: 0)
        ringView.layer.insertSublayer(orangeLayer, at: 0)
    }

    @objc private func didTapMood(_ sender: UIButton) {
        var tappedKey: String?
        for item in moodItems {
            if item.button == sender {
                tappedKey = item.key
            }
        }
        guard let key = tappedKey else { return }
        if selectedMood == key {
            selectedMood = nil
        } else {
            selectedMood = key
        }
        refreshMoodButtons()
        updateMoodPlayback()
        scheduleDraftSave()
    }

    // MARK: - 图片条

    private func createImageItem(localImage: UIImage?, key: String?, uploading: Bool, localFile: String?, failed: Bool) -> ComposerImageItem {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // 网页 thumb 本身无容器底：单项背后不再铺 faint 底，圆角 10 由容器裁剪提供。
        container.backgroundColor = UIColor.clear
        container.layer.cornerRadius = 10
        container.layer.masksToBounds = true
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = localImage
        container.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapImageItem(_:)))
        container.addGestureRecognizer(tap)
        let spinner = BearyRefreshIconView()
        // 失败态：行内红底块（网页 thumb-fail 同款：红 10% 底 + 图标 + “失败，点我重试”），
        // 点块重试，不弹全局框；发布时有失败图直接 toast 拦截（决议第 5 项 A），不弹框。
        let failView = UIView()
        failView.translatesAutoresizingMaskIntoConstraints = false
        failView.backgroundColor = BearyColors.red.withAlphaComponent(0.10)
        failView.layer.cornerRadius = 10
        failView.layer.masksToBounds = true
        failView.isHidden = !failed
        let failStack = UIStackView()
        failStack.translatesAutoresizingMaskIntoConstraints = false
        failStack.axis = .vertical
        failStack.spacing = 3
        failStack.alignment = .center
        let failIcon = UIImageView(image: BearyIconImages.image(named: "icon_image", pointSize: 20))
        failIcon.tintColor = BearyColors.red
        failIcon.contentMode = .scaleAspectFit
        failIcon.translatesAutoresizingMaskIntoConstraints = false
        let failLabel = UILabel()
        failLabel.translatesAutoresizingMaskIntoConstraints = false
        failLabel.text = "失败，点我重试"
        failLabel.font = UIFont.systemFont(ofSize: 10)
        failLabel.textColor = BearyColors.red
        failLabel.textAlignment = .center
        failStack.addArrangedSubview(failIcon)
        failStack.addArrangedSubview(failLabel)
        failView.addSubview(failStack)
        let removeButton = BearyHit44Button(type: .system)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        // I6：图片移除改用 icon_close 资产（不再用文字 ×）。
        // D-G16：网页 .thumb-x 22×22、top 4、right 4；原 20/top 2/right -2 改齐，
        // 圆角随尺寸改 11 以保持正圆（裁剪钮不在本项内，不动）。
        removeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 12), for: .normal)
        removeButton.tintColor = UIColor.white
        removeButton.backgroundColor = BearyColors.scrim
        removeButton.layer.cornerRadius = 11
        removeButton.layer.masksToBounds = true
        removeButton.addTarget(self, action: #selector(didTapRemoveImage(_:)), for: .touchUpInside)
        removeButton.bearyAddPressFeedback()
        // C11：左下角独立裁剪钮已删，点缩略图主体直接进裁剪页（见 didTapImageItem）。
        container.addSubview(imageView)
        container.addSubview(spinner)
        container.addSubview(failView)
        container.addSubview(removeButton)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 84),
            container.heightAnchor.constraint(equalToConstant: 84),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            failView.topAnchor.constraint(equalTo: container.topAnchor),
            failView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            failView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            failView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            failStack.centerXAnchor.constraint(equalTo: failView.centerXAnchor),
            failStack.centerYAnchor.constraint(equalTo: failView.centerYAnchor),
            failStack.leadingAnchor.constraint(greaterThanOrEqualTo: failView.leadingAnchor, constant: 4),
            failStack.trailingAnchor.constraint(lessThanOrEqualTo: failView.trailingAnchor, constant: -4),
            failIcon.widthAnchor.constraint(equalToConstant: 20),
            failIcon.heightAnchor.constraint(equalToConstant: 20),
            removeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        if uploading {
            spinner.startSpinning()
        }
        if failed {
            imageView.isHidden = true
        }
        let item = ComposerImageItem(key: key, uploading: uploading, localFile: localFile, failed: failed, container: container, imageView: imageView, spinner: spinner, failView: failView, removeButton: removeButton)
        return item
    }

    // MARK: - 上传状态（上传中 / 已传 / 失败三态；失败只亮红底重试块，不弹框）

    private func markUploading(_ item: ComposerImageItem) {
        item.uploading = true
        item.failed = false
        item.failView.isHidden = true
        item.imageView.isHidden = false
        item.imageView.alpha = 1.0
        item.spinner.startSpinning()
    }

    private func markUploaded(_ item: ComposerImageItem, key: String) {
        item.key = key
        item.uploading = false
        item.failed = false
        item.failView.isHidden = true
        item.imageView.isHidden = false
        item.imageView.alpha = 1.0
        item.spinner.stopSpinning()
    }

    private func markFailed(_ item: ComposerImageItem) {
        item.uploading = false
        item.failed = true
        item.failView.isHidden = false
        item.imageView.isHidden = true
        item.spinner.stopSpinning()
    }

    @objc private func didTapImageItem(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view else { return }
        for item in imageItems {
            if item.container === tappedView {
                if item.failed {
                    if let name = item.localFile {
                        // 失败图重试：读盘解码也走后台队列，解完回主线程再起上传。
                        imagePrepQueue.async { [weak self, weak item] in
                            let image = BearyDraftImageStore.image(for: name)
                            DispatchQueue.main.async {
                                guard let self = self, let item = item else { return }
                                var stillThere = false
                                for existing in self.imageItems {
                                    if existing === item {
                                        stillThere = true
                                    }
                                }
                                if !stillThere {
                                    return
                                }
                                if let image = image {
                                    self.startUpload(for: item, image: image)
                                }
                                // 本地文件读不出：保持失败态，下次点图再试。
                            }
                        }
                    } else {
                        // 无本地文件又无 key：无物可传，移除该项。
                        removeImageItem(item)
                    }
                    return
                }
                // C11：点缩略图主体直接进预览/裁剪页（左下角独立裁剪钮已删）；
                // 上传中不进（裁剪源未落定），与旧裁剪钮守卫同款。
                if item.uploading { return }
                openCropEditorForImageItem(item)
                return
            }
        }
    }

    /// C11：裁剪源解析（旧裁剪钮处理同款）：优先本地原图，其次条内图。
    private func openCropEditorForImageItem(_ item: ComposerImageItem) {
        if presentedViewController != nil { return }
        if let name = item.localFile {
            imagePrepQueue.async { [weak self, weak item] in
                let diskImage = BearyDraftImageStore.image(for: name)
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    if let source = diskImage ?? item.imageView.image {
                        self.presentCropEditor(for: item, source: source)
                    } else {
                        self.showToast(message: "图片还没加载好，稍后再试")
                    }
                }
            }
        } else if let source = item.imageView.image {
            presentCropEditor(for: item, source: source)
        } else {
            showToast(message: "图片还没加载好，稍后再试")
        }
    }

    private func insertImageItem(_ item: ComposerImageItem) {
        imageItems.append(item)
        imageStackView.addArrangedSubview(item.container)
        refreshImageStripVisibility()
        updatePublishState()
        updatePreferredContentSize()
    }



    private func removeImageItem(_ item: ComposerImageItem) {
        var kept: [ComposerImageItem] = []
        for existing in imageItems {
            if existing !== item {
                kept.append(existing)
            }
        }
        imageItems = kept
        if let name = item.localFile {
            BearyDraftImageStore.deletePair(fullName: name)
        }
        imageStackView.removeArrangedSubview(item.container)
        item.container.removeFromSuperview()
        refreshImageStripVisibility()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
    }

    /// C11：删图不再弹确认：先入单槽缓冲、条内即时消失、撤销条可见 10 秒。
    /// 期间草稿已按删除后状态落盘（scheduleDraftSave），本地文件暂不删；
    /// 点撤销即按原位恢复（含 key/localFile/上传态），恢复后重新落盘。
    private func deleteImageItemWithUndo(_ item: ComposerImageItem) {
        var index = imageItems.count
        for (i, existing) in imageItems.enumerated() {
            if existing === item {
                index = i
            }
        }
        // 新删除顶掉旧缓冲：旧项先彻底提交（删本地文件），缓冲永不积压两项。
        commitPendingRemoval()
        var kept: [ComposerImageItem] = []
        for existing in imageItems {
            if existing !== item {
                kept.append(existing)
            }
        }
        imageItems = kept
        imageStackView.removeArrangedSubview(item.container)
        item.container.removeFromSuperview()
        pendingRemovedImage = PendingRemovedImage(item: item, index: index)
        pendingUndoTimer = Timer.scheduledTimer(withTimeInterval: Self.imageUndoSeconds, repeats: false) { [weak self] _ in
            self?.commitPendingRemoval()
        }
        refreshImageUndoBar()
        refreshImageStripVisibility()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
    }

    @objc private func didTapUndoRemovedImage() {
        guard let pending = pendingRemovedImage else { return }
        pendingUndoTimer?.invalidate()
        pendingUndoTimer = nil
        pendingRemovedImage = nil
        let item = pending.item
        let index = min(pending.index, imageItems.count)
        imageItems.insert(item, at: index)
        imageStackView.insertArrangedSubview(item.container, at: index)
        refreshImageUndoBar()
        refreshImageStripVisibility()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
        // 上传中途被删又撤销：删期间到账的上传回调因“不在条里”已丢弃，
        // 恢复后若仍是上传态，从本地/条内图重启一次上传，避免永久卡上传中。
        if item.uploading {
            restartUploadForRestoredItem(item)
        }
    }

    private func restartUploadForRestoredItem(_ item: ComposerImageItem) {
        if let name = item.localFile {
            imagePrepQueue.async { [weak self, weak item] in
                let image = BearyDraftImageStore.image(for: name)
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    if let image = image {
                        self.startUpload(for: item, image: image)
                    } else {
                        self.markFailed(item)
                        self.updatePublishState()
                    }
                }
            }
        } else if let image = item.imageView.image {
            startUpload(for: item, image: image)
        } else {
            markFailed(item)
            updatePublishState()
        }
    }

    /// 提交缓冲删除（彻底删除）：计时到期、新删除顶替、发布/保存成功、取消、
    /// 切草稿时调用。本地文件删除、key 丢弃（不调服务端，与旧直接删除同款
    /// 孤 key 口径）；无缓冲时为空操作（只清计时器与撤销条）。
    private func commitPendingRemoval() {
        pendingUndoTimer?.invalidate()
        pendingUndoTimer = nil
        guard let pending = pendingRemovedImage else {
            refreshImageUndoBar()
            return
        }
        pendingRemovedImage = nil
        if let name = pending.item.localFile {
            BearyDraftImageStore.deletePair(fullName: name)
        }
        refreshImageUndoBar()
    }

    private func refreshImageUndoBar() {
        let visible = pendingRemovedImage != nil && !quotePanelOpen
        imageUndoBar.isHidden = !visible
        contentStack.setCustomSpacing(visible ? 8 : 0, after: imageUndoBar)
    }

    @objc private func didTapRemoveImage(_ sender: UIButton) {
        for item in imageItems {
            if item.removeButton == sender {
                // C11：不再直接删，改删后 10 秒撤销（见 deleteImageItemWithUndo）；
                // 提交后仍只去本地与 key 列表，不调服务端（孤 key 残留同旧口径）。
                deleteImageItemWithUndo(item)
                return
            }
        }
    }

    // MARK: - 裁剪调整（C11：点缩略图主体进页；确认替换、取消不动）

    private func presentCropEditor(for item: ComposerImageItem, source: UIImage) {
        // 磁盘读图是异步的：回到主线程时若已有弹窗在上（草稿箱等），不再叠页。
        if presentedViewController != nil { return }
        let cropVC = BearyImageCropViewController(image: source, aspectRatio: 1)
        cropVC.modalPresentationStyle = .fullScreen
        cropVC.onConfirm = { [weak self, weak item] cropped in
            guard let self = self, let item = item else { return }
            self.applyCroppedImage(cropped, to: item)
        }
        present(cropVC, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// 确认裁剪：先在后台编一次码（失败则原图原样不动、只 toast），成功后才替换预览、
    /// 清掉旧 key（旧 key 指向未裁剪原图，不可复用；孤 key 残留与移除同款已知可接受）、
    /// 删旧本地对、落盘新图、走与选图同一份 uploadPrepared 上传；取消则全程不碰原项。
    /// 编辑模式同款：新 key 进 uploadedImageKeys，保存走 PUT，不碰草稿流。
    private func applyCroppedImage(_ cropped: UIImage, to item: ComposerImageItem) {
        var stillThere = false
        for existing in imageItems {
            if existing === item {
                stillThere = true
            }
        }
        if !stillThere { return }
        let oldName = item.localFile
        imagePrepQueue.async { [weak self, weak item] in
            guard let full = BearyImagePrep.jpegData(cropped, maxSide: 1600, quality: 0.85),
                  let thumb = BearyImagePrep.thumbData(cropped, maxSide: 480) else {
                DispatchQueue.main.async {
                    self?.showToast(message: "裁剪保存失败，原图未改")
                }
                return
            }
            let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb)
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                if !stillThere {
                    return
                }
                if let saved = saved {
                    // 落盘成功才替换预览、清旧 key、删旧本地对（旧 key 指向未裁剪
                    // 原图，不可复用；孤 key 残留与移除同款已知可接受）。
                    item.imageView.image = cropped
                    item.key = nil
                    item.failed = false
                    item.localFile = saved
                    if let oldName = oldName, oldName != saved {
                        BearyDraftImageStore.deletePair(fullName: oldName)
                    }
                } else {
                    // P1-19：落盘失败时旧文件、旧 key、旧预览一律不动，只 toast，
                    // 不删原图、不走上传——失败的裁剪不丢原图。
                    self.showToast(message: "裁剪保存失败，原图未改")
                    return
                }
                self.markUploading(item)
                self.saveDraftNow()
                self.updatePublishState()
                self.imagePrepQueue.async { [weak self, weak item] in
                    self?.uploadPrepared(for: item, full: full, thumbData: thumb, image: cropped)
                }
            }
        }
    }

    @objc private func didTapAddImage() {
        // 编辑器改版：弹出框打开时点其他工具钮，先收起框再走各自处理。
        hideCallout(animated: false)
        // P2：9 图上限到达时不再完全静默，给 toast（不改按钮置灰口径）。
        if imageItems.count >= BearyComposerViewController.maxImages {
            showToast(message: "最多 9 张图片")
            return
        }
        var config = PHPickerConfiguration()
        config.selectionLimit = BearyComposerViewController.maxImages - imageItems.count
        config.filter = .images
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: BearyMotion.animated(true))
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: BearyMotion.animated(true))
        for result in results {
            if imageItems.count >= BearyComposerViewController.maxImages {
                break
            }
            let provider = result.itemProvider
            if !provider.canLoadObject(ofClass: UIImage.self) {
                continue
            }
            // 先按选择顺序占位建项（转圈态），加载完成后再填图上传：
            // 异步加载各图快慢不一，旧写法按完成顺序建项会打乱用户选图顺序。
            // 占位项计入 9 张上限，发布在上传完成前保持禁用，与原有联动一致。
            let item = createImageItem(localImage: nil, key: nil, uploading: true, localFile: nil, failed: false)
            insertImageItem(item)
            provider.loadObject(ofClass: UIImage.self) { [weak self, weak item] object, _ in
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    guard let image = object as? UIImage else {
                        // 读不出图：占位项直接移除，不留转圈、不留误导的重试态。
                        self.removeImageItem(item)
                        return
                    }
                    item.imageView.image = image
                    // 先落盘再上传：选完图立刻有本地文件，杀 App 也不丢图。
                    // 落盘失败则按无本地文件降级（与旧行为一致，草稿里只有 key）。
                    // 编码 + 落盘 + 上传序列化全走后台队列，只编一次（旧写法落盘编一次、
                    // startUpload 又编一次）；主线程只填图与更新 UI。
                    self.imagePrepQueue.async { [weak self, weak item] in
                        guard let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                              let thumb = BearyImagePrep.thumbData(image, maxSide: 480) else {
                            DispatchQueue.main.async {
                                guard let self = self, let item = item else { return }
                                self.markFailed(item)
                                self.saveDraftNow()
                                self.updatePublishState()
                            }
                            return
                        }
                        let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb)
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else { return }
                            var stillThere = false
                            for existing in self.imageItems {
                                if existing === item {
                                    stillThere = true
                                }
                            }
                            if !stillThere {
                                return
                            }
                            if let saved = saved {
                                item.localFile = saved
                            }
                            self.saveDraftNow()
                        }
                        // 上传用同一份编码结果，不再重编（uploadPrepared 内 base64 与
                        // BearyAPI 的 JSON 序列化都在本后台线程上，不占主线程）。
                        self?.uploadPrepared(for: item, full: full, thumbData: thumb, image: image)
                    }
                }
            }
        }
    }

    /// 上传入口（重试/续传）：主线程只置上传态，编码 + base64 + 上传序列化走后台队列。
    private func startUpload(for item: ComposerImageItem, image: UIImage) {
        markUploading(item)
        // 扫一遍同款（4c）：置上传态即改发布启用态，旧代码只在上传完成回调里
        // 同步，续传/重试起传后到完成前发布态是陈旧的（应禁用时仍显可用）。
        updatePublishState()
        imagePrepQueue.async { [weak self, weak item] in
            guard let full = BearyImagePrep.jpegData(image, maxSide: 1600, quality: 0.85),
                  let thumb = BearyImagePrep.thumbData(image, maxSide: 480) else {
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
                return
            }
            self?.uploadPrepared(for: item, full: full, thumbData: thumb, image: image)
        }
    }

    /// 用已编好的数据上传（调用方已在后台线程上；base64 与 BearyAPI 的 JSON 序列化
    /// 都发生在本线程，回调回主线程后只更新 UI 与落盘）。
    private func uploadPrepared(for item: ComposerImageItem?, full: (data: Data, w: Int, h: Int), thumbData: Data, image: UIImage) {
        guard let item = item else { return }
        BearyAPI.shared.uploadImage(dataUrl: BearyImagePrep.dataURL(full.data), width: full.w, height: full.h, thumbDataUrl: BearyImagePrep.dataURL(thumbData)) { [weak self, weak item] result in
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                if !stillThere {
                    return
                }
                switch result {
                case .success(let resp):
                    if let key = resp.key {
                        self.markUploaded(item, key: key)
                        item.imageView.image = image
                        self.scheduleDraftSave()
                        self.updatePublishState()
                    } else {
                        self.markFailed(item)
                        self.saveDraftNow()
                        self.updatePublishState()
                    }
                case .failure:
                    // 失败只亮重试态：图留在条里，点图重试；不弹全局框、不删项。
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
            }
        }
    }

    /// 重开编辑器时续传：有本地文件、无 key、非失败态的项自动重新上传。
    /// 失败态的项不自动续传，等用户点图重试；本地文件读不出的项置失败态。
    /// 一律后台读盘解码（不复用条内图：解码失败时条内可能是远程缩略图，复用会把
    /// 缩略图当原图上传）。
    private func resumePendingUploads() {
        let pending = imageItems
        for item in pending {
            if item.key != nil || item.uploading || item.failed {
                continue
            }
            guard let name = item.localFile else { continue }
            imagePrepQueue.async { [weak self, weak item] in
                let image = BearyDraftImageStore.image(for: name)
                DispatchQueue.main.async {
                    guard let self = self, let item = item else { return }
                    var stillThere = false
                    for existing in self.imageItems {
                        if existing === item {
                            stillThere = true
                        }
                    }
                    if !stillThere {
                        return
                    }
                    if let image = image {
                        self.startUpload(for: item, image: image)
                    } else {
                        self.markFailed(item)
                    }
                }
            }
        }
    }

    private func uploadedImageKeys() -> [String] {
        var keys: [String] = []
        for item in imageItems {
            if let key = item.key {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - 编辑模式回填（只读原值，不碰草稿）

    /// C12：编辑回填带加载态与失败路径。quote 体缺失（quote 为空但有 quoteId、
    /// 或 quote 有 id 无正文）时补拉单篇（详情同款 fetchEntry）：拉取中标题为
    /// “加载日记…”，成功后以新 entry 重填；失败则关编辑器 + toast“日记加载失败，
    /// 请重试”（toast 挂在 presenting 方，关编辑器后仍可见）。补拉只做一次，
    /// 已删引用（gone 只有 id、无正文）补拉后仍无正文时不再反复请求。
    private func setupEditContent() {
        guard let entry = editingEntry else { return }
        // 录屏批 (b) 同款：面板打开时标题归面板（“选择引用”），回填不许把它顶回
        // “编辑日记”；只把关闭后要还原的标题改成“编辑日记”，关闭时还原即正确。
        if quotePanelOpen {
            quotePanelSavedTitle = "编辑日记"
        } else {
            titleLabel.text = "编辑日记"
        }
        textView.text = entry.content ?? ""
        applyBodyLineHeight()
        // A4-App：编辑回填标题（无标题时字段留空，不做占位决定）。
        titleField.text = entry.title ?? ""
        selectedMood = entry.mood
        refreshMoodButtons()
        selectedWeather = entry.weather
        refreshWeatherButtons()
        // 补拉重填（setupEditContent 二次调用）不碰 @ 态：用户可能已在加载期间改选/清除，
        // 首次回填时才以服务端原 @ 为准（editQuoteFetchAttempted 此时仍为 false）。
        if !editQuoteFetchAttempted {
            lockedRecipientName = entry.mentionedName
            lockedMentionedUserId = entry.mentionedUserId
            editMentionCleared = false
        }
        let quoteBodyMissing: Bool
        if let quote = entry.quote {
            quoteBodyMissing = quote.id != nil && quote.content == nil
        } else {
            quoteBodyMissing = entry.quoteId != nil
        }
        if quoteBodyMissing && !editQuoteFetchAttempted, let entryId = entry.id, !entryId.isEmpty {
            editQuoteFetchAttempted = true
            if quotePanelOpen {
                quotePanelSavedTitle = "加载日记…"
            } else {
                titleLabel.text = "加载日记…"
            }
            refreshRecipientRow()
            refreshQuoteSection()
            refreshToolStrip()
            BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let fetched):
                        self.editingEntry = fetched
                        self.setupEditContent()
                    case .failure:
                        self.showToastAfterClose(message: "日记加载失败，请重试")
                        self.onCancelled?()
                    }
                }
            }
            return
        }
        if let quote = entry.quote, let quoteId = quote.id, let content = quote.content {
            // 内容为空的引用 = 已删（服务端 gone 只剩 id，网页版同款：已删引用不回填，保存时即丢弃）。
            lockedQuote = SelectedQuote(entryId: quoteId, content: content, createdAt: quote.createdAt, authorName: quote.authorName, authorAvatar: quote.authorAvatar, images: quote.images ?? [], isPublic: quote.isPublic, publishAt: nil, imgDims: nil, isDeleted: false) // P3-41 注：编辑态锁定来自服务端直传 Quote（attachQuotes 不返回 ephemeral_until，算不出有效态），暂留原值；新选/恢复校验两处已走有效态。
        }
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        startEditTimer()
        for key in entry.images ?? [] {
            let item = createImageItem(localImage: nil, key: key, uploading: false, localFile: nil, failed: false)
            insertImageItem(item)
            if let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                // B3-2：图片条单项 84×84，下采样到显示尺寸。
                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
            }
        }
        refreshImageStripVisibility()
        updateTextViewHeight()
        // 扫一遍同款（4c）：补拉单篇后的第二次回填是 viewDidLoad 之后唯一的正文
        // 填充点，此前不调 updatePublishState，保存钮会留在空态灰直到用户输入。
        updatePublishState()
    }

    /// 回填后原引用的有效 id（setup 时 content 为空的引用视为已删、不算原引用，
    /// 否则改动判定会把“没改过”误判为改过）。
    private func originalQuoteId() -> String? {
        guard let quote = editingEntry?.quote, let quoteId = quote.id, quote.content != nil else { return nil }
        return quoteId
    }

    /// 编辑期内的本地文件（本轮新选的图）：取消/保存成功后删本地文件，不留孤文件；
    /// 原日记的图 localFile 为 nil，不受影响。失败时不删，留着给重试用。
    private func deleteEditLocalFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
    }

    // P2：isEditDirty() 为死代码（无调用点），直接删除，不接入其比较口径。

    // MARK: - 草稿

    private func scheduleDraftSave() {
        // 编辑模式不走草稿流：任何编辑中的改动都不写 beary_draft_v3。
        if isEditMode { return }
        // 防抖等待期先显“保存中…”（网页 queueSaveDraft 同款），落盘后由保存级别覆盖。
        // D-G14：网页保存中态带 15px beary-loading 转圈图标（queueSaveDraft 的
        // spin 图标 + “保存中…”），原 App 只出文字无图标；此处换 icon_refresh 图并转圈，
        // 落盘后 updateDraftStatusLabel 会停转并换回对勾。
        draftStatusGroup.isHidden = false
        draftStatusIcon.image = BearyIconImages.image(named: "icon_refresh", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.gray
        draftStatusIcon.isHidden = false
        BearyIconMotion.startSpin(on: draftStatusIcon, duration: 0.9, key: "bearyDraftSavingSpin")
        draftStatusLabel.text = "保存中…"
        draftStatusLabel.textColor = BearyColors.blue
        draftTimer?.invalidate()
        // 网页 queueSaveDraft 防抖 400ms（原先 500ms）。
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.saveDraftNow()
        }
    }

    /// 立即落盘（主线程只拍快照，整库读/写走 BearyDraftStore.ioQueue；写盘本身已是原子替换）。
    /// completion 在主线程回调（存完才开草稿箱 / 保留后才关编辑器等顺序敏感路径用）。
    private func saveDraftNow(completion: (() -> Void)? = nil) {
        // 编辑模式不写草稿（scheduleDraftSave 已拦，这里再拦一道，防以后新增调用点漏拦）。
        if isEditMode {
            completion?()
            return
        }
        // clientReq 与 draftId 都是本篇草稿创建时生成一次，之后全程复用（含发布重试），
        // 成功拿到 entry id 前绝不换——服务端靠 clientReq 做发布幂等，本地靠 draftId 分篇。
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        if currentDraftId == nil {
            currentDraftId = BearyDraftStore.newDraftId()
            clearedCurrentDraftId = nil
        }
        guard let req = draftClientReq, let draftIdValue = currentDraftId else {
            completion?()
            return
        }
        // C10 空判定（心情不算内容）：正文 trim 为空、且无已上传图、无天气、无 @、
        // 无引用时，整篇视为空——已有草稿删篇并隐藏状态，不新建空草稿。
        // 上传中/失败图不进草稿（网页 draftImgList 同款：up_ 占位一律排除），故空判定
        // 与落盘图片都只看已上传图；内存里的上传中/失败项仍留在图片条里可续传/重试。
        var uploadedItems: [ComposerImageItem] = []
        for item in imageItems {
            if item.key != nil {
                uploadedItems.append(item)
            }
        }
        let hasRealContent = !trimmedContent().isEmpty || !uploadedItems.isEmpty
            || selectedWeather != nil || selectedRecipient != nil || selectedQuote != nil
        if !hasRealContent {
            let deletingId = draftIdValue
            currentDraftId = nil
            clearedCurrentDraftId = nil
            draftClientReq = nil
            // 删篇走 deleteAsync（ioQueue 内删，完成后回主线程刷新状态与 pill）。
            // 状态只在仍是空篇时清：删盘期间用户已开始写新篇（currentDraftId 已换）
            // 时不碰新篇的状态行，pill 计数全局刷新无妨。
            BearyDraftStore.deleteAsync(draftId: deletingId) { [weak self] in
                guard let self = self else { return }
                if self.currentDraftId == nil {
                    self.draftStatusLevel = nil
                    self.updateDraftStatusLabel()
                }
                self.updateDraftPillCount()
                completion?()
            }
            return
        }
        var images: [BearyDraftImageItem] = []
        for item in uploadedItems {
            images.append(BearyDraftImageItem(localFile: item.localFile, serverKey: item.key, state: .uploaded))
        }
        // @ 展示名口径与 refreshRecipientRow 一致（展示名 / @handle / “用户”兜底），
        // 只为恢复 chip 显示；发布仍以 mentioned_user_id 为准。
        var recipientNameValue: String?
        var recipientUserId: Int?
        if let recipient = selectedRecipient {
            recipientUserId = recipient.id
            if let display = recipient.displayName {
                recipientNameValue = display
            } else if let handle = recipient.handle {
                recipientNameValue = "@" + handle
            } else {
                recipientNameValue = "用户"
            }
        }
        let draft = BearyDraft(
            draftId: draftIdValue,
            // P1-15：草稿快照只存已落字（拼音组词期的未落字拼音不进草稿），
            // textView 本体不动，组词继续。
            content: committedContent(),
            title: trimmedTitle(),
            mood: selectedMood,
            images: images,
            clientReq: req,
            updatedAt: Date().timeIntervalSince1970,
            weather: selectedWeather,
            visibilitySegmentIndex: selectedVisibilityPublished ? 1 : 0,
            recipientId: recipientUserId,
            recipientName: recipientNameValue,
            recipientAvatar: selectedRecipient?.avatarUrl,
            notifyRecipient: notifyRecipient,
            quoteId: selectedQuote?.entryId,
            quoteAuthorName: selectedQuote?.authorName,
            quoteAuthorAvatar: selectedQuote?.authorAvatar,
            quoteCreatedAt: selectedQuote?.createdAt,
            quoteContent: selectedQuote?.content,
            quoteImages: selectedQuote?.images ?? [],
            quoteIsPublic: selectedQuote?.isPublic,
            quoteDeleted: selectedQuote?.isDeleted ?? false)
        // 快照里的图片在途态拍在主线程（内存态），整库写 + 回读验证走后台队列。
        var hasUnsavedImageSnapshot = false
        for item in imageItems {
            if item.key == nil {
                hasUnsavedImageSnapshot = true
            }
        }
        // 写 + 回读验证都在 BearyDraftStore.ioQueue 内完成（saveAsync 只管写、不回
        // 传验证结果，故这里直接用同一队列；与草稿箱的写删串行，不会旧读回写复活
        // 已删草稿；快照本身只是单篇 struct，不含整库旧状态）。
        // 审计三轮第 2 项：入队前捕获账号，写与回读一律用捕获值，排队期间切号不串桶。
        let saveAccountId = BearyDraftStore.currentAccountId
        BearyDraftStore.ioQueue.async { [weak self] in
            let writeSucceeded = BearyDraftStore.save(draft, forAccount: saveAccountId)
            // 保存级别跟随图片状态：有失败/未上传的图 = 1（文字已保存，图片未保存），否则 2；
            // 落盘失败 = 0（失败红字）。saveAll 是原子写，失败时旧库原样保留，
            // 故已有草稿更新失败时回读仍命中旧版本——必须以 save 的 Bool 为准，
            // 回读只作辅助确认（save 成功仍回读不到本篇同样判失败），不得以回读
            // 命中掩盖写失败；多槽下必须按 draftId 查本篇，不能用“库非空”当成功信号。
            var foundCurrentDraft = false
            var totalCount = 0
            for savedDraft in BearyDraftStore.loadAll(forAccount: saveAccountId) {
                totalCount += 1
                if savedDraft.draftId == draftIdValue {
                    foundCurrentDraft = true
                }
            }
            // 成功 = 写盘成功且回读确认本篇存在；任一不成立均为失败。
            let savedCurrentDraft = writeSucceeded && foundCurrentDraft
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 状态只在仍是本篇时写：落盘期间编辑器已切篇（如保留后新建）时，
                // 旧篇的完成回调不把“草稿已保存”写到空白新篇上；pill 计数全局刷新无妨。
                if self.currentDraftId == draftIdValue {
                    if savedCurrentDraft == false {
                        self.draftStatusLevel = 0
                    } else {
                        self.draftStatusLevel = hasUnsavedImageSnapshot ? 1 : 2
                    }
                    self.updateDraftStatusLabel()
                }
                self.setDraftPillCount(totalCount)
                completion?()
            }
        }
    }

    /// FAB 打开时的草稿恢复（E1-3）：整库读 + 无主文件回收走 BearyDraftStore.ioQueue，
    /// 本地图解码走图片后台队列，主线程只填字段与建项；恢复完成 350ms 后 toast（网页同款）。
    private func restoreDraft() {
        BearyDraftStore.ioQueue.async { [weak self] in
            guard let draft = BearyDraftStore.load() else { return }
            // 回收无主文件（杀 App 后、首存前产生的孤文件）：多槽下必须保留全部草稿的
            // 引用并集，只留本篇会误删其他篇的本地图片。
            var referenced = Set<String>()
            for img in draft.images {
                if let name = img.localFile {
                    referenced.insert(name)
                }
            }
            for otherDraft in BearyDraftStore.loadAll() {
                for img in otherDraft.images {
                    if let name = img.localFile {
                        referenced.insert(name)
                    }
                }
            }
            BearyDraftImageStore.sweep(keeping: referenced)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 52 批补充：恢复竞态门——恢复是异步读盘，落地时用户可能已经打过字；
                // 此时整段覆盖会抹掉刚打的字（拼音组词中还会被 attributedText 重设打散）。
                // 用户已打字时整单跳过恢复（旧草稿仍在草稿箱，不丢），只字为空时才应用。
                let wasEmptyBeforeRestore = self.textView.text.isEmpty
                guard wasEmptyBeforeRestore else { return }
                self.currentDraftId = draft.draftId
                self.clearedCurrentDraftId = nil
                self.draftClientReq = draft.clientReq
                self.textView.text = draft.content
                self.applyBodyLineHeight()
                // 恢复后光标置末尾（接着写）：未出现时由 viewDidAppear 兜底，已聚焦且
                // 恢复前为空时也置末尾；恢复前已有用户输入时不抢光标。
                if self.view.window == nil || (wasEmptyBeforeRestore && self.textView.isFirstResponder) {
                    self.textView.selectedRange = NSRange(location: self.textView.text.count, length: 0)
                }
                self.selectedMood = draft.mood
                self.refreshMoodButtons()
                self.selectedWeather = draft.weather
                self.refreshWeatherButtons()
                self.restoreVisibility(index: draft.visibilitySegmentIndex)
                self.selectedRecipient = self.restoredRecipient(from: draft)
                self.notifyRecipient = draft.notifyRecipient
                self.selectedQuote = self.restoredQuote(from: draft)
                self.refreshRecipientRow()
                self.refreshQuoteSection()
                for img in draft.images {
                    let failed = (img.state == .failed)
                    let item = self.createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
                    self.insertImageItem(item)
                    // 只有 key 的老项（v1 迁移而来）走远程缩略图；有本地文件的项等后台解码后填图。
                    if img.localFile == nil, let key = img.serverKey,
                       let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                        item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
                    }
                }
                self.updateCountLabel()
                self.refreshToolStrip()
                self.updateDraftPillCount()
                self.updateTextViewHeight()
                self.updatePreferredContentSize()
                // 录屏批 (c)：恢复草稿后同步一次发布启用态，且放在全部刷新之后当
                // 最后一句——旧代码的 updatePublishState 在选择条刷新之前，恢复
                // 流程收尾时发布态不是最后一句，恢复后发布钮仍留空态灰，直到用户
                // 重新输入触发 textViewDidChange 才变白；放末尾保证收尾态即终态。
                self.updatePublishState()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self = self, self.view.window != nil else { return }
                    self.showToast(message: "已恢复上次的草稿")
                }
                // 本地图后台解码：失败态不解码（重试时再读盘）；解码失败且有 key 时退回远程缩略图。
                let decodingImages = draft.images
                self.imagePrepQueue.async { [weak self] in
                    var decoded: [(name: String, image: UIImage?)] = []
                    for img in decodingImages {
                        if img.state == .failed { continue }
                        if let name = img.localFile {
                            decoded.append((name: name, image: BearyDraftImageStore.image(for: name)))
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        for entry in decoded {
                            for item in self.imageItems {
                                if item.localFile == entry.name {
                                    if let image = entry.image {
                                        item.imageView.image = image
                                    } else if let key = item.key,
                                              let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                                        item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
                                    }
                                }
                            }
                        }
                        self.resumePendingUploads()
                        self.verifyRestoredQuote()
                        // 录屏批 (c) 同款：异步解码/续传完成后也同步一次发布态，
                        // 续传起的上传态经 startUpload 的同步 + 上传完成回调覆盖，
                        // 这里只保证恢复流程收尾时发布态与当前内容一致。
                        self.updatePublishState()
                    }
                }
            }
        }
    }

    /// v3 @ 快照还原为选人对象：id 为空即无 @；展示名/头像只供 chip 显示。
    private func restoredRecipient(from draft: BearyDraft) -> SearchUser? {
        guard let recipientUserId = draft.recipientId else { return nil }
        return SearchUser(id: recipientUserId, displayName: draft.recipientName, handle: nil, avatarUrl: draft.recipientAvatar, coverUrl: nil)
    }

    /// 草稿可见性恢复：index 与 selectedVisibilityPublished 同步写（发布
    /// 即读后者，只写 index 不动它仍会发出私密）；限时开时钮锁死公开且禁用
    /// （didToggleEphemeral 同款锁态），不以草稿值覆盖锁态；非法 index 一律
    /// 按私密兜底。restoreDraft 与 loadDraftFromBox 两路共用。
    private func restoreVisibility(index: Int) {
        if ephemeralSwitch.isOn {
            selectedVisibilityPublished = true
            visibilityButton.isEnabled = false
        } else {
            let restoredIndex = index == 1 ? 1 : 0
            selectedVisibilityPublished = restoredIndex == 1
            visibilityButton.isEnabled = true
        }
        refreshVisibilityButton()
    }

    /// v3 引用快照还原为选引用对象：quoteId 为空即无引用；已删标记照原样带回，
    /// 快照正文在已删态下不展示（见 refreshQuoteSection 的已删行）。
    private func restoredQuote(from draft: BearyDraft) -> SelectedQuote? {
        guard let quoteEntryId = draft.quoteId else { return nil }
        return SelectedQuote(entryId: quoteEntryId, content: draft.quoteContent ?? "", createdAt: draft.quoteCreatedAt, authorName: draft.quoteAuthorName, authorAvatar: draft.quoteAuthorAvatar, images: draft.quoteImages, isPublic: draft.quoteIsPublic, publishAt: nil, imgDims: nil, isDeleted: draft.quoteDeleted)
    }

    /// 恢复后校验引用是否还在：快照只能证明“选过”，不能证明“还在”。
    /// 只读单篇接口；仅 notFound 才翻为已删态并落盘标记（下次恢复直接显已删，
    /// 不再请求），其他失败（离线/未登录/服务端错）一律保留快照，不误判已删。
    /// 回包时若引用已被用户换掉或清除，不碰当前引用。
    private func verifyRestoredQuote() {
        guard let quote = selectedQuote, quote.isDeleted == false else { return }
        let quoteEntryId = quote.entryId
        BearyAPI.shared.fetchEntry(id: quoteEntryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentQuote = self.selectedQuote, currentQuote.entryId == quoteEntryId, currentQuote.isDeleted == false else { return }
                switch result {
                case .success(let fetched):
                    // 补缺 P3-41：恢复后以最新有效可见性刷新快照并重算角标（原直接 return，快照恒旧）；
                    // 落盘使刷新跨杀 App 生效（已删分支同款 saveDraftNow）。
                    self.selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: currentQuote.content, createdAt: currentQuote.createdAt, authorName: currentQuote.authorName, authorAvatar: currentQuote.authorAvatar, images: currentQuote.images, isPublic: BearyEphemeral.isEffectivelyPublic(fetched), publishAt: currentQuote.publishAt, imgDims: currentQuote.imgDims, isDeleted: false)
                    self.refreshQuoteSection()
                    self.saveDraftNow()
                    return
                case .failure(let fetchError):
                    if case .notFound = fetchError {
                        self.selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: "", createdAt: nil, authorName: nil, authorAvatar: nil, images: [], isPublic: nil, publishAt: nil, imgDims: nil, isDeleted: true)
                        self.refreshQuoteSection()
                        self.refreshToolStrip()
                        self.saveDraftNow()
                    }
                }
            }
        }
    }

    /// 发布成功 / 丢弃草稿时：只清本篇草稿 + 本篇全部本地图片文件 + 换掉 clientReq。
    /// 多槽下绝不能整库清，否则会误删其他篇。服务端孤 key 无删除接口，残留是已知可接受项（见文末注）。
    /// 整库删除走 deleteAsync（ioQueue 内删，完成后回主线程刷新 pill；调用方不依赖删完时序）。
    private func clearDraftAndFiles() {
        for item in imageItems {
            if let name = item.localFile {
                BearyDraftImageStore.deletePair(fullName: name)
            }
        }
        let draftIdValue = currentDraftId
        currentDraftId = nil
        clearedCurrentDraftId = nil
        draftClientReq = nil
        draftStatusLevel = nil
        updateDraftStatusLabel()
        if let draftIdValue = draftIdValue {
            BearyDraftStore.deleteAsync(draftId: draftIdValue) { [weak self] in
                self?.updateDraftPillCount()
            }
        } else {
            updateDraftPillCount()
        }
    }

    // MARK: - 草稿箱（BearyDraftBoxViewController 由草稿箱代理新建文件提供，只调用不定义）

    @objc private func didTapDraftBox() {
        // P3-5：编辑态草稿 pill 仍不开箱（行为不变），给提示不再静默 return。
        if isEditMode {
            showToast(message: "编辑日记时不能打开草稿箱")
            return
        }
        // P1-14：发布在途时不开箱（冻结已禁 pill，此为第二道守卫），
        // 否则切草稿会把在途发布的那篇换掉/删错篇。
        if isPublishing {
            showToast(message: "发布中…")
            return
        }
        // presented 守卫 + 在途标记（E4-3）：连点不叠开两个草稿箱。
        if presentedViewController != nil || isDraftBoxPresenting { return }
        // 有内容先落盘当前篇，再开箱（箱内计数含当前篇）；空白编辑器不建空草稿。
        // 落盘已走后台队列，开箱等存完回调再 present，计数不滞后。
        let openBox: () -> Void = { [weak self] in
            guard let self = self else { return }
            if self.presentedViewController != nil || self.isDraftBoxPresenting { return }
            self.isDraftBoxPresenting = true
            let box = BearyDraftBoxViewController(
                onNew: { [weak self] in
                    guard let self = self else { return }
                    self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
                        self.openBlankDraftFromBox()
                    }
                },
                onOpen: { [weak self] draft in
                    guard let self = self else { return }
                    self.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) {
                        self.loadDraftFromBox(draft)
                    }
                }
            )
            // DF-2 接线（收尾）：箱内删正在写草稿时通知编辑器，编辑器清 currentDraftId，
            // 下次落盘不再复活已删草稿；箱内“正在写”标记以 currentDraftId 为准。
            box.currentDraftId = self.currentDraftId
            box.onDeleteCurrentDraft = { [weak self] deletedId in
                if self?.currentDraftId == deletedId {
                    self?.currentDraftId = nil
                    // 审计 P1-9：记下被清掉的那篇 id，供撤销恢复时比对绑回。
                    self?.clearedCurrentDraftId = deletedId
                    // P1-16：只清 currentDraftId 会让新篇复用旧幂等键——
                    // 删“正在写”草稿时 clientReq 一并清掉，下次落盘重新生成。
                    self?.draftClientReq = nil
                }
            }
            // 审计 P1-9：箱内撤销恢复正在写草稿时绑回编辑器——仅当恢复的正是
            // 刚被清掉的那篇（clearedCurrentDraftId 比对，防串篇）且编辑器未接新篇时；
            // 不满足时恢复的篇仍在箱里，点开即是原有 onOpen 路径，不丢数据。
            box.onUndoCurrentDraft = { [weak self] draft in
                guard let self = self else { return }
                if self.currentDraftId == nil, draft.draftId == self.clearedCurrentDraftId {
                    self.currentDraftId = draft.draftId
                    self.clearedCurrentDraftId = nil
                }
            }
            self.present(box, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.isDraftBoxPresenting = false
            }
        }
        if hasEditorContent() {
            saveDraftNow(completion: openBox)
        } else {
            openBox()
        }
    }

    /// 草稿箱“新建日记”：有内容先走守卫（继续写 / 保留并新建 / 丢弃并新建），
    /// 无内容直接重置。v3 多槽下“保留并新建”成立：先落盘当前篇，再开空白新篇，
    /// 当前篇留在箱里不删；取消与发布逻辑不在这里，不动。
    private func openBlankDraftFromBox() {
        if isEditMode { return }
        if hasEditorContent() {
            let sheet = UIAlertController(title: nil, message: "当前内容还没发布，换成空白新日记吗？", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "继续写", style: .cancel, handler: nil))
            sheet.addAction(UIAlertAction(title: "保留并新建", style: .default) { [weak self] _ in
                guard let self = self else { return }
                // 落盘走后台队列：存完回调里再重置（快照在 saveDraftNow 调用时已拍，
                // 存完前切篇的状态守卫见 saveDraftNow 完成回调）。
                self.saveDraftNow {
                    self.resetEditorToBlank()
                }
            })
            sheet.addAction(UIAlertAction(title: "丢弃并新建", style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.clearDraftAndFiles()
                self.resetEditorToBlank()
            })
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = draftPillButton
                pop.sourceRect = draftPillButton.bounds
            }
            present(sheet, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            clearDraftAndFiles()
            resetEditorToBlank()
        }
    }

    /// 编辑器有无实质内容（C10：心情是常驻选择、不算内容——纯心情不建草稿；
    /// P2：正文按 trim 后算，纯空格不算有内容，与 saveDraftNow 的落盘口径一致；
    /// trimmedContent 本身已排除拼音组合串，纯组词也不算有内容）。
    private func hasEditorContent() -> Bool {
        if !trimmedContent().isEmpty { return true }
        if selectedWeather != nil { return true }
        if selectedRecipient != nil { return true }
        if selectedQuote != nil { return true }
        if !imageItems.isEmpty { return true }
        return false
    }

    /// 重置为空白新日记：清字段与图片视图、当前篇槽位与 clientReq（存储删除由调用方决定：
    /// 丢弃路径先调 clearDraftAndFiles 删本篇，保留路径先调 saveDraftNow 落盘本篇，
    /// 这里只清视图与槽位，不重复删存文件）。
    private func resetEditorToBlank() {
        draftTimer?.invalidate()
        textView.text = ""
        // A4-App：空白新日记清标题。
        titleField.text = ""
        selectedMood = nil
        selectedWeather = nil
        selectedRecipient = nil
        notifyRecipient = true
        selectedQuote = nil
        setQuotePanelOpen(false)
        removeAllImageViews()
        // 只清视图与槽位，不碰存储：删篇由调用方决定（丢弃路径先调 clearDraftAndFiles
        // 删本篇，保留路径先调 saveDraftNow 落盘本篇）；这里再整库清会误删其他篇。
        currentDraftId = nil
        draftClientReq = nil
        draftStatusLevel = nil
        updateCountLabel()
        updatePublishState()
        refreshMoodButtons()
        refreshWeatherButtons()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        updateDraftStatusLabel()
        updateDraftPillCount()
        // P1-17：重置为空白后同款同步——正文区回落下限高，缓存同步，
        // 避免残留旧篇高度导致空白编辑器正文区过高/过矮。
        updateTextViewHeight()
        lastTextViewContentHeight = textView.contentSize.height
        updatePreferredContentSize()
    }

    /// 草稿箱打开某篇：正文/心情/图片/天气/@/引用按 v3 原样恢复；之后再保存、
    /// 发布、丢弃都只针对这一篇（currentDraftId 已切到该篇）。
    private func loadDraftFromBox(_ draft: BearyDraft) {
        if isEditMode { return }
        draftTimer?.invalidate()
        removeAllImageViews()
        currentDraftId = draft.draftId
        draftClientReq = draft.clientReq
        textView.text = draft.content
        applyBodyLineHeight()
        // A4-App：草稿恢复标题。
        titleField.text = draft.title ?? ""
        selectedMood = draft.mood
        selectedWeather = draft.weather
        restoreVisibility(index: draft.visibilitySegmentIndex)
        selectedRecipient = restoredRecipient(from: draft)
        notifyRecipient = draft.notifyRecipient
        selectedQuote = restoredQuote(from: draft)
        setQuotePanelOpen(false)
        for img in draft.images {
            let failed = (img.state == .failed)
            let item = createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
            insertImageItem(item)
            // 只有 key 的老项走远程缩略图；有本地文件的项等后台解码后填图。
            if img.localFile == nil, let key = img.serverKey,
               let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
            }
        }
        refreshImageStripVisibility()
        // 本地图后台解码（失败态不解码，重试点图时再读盘），解完再续传。
        let decodingImages = draft.images
        imagePrepQueue.async { [weak self] in
            var decoded: [(name: String, image: UIImage?)] = []
            for img in decodingImages {
                if img.state == .failed { continue }
                if let name = img.localFile {
                    decoded.append((name: name, image: BearyDraftImageStore.image(for: name)))
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for entry in decoded {
                    for item in self.imageItems {
                        if item.localFile == entry.name {
                            if let image = entry.image {
                                item.imageView.image = image
                            } else if let key = item.key,
                                      let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
                            }
                        }
                    }
                }
                self.resumePendingUploads()
                // 录屏批 (c) 同款：草稿箱恢复的异步解码收尾时同步一次发布态。
                self.updatePublishState()
            }
        }
        updateCountLabel()
        refreshMoodButtons()
        refreshWeatherButtons()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        updateDraftPillCount()
        verifyRestoredQuote()
        // 录屏批 (c) 同款：草稿箱恢复后同步一次发布启用态，放全部刷新之后。
        updatePublishState()
        // P1-17：切草稿后正文区高度同步（先按新正文定高、再同步高度缓存、
        // 最后按新高重算 sheet 高，避免正文区停在旧篇高度）。
        updateTextViewHeight()
        lastTextViewContentHeight = textView.contentSize.height
        updatePreferredContentSize()
    }

    /// 只拆视图不删文件（切草稿时旧篇文件仍归旧篇所有，删文件只在丢弃/发布成功时做）。
    private func removeAllImageViews() {
        // 切草稿/重置时撤销缓冲一并提交（旧缓冲项不跟进新篇，见 commitPendingRemoval）。
        commitPendingRemoval()
        for item in imageItems {
            imageStackView.removeArrangedSubview(item.container)
            item.container.removeFromSuperview()
        }
        imageItems = []
        refreshImageStripVisibility()
    }

    // MARK: - 取消与发布

    @objc private func didTapCancel() {
        // P1-7：发布/保存进行中时取消键不走取消流程，给进行中提示（与 didTapPublish
        // 首行 isPublishing 守卫同口径；真取消在途请求属结构改动，本批不做）。
        if isPublishing {
            showToast(message: isEditMode ? "保存中…" : "发布中…")
            return
        }
        // qp-mode 下取消键是“返回”，只退面板，不走整编取消流程（网页同款）。
        if quotePanelOpen {
            setQuotePanelOpen(false)
            return
        }
        // presented 守卫（选人器/裁剪/草稿箱同款）：已有弹层在上时不动作。
        if presentedViewController != nil { return }
        // B 修法：取消退场前先收起未收的弹出框（无动画，退场不带它滑）；到此已确定退出
        //（编辑态与新建态两分支随后都走 onCancelled），守卫分支（发布在途／面板态／已有弹层）已在上文返回。
        hideCallout(animated: false)
        if isEditMode {
            // 决议第 4 项 B：取消直接关，不弹确认；只清本地临时图文件，不删原日记、不碰草稿。
            commitPendingRemoval()
            deleteEditLocalFiles()
            onCancelled?()
            return
        }
        // 决议第 4 项 B：取消不再弹三选、无丢弃路径，直接关 + 静默存草稿。
        // 草稿规则不动：saveDraftNow 原样走分级保存、纯心情不保存的现有逻辑。
        // C10：关闭时仍有图片在上传（失败图不算）——toast 挂 presenting 方，
        // 关编辑器后仍可见。旧文案“这次没存进草稿”范围过大：紧接着仍调
        // saveDraftNow，正文与已上传图等按原逻辑照常落盘，只有 key 为空的
        // 上传中图被落盘过滤排除；故新文案只说上传中的图片没存进草稿。
        if hasUploadingImage() {
            showToastAfterClose(message: "还有图片没上传完，上传中的图片没存进草稿")
        }
        // 关闭即提交缓冲删除（草稿随即按删除后状态落盘，见 saveDraftNow）。
        commitPendingRemoval()
        saveDraftNow {
            self.onCancelled?()
        }
    }

    @objc private func didTapPublish() {
        if isPublishing {
            return
        }
        if !SessionManager.shared.isLoggedIn {
            // G26：登录态未知（网络失败）时不弹登录页，改给网络不稳定提示。
            if SessionManager.shared.authUnknown {
                showToast(message: "网络不稳定，请稍后再试")
                return
            }
            onRequireLogin?()
            return
        }
        let trimmed = trimmedContent()
        if trimmed.isEmpty {
            // U13：空正文点按给轻提示（按钮视觉置灰但仍可点，见 updatePublishState）。
            showToast(message: "先写点什么")
            updatePublishState()
            return
        }
        // D-G5：网页发布先 trim 再量长（editorText.value.trim() 后 c.length>2000）；
        // 此处原用未 trim 长度，首尾空白会误判超长。改用已 trim 的 trimmed 计长。
        if trimmed.count > BearyComposerViewController.maxLength {
            showToast(message: "最多 2000 字，现在 \(trimmed.count) 字")
            return
        }
        // 决议第 5 项 A：有上传失败的图片时拦截不发（网页 beary.html 编辑器发布口径，
        // 文案逐字取自网页拦截 toast），出 toast 并停留在编辑器，不发请求。
        if hasFailedImage() {
            showToast(message: "有图片上传失败，点失败的图重试或移除后再发布")
            return
        }
        // 决议第 3 项 B：去掉发布/保存确认弹框，点发布/保存直接发（网页口径：
        // 网页 editorPublish 直接走校验与请求，无确认弹框）。
        if isEditMode {
            performUpdate(trimmed: trimmed)
            return
        }
        performPublish(trimmed: trimmed)
    }

    private func hasFailedImage() -> Bool {
        for item in imageItems {
            if item.failed {
                return true
            }
        }
        return false
    }

    private func performPublish(trimmed: String) {
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        guard let req = draftClientReq else { return }
        // 先把本次 clientReq 落盘：服务端已落库但回包丢了，重试用同一 clientReq，
        // 服务端直接返回已落库的那篇，不重复发。
        saveDraftNow()
        isPublishing = true
        updatePublishState()
        // 已删引用不传 quoteId：只剩 id 的引用服务端会拒，发布应按无引用走，
        // 展示态仍保留到发布成功清本篇草稿为止。
        let publishQuoteId = (selectedQuote?.isDeleted == true) ? nil : selectedQuote?.entryId
        // R1 复核：新建仍传 trimmedTitle()（空时为 nil，API 省略不传），新建
        // 不填标题的行为不变；显式空串清标题只发生在编辑 PUT（performUpdate）。
        // iCity：可见性值即 visibility（published 0/1）；@ 以 mentioned_user_id 发出，无按篇通知开关。
        // 限时：开关开时可见性必为公开，ephemeral=1 随新建发出（服务端写 24 小时到期）。
        let publishVisibility = selectedVisibilityPublished ? 1 : 0
        BearyAPI.shared.publishEntry(content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: publishQuoteId, published: publishVisibility, mentionedUserId: selectedRecipient?.id, title: trimmedTitle(), ephemeral: ephemeralSwitch.isOn ? 1 : nil, clientReq: req) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success(let resp):
                    if let entryId = resp.id {
                        // 只有拿到 entry id 才清草稿与本地图片。
                        self.clearDraftAndFiles()
                        self.commitPendingRemoval()
                        // iCity：成功 toast 按目标态动态（创建响应不带可见性字段，
                        // 以本次发送的可见性值为准）；toast 挂在 presenting 方视图上
                        //（showToastAfterClose），容器随后 dismiss 本页 + 切时间线时
                        // toast 不随编辑器消失。
                        // 落点高亮见交回说明：时间线无现成按 id 高亮入口，接线在
                        // SceneDelegate.onPublished（D 路禁改），本处不硬编。
                        // 100 包编辑器面修法：toast 必须用本次发送的可见性值
                        // publishVisibility，而非回包时的 live 旗标——可见性在
                        // 发布在途时此前未冻结（见 refreshPublishingInputFreeze），
                        // 在途改动会使 toast 与实际发出态相反；现可见性已随冻结
                        // 禁用，此处仍以发送值为准，双保险。
                        self.showToastAfterClose(message: publishVisibility == 1 ? "已发布 · 已公开" : "已发布 · 已设为私密")
                        BearyHaptics.publishSuccess()
                        BearySoundPlayer.play(.publishSuccess)
                        // B 修法：发布成功退场前先收起弹出框（无动画）。
                        self.hideCallout(animated: false)
                        self.onPublished?(entryId)
                    } else {
                        self.saveDraftNow()
                        self.showAlert(message: "发布失败，请重试")
                    }
                case .failure(let error):
                    // 失败一律保留草稿；离线/网络错误给明确文案。
                    self.saveDraftNow()
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，已保存为草稿，联网后可重试")
                    } else {
                        self.showAlert(message: self.message(forPublishError: error))
                    }
                }
            }
        }
    }

    private func message(forPublishError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "create_gap":
                return "发得有点快，歇一下再写"
            case "create_day_limit":
                return "今天写够了，明天再继续吧"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "recipient_invalid", "mentioned_user_invalid":
                return "提到的人无效，请重新选择"
            default:
                return "发布失败，请重试"
            }
        }
        return "发布失败，请重试"
    }

    // MARK: - 编辑保存（PUT；15 分钟规则只由服务端判定，App 只展示与转文案）

    private func performUpdate(trimmed: String) {
        guard let entryId = editingEntry?.id, !entryId.isEmpty else {
            showAlert(message: "找不到要编辑的日记")
            return
        }
        isPublishing = true
        updatePublishState()
        // R1：编辑时标题清空必须显式传空串，不能省略不传（省略=服务端
        // 保留旧标题）。trimmedTitle() 空时为 nil，此处转 ""；有标题时原样传。
        // 新建走 performPublish，仍传 trimmedTitle()（空时 nil 省略），行为不变。
        // iCity：编辑 @ 三态——已改选发新 id；已清除发 clearMentioned；未动则两者皆空、服务端保留原值。
        let updateMentionedId: Int? = selectedRecipient?.id
        let updateClearMentioned: Bool = (selectedRecipient == nil && editMentionCleared)
        BearyAPI.shared.updateEntry(id: entryId, content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: lockedQuote?.entryId, title: trimmedTitle() ?? "", mentionedUserId: updateMentionedId, clearMentioned: updateClearMentioned) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success:
                    self.deleteEditLocalFiles()
                    self.commitPendingRemoval()
                    // D2：把编辑器终态写回原 Entry 副本传给容器（引用已清时 quoteId/quote
                    /// 均为 nil，容器据此清行内引用卡；已删引用不按正常 quote 回传）。
                    if var updated = self.editingEntry {
                        updated.content = trimmed
                        // R1：编辑 PUT 已显式传空串清标题，故本地副本直接跟随终态：
                        // 有标题写标题，清空写 nil（与服务端清为 NULL 一致），否则
                        // 保存后列表仍显示旧标题，与服务端不一致。
                        updated.title = self.trimmedTitle()
                        updated.images = self.uploadedImageKeys()
                        updated.mood = self.selectedMood
                        updated.weather = self.selectedWeather
                        updated.quoteId = self.lockedQuote?.entryId
                        // iCity：编辑回传的 @ 终态同步进本地副本（改选→新 id/名，清除→nil，未动→保留原值）。
                        if let picked = self.selectedRecipient {
                            updated.mentionedUserId = picked.id
                            if let display = picked.displayName {
                                updated.mentionedName = display
                            } else if let handle = picked.handle {
                                updated.mentionedName = handle
                            }
                        } else if self.editMentionCleared {
                            updated.mentionedUserId = nil
                            updated.mentionedName = nil
                        }
                        if let locked = self.lockedQuote, locked.isDeleted == false {
                            updated.quote = Quote(
                                id: locked.entryId,
                                content: locked.content,
                                images: locked.images,
                                imgDims: locked.imgDims,
                                createdAt: locked.createdAt,
                                isPublic: locked.isPublic,
                                gone: nil,
                                locked: nil,
                                authorName: locked.authorName,
                                authorAvatar: locked.authorAvatar,
                                authorBadge: nil,
                                authorPlus: nil,
                                authorId: nil,
                                isMine: nil
                            )
                        } else {
                            updated.quote = nil
                        }
                        // B 修法：编辑保存成功退场前先收起弹出框（无动画；编辑器不关闭时本分支不跑，不误收）。
                        self.hideCallout(animated: false)
                        self.onUpdated?(updated)
                    }
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .server(let code) = error, code == "edit window expired" {
                        // C5：编辑期过期只 toast“超过 15 分钟，已无法编辑”，编辑器保持打开、
                        // 不删本地文件、不关编辑器（网页 PUT 失败同款收尾）。
                        // iCity：编辑锁只看 15 分钟、与可见性无关——旧“已公开”分支已删，
                        // 万一服务端仍回该码，走通用失败文案，不擅自关编辑器。
                        self.showToast(message: "超过 15 分钟，已无法编辑")
                    } else if case .network = error {
                        self.showAlert(message: "网络不可用，修改未保存，请联网后重试")
                    } else {
                        self.showAlert(message: self.message(forUpdateError: error))
                    }
                }
            }
        }
    }

    private func message(forUpdateError error: APIError) -> String {
        if case .server(let code) = error {
            switch code {
            case "content too long":
                return "正文最多 2000 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "invalid image ownership":
                return "图片归属异常，请重新添加"
            default:
                return "保存失败，请重试"
            }
        }
        return "保存失败，请重试"
    }

    // MARK: - 键盘

    /// 2026-10-29 第 28 项：焦点切换时（键盘已在上、无键盘通知）立即做最小滚动修正；
    /// 键盘刚弹出时的修正走 applyKeyboard 动画完成回调（inset 落定后再算，不与
    /// 系统自动 caret 滚动打架；已在位时修正为 no-op）。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if currentKeyboardHeight > 0 {
            scrollFocusedFieldIntoView(animated: true)
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if currentKeyboardHeight > 0 {
            scrollFocusedFieldIntoView(animated: true)
        }
    }

    /// 可见性滚动留白：目标离可视区顶的距离（2026-10-30 滚动留白口径，
    /// 贴边改留白；已完整可见时仍不动）。
    private static let focusVisibleTopMargin: CGFloat = 16

    /// 2026-10-29 第 28 项：只滚到刚好让焦点框完整可见的最小滚动——焦点框在可视区
    /// 上方时上滚到其顶离可视区顶留 16pt（绝不顶出顶部），在可视区下方时下滚到其底恰贴
    /// 键盘顶；已完整可见时不动。标题栏用整框（单行短框），正文用 caret 矩形
    /// （整框可能高于可视区，整框口径会乱滚）。可视区按当前 contentInset 算
    /// （键盘高已计入 bottom inset），目标偏移 clamp 到内容合法范围。
    private func scrollFocusedFieldIntoView(animated: Bool) {
        let targetRect: CGRect?
        if titleField.isFirstResponder {
            targetRect = contentView.convert(titleField.bounds, from: titleField)
        } else if textView.isFirstResponder {
            if let selectedRange = textView.selectedTextRange {
                let caret = textView.caretRect(for: selectedRange.end)
                targetRect = contentView.convert(caret, from: textView)
            } else {
                targetRect = contentView.convert(textView.bounds, from: textView)
            }
        } else {
            targetRect = nil
        }
        guard let fieldFrame = targetRect else { return }
        let topInset = scrollView.contentInset.top
        let bottomInset = scrollView.contentInset.bottom
        let visibleTop = scrollView.contentOffset.y + topInset
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - bottomInset
        var targetY = scrollView.contentOffset.y
        if fieldFrame.minY < visibleTop {
            targetY = fieldFrame.minY - topInset - Self.focusVisibleTopMargin
        } else if fieldFrame.maxY > visibleBottom {
            targetY = fieldFrame.maxY - (scrollView.bounds.height - bottomInset)
        } else {
            return
        }
        let minY = -topInset
        let maxY = max(minY, scrollView.contentSize.height + bottomInset - scrollView.bounds.height)
        targetY = min(max(targetY, minY), maxY)
        if targetY != scrollView.contentOffset.y {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: animated)
        }
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        NSLog("[Diag] composer-keyboard-willShow")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("keyboard-willShow")
        applyKeyboard(notification, showing: true)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        applyKeyboard(notification, showing: false)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        // 旋转、表情/听写键盘高度变化、悬浮键盘拖动只发 WillChangeFrame，不发 WillShow：
        // 同一套 inset 计算跟随最终帧；出现时与 WillShow 同值、beginFromCurrentState 保证幂等，不叠加；
        // 键盘收起时最终帧在屏外，算出的高度为 0，与 WillHide 一致。
        applyKeyboard(notification, showing: true)
    }

    /// 52 批收键盘：点编辑器空白处收键盘（手势挂在 scrollView 上；正文区点按由下方代理排除，不干扰聚焦）。
    @objc private func dismissKeyboardTap() {
        view.endEditing(true)
    }

    /// 手势代理：落在正文 textView（含占位 label 子视图）与标题 titleField 内的点按
    /// 不触发收键盘，交给输入框正常聚焦/选区；其余空白与控件点按照常收键盘
    /// （cancelsTouchesInView=false，控件自身点按不受影响）。
    /// 标题必须排除（编辑器批第 4 项）：titleField 在 contentStack 内、属 scrollView 子树，
    /// 不排除时点标题先聚焦（touch down）又被本手势立即 endEditing（touch up），
    /// 键盘/工具栏/inset 上下弹跳一次，用户感知为“点标题页面自动往上跑”。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let touchedView = touch.view, touchedView.isDescendant(of: textView) || touchedView === textView {
            return false
        }
        if let touchedView = touch.view, touchedView.isDescendant(of: titleField) || touchedView === titleField {
            return false
        }
        return true
    }

    private func applyKeyboard(_ notification: Notification, showing: Bool) {
        var height: CGFloat = 0
        if showing {
            if let userInfo = notification.userInfo {
                if let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
                    let frame = view.convert(frameValue.cgRectValue, from: nil)
                    height = max(0, view.bounds.maxY - frame.minY)
                }
            }
        }
        var duration: TimeInterval = 0.25
        var curveRaw: UInt = 0
        if let userInfo = notification.userInfo {
            if let d = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                duration = d
            }
            if let c = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
                curveRaw = c.uintValue
            }
        }
        // 编辑器批第 5 项：键盘高度存属性供 updateTextViewHeight 封顶扣减。
        currentKeyboardHeight = height
        // 2026-10-29 第 28 项：弹出跃迁（此前不可见 → 现在有高度）时保存原位；
        // 帧变化不重复保存；收起时在完成回调里恢复原位（clamp 到收起后的合法范围）。
        let wasVisible = keyboardVisible
        let isHiding = !showing || height == 0
        if showing && height > 0 && !wasVisible {
            keyboardSavedContentOffset = scrollView.contentOffset
            keyboardVisible = true
        } else if isHiding && wasVisible {
            keyboardVisible = false
        }
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: { [weak self] in
            guard let self = self else { return }
            self.scrollView.contentInset.bottom = height
            self.scrollView.scrollIndicatorInsets.bottom = height
            // 封顶重算走同一键盘曲线；layoutIfNeeded 使高度约束变化随键盘动画走，
            // 而非下一布局帧跳变。外层 inset 保留不动（供其他内容外层滚动）。
            // 6-3 例外：本 layoutIfNeeded 在键盘动画内、duration/curve 均取键盘通知，
            // 属系统曲线同步，保留不重写（不要当作通用约束动画口径扩散）。
            self.updateTextViewHeight()
            self.view.layoutIfNeeded()
            // 64 包反馈修（第 13 项）：不再给 textView 内层加键盘底 inset——旧代码内外两层
            // 同加 keyboardHeight，空态下内层可视高 =  bounds 高 − 键盘高成负值，caret
            // 可见性计算退化、contentOffset 自己往上跳（占位 label 随之下滑），即 Li 报的
            // “什么都没写也会往上滑一下”。外层 inset 已把整区抬到键盘上方，内层 inset
            // 是冗余的；去掉后空态 caret 本就在可视区内，打开与空态 contentOffset 全程不动，
            // 长文 caret 仍走系统标准 caret 可见滚动（只在用户打到可视区外时动）。
        }, completion: { [weak self] _ in
            guard let self = self else { return }
            // 2026-10-29 第 28 项：inset 落定后再修正焦点框——系统自动 caret 滚动若把
            // 标题顶出顶部，此处按最小滚动口径拉回（已在位时 no-op）；收起时恢复原位。
            if isHiding {
                if let saved = self.keyboardSavedContentOffset {
                    self.keyboardSavedContentOffset = nil
                    let minY = -self.scrollView.contentInset.top
                    let maxY = max(minY, self.scrollView.contentSize.height + self.scrollView.contentInset.bottom - self.scrollView.bounds.height)
                    let restoredY = min(max(saved.y, minY), maxY)
                    self.scrollView.setContentOffset(CGPoint(x: self.scrollView.contentOffset.x, y: restoredY), animated: false)
                }
            } else {
                self.scrollFocusedFieldIntoView(animated: false)
            }
        })
    }

    // MARK: - 通用

    /// 轻提示：委托统一 BearyToast。编辑器是全屏模态，不在 Chrome
    /// 子页内，落点由组件回落安全区 -32。
    /// 调用签名与文案、触发时机不变。
    private func showToast(message: String) {
        BearyToast.show(in: view, message: message)
    }

    /// 关编辑器后仍可见的 toast：挂在 presenting 方视图上（网页 toast 在页面层、
    /// 不随编辑器关闭而消失的等价处理），调用方随后走 onCancelled 关闭本页。
    /// 若无 presenting 方（如已被 dismiss），退回本页 toast。落点由组件按
    /// 呈现方实际 chrome 算：呈现方是 Chrome 容器时落 FAB／底栏之上，
    /// 其他呈现方（详情等）落 -32。
    private func showToastAfterClose(message: String) {
        if let parent = presentingViewController {
            BearyToast.show(in: parent.view, message: message)
        } else {
            showToast(message: message)
        }
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: nil))
        present(alert, animated: BearyMotion.animated(true))
    }
}

// MARK: - 图片条单项（class，便于上传回调按身份认领，不受数组顺序变化影响）

private final class ComposerImageItem {
    var key: String?
    var uploading: Bool
    var localFile: String?
    var failed: Bool
    let container: UIView
    let imageView: UIImageView
    let spinner: BearyRefreshIconView
    let failView: UIView
    let removeButton: UIButton

    init(key: String?, uploading: Bool, localFile: String?, failed: Bool, container: UIView, imageView: UIImageView, spinner: BearyRefreshIconView, failView: UIView, removeButton: UIButton) {
        self.key = key
        self.uploading = uploading
        self.localFile = localFile
        self.failed = failed
        self.container = container
        self.imageView = imageView
        self.spinner = spinner
        self.failView = failView
        self.removeButton = removeButton
    }
}

// 注：
// 1. 天气（weather）：图标 + 名 chip，首项“无”，选中墨色边框（无底，与网页 wx-chip.on 同款），
//    再点已选项不取消；publish 传 weather；不选不传（服务端 validWeather 对缺失值置 null，
//    与网页同口径）。publishEntry 同步补齐 quote_id/published/mentioned_user_id
//    （默认参数，旧调用点不受影响）。天气图标见 icon_wx_<key>（与网页 WX_ICON 同款）。
// 2. @：新建模式只选一人（搜索接口 users 组），@ 图标 + “@ 谁”钮 / chip；
//    @ 提醒无按篇开关；编辑模式可改选可清除（PUT 带 mentioned_user_id，清除发 clearMentioned）。
//    引用：qp-mode 面板三 tab（我的日记 timeline / 赞过的 liked / 收藏的 saved），行是完整
//    lite 卡（头像 40 + 名 + 日期 + 全文 + 118 图片条；Plus 皇冠已取消显示）；服务端
//    validQuoteId 只接受本人日记，非本人 picks 仍会被服务端静默丢弃（与网页行为一致）；
//    编辑模式引用可改可删（PUT 带新 quote_id，删为空时服务端按 null 写）；内容为空的引用
//    视为已删，不回填、保存时即丢弃（与网页编辑同款）。
// 3. 编辑模式：init(entry:) 进入；正文/心情/天气/图片/引用/@ 可改；不读不写 beary_draft_v3（
//    scheduleDraftSave/saveDraftNow 在编辑模式直接 return）；取消时不删原日记，直接关（决议第 4 项 B）；
//    保存走 PUT，15 分钟规则只由服务端判定（edit window expired 只 toast 且编辑器保持打开，
//    与可见性无关；旧 already public 分支已删）；
//    成功后删本轮新选图的本地文件（原日记的图 localFile 为 nil，不受影响），失败不删、留着重试。
// 4. 草稿 v3 多槽：正文/心情/图片/天气/@/引用全部进草稿，杀 App 后原样恢复；
//    发布成功与丢弃只清本篇（currentDraftId），不碰其他篇。
// 5. 发布/保存无确认弹框（决议第 3 项 B）：点发布/保存直接发；有失败图时 toast 拦截不发（决议第 5 项 A）。
// 6. 超 2000 字红字提示用 BearyColors.red（网页 --red #e5484d，浅深同值），字数圆环同步变红；
//    图片 × 衬底用 BearyColors.scrim（固定深色半透明，深色下 ink 是近白、白字会看不清）；
//    上传失败图为行内红底块（红 10% 底 + “失败，点我重试”），发布时有失败图 toast 拦截不发。
//    其余白字只出现在恒定橙底上（心情 chip 回退名）与墨底上（发布 pill），浅深皆可读。
// 8. C1：段落顺序改为正文 → 已选 Chip 行 → 图片 → 状态行 → 引用 → 规则框；
//    工具栏贴键盘上方，心情/天气/@ 为工具栏上方单行选择条（旧附加选项栏已删）；
//    草稿 pill 计数按 v3 多槽篇数，0 篇时只留“草稿”二字、计数段隐藏；
//    引用面板为网页 qp-mode 整编形态（打开只留面板、发布钮隐藏、取消变“返回”只退面板、
//    进出保存/恢复滚动位置、每 tab 缓存 + 序号守卫、选篇立即落盘）；
//    编辑倒计时到 0 显示“编辑已结束”并走 onCancelled 关闭编辑器（网页 closeEditor + loadFeed 同款，
//    列表刷新需容器侧接线，本文件不碰 SceneDelegate）。
//    草稿箱弹层 BearyDraftBoxViewController 与熊图 BearyEmoteImages 均由其他代理新建文件提供，
//    本文件只调用、不定义；两者未落地前本文件单独编译会缺符号，待齐套后由 CI 验证。
// 3. 图片 × 只移除本地与 key 列表，不调服务端；未发布的孤 key 残留是已知可接受项；
//    C11：× 改为删后 10 秒撤销（单槽缓冲，到期/顶替/发布/取消/切草稿时提交删除）。
// 4. 草稿 v3（BearyDraftFiles.swift）：v2 字段 + 天气 + 写给 + 引用快照，每篇独立 draftId，
//    多篇存一个 v3 数组文件（updatedAt 倒序），JSON 文件原子写；
//    旧 v2 单槽首次读取迁入 v3（有内容才迁），成功后删旧 v2 文件；
//    v1 草稿首次读取迁移为无本地文件的 key 项，走远程图显示。
// 5. 丢弃草稿 / 发布成功会删本地图片文件；服务端孤 key 无删除接口，残留是已知可接受项。
// 6. 发布时有上传失败的图片 toast 拦截不发（防静默丢图）；离线/网络错误文案为“网络不可用，
//    已保存为草稿，联网后可重试”，失败一律保留草稿。
// 7. 第四项：键盘跟随 WillChangeFrame（旋转/表情键盘/悬浮键盘拖动）；打开编辑器自动聚焦一次，
//    有草稿时光标置末尾；选图按选择顺序占位插入（.ordered + 先建项后填图），读图失败直接移除占位项。

// MARK: - 虚线“写给某个人”钮（网页 addr-pick：1.5px dashed line、pill 圆角；
// 实现同款详情页 BearyDashedAddButton：CAShapeLayer 虚线，布局时按当前 bounds 重画路径）

private final class BearyComposerDashedPickButton: UIButton {

    private let dashedLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1.5
        dashedLayer.lineDashPattern = [4, 3]
        updateStrokeColor()
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStrokeColor() {
        dashedLayer.strokeColor = BearyColors.line.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColor()
    }
}

// MARK: - 限时行开关（v6-7：圆钮内嵌限时图标）

/// v6 限时开关：系统 UISwitch 无法在圆钮内嵌图标、也定不了黑轨道，
/// 故自绘 51×31 控件，对外只暴露 UISwitch 旧调用点用到的口径：
/// isOn（读写，不发事件）、isEnabled、valueChanged（点按切换后发送）。
/// 圆钮 27pt、内嵌限时行现有的官方 icon_limited 图标 18pt（熊头＋下半虚线弧，
/// 不自绘）；浅色黑轨道白圆钮黑图标，深色反转（轨道 ink、白圆钮取 bg、
/// 图标 ink——ink/bg 均为动态色，深浅切换自动跟随）。
/// 圆钮位置只由 isOn 与布局决定：点按先改 isOn 再沿当前转场播 layout，
/// 减动效时瞬时落位；编程式改 isOn 只改无障碍值、不播动画。
private final class BearyLimitedSwitch: UIControl {

    private static let trackWidth: CGFloat = 51
    private static let trackHeight: CGFloat = 31
    private static let thumbDiameter: CGFloat = 27
    private static let thumbInset: CGFloat = 2
    private static let iconSize: CGFloat = 18

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            accessibilityValue = isOn ? "开" : "关"
            refreshTrackColor()
            setNeedsLayout()
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.5 }
    }

    /// track 底色：ON = ink（现行不变），OFF = gray（动态色，深浅模式均与 ink 有区分度）。
    private func refreshTrackColor() {
        trackView.backgroundColor = isOn ? BearyColors.ink : BearyColors.gray
    }

    private let trackView = UIView()
    private let thumbView = UIView()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        refreshTrackColor()
        trackView.layer.cornerRadius = Self.trackHeight / 2
        trackView.isUserInteractionEnabled = false
        thumbView.backgroundColor = BearyColors.bg
        thumbView.layer.cornerRadius = Self.thumbDiameter / 2
        thumbView.layer.shadowColor = UIColor.black.cgColor
        thumbView.layer.shadowOpacity = 0.25
        thumbView.layer.shadowRadius = 2
        thumbView.layer.shadowOffset = CGSize(width: 0, height: 1)
        thumbView.isUserInteractionEnabled = false
        iconView.image = BearyIconImages.image(named: "icon_limited", pointSize: Self.iconSize)
        iconView.tintColor = BearyColors.ink
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false
        thumbView.addSubview(iconView)
        addSubview(trackView)
        addSubview(thumbView)
        addTarget(self, action: #selector(didTap), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = "限时日记"
        accessibilityTraits = [.button]
        accessibilityValue = "关"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.trackWidth, height: Self.trackHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = bounds
        let thumbX = isOn
            ? bounds.width - Self.thumbInset - Self.thumbDiameter
            : Self.thumbInset
        thumbView.frame = CGRect(x: thumbX, y: Self.thumbInset, width: Self.thumbDiameter, height: Self.thumbDiameter)
        iconView.frame = CGRect(
            x: (Self.thumbDiameter - Self.iconSize) / 2,
            y: (Self.thumbDiameter - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
    }

    @objc private func didTap() {
        guard isEnabled else { return }
        isOn.toggle()
        sendActions(for: .valueChanged)
        if UIAccessibility.isReduceMotionEnabled {
            layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.25, animations: { self.layoutIfNeeded() })
        }
    }
}

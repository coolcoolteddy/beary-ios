import UIKit
import Photos
import PhotosUI

// ===== beary 原生编辑器（第二阶段 + 主线闭环第一块 + 网页对齐批）=====
// 只负责写日记：正文 + 心情 + 天气 + @ + 引用 + 图片（上限 9 张）。
// 编辑模式复用同一界面：正文/心情/天气/图片/引用/@ 可改，
// 不走新日记草稿流（不读不写 beary_draft_v3、不复用新篇 client_req）。
// iCity：新建默认私密（顶栏可见性钮点开菜单直选：私密/仅好友/公开/限时，编辑模式隐藏）；
// 限时行已删（2026-10-31）：限时态即公开语义，ephemeral=1 发出后服务端 24 小时后转私密，无日期行。
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
/// 固定偏上修（本支）：110 门限（super 高 > 行高 × 1.3 才下移）分不清两种
/// super 短矩形——片段顶锚定的短矩形与字形锚定的短矩形高度相近，前者原样
/// 返回即每行固定偏上 ascender × (倍数 − 1)（16pt 字约 11pt，不随行数增长；
/// 真机纠正：此前“逐行变大”的说法不成立）。本支不再用 super 的 y：从光标
/// 所在行同行字符的选区矩形取行片段顶，再按基线公式锚定（顶 = 片段顶 +
/// ascender × (倍数 − 1)，高 = ascender − descender），两种 super 行为下
/// 结果一致；取不到片段时回退 110 门限旧口径。x 与宽仍取 super；
/// isScrollEnabled、倍数、inset、占位与天气 chip 一律不动。
private final class BearyBodyTextView: UITextView {
    /// 正文编辑器恒定的行高倍数，由 Composer 在 buildTextArea 里与 typingAttributes
    /// 用同一个 bodyParagraph 一并设定；本类只用于正文编辑器，倍数恒定。
    var fixedLineHeightMultiple: CGFloat?
    /// 光标行实际渲染字体：优先取光标处 attributedText 的字体属性（粘贴/
    /// 回填后该处字体可能与 typingAttributes 不一致时，以渲染字体为准），
    /// 取不到时回退 typingAttributes，再回退 textView.font。
    private func caretFont(at position: UITextPosition) -> UIFont? {
        let text = attributedText ?? NSAttributedString()
        if text.length > 0 {
            let offset = self.offset(from: beginningOfDocument, to: position)
            let index = min(max(offset - 1, 0), text.length - 1)
            if let lineFont = text.attribute(.font, at: index, effectiveRange: nil) as? UIFont {
                return lineFont
            }
        }
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
        guard rect.height > 0, let caretFont = caretFont(at: position), caretFont.lineHeight > 0 else { return rect }
        let multiple = fixedLineHeightMultiple ?? lineHeightMultiple(at: position)
        if let multiple = multiple, multiple > 1.0 {
            let height = caretFont.ascender - caretFont.descender
            guard height > 0 else { return rect }
            // 固定偏上修：不再以 super 矩形高度猜锚点。110 门限（高 > 行高 × 1.3
            // 才下移）有个盲区：TextKit 2 下 super 有时返回片段顶锚定的短矩形
            // （高约行高、但 origin.y 仍是片段顶），门限误判为“已字形锚定”
            // 而原样返回，光标每行固定高出字形 ascender × (倍数 − 1)（16pt 字
            // 约 11pt，不随行数增长）；与 110 那次“已字形锚定再下移即
            // double-count”的情形恰好相反——单凭高度分不清这两种 super 矩形，
            // 门限本身不可靠。改为从光标所在行的真实排版矩形直接推导
            // （见 lineFragmentTop）：顶 = 片段顶 + ascender × (倍数 − 1)，
            // 高 = ascender − descender；super 的 y 从此不再参与，两种 super
            // 行为下结果一致；x 与宽仍取 super。
            if let fragmentTop = lineFragmentTop(for: position, caretX: rect.origin.x) {
                rect.origin.y = fragmentTop + caretFont.ascender * (multiple - 1)
                rect.size.height = height
                return rect
            }
            // 取不到行片段时回退 110 门限旧口径（空文档、TextKit 1 等）。
            if rect.height > caretFont.lineHeight * 1.3 {
                rect.origin.y = rect.origin.y + caretFont.ascender * (multiple - 1)
                rect.size.height = height
                return rect
            }
            return rect
        }
        let centerY = rect.midY
        rect.origin.y = centerY - caretFont.lineHeight / 2
        rect.size.height = caretFont.lineHeight
        return rect
    }

    /// 光标所在行片段顶（textView 坐标系，与 caretRect 同空间）。
    /// 取同行文字字符的选区矩形 origin.y：选区高亮按行片段满高绘制，
    /// 故该 y 即行片段顶，与 super 的 y 取值无关——super 在 TextKit 2 下
    /// 的锚点差异不再影响结果，每行各取各行的片段顶。
    /// 换行边界（前字符与后字符属不同行）时以 super 的 x 判定归属：
    /// x 贴左缘（行首）归后一行，否则归前一行；附件字符、换行符不作
    /// 行内探针；文档末尾换行后，下一行片段顶 = 换行符所在行片段底。
    /// 探不到时返回 nil，调用方回退 110 门限旧口径。
    private func lineFragmentTop(for position: UITextPosition, caretX: CGFloat) -> CGFloat? {
        let text = attributedText ?? NSAttributedString()
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard offset >= 0 else { return nil }
        let nsText = text.string as NSString
        // 单字符选区矩形；附件字符不作探针（其矩形是图高、不是行片段）。
        func selectionRect(ofCharAt index: Int) -> CGRect? {
            guard index >= 0, index < text.length else { return nil }
            if nsText.character(at: index) == 0xFFFC { return nil }
            if text.attribute(.attachment, at: index, effectiveRange: nil) != nil { return nil }
            guard let start = self.position(from: beginningOfDocument, offset: index),
                  let end = self.position(from: beginningOfDocument, offset: index + 1),
                  let range = self.textRange(from: start, to: end),
                  let first = selectionRects(for: range).first,
                  first.rect.height > 0 else { return nil }
            return first.rect
        }
        let prevIsNewline = offset > 0 && offset - 1 < text.length && nsText.character(at: offset - 1) == 0x000A
        let prevRect = offset > 0 ? selectionRect(ofCharAt: offset - 1) : nil
        let nextRect = offset < text.length ? selectionRect(ofCharAt: offset) : nil
        // 换行符属前一行，不作行内探针。
        let prevTop = prevIsNewline ? nil : prevRect?.origin.y
        let nextTop = nextRect?.origin.y
        if let prevTop = prevTop, let nextTop = nextTop {
            if abs(prevTop - nextTop) < 0.5 { return prevTop }
            return caretX <= textContainerInset.left + 2 ? nextTop : prevTop
        }
        if let prevTop = prevTop { return prevTop }
        if let nextTop = nextTop { return nextTop }
        if prevIsNewline, let prevRect = prevRect { return prevRect.origin.y + prevRect.height }
        return nil
    }
}

/// U3：编辑器工具栏六钮专用热区钮（图片／定位／心情／天气／@／引用）。
/// 根因：六钮视觉帧 24pt，父类 BearyHit44Button 对称各扩 10pt 至 44pt；
/// 工具行间距 16 时中心距 24+16=40 < 44，相邻热区重叠 4pt，窄屏间距压到 8 时
/// 中心距 32、重叠 12pt，交界处点按落到后加的右钮。
/// 修法：横向扩量改由工具行间距实时给定（maxSideExpansion = 间距 / 2），
/// 相邻热区宽 = 24 + 间距 = 中心距，恰好相接、不互叠；纵向仍扩满 44
/// （工具行高 ≥44，纵向无相邻钮可叠）。视觉帧、图标、顺序、目标动作一律不动；
/// 仅六个工具钮用本类，顶栏／重试等其余 Hit44 钮不受影响。
/// 按压反馈仍走原 bearyAddPressFeedback（只走 transform／opacity），
/// 本类不新增交互面，不涉及 tap 高亮与焦点描边。
private final class BearyComposerToolButton: BearyHit44Button {
    /// 横向单侧最大扩量，由 setToolbarToolRowSpacing 随工具行间距同步；
    /// 默认 8 = 默认间距 16 的一半。
    var maxSideExpansion: CGFloat = 8
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx: CGFloat = bounds.width < 44 ? min((44 - bounds.width) / 2, maxSideExpansion) : 0
        let dy: CGFloat = bounds.height < 44 ? (44 - bounds.height) / 2 : 0
        if dx == 0 && dy == 0 { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

final class BearyComposerViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate {

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

    /// 心情顺序 = 熊脸 32 只（后 8 只非熊脸已删，不进选择器、不进记号集）。
    /// 注意：此处必须保持字面数组写法，不能改成 BearyText.bearMoodKeys 引用——
    /// CI 的 scripts/check-beary-assets.py 用正则直接抠本文件 moodOrder 的
    /// 字面数组校验 emote 资产，改引用会使该检查报 key source not found 而全红
    /// （#421 合入后 CI 红的根因）。集合与 bearMoodKeys 逐项一致，改一处要同步另一处。
    private let moodOrder: [String] = [
        "agree", "happy", "applause", "cheer", "comfort", "confused", "love", "determined",
        "facepalm", "shy", "goodnight", "hug", "wink", "idea", "kiss", "thinking",
        "listening", "lonely", "speechless", "nope", "surprised", "pat", "peek", "sleepy",
        "proud", "shrug", "sorry", "cry", "angry", "thanks", "zap", "wave",
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
        /// 引用规则简化门禁：来源作者判定用（is_mine 优先，其次 author_id 比对；
        /// 草稿还原时两者皆无则按他人处理，绝不挂一并公开项）。
        let authorId: Int?
        let isMine: Bool?
        /// 引用规则简化来源行：来源作者 handle（面板选篇取 Entry.authorHandle、
        /// 编辑锁定取 Quote.authorHandle；草稿还原时无则 nil，来源行不编造）。
        let authorHandle: String?
        let images: [String]
        /// 补缺 P3-41：此处存“上次已知有效可见性”（过期即私密），非服务端 is_public 原值；
        /// 新选与恢复校验以 BearyEphemeral.isEffectivelyPublic 写入；编辑态锁定同样
        /// 走有效态（审计 2026-11-02 第十节：Quote 已补 ephemeral_until 字段）。
        let isPublic: Bool?
        /// 审计 2026-11-02 第十节：来源可见性三档与限时到期戳（草稿往返保留，
        /// 还原时据此重算有效态，不再只凭原始 isPublic）。
        let visibility: String?
        let ephemeralUntil: Int?
        /// iCity：旧送达时间字段已废（面板选篇行不再挂 pill）；保留字段仅作解码兼容。
        let publishAt: Int?
        let imgDims: [String: [Int]]?
        /// 已删态：原日记已删时只剩 id，恢复时不按正常 lite 卡显示，见 refreshQuoteSection。
        /// 发布时已删引用不传 quoteId（服务端会拒），只作展示态保留到用户清除或发布。
        let isDeleted: Bool
        /// B6 暂时看不到态：回包占位/明确无权限时只剩 id，不按正常 lite 卡显示，
        /// 见 refreshQuoteSection；下次恢复重新校验，可恢复（不落盘标记）。
        let isUnavailable: Bool

        /// 修红（#632 合入后 CI 红）：合成逐成员 init 只含 13 个无默认值字段，
        /// 不含带默认值的 visibility/ephemeralUntil/isUnavailable，故 #632 新增的
        /// 5 处 15 参构造编译不过；此处显式 init 把三字段放末尾并给默认值，新旧
        /// 6 处构造全兼容。
        init(entryId: String, content: String, createdAt: Int?, authorName: String?, authorAvatar: String?, authorId: Int?, isMine: Bool?, authorHandle: String?, images: [String], isPublic: Bool?, publishAt: Int?, imgDims: [String: [Int]]?, isDeleted: Bool, visibility: String? = nil, ephemeralUntil: Int? = nil, isUnavailable: Bool = false) {
            self.entryId = entryId
            self.content = content
            self.createdAt = createdAt
            self.authorName = authorName
            self.authorAvatar = authorAvatar
            self.authorId = authorId
            self.isMine = isMine
            self.authorHandle = authorHandle
            self.images = images
            self.isPublic = isPublic
            self.visibility = visibility
            self.ephemeralUntil = ephemeralUntil
            self.publishAt = publishAt
            self.imgDims = imgDims
            self.isDeleted = isDeleted
            self.isUnavailable = isUnavailable
        }
    }

    private static let maxLength = 2000
    private static let maxImages = 9

    // MARK: - 状态

    private var selectedMood: String? {
        didSet { editorEditVersion += 1 }
    }
    /// 插入式心情的上次焦点框：点选心情钮/弹出框选项时焦点可能已被
    /// 拾取动作带走，单靠 isFirstResponder 会误判；本字段记最后一次
    /// 获焦的框（标题/正文），兜底时仍插到上次光标所在的框。
    private enum ComposerInput { case headline, body }
    private var lastFocusedComposerInput: ComposerInput?
    private var selectedWeather: String? {
        didSet { editorEditVersion += 1 }
    }
    /// 天气气温（摄氏度整数）：自动填或手改后才有值；清天气类型时同清。
    private var selectedTemperature: Int? {
        didSet { editorEditVersion += 1 }
    }
    /// 当地天气取数代次：快速连点天气钮时旧回包过期作废，不覆盖新一次的结果；
    /// 手选天气/手改气温时亦 +1，使在途自动填回包过期作废、不覆盖手改值。
    /// 再点天气钮会重新取数（代次再 +1），仍按 #427 口径覆盖手改。
    private var weatherFetchGeneration = 0
    /// 批 E 编辑器位置：已确认的位置（只有文本，无坐标）。nil = 未定位；
    /// 定位失败不改本值（失败只 toast、不静默清掉已确认的位置；从未确认过时行即隐藏 = 未定位态）。
    private var selectedLocation: DiaryLocation? {
        didSet { editorEditVersion += 1 }
    }
    /// 批 E 编辑态原位置快照（setupEditContent 首次回填时记下）：PUT 时与终态比对，
    /// 未动省略、改选发新值、清除发显式 null；新建模式恒为 nil。
    private var originalLocation: DiaryLocation?
    /// 新建模式的 @ 对象（编辑模式经 selectedRecipient 改选，见 refreshRecipientRow 编辑分支）。
    private var selectedRecipient: SearchUser? {
        didSet { editorEditVersion += 1 }
    }
    /// 通知对方：iCity @ 提醒无按篇开关——选人面板的开关值不再用于发布，
    /// 仅作面板初值占位保留，不触发重渲染、不进请求。
    private var notifyRecipient = true {
        didSet { editorEditVersion += 1 }
    }
    /// 新建模式的引用（编辑模式不用它，引用锁定，见 lockedQuote）。
    private var selectedQuote: SelectedQuote? {
        didSet { editorEditVersion += 1 }
    }
    /// 编辑模式原 @ 展示名（未动时回填展示；改选/清除后以 selectedRecipient/editMentionCleared 为准）。
    private var lockedRecipientName: String?
    /// 编辑模式原 @ 用户 id（未动时 PUT 省略 mentioned_user_id，服务端保留原值）。
    private var lockedMentionedUserId: Int?
    /// 编辑模式已清除 @（且未重新选人）：PUT 显式清 mentioned_user_id。
    private var editMentionCleared = false
    /// iCity：新建编辑器可见性初值硬编码私密（false），不读 UserDefaults、不记住上次选择。
    private var selectedVisibilityPublished = false {
        didSet { editorEditVersion += 1 }
    }
    /// 好友第一期：仅好友档（与 published/ephemeral 互斥三态之一；限时恒公开，
    /// 故仅好友与限时互斥：菜单直选任一档即定格该档，不经过中间档）。
    private var selectedVisibilityFriends = false {
        didSet { editorEditVersion += 1 }
    }
    /// 顶栏菜单的限时档：true 恒与 published=true 同行（限时即公开语义）；
    /// 切到私密或普通公开时即清掉，不残留（见 applyVisibilityChoice）。
    private var isEphemeral = false {
        didSet { editorEditVersion += 1 }
    }
    /// 编辑模式的引用：初始为原值，可改可删（网页 PUT 同款：body 带新 quote_id；
    /// 删为空时 updateEntry 省略 quote_id，服务端按 null 写，旧引用即清掉）。
    private var lockedQuote: SelectedQuote?
    /// 引用规则简化存量提示：本编辑器实例内只弹一次；setupEditContent 时若尚未
    /// appear 则先挂起（viewDidAppear 里补弹），补拉回填后已 appear 则当场弹。
    private var storedQuotePromptShown = false
    private var storedQuotePromptPending = false
    private var composerDidAppear = false
    /// 编辑回填补拉单篇只做一次（quote 体缺失时）：避免已删引用（gone 只有 id、无正文）
    /// 补拉后仍无正文时反复请求。
    private var editQuoteFetchAttempted = false
    /// 编辑回填补拉失败态：true 时编辑器留在页上、引用区露“加载失败 + 重试”行，
    /// 保存钮禁用（此时 lockedQuote 与图片条尚未回填，PUT 会误清原引用与原图，
    /// 故禁发）；点重试重新补拉，成功后清掉并走正常回填。失败不再关编辑器。
    private var editQuoteFetchFailed = false
    /// 编辑回填补拉在途态：true 时引用区失败行暂隐（防重复点重试）、保存钮同样
    /// 禁用（回填未完成时 PUT 同样会误清原引用与原图）；成功或失败回落时清掉。
    private var editQuoteFetchInFlight = false
    /// 引用 qp-mode 进出时保存/恢复的外层滚动位置（网页 qpPrevScroll 的 sheet 滚动等价；
    /// 正文 UITextView 关滚动、随内容生长，故无 textarea 内部滚动需要另存）。
    private var quotePanelSavedScrollOffset = CGPoint.zero
    private var quotePanelSavedScrollValid = false
    /// C1：工具栏上方选择条：同一时刻最多展开一条（写给），nil=全部收起。
    /// 心情/天气旧条带已删（见下），入口只走心情/天气尖角弹出框，不再走本值；
    /// 旧附加栏三态随双重入口删除而整组拆除，不再有“附加栏撑着显示天气行”的压制状态机。
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
    /// R22-#6：上传状态统一同步边界。uploadGeneration / uploadAccountId /
    /// uploadTask 的一切读写都走这把锁：主线程取消与后台队列递增不再各改
    /// 各的；编码完成后的起传门控（校验 + 建任务）在同一把锁内原子完成，
    /// 取消无法插进校验与建任务之间。锁内只做整数校验与任务创建，不调用
    /// 任何会回主线程或重入本锁的代码；authAccountId 的读（authStateQueue
    /// 的 sync）不回调编辑器，无死锁环。
    private let uploadStateLock = NSLock()

    /// 发起一次上传：发新令牌（代次 +1）并绑定当前鉴权账号，返回发起时
    /// 捕获的（代次，账号）。调用方把令牌带进编码闭包，编码完成后传给
    /// uploadPrepared 作起传门控；令牌在编码期间被取消作废即不起传。
    private func issueUploadToken(for item: ComposerImageItem) -> (generation: Int, accountId: Int?) {
        let accountId = BearyAPI.shared.authAccountId
        uploadStateLock.lock()
        defer { uploadStateLock.unlock() }
        item.uploadGeneration += 1
        item.uploadAccountId = accountId
        return (item.uploadGeneration, accountId)
    }

    /// 锁内读当代次（回包认领用）。
    private func lockedUploadGeneration(of item: ComposerImageItem) -> Int {
        uploadStateLock.lock()
        defer { uploadStateLock.unlock() }
        return item.uploadGeneration
    }

    /// 锁内清任务句柄（回包认领后）。
    private func lockedClearUploadTask(of item: ComposerImageItem) {
        uploadStateLock.lock()
        defer { uploadStateLock.unlock() }
        item.uploadTask = nil
    }
    private var draftClientReq: String?
    /// 当前正在写的草稿篇 id（v3 多槽键）：恢复/从箱打开时取该篇 draftId，
    /// 首次保存时生成；发布成功与丢弃只删这一篇，不碰其他篇。
    private var currentDraftId: String?
    /// 审计 P1-9：箱内删“正在写”草稿时被清掉的 draftId（onDeleteCurrentDraft 处记下），
    /// 供箱内撤销恢复时比对——只绑回正是这一篇的恢复，防串篇；新篇接管/重开/发布重置时清掉。
    private var clearedCurrentDraftId: String?
    /// 审计第 26 项：编辑版本——打开编辑器（restoreDraft 入口）时记下基线，
    /// 此后任何草稿字段变化都 +1（各字段的 didSet、正文/标题变化入口），
    /// 异步恢复回包仅在版本与草稿身份均未变化时才应用；跳过时旧草稿
    /// 仍在草稿箱，不丢数据。恢复自身的回填发生在门通过之后，不影响门。
    /// B2：关闭流程复用本版本绑定当前内容（见 performCloseSave）。
    private var editorEditVersion = 0
    /// 审计二轮 08：组词期间切主题被 refreshInlineMoodImages 跳过时记待刷新，
    /// 组词落字后补执行一次（textViewDidChange 里检测）。
    private var inlineMoodRefreshPending = false
    /// B2：关闭进行中守卫——didTapCancel（取消钮）与边缘关闭共用同一入口，
    /// 快速连点只接一次关闭流程；在途关闭再次点按直接忽略（返回 false，
    /// 边缘手势把视图滑回原位）。成功关闭时随编辑器一起消失，不复位；
    /// 失败/留页分支须复位（见 performCloseSave），否则再点关闭会被挡住。
    private var isClosing = false
    private var isPublishing = false
    /// P1-4：本篇已发布成功标记——成功回包后待执行的自动保存计时器
    /// 若触发，saveDraftNow 不得把内存里已发布的内容当新草稿落盘。
    /// 只在切篇/重置为空白时清掉（新篇重新计）；用户输入不经过它清，
    /// 发布成功后编辑器即退场，残留输入本就不应再落盘。
    private var publishedCurrentDraft = false
    /// R14 P1-6：退出保存进行态（关闭／保留并新建两路共用）。写盘期间编辑器
    /// 未冻结时用户继续输入会使首拍快照过期（#1002 只修了关闭路径的版本
    /// 复核，未修冻结）；置位期间 refreshPublishingInputFreeze 把正文／标题
    /// 与全部入口钮一并冻住，发布钮亦禁用，状态行显“保存中…”＋转圈（与
    /// scheduleDraftSave 的保存中态同款视觉），输入不再产生新版本；等待
    /// 结束（成功／失败任一终态）即恢复。只由退出保存路径置位，日常防抖
    /// 保存不动它；setDraftExitSaving(false) 只走终态分支，不走 #1002 式
    /// 版本复核的重存中途（重存期间冻结保持，见 saveDraftVersionedForExit）。
    private var isDraftExitSaving = false
    /// 编辑期到点时正好有保存 PUT 在途：计时器不自动关编辑器，改由服务端
    /// 结果定去留（见 startEditTimer / performUpdate 失败分支）。置位后即便
    /// 请求失败也不再允许重发——期限已过，服务端同样会以 edit window
    /// expired 拒绝；编辑器保持打开、正文与标题原样保留，供用户复制后
    /// 再手动关闭。正常到点（无在途请求）不置位，直接走原关闭路径；
    /// 新建发布没有编辑计时器，不受影响。
    private var editSaveBlockedAfterDeadline = false
    /// 审计四轮增量 09：编辑检查点恢复提示状态（每编辑器实例只弹一次）。
    /// pending 由回填末尾的检查点查到后挂起，viewDidAppear 后才弹
    /// （存量引用提示同款 composerDidAppear 守卫）；弹层挡住时 1 秒
    /// 重试、最多 3 次，仍被挡时留盘、下次进编辑器再问。
    private var editCheckpointPromptShown = false
    private var pendingEditCheckpoint: BearyDraftStore.BearyEditCheckpoint?
    private var editCheckpointPromptRetries = 0
    /// 一并公开引用发布流程代次（quote-freeze）：每次点发布（新建态）即 +1，
    /// setVisibility 与 publishEntry 的回调只认创建时的代次；过期回调直接
    /// 丢弃，不碰 isPublishing、不 toast、不覆盖新一轮流程的状态。
    private var publishGeneration = 0
    /// 发布发起账号（新建发布专用）：首次点发布时捕获，之后本篇的发布重试
    /// 一律认它，不随重登改写。401 后重登成另一账号时，旧账号内容不得
    /// 写进新账号草稿文件、也不得以新账号发出：didTapPublish、saveDraftNow、
    /// beginPublishTogether、performPublish 四处均以它校验，失配即中止并
    /// 提示回到原账号或重新开始（见 showPublishAccountMismatchAlert）。
    /// 同账号重登 id 不变，校验通过、同一草稿可续写；编辑模式不设它
    /// （saveDraftNow 在编辑态本就是空操作，见 saveDraftNow 首行守卫）。
    private var publishOriginAccountId: Int?
    /// 打开编辑器时绑定的账号（P0-1）：viewDidLoad 即记下打开时的账号，
    /// 此后草稿保存一律写该账号的桶，不随重登改写；发布前校验亦认它
    /// （见 isPublishOriginMismatch）。与 publishOriginAccountId 的区别：
    /// 后者只在首次点发布时才定（#761），定之前存在“重登后自动保存
    /// 先把旧内容写进新号桶”的窗口，本绑定堵的就是这个窗口。
    /// 切篇（loadDraftFromBox）时按箱内草稿所属的当前账号重绑；
    /// 发布成功/丢弃/重置空白时随 publishOriginAccountId 一并清掉，
    /// 下一篇再按打开时账号重绑。编辑态不写草稿，绑定无实际作用。
    private var composerOriginAccountId: Int?
    /// 一并公开部分成功态：setVisibility 已成功、原日记已公开的原日记 id。
    /// 此后新篇发布失败不再回滚原日记（见 performPublish 部分成功分支），
    /// 重试（弹框按钮或再点发布）只发新篇，不再走门禁/setVisibility。
    /// 发布成功、清草稿、重置空白、从草稿箱切篇时清掉。
    private var publishTogetherPublishedSourceId: String?
    /// 发布账号口径：登录态 id 优先，取不到时退回草稿分桶 id（两者正常
    /// 情况下一致，登录切换时由容器 setAccount 同步）。
    private func currentAccountIdForPublish() -> Int? {
        if let id = SessionManager.shared.currentUser?.id {
            return id
        }
        return BearyDraftStore.currentAccountId
    }
    /// 发起账号是否已失配：发起账号已定、且当前账号已定、两者不同。
    /// 当前账号未定（如 401 刚清态、尚未重登）不算失配，沿旧口径走
    /// 登录入口，不在此处误拦。
    /// P0-1：首次点发布前 publishOriginAccountId 尚未定，此时认打开编辑器
    /// 时绑定的 composerOriginAccountId——重登成另一账号后自动保存与
    /// 发布都在四处旧校验点（saveDraftNow/didTapPublish/beginPublishTogether/
    /// performPublish）被同一函数拦下，不另起校验。
    private func isPublishOriginMismatch() -> Bool {
        guard let origin = publishOriginAccountId ?? composerOriginAccountId,
              let current = currentAccountIdForPublish() else { return false }
        return origin != current
    }
    /// 账号失配提示：只提示、不删不改任何草稿与已公开态。部分成功态
    /// （原日记已公开）另加一句，免得用户误以为什么都没发生。
    /// “重新开始”不由本弹框自动执行：用户走现有草稿箱“丢弃并新建”，
    /// clearDraftAndFiles 会清掉发起账号绑定，新篇再发布即按新账号计。
    private func showPublishAccountMismatchAlert() {
        if let sourceId = publishTogetherPublishedSourceId,
           sourceId == selectedQuote?.entryId {
            showAlert(message: "原日记已公开，新篇未发布。账号已变化，请回到原账号后再发布，或丢弃本篇重新开始。")
        } else {
            showAlert(message: "账号已变化，本篇未发布。请回到原账号后再发布，或丢弃本篇重新开始。")
        }
    }
    /// 第一次点按时拍下的不可变完整发布快照（quote-freeze）：正文、图片、
    /// 实况映射、心情、天气、气温、引用、可见性、@、标题、限时、位置、
    /// clientReq 全在点按瞬间定格；门禁与 setVisibility 在途期间
    /// 用户改什么都不再进提交载荷，performPublish 只读本快照。
    private struct PublishSnapshot {
        let content: String
        let imageKeys: [String]
        let liveVideos: [String: String]
        let mood: String?
        let weather: String?
        let temperature: Int?
        var quoteId: String?
        var published: Int
        /// 好友第一期：新建三档（private/friends/public；限时恒 public）。
        /// 快照拍定后 publishEntry 按它发，published 同步作旧版兼容（friends→0）。
        var visibility: String
        let mentionedUserId: Int?
        let title: String?
        var ephemeral: Int?
        let locationName: String?
        let locationDistrict: String?
        let clientReq: String
        /// 快照拍定时的发起账号：performPublish 入口再校验一次，防门禁/
        /// setVisibility 在途期间账号已变仍把旧篇以新账号发出。
        let originAccountId: Int?
        /// P0-2：提交时记录的草稿 id 与账号：成功回包只清理这一篇。
        /// 回包时 currentDraftId 可能已切到另一篇，绝不能按现值删。
        let draftId: String?
        let accountId: Int?
        /// P0-2：提交时本篇图片的本地文件名：成功后只删这些文件，
        /// 不碰切篇后新篇的图片。
        let imageLocalFiles: [String]
    }
    /// 新建发布快照（quote-freeze）：在 didTapPublish 校验通过后、门禁弹出
    /// 前调用。clientReq 在此创建（原 performPublish 首步），调用方随后等
    /// saveDraftNow 落盘成功才发首个会改变服务端状态的请求（P1-5），
    /// 保证服务端幂等键在任何请求发出前已持久化（不只是入队）。
    private func makePublishSnapshot(trimmed: String) -> PublishSnapshot? {
        if draftClientReq == nil {
            draftClientReq = BearyDraftStore.newClientReq()
        }
        // P0-2：快照同时记下提交时的草稿 id——saveDraftNow 复用同一 id 落盘，
        // 成功回包只删这一篇，不按回包时刻的现值删。
        if currentDraftId == nil {
            currentDraftId = BearyDraftStore.newDraftId()
            clearedCurrentDraftId = nil
        }
        guard let req = draftClientReq else { return nil }
        return PublishSnapshot(
            content: trimmed,
            imageKeys: uploadedImageKeys(),
            liveVideos: uploadedLiveVideos(),
            mood: selectedMood,
            weather: selectedWeather,
            temperature: selectedTemperature,
            quoteId: (selectedQuote?.isDeleted == true) ? nil : selectedQuote?.entryId,
            published: selectedVisibilityPublished ? 1 : 0,
            visibility: isEphemeral || selectedVisibilityPublished ? "public" : (selectedVisibilityFriends ? "friends" : "private"),
            mentionedUserId: selectedRecipient?.id,
            title: headlineForCreate,
            ephemeral: isEphemeral ? 1 : nil,
            locationName: selectedLocation?.name,
            locationDistrict: selectedLocation?.district,
            clientReq: req,
            originAccountId: currentAccountIdForPublish(),
            draftId: currentDraftId,
            accountId: currentAccountIdForPublish(),
            imageLocalFiles: imageItems.compactMap { $0.localFile })
    }
    private var didAutoFocus = false
    // 标题行已去掉：进页拉回旗标与 ensureTitleRowVisibleOnEntry 已整段删除
    //（#219 只覆盖打字时、长草稿光标在末尾进页拉回故意不执行那 case 本就未解决；
    // 本批不修可见性、直接去掉标题行根除该问题，进页聚焦默认只走正文）。
    private var draftTimer: Timer?
    /// 审计四轮 07：切后台冲刷用的后台任务句柄；.invalid = 未持有任务。
    private var backgroundDraftTask: UIBackgroundTaskIdentifier = .invalid
    /// 审计四轮 07：上次后台冲刷时的编辑版本——版本未变说明冲刷后无新输入，
    /// willResignActive 与 didEnterBackground 两次触发只存一次，不重复写盘。
    private var lastBackgroundFlushVersion = -1
    /// R14 P1-7：在途草稿写盘计数（save/delete 两路入队时 +1，主线程回包时 −1；
    /// 只在主线程读写，与 saveDraftNow 的调用方同线程）。退后台补存时若
    /// 计时器已空、但仍有写盘在途，补存完成回调排进 draftSaveDrainCompletions，
    /// 等计数归零再回（调用方据此持后台任务，不让写盘在后台被挂起）。
    private var draftSaveInFlightCount = 0
    private var draftSaveDrainCompletions: [() -> Void] = []
    private var editTimer: Timer?
    private var imageItems: [ComposerImageItem] = [] {
        didSet { editorEditVersion += 1 }
    }
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
    // 109：发布 pill 改 BearyHit44Button——视觉高仍钉死 36、圆角 18 与文案不动，
    // 仅 point(inside:) 把热区扩到 44（同栏其余三钮均为 44；此前普通钮高 36，
    // 上下各缺 4pt 可点区）。不要把视觉高改成 44。
    private let publishButton = BearyHit44Button(type: .system)
    private let publishRingView = UIImageView()
    private let topSeparator = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()
    // MARK: - 109 标题重写（从零新写，不复用 #244 前的旧标题实现）
    /// 设计（先写清再施工）：
    /// - 输入位置：内容栈首项、正文 textView 上方，一行独立输入区
    ///   （headlineWrap：单行输入框 + 底部 1pt 细线），不进顶栏、不叠正文。
    /// - 长度上限：30 字——与服务端 normalizeEntryTitle 口径一致
    ///   （>30 字服务端 400），前端输入时即截断到 30 字，不靠服务端报错。
    /// - 显示位置与样式：卡片与详情已有标题行（16.5 粗体，空标题整行
    ///   隐藏、不占位），本支不改其样式；编辑器输入框 17 粗体、占位灰字
    ///   “给这篇日记起个标题（可选）”，空 = 无标题。
    /// - 空态：字段留空即无标题；卡片/详情空标题不占位、不显“日记”占位；
    ///   列表行（那年今日/对话原篇、地图列表、星图 sheet）的“无标题又无
    ///   正文显日记”回退一并去掉，改为空串（只剩日期/副文案可读）。
    /// - 数据口径：只复用现行数据字段（Entry.title、BearyDraft.title、
    ///   publish/update API 的 title 参数），不复用旧前端代码；编辑入口
    ///   本就只在 15 分钟内出现（详情/卡片 ⋯ 菜单按 editDeadline 门控，
    ///   服务端 PUT 同样按 edit_deadline 403），标题改动与正文同窗口，
    ///   超时只能删不能改标题，无需另设标题门控。
    /// - 清空语义：编辑时字段清空 → PUT 发显式空串，服务端归一化为空
    ///   标题 NULL（即清掉旧标题）；新建时空字段按省略不传（同为无标题）。
    private let headlineWrap = UIView()
    /// 标题输入：单行 UITextView（UITextField 放不下图片附件；熊脸图必须
    /// 直接显示在标题里，故换成能放附件的 UITextView，再以单行口径约束：
    /// 不换行、横向滚动、高度钉死一行，视觉与原单行框一致）。
    private let headlineField = UITextView()
    private let headlinePlaceholderLabel = UILabel()
    private let headlineClearButton = UIButton(type: .system)
    /// 审计三轮第 2 项：清除钮 44pt 透明命中容器——视觉钮仍 22pt 不动，
    /// 命中钮浮在内容栈上层、右缘与视觉钮对齐（不超出内容右缘），读屏只认命中钮。
    private let headlineClearHitButton = UIButton(type: .custom)
    private var headlineHeightConstraint: NSLayoutConstraint?
    private let headlineRule = UIView()
    private static let headlineMaxLength = 30
    /// 112：标题超 30 字截断提示的“本轮已弹”标记。截断落到正好 30 字不算
    /// 回落（仍属同一轮超限），只有删回 30 字以下才重置，下一轮超限可再弹；
    /// 这样连按超限键只弹一次，又不会一次弹完后续轮次再也不弹。
    private var headlineLimitToastShown = false
    /// 编辑器标题当前值（去首尾空白；空串 = 无标题，供各发送点按需取用）。
    private var headlineText: String {
        BearyText.inlinePlainText(from: headlineField.attributedText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var headlineFont: UIFont {
        BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
    }
    /// 正文动态字号（标题 headlineFont 同款口径）：正文、占位、输入属性、
    /// 回填属性统一走这里，不再各写固定 16pt。
    private var bodyFont: UIFont {
        BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
    }
    private var headlineIsDark: Bool { traitCollection.userInterfaceStyle == .dark }
    /// 新建/草稿用：无标题按 nil（省略不传，服务端即 NULL）。
    private var headlineForCreate: String? {
        headlineText.isEmpty ? nil : headlineText
    }
    private let textView = BearyBodyTextView()
    /// 正文区高度约束（2026-11-01 撑满口径：区高 = 滚动区可用高 − 其他区高，
    /// 下限 140；内容短时撑满、内容长时内层滚动，旧 sheet 封顶已废）。
    private var textViewHeightConstraint: NSLayoutConstraint?
    /// 占位顶约束（字号档位变化时跟 bodyFont 重算基线偏移，见 trait 回调）。
    private var placeholderTopConstraint: NSLayoutConstraint?
    /// 当前键盘高度（applyKeyboard 算出，编辑器批第 5 项）：updateTextViewHeight 的封顶
    /// 须再减它，否则正文帧底伸到键盘下方、末行被盖且内层滚到头也露不出来；
    /// 键盘收起/移出屏时为 0，WillChangeFrame 路径同值幂等。
    private var currentKeyboardHeight: CGFloat = 0
    /// 2026-10-29 第 28 项：键盘弹出前保存的滚动位置（收起时恢复原位）与
    /// 键盘可见跟踪（帧变化通知不重复保存，避免覆盖弹出时刻的原位）。
    private var keyboardSavedContentOffset: CGPoint?
    private var keyboardVisible = false
    /// 2026-10-31 上滑闪回修：键盘动画在途标志与已落定高度。
    /// WillShow 与 WillChangeFrame 会对同一次键盘出现各发一次，若两次都跑
    /// applyKeyboard＋完成回调的瞬时修正，就会先滑后闪回；同一高度重复到
    /// 达时直接跳过（见 applyKeyboard），动画在途中的焦点滚动只记 pending、
    /// 由完成回调统一做一次带键盘曲线的动效修正，不多路抢偏移。
    private var keyboardAnimationInFlight = false
    private var lastAppliedKeyboardHeight: CGFloat = -1
    private var pendingFocusScrollAfterKeyboard = false
    // 2026-11-01：标题聚焦快照/守卫/代次已随标题滚动链整段删除
    // （点标题只聚焦、不滚动，见 headlineDidBeginEditing）。
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
    /// 2026-10-31：工具栏上方限时行已整组删除（行、开关、文案、约束全清），
    /// 限时并进顶栏可见性钮菜单（12b 前为点按循环）；滚动区底锚直接走工具栏档（见 updateScrollBottomAnchoring）。
    private var scrollBottomToToolbarConstraint: NSLayoutConstraint?
    private var scrollBottomToStripConstraint: NSLayoutConstraint?
    private var scrollBottomToViewConstraint: NSLayoutConstraint?
    /// 2026-10-29 第 27 项：回应面板（心情条）改锚小熊按钮本体——条底贴工具栏顶
    /// （触发按钮行正上方），不再随 toolStripStack 锚在限时行上方。
    /// 关闭退场 B 修法：工具栏底锚两档——编辑态钉键盘顶（默认激活），
    /// 真正被 dismiss 时换钉自身 safeArea 底（初始不激活），簇随页滑走；
    /// 被其他 modal 盖住时的 viewWillDisappear 不换（见 viewWillDisappear 的 isBeingDismissed 判定）。
    private var toolbarBottomToKeyboardConstraint: NSLayoutConstraint?
    private var toolbarBottomToSafeAreaConstraint: NSLayoutConstraint?
    private var toolbarReanchoredForDismiss = false
    /// 补缺 P2-20（天气条独立锚点）：天气条底贴工具栏顶（2026-10-31 随限时行删除，天气档约束一并清掉）。
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
    /// 窄屏 5 项之 3：草稿状态独立行（工具栏上方、工具行之上），只承载
    /// level 0 失败与 level 1 部分保存：完整文案＋重试钮，不再挤进工具行
    /// 与 6 个图标抢宽。level 2 已保存仍走工具行右端原口径，本行不启用。
    private let draftStatusBanner = UIStackView()
    private let draftStatusBannerLabel = UILabel()
    private let draftStatusRetryButton = BearyHit44Button(type: .system)
    private var toolbarToolRow: UIStackView?
    private var toolbarToolRowTopToSeparatorConstraint: NSLayoutConstraint?
    private var toolbarToolRowTopToBannerConstraint: NSLayoutConstraint?
    /// 窄屏 5 项之 3：独立行隐藏时的 0 高约束。隐藏态只靠 isHidden 不够——
    /// 行高仍由子项固有高撑着、会把工具行顶下去；隐藏时钉 0、显示时停用。
    private var draftStatusBannerHeightConstraint: NSLayoutConstraint?
    private let imageToolButton = BearyComposerToolButton(type: .system)
    /// 批 E 定位钮：工具栏左组第 2 位（图片右边、心情之前，预览 v2 定版；v1 的心情/天气并列位置已作废）。
    private let locationToolButton = BearyComposerToolButton(type: .system)
    private let moodToolButton = BearyComposerToolButton(type: .system)
    private let weatherToolButton = BearyComposerToolButton(type: .system)
    private let recipientToolButton = BearyComposerToolButton(type: .system)
    private let quoteToolButton = BearyComposerToolButton(type: .system)
    private let draftPillButton = UIButton(type: .system)
    /// 顶栏可见性钮（2026-10-30 建、2026-10-31 改三态、12b 改点开菜单）：锁＝私密、地球＝公开、
    /// 时钟＝限时，点开系统 UIMenu 直选四档；取代正文区分段，为唯一可见性入口；
    /// 编辑模式隐藏（编辑不改可见性）；限时态即公开语义，不再另设锁定开关。
    private let visibilityButton = UIButton(type: .system)
    // 编辑器改版（2026-10-29）：心情/天气尖角弹出框（取代旧选择条）+ 框外收起层。
    private let moodCallout = BearyCalloutPickerView()
    private let weatherCallout = BearyCalloutPickerView()
    private let calloutDismissView = BearyCalloutDismissView()
    /// 批 E 定位气泡与专属框外收起层（不复用 calloutDismissView：心情/天气框与定位气泡
    /// 的显隐状态机各自独立，复用会使一方收起时误关另一方）。
    private let locationPopover = BearyLocationPopoverView()
    private let locationDismissView = BearyCalloutDismissView()
    private var locationPopoverOpen = false
    /// 批 E 编辑器下方定位行（精确地点名 + 公开提示副行；无位置时整行隐藏，不留空行）。
    private let locationRowStack = UIStackView()
    private let locationLineRow = UIStackView()
    private let locationIconView = UIImageView()
    private let locationLabel = UILabel()
    // 按钮普查：视觉 24×24，热区用 Hit44 扩到 44（视觉不动；左右邻居为文字行，无互叠按钮）。
    private let locationClearButton = BearyHit44Button(type: .system)
    private let locationNoteLabel = UILabel()
    private enum CalloutKind { case mood, weather }
    private var activeCallout: CalloutKind?
    /// 审计第 31 项：打开当前框的触发钮（工具钮或已选 chip，二选一的实际点按者）。
    /// 关闭还焦点只认它；程序性收起（换工具/面板/发布/取消等）不还焦点，故
    /// 本字段只在用户主动关闭时由 hideCallout(restoreFocus: true) 消费。
    private weak var calloutAccessibilityTrigger: UIView?
    private var calloutTransitionGeneration = 0
    /// 审计 1：浮层展示意图代次（与天气取数代次、转场代次分开）。
    /// 天气钮点按时记下当次意图；点按定位/心情/写给/引用等其他工具、
    /// 或另一次显式 showCallout 时 +1，旧意图即失效——天气回包仍按
    /// weatherFetchGeneration 正常落数、正常 toast，只是末尾不再抢开天气框。
    private var calloutPresentationGeneration = 0
    private func invalidatePendingCalloutPresentation() {
        calloutPresentationGeneration += 1
    }
    private static let calloutTransitionDuration: TimeInterval = 0.20
    private static let calloutTransitionOffset: CGFloat = 6
    private static let calloutHeight: CGFloat = 78
    /// [24] 小项 2：天气框高约束（基准 78；步进器附属行显时 += 附属行高，
    /// 见 updateWeatherCalloutHeight；心情框仍走固定 78，不受影响）。
    private var weatherCalloutHeightConstraint: NSLayoutConstraint?

    /// [24] 小项 2：天气框高 = 基准 + 附属行显隐对应的增量；框未搭建时
    /// 约束为 nil，直接跳过（refreshSelectedChips 在搭建前也可能调到）。
    private func updateWeatherCalloutHeight() {
        guard let constraint = weatherCalloutHeightConstraint else { return }
        constraint.constant = Self.calloutHeight + weatherCallout.accessoryExtraHeight
    }
    // C1：已选中项轻量 Chip 行（正文下方）：心情/天气/写给各一枚，点 chip 打开对应选择条。
    private let selectedChipsRow = UIStackView()
    /// 审计 P1-3：Chip 行首行（心情/天气/写给单行态）；写给换行时脱离本行、改作
    /// selectedChipsRow 的第二行（见 layoutSelectedChips），不另建容器。
    private let selectedChipsFirstRow = UIStackView()
    /// 审计 P1-3：写给当前是否在独立第二行；viewDidLayoutSubviews 宽变化时
    /// 凭此 + 宽门限决定是否重算，避免移行触发布局 → 再移行的循环。
    private var selectedChipsRecipientOnSecondRow = false
    private var selectedChipsLastLayoutWidth: CGFloat = -1
    /// [24] 审计后续小项 2：气温步进器已收进天气框附属行，不再进 chip 行；
    /// 窄屏第二行包壳与换行兜底随之删除（步进器不再参与首行宽度计算）。
    /// 审计 P1-8：选择条转场代次——每次 refreshToolStrip 显隐变化即 +1；旧转场
    /// 的 completion 凭代次过期作废，不再碰视图，快速连点只收敛到最后状态。
    private var toolStripTransitionGeneration = 0
    private let moodChipButton = BearyHit44Button(type: .system)
    private let weatherChipButton = BearyHit44Button(type: .system)
    /// 气温步进器（只在已选天气时显）：− / 数值 / +，点数值弹系统输入框直输；
    /// 无气温时点 ± 先落到 18° 再调（不凭空猜一个当地值当起点以外的数）。
    private let tempStepperStack = UIStackView()
    private let tempMinusButton = BearyHit44Button(type: .system)
    private let tempLabelButton = BearyHit44Button(type: .system)
    private let tempPlusButton = BearyHit44Button(type: .system)
    private let recipientChipButton = BearyHit44Button(type: .system)
    // C11：删图撤销条（图片条下方）：文案 + 撤销钮，10 秒到期自动消失并提交删除。
    private let imageUndoBar = UIView()
    private let imageUndoLabel = UILabel()
    private let imageUndoButton = BearyHit44Button(type: .system)
    // 状态行：编辑倒计时 + 草稿状态 + 字数圆环
    private let statusRow = UIStackView()
    /// 窄屏 5 项之 4：状态行内的弹性 spacer（无内容、无高度，只占剩余宽）——
    /// refreshStatusRowVisibility 判“有无实际内容”时须排除它，否则 spacer 永真、
    /// 空行永远判为有内容。buildStatusRow 里用本项，不再另建局部 spacer。
    private let statusRowSpacer = UIView()
    /// 窄屏 5 项之 4：状态行最低高约束（≥18）。无内容隐藏整行时须停用它，
    /// 否则隐藏的 arranged 子项仍被自身 ≥18 约束撑住、塌不掉。
    private var statusRowMinHeightConstraint: NSLayoutConstraint?
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
    // @（写给区：仅已选 chip；无按篇通知行）
    private let recipientSection = UIStackView()
    private let recipientLine = UIStackView()
    private let recipientChipView = UIView()
    private let recipientChipAvatar = UIImageView()
    private let recipientChipFallback = UILabel()
    private let recipientChipName = UILabel()
    private let recipientClearButton = BearyHit44Button(type: .system)
    private let notifyGroup = UIStackView()
    private let notifyCheckButton = BearyHit44Button(type: .system)
    private let notifyLabel = UILabel()
    // 顶部 @ 提示行（顶栏下方固定行，写字时始终可见；点按同底部 chip，走 openToolStrip(.recipient)）。
    private let mentionTopRow = UIView()
    private let mentionTopPill = BearyHit44Button(type: .system)
    private var mentionTopRowHeightConstraint: NSLayoutConstraint?
    private var mentionTopName: String?
    private static let mentionTopRowHeight: CGFloat = 44
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
    /// “移除”钮走 BearyHit44Button：13pt 文字视觉帧不动，热区由 point(inside:) 扩至 44；
    /// 引用卡右上角 ×（quoteCardRemoveButton）本身已是 Hit44，本支不动它。
    private let quoteDeletedRow = UIStackView()
    private let quoteDeletedLabel = UILabel()
    private let quoteDeletedRemoveButton = BearyHit44Button(type: .system)
    /// B6 暂时看不到态行：灰字“引用的日记暂时看不到”+ 右端“移除”钮（已删行同款布局，
    /// 见 buildQuoteSection）；回包占位/明确无权限时露，旧预览正文/缩略图已清。
    private let quoteUnavailableRow = UIStackView()
    private let quoteUnavailableLabel = UILabel()
    private let quoteUnavailableRemoveButton = BearyHit44Button(type: .system)
    /// 编辑回填补拉失败行：灰字“引用的日记加载失败”+ 右端“重试”钮（已删行同款
    /// 布局，见 buildQuoteSection）；失败态才露，在途时暂隐防重复点按。
    private let quoteFetchFailedRow = UIStackView()
    private let quoteFetchFailedLabel = UILabel()
    private let quoteFetchFailedRetryButton = UIButton(type: .system)
    private let quotePanel = UIView()
    // 选择引用置顶 tab 条（预览 preview-quote-select-redesign-20261031.html）：
    // 直接挂在根视图、锚顶栏底，不随滚动区滚动；旧的面板内 tab 条已废除
    // （截图实测：面板内 tab 条在真机上整段不可见，改置顶后不再依赖面板内布局）。
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
        // 编辑器页底改与首页（广场）同色：玻璃背板已撤，实色 bg 底（浅白／深纯黑）；
        // 顶栏／标题／正文／工具栏均为 clear，自动跟页底走；后续 build* 加的
        // 子视图自然在其上；呈现层文件不动，卡片内按钮点亮色与功能全不动。
        view.backgroundColor = BearyColors.bg
        buildLayout()
        buildTopBar()
        buildMentionTopRow()
        // 109：内容栈首项为新标题输入区（见 buildHeadlineField），其下为正文。
        buildTextArea()
        buildSelectedChipsRow()
        buildLocationRow()
        buildImageRow()
        buildImageUndoBar()
        buildToolbarRow()
        buildCallouts()
        buildLocationPopover()
        buildStatusRow()
        buildRecipientRow()
        buildQuoteSection()
        buildQuotePanel()
        // P0-1：打开编辑器即绑定原账号（先于 restoreDraft 记下，恢复读盘
        // 与后续自动保存都认它，不随重登改写；见 composerOriginAccountId）。
        composerOriginAccountId = currentAccountIdForPublish()
        if isEditMode {
            setupEditContent()
        } else {
            restoreDraft()
        }
        updateCountLabel()
        updatePublishState()
        refreshToolStrip()
        refreshDraftPillWidth()
        // 首帧高度预先算好（D-12 编辑器部分）：viewDidLoad 末尾即按内容栈 fitting
        // 定一次 preferredContentSize，呈现层首帧不再以 0 占位走 80%/88% 满高封顶；
        // 此时 view.bounds 可能仍为 0，updatePreferredContentSize 内用屏宽估算兜底，
        // viewDidLayoutSubviews 后再按真实宽纠正一次。
        updatePreferredContentSize()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // 审计四轮 07：失活/入后台时冲刷未落盘的草稿——防抖只有 400ms 窗口，
        // 进程若在窗口内被终止，最后输入会丢。deinit 已统一 removeObserver。
        NotificationCenter.default.addObserver(self, selector: #selector(flushDraftBeforeBackground), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushDraftBeforeBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
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
            refreshSelectedChips()
            syncWeatherToolButton()
            // 审计 15 项第 5 项：此前此处紧接着又调一次 refreshSelectedChips
            // （补丁叠加留下的重复调用），已删——一次刷新即含图标与换行重算。
            refreshInlineMoodImages()
            headlineHeightConstraint?.constant = max(28, ceil(headlineFont.lineHeight) + 2)
            refreshNotifyCheck()
            notifyCheckButton.layer.bearyDynamicBorderColor = BearyColors.line
            draftPillButton.layer.bearyDynamicBorderColor = BearyColors.line
            charTrackLayer?.strokeColor = BearyColors.line.cgColor
            updateCountLabel()
        }
        // 审计补漏：字号档变化时发布钮宽度重算（此前只在搭建与忙态切换时算，
        // 编辑器开着时改系统字号，pill 宽度直接过期、大字号下裁标题）。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            refreshPublishButtonWidth()
        }
        // 动态字号变化时标题字号跟随（原 UITextField 靠
        // adjustsFontForContentSizeCategory 自动跟，UITextView 没有该属性，
        // 故手动重建标题 attributed；字号没变时不动，不打断正在输入的标题）。
        if headlineField.font?.pointSize != headlineFont.pointSize {
            headlineField.font = headlineFont
            headlinePlaceholderLabel.font = headlineFont
            setHeadlineText(headlineText)
            headlineHeightConstraint?.constant = max(28, ceil(headlineFont.lineHeight) + 2)
        }
        // 正文动态字号跟随（UITextView 不自动跟档位，标题同款手动刷新）：
        // 字号变了才重设，不打断正在输入的正文；已有文本走回填同款重刷。
        if textView.font?.pointSize != bodyFont.pointSize {
            textView.font = bodyFont
            textView.typingAttributes = [.font: bodyFont, .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraphStyle()]
            placeholderLabel.font = bodyFont
            // fixedLineHeightMultiple 为 nil = 未设倍数覆盖，按默认 1.0 计（偏移 0）；约束只在
            // buildTextArea 后存在，而那里恒设 1.7，故该回退实际走不到，仅过编译。
            placeholderTopConstraint?.constant = bodyFont.ascender * ((textView.fixedLineHeightMultiple ?? 1) - 1)
            applyBodyLineHeight()
        }
    }

    // 看门狗修法（2026-10-27，74 包 .ips 定案）：布局轮次里重算 preferred 会与呈现层
    // 容器布局成环——测量值每轮漂移 >0.5pt 时 0.5pt 门限防不住，主线程转圈 10 秒触发
    // 系统 scene-update 看门狗杀进程。故只在宽变化时重算；天气开关/附加栏/图片/
    // 正文/引用等各入口都直接调 updatePreferredContentSize，不走这里，不会丢更新。
    // 首帧：viewDidLoad 已算一次，首个非 0 宽布局再纠正一次（lastLayoutWidth 初值 -1）。
    private var lastLayoutWidth: CGFloat = -1

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 草稿 pill 宽度兜底（2026-10-29，同上）：每次布局后按当前标题重算一次宽度
        // 约束常量，约束若在某次布局中被打破也能在下次布局恢复；同值重设不触发重排。
        refreshDraftPillWidth()
        // 109：工具栏宽变化（旋转/分屏/居中列切换）时重算草稿状态适配，320 宽下只留对勾、宽回升恢复文案。
        applyDraftStatusToolbarFit()
        // 编辑器改版（2026-10-29）：弹出框打开时，尖角跟随工具栏图标中心；
        // 放宽门之前（键盘只动工具栏纵向时宽门会早退，但锚点仍需每轮重算；
        // 仅改尖角图层路径与收起层穿透区，不触发布局环）。
        if activeCallout != nil {
            updateCalloutArrowPositions()
        }
        // 审计 15 项第 9 项：定位气泡打开后，布局变化（键盘弹出、旋转、
        // 分屏致工具栏移动）同样要更新箭头与收起层穿透区坐标——只更新坐标，
        // 不重建视图；此前 viewDidLayoutSubviews 只处理心情/天气气泡。
        if locationPopoverOpen {
            updateLocationPopoverArrow()
            locationDismissView.passthroughRects = [toolbarContainer.convert(toolbarContainer.bounds, to: locationDismissView)]
        }
        // 审计 P1-3：宽变化（旋转/分屏/居中列切换）时重算 Chip 行换行；同宽不重算，
        // 移行本身触发布局也不会再进本分支，不成环。宽门限 0.5pt 与 sheet 高同款。
        if selectedChipsRow.bounds.width > 0,
           abs(selectedChipsRow.bounds.width - selectedChipsLastLayoutWidth) > 0.5 {
            layoutSelectedChips()
        }
        // 临时诊断（82 包追加，定根因后删除）：入口每调一次记一次，不节流。
        DiagFile.mark("composer-layout")
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
        composerDidAppear = true
        maybePresentStoredQuotePrompt()
        maybePresentEditCheckpointPrompt()
        NSLog("[Diag] composer-viewDidAppear")
        // 临时诊断（81 包，定根因后删除）。
        DiagFile.mark("viewDidAppear")
        // 打开即聚焦正文：编辑器唯一目的就是写，首屏就绪后直接可打字；只做一次，
        // 从选图/弹窗回来不抢焦点；有草稿时光标置末尾，接着写。
        // 与草稿恢复/图片续传无冲突：恢复在 viewDidLoad 已完成，续传是后台任务。
        if !didAutoFocus {
            didAutoFocus = true
            if !textView.text.isEmpty {
                // selectedRange 是 UTF-16 单位，String.count 是字素簇数：
                // 含 emoji 时两者不等（"😀a" 计 2 簇、3 个 UTF-16 单位），
                // 用 .count 会把光标落在正文中间；attributedText.length 即 UTF-16 长。
                textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
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
        // 焦点滚动口径钉死：滚动区可视区顶的计算口径钉死——默认 .automatic 会随
        // 呈现/安全区再补一份顶 inset，scrollFocusedFieldIntoView 按 contentInset.top
        // 算可视区顶就会错位；本页滚动区顶已锚顶栏底、不贴安全区，.never 让数学精确。
        scrollView.contentInsetAdjustmentBehavior = .never
        // 2026-11-01：外层滚动区不再设 delegate——它只为已删除的标题
        // 聚焦守卫服务（用户拖动清守卫），守卫删了，delegate 一并撤掉；
        // 内层正文 textView 另有自己的 delegate，不受此影响。
        scrollView.delaysContentTouches = false
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
        contentStack.layoutMargins = UIEdgeInsets(top: BearySpace.lg, left: BearySpace.lg, bottom: BearySpace.lg, right: BearySpace.lg)
        view.addSubview(topBar)
        view.addSubview(toolbarContainer)
        view.addSubview(toolStripStack)
        view.addSubview(mentionTopRow)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(contentStack)
        // C1：正文从顶栏下方直接开始（scrollView 顶锚顶栏）；工具栏贴键盘上方，
        // 选择条贴工具栏上方；scrollView 底锚三档切换（见 updateScrollBottomAnchoring），初始锚工具栏。
        scrollBottomToToolbarConstraint = scrollView.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor)
        scrollBottomToStripConstraint = scrollView.bottomAnchor.constraint(equalTo: toolStripStack.topAnchor)
        scrollBottomToViewConstraint = scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        // B 修法：工具栏底锚两档在此建好（键盘档激活、自身档待命），见声明注释。
        toolbarBottomToKeyboardConstraint = toolbarContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        toolbarBottomToSafeAreaConstraint = toolbarContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        toolbarBottomToKeyboardConstraint?.isActive = true
        toolbarBottomToSafeAreaConstraint?.isActive = false
        // 2026-10-31：限时行已删，滚动区底锚初始即工具栏档（新建/编辑同值，
        // 后续由 updateScrollBottomAnchoring 按选择条/引用面板切换；原 48pt 限时行空间收回）。
        scrollBottomToToolbarConstraint?.isActive = true
        // 选择条：竖栈，现只剩写给区（心情条第 27 项、天气条补缺 P2-20 已先后脱离栈）；
        // 全藏时栈高为 0，不占位。左右与工具栏同宽（跟随居中 608）。
        toolStripStack.axis = .vertical
        toolStripStack.spacing = 0
        toolStripStack.alignment = .fill
        toolStripStack.translatesAutoresizingMaskIntoConstraints = false
        // 92 包整页列宽：贴边约束与居中约束二选一，由 updateColumnConstraints 按宽切换
        //（个人主页同款：lazy 式成对约束、状态变化时才切换）。居中约束初始不激活。
        // 窄屏分支：左右锚横向安全区（非 view 边缘）——竖屏安全区左右 inset 为 0，
        // 故竖屏几何不变；横屏（刘海/主屏幕指示器侧边 inset）与 iPad 窄分屏时，
        // 顶栏按钮、滚动内容、工具栏不再贴到安全区外。宽 ≥821 的居中约束不动。
        topBarLeadingConstraint = topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        topBarTrailingConstraint = topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        toolbarLeadingConstraint = toolbarContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        toolbarTrailingConstraint = toolbarContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        scrollLeadingConstraint = scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        scrollTrailingConstraint = scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        topBarCenterXConstraint = topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        topBarWidthConstraint = topBar.widthAnchor.constraint(equalToConstant: 640)
        toolbarCenterXConstraint = toolbarContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        toolbarWidthConstraint = toolbarContainer.widthAnchor.constraint(equalToConstant: 608)
        scrollCenterXConstraint = scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        scrollWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: 640)
        // 顶部 @ 行高约束先建好（初值 0、不占位），显隐由 refreshMentionTopRow 改它；
        // 约束在 buildLayout 建、样式在 buildMentionTopRow 建，首帧布局前两者都已就位。
        mentionTopRowHeightConstraint = mentionTopRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarLeadingConstraint!,
            topBarTrailingConstraint!,
            // v6：顶栏高 60，发布钮 36 居中后底部到分界线净留白 12（见 buildTopBar）。
            topBar.heightAnchor.constraint(equalToConstant: 60),
            // 顶部 @ 行：顶栏下方固定行（无收件人时高 0、不占位），滚动区顶锚它；
            // 左右跟滚动区走（居中 640 列下自动跟随），不另建列约束。
            mentionTopRow.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            mentionTopRow.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            mentionTopRow.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            mentionTopRowHeightConstraint!,
            scrollView.topAnchor.constraint(equalTo: mentionTopRow.bottomAnchor),
            toolbarBottomToKeyboardConstraint!,
            toolStripStack.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolStripStack.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            // 2026-10-31：选择条底直接贴工具栏顶（原贴限时行顶，行已删）。
            toolStripStack.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor),
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
        // 顶部 @ 行不在内容栈里：出现时 sheet 高另加它（面板打开时走视口档，不到此处）。
        let mentionTopHeight = mentionTopRow.isHidden ? 0 : Self.mentionTopRowHeight
        let total = fitted.height + 60 + toolbarHeight + mentionTopHeight
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
        // 全屏页左上角统一左箭头：此前是 plain X 叉叉，现改 icon_back 24pt
        // 墨色（深色反白走 ink 动态色）、44pt 热区；VoiceOver 读“返回”。
        // 行为不变：引用面板打开时本钮只退面板，见 setQuotePanelOpen；
        // 面板关着时点按仍走 didTapCancel 原取消流程（存草稿/清临时文件）。
        cancelButton.setTitle(nil, for: .normal)
        cancelButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        cancelButton.tintColor = BearyColors.ink
        cancelButton.accessibilityLabel = "返回"
        cancelButton.contentEdgeInsets = .zero
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        titleLabel.text = isEditMode ? "编辑日记" : "新日记"
        // 审计-编辑器详情：顶栏标题走 Dynamic Type（正文标题输入框此前已
        // 走 scaledFont，此处补顶栏标题一处；窄屏压缩优先级 749 不动）。
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        // v6-2：标题靠左对齐、紧贴叉叉右侧 8pt，不再居中（v3 左右钮之间居中口径已推翻，不实施）。
        titleLabel.textAlignment = .left
        // L10：标题允许截断（单行尾部省略），不与左右钮重叠见下方不等式。
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        // 窄屏 5 项之 2：顶栏标题是明确的压缩项（749，低于按钮组）。
        // 旧口径把标题抗压钉死 required：320pt 下标题＋固定宽按钮组＋发布显式宽
        // 已超宽，required 对 required 成约束冲突、系统任意破一条，按钮会被
        // 截断或横向跳动。标题降到 749 后窄屏只压标题（单行尾截断、不断到
        // 看不见），草稿 pill（required）与可见性钮（下文 required）与发布显式宽
        // 全数保全；常态宽度够用时标题完整显示，布局语义不变。
        titleLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        // 发布：墨底白字 pill + 发送图标（网页 obtn p）；禁用时按网页口径：无底灰字。
        publishButton.setTitle(isEditMode ? "保存" : "发布", for: .normal)
        // 按钮普查：36 高固定容器，标题走 cappedFont（上限 20，工厂紧凑款同款口径），
        // 默认字号下与原 14 一致，超大字号档不再被固定高度裁剪。
        publishButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14))
        publishButton.titleLabel?.adjustsFontForContentSizeCategory = true
        publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 24), for: .normal)
        // 顶栏右上角三钮收紧（2026-10-31 真机报间距偏大）：发布 pill 左右内边距 12 → 10，
        // 宽度重算读 live 边距（refreshPublishButtonWidth），spinner 前沿同步 12 → 10，见下。
        publishButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
        // v6-4：发布钮高 44 → 36、pill 圆角随高取半 18；顶栏高 60 居中后底部到分界线净留白 12。其余样式与行为不动。
        publishButton.layer.cornerRadius = BearyCorners.single
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
            publishRingView.leadingAnchor.constraint(equalTo: publishButton.leadingAnchor, constant: 10),
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
        visibilityButton.accessibilityHint = "点开菜单选择私密、仅好友、公开、限时"
        // 12b：点开菜单直选，取代 #596 的点按四态循环（循环入口整段删除，不留两套入口）。
        // 系统 UIMenu（不自绘）：菜单内容由 refreshVisibilityButton 按当前档重建，当前档打勾。
        visibilityButton.menu = makeVisibilityMenu()
        visibilityButton.showsMenuAsPrimaryAction = true
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
            // 顶栏右上角三钮间距（样式规格定版）：钮间 gap 统一 8（草稿—可见性、可见性—发布、
            // 编辑态草稿—发布同口径）；右沿留白仍 16，与左沿关闭钮对称口径不变。
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
        // 纯图标固定 44，宽度由 refreshDraftPillWidth 钉死，不再按标题/计数重算（审计第 25 项）。
        let draftPillWidth = draftPillButton.widthAnchor.constraint(equalToConstant: 0)
        draftPillWidth.isActive = true
        draftPillWidthConstraint = draftPillWidth
        refreshDraftPillWidth()
        refreshVisibilityButton()
        // 草稿 pill 抗压钉死（2026-10-29）：99 包真机上 pill 在工具栏右端完全不渲染，
        // 静态排查已排除隐藏/移除/宽度为 0/溢出；剩余疑似布局引擎在某次布局中压没了它，
        // 故把水平抗压提到 required，让标题先截断而不是 pill 被压没。
        draftPillButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 窄屏 5 项之 2：可见性钮同为固定 44 图标钮，抗压亦钉死，与草稿 pill
        // 同口径——窄屏先压的只能是已降到 749 的标题，不是图标钮。
        visibilityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// 发布钮显式宽度（点赞钮同款修法）：UIButton 固有宽不含 titleEdgeInsets，
    /// 前沿自由的按钮按固有宽给帧时，标题会被左边距吃掉尾部（常态 6pt、发布中态 24pt，
    /// 后者会把“发布中…”裁成残字）。宽度按实测字宽重算：左右 content 边距 +
    /// 图宽 + 左右 title 边距 + 字宽；发布中态图为 nil、title 左边距取 publishSpinnerTitleInset 已含 spinner 位。
    /// 窄屏 5 项之 2：预留稳定宽度＝常态宽与忙态宽取大（与当前态无关重算，
    /// 不读 live 标题／图标，忙态切换时宽约束常量不再变、顶栏不再横向跳动；
    /// 代价是常态 pill 比文字宽约一格忙态增量，内容居中、仍是同一 pill，不改常态语义）。
    private func refreshPublishButtonWidth() {
        // 审计补漏：宽度按标题实际字体算（标题走 cappedFont 上限 20pt，
        // 原写死 14pt 量出的“发布中…”比大字号下实际窄约三分之一，pill 会裁标题）。
        let font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14))
        func textWidth(_ text: String) -> CGFloat {
            return ceil((text as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width)
        }
        let contentLeft = publishButton.contentEdgeInsets.left
        let contentRight = publishButton.contentEdgeInsets.right
        let titleRight = publishButton.titleEdgeInsets.right
        let normalTitle = isEditMode ? "保存" : "发布"
        let busyTitle = isEditMode ? "保存中…" : "发布中…"
        let sendImageWidth = BearyIconImages.image(named: "icon_send", pointSize: 24)?.size.width ?? 24
        let normalWidth = contentLeft + sendImageWidth + 6 + textWidth(normalTitle) + titleRight + contentRight
        let busyWidth = contentLeft + Self.publishSpinnerTitleInset + textWidth(busyTitle) + titleRight + contentRight
        publishWidthConstraint?.constant = max(normalWidth, busyWidth)
    }

    /// 发布钮外观跟随启用态（updatePublishState 只改 isEnabled，这里同步颜色/底色）。
    private func refreshPublishAppearance() {
        // 审计-编辑器详情：视觉禁用态与 VoiceOver 同步——只按 isEnabled
        // 挂/摘 .notEnabled，不按外观。空正文现为真禁用（见 updatePublishState），
        // 禁用态带 .notEnabled 与事实一致（旧 U13 可点置灰分支已随真禁用删除）。
        if publishButton.isEnabled {
            publishButton.accessibilityTraits.remove(.notEnabled)
        } else {
            publishButton.accessibilityTraits.insert(.notEnabled)
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

    // 109：标题输入区见 buildHeadlineField（内容栈首项）；进页聚焦默认
    // 仍只走正文 textView（见 viewDidAppear），标题框点按聚焦、回车跳正文。

    /// 109 标题输入区（新写）：内容栈首项。单行 UITextView + 底部细线，
    /// 回车跳正文；输入变化即走草稿防抖保存（与正文同流），不另起定时器。
    private func buildHeadlineField() {
        headlineWrap.translatesAutoresizingMaskIntoConstraints = false
        headlineField.translatesAutoresizingMaskIntoConstraints = false
        headlinePlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineClearButton.translatesAutoresizingMaskIntoConstraints = false
        headlineRule.translatesAutoresizingMaskIntoConstraints = false
        headlineField.font = headlineFont
        headlineField.textColor = BearyColors.ink
        headlineField.backgroundColor = UIColor.clear
        headlineField.textContainerInset = UIEdgeInsets.zero
        headlineField.textContainer.lineFragmentPadding = 0
        // 单行口径：容器宽钉死为超大值、不跟随视图宽，文字只沿一行横向走，
        // 超长时框内横向滚动（原 UITextField 同款行为）；换行在 delegate 里拦。
        headlineField.textContainer.widthTracksTextView = false
        headlineField.textContainer.size = CGSize(width: 10000, height: 64)
        headlineField.isScrollEnabled = true
        headlineField.showsHorizontalScrollIndicator = false
        headlineField.showsVerticalScrollIndicator = false
        headlineField.returnKeyType = .next
        headlineField.delegate = self
        headlineField.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
        headlinePlaceholderLabel.text = "给这篇日记起个标题（可选）"
        headlinePlaceholderLabel.font = headlineFont
        headlinePlaceholderLabel.textColor = BearyColors.gray
        headlinePlaceholderLabel.isUserInteractionEnabled = false
        // 窄屏 5 项之 5：标题清除钮改官方 beary-ui icon_close（16pt，与位置
        // 清除钮同口径），不再混用 SF Symbol xmark.circle.fill——本文件内
        // 关闭类图标至此一律 icon_close，不补新资产、不自绘。
        headlineClearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 16), for: .normal)
        headlineClearButton.tintColor = BearyColors.gray
        headlineClearButton.isHidden = true
        headlineClearButton.addTarget(self, action: #selector(clearHeadline), for: .touchUpInside)
        headlineRule.backgroundColor = BearyColors.line
        headlineWrap.addSubview(headlineField)
        headlineWrap.addSubview(headlinePlaceholderLabel)
        headlineWrap.addSubview(headlineClearButton)
        headlineWrap.addSubview(headlineRule)
        contentStack.addArrangedSubview(headlineWrap)
        headlineHeightConstraint = headlineField.heightAnchor.constraint(equalToConstant: max(28, ceil(headlineFont.lineHeight) + 2))
        NSLayoutConstraint.activate([
            headlineField.topAnchor.constraint(equalTo: headlineWrap.topAnchor),
            headlineField.leadingAnchor.constraint(equalTo: headlineWrap.leadingAnchor),
            headlineField.trailingAnchor.constraint(equalTo: headlineWrap.trailingAnchor),
            headlineHeightConstraint!,
            headlinePlaceholderLabel.topAnchor.constraint(equalTo: headlineField.topAnchor),
            headlinePlaceholderLabel.leadingAnchor.constraint(equalTo: headlineField.leadingAnchor),
            headlinePlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: headlineWrap.trailingAnchor),
            headlineClearButton.trailingAnchor.constraint(equalTo: headlineWrap.trailingAnchor),
            headlineClearButton.centerYAnchor.constraint(equalTo: headlineField.centerYAnchor),
            headlineClearButton.widthAnchor.constraint(equalToConstant: 22),
            headlineClearButton.heightAnchor.constraint(equalToConstant: 22),
            headlineRule.topAnchor.constraint(equalTo: headlineField.bottomAnchor, constant: 6),
            headlineRule.leadingAnchor.constraint(equalTo: headlineWrap.leadingAnchor),
            headlineRule.trailingAnchor.constraint(equalTo: headlineWrap.trailingAnchor),
            headlineRule.heightAnchor.constraint(equalToConstant: 1),
            headlineRule.bottomAnchor.constraint(equalTo: headlineWrap.bottomAnchor),
        ])
        // 审计三轮第 2 项：命中钮不进 headlineWrap（44 高以标题行为中心会伸出 wrap
        // 上沿、命中又被 wrap 边界裁掉），改浮在内容栈上层，右缘与视觉钮对齐，
        // 全 44×44 都在内容栈内可点；视觉钮只留样子，读屏元素只留命中钮。
        headlineClearHitButton.translatesAutoresizingMaskIntoConstraints = false
        headlineClearHitButton.addTarget(self, action: #selector(clearHeadline), for: .touchUpInside)
        headlineClearHitButton.accessibilityLabel = "清除标题"
        headlineClearButton.isAccessibilityElement = false
        contentStack.addSubview(headlineClearHitButton)
        NSLayoutConstraint.activate([
            headlineClearHitButton.trailingAnchor.constraint(equalTo: headlineClearButton.trailingAnchor),
            headlineClearHitButton.centerYAnchor.constraint(equalTo: headlineClearButton.centerYAnchor),
            headlineClearHitButton.widthAnchor.constraint(equalToConstant: 44),
            headlineClearHitButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        contentStack.setCustomSpacing(10, after: headlineWrap)
    }

    @objc private func clearHeadline() {
        headlineField.attributedText = NSAttributedString()
        headlineField.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
        headlineDidChange()
    }

    /// 标题占位与清除钮：占位只在空标题时显；清除钮只在编辑中且非空时显，
    /// 显时正文右留 44pt 不让末字被 44pt 命中钮盖住（原 28pt 只够 22pt 视觉钮）。
    private func refreshHeadlineChrome() {
        let empty = (headlineField.attributedText?.length ?? 0) == 0
        headlinePlaceholderLabel.isHidden = !empty
        let showClear = headlineField.isFirstResponder && !empty
        headlineClearButton.isHidden = !showClear
        headlineClearHitButton.isHidden = !showClear
        headlineField.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: showClear ? 44 : 0)
    }

    /// 标题回填/清空统一入口：纯文本记号转回熊脸附件（换行压成空格保单行），
    /// 之后 typingAttributes 复位，免得附件后的打字跟了附件字体。
    private func setHeadlineText(_ plain: String?) {
        let text = (plain ?? "").replacingOccurrences(of: "\n", with: " ")
        headlineField.attributedText = BearyText.inlineAttributedText(from: text, font: headlineFont, color: BearyColors.ink, paragraphStyle: nil, dark: headlineIsDark)
        headlineField.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
        refreshHeadlineChrome()
    }

    /// 扫查组（#433，适配 #421 后的 attributed 标题模型）：标题长度按
    /// 服务端口径计——服务端 normalizeEntryTitle 用 JS `[...t].length`
    /// （码点数），Swift `.count` 是字素簇数，两者对 ZWJ 组合表情
    /// （如 👨‍👩‍👧‍👦 计 1 簇、7 码点）、结合符不一致：30 簇内含组合表情时
    /// 客户端放行、服务端 400 title too long，发布只剩一句通用失败。
    /// 故此处按送往服务端的序列化串（headlineText：附件已还原为记号）
    /// 的 unicodeScalars（= 码点数）计量；截断按簇从尾删，永不拆散一个
    /// 组合表情（prefix(30) 按簇截同样会漏码点，不可用）；若截断点落在
    /// 末尾心情记号内，整条记号一起删，免得记号被截成半截 literal 文本。
    private static func truncatedHeadline(_ text: String) -> String {
        var result = text
        while result.unicodeScalars.count > headlineMaxLength {
            if let range = result.range(of: #"\[mood:[a-z_]+\]$"#, options: .regularExpression) {
                result.removeSubrange(range)
            } else {
                result = String(result.dropLast())
            }
        }
        return result
    }

    private func headlineDidChange() {
        // 审计第 26 项：标题变化（打字、清标题、心情插入、粘贴改写均走这里）
        // 递增编辑版本，使在途的异步草稿恢复不再覆盖已填的标题。
        editorEditVersion += 1
        refreshHeadlineChrome()
        // 组词中的拼音组合串不截断（marked 时不动，落字后再按 30 字封顶），
        // 否则中文输入法组词会被打断。
        if headlineField.markedTextRange == nil {
            let plain = BearyText.inlinePlainText(from: headlineField.attributedText)
            if plain.unicodeScalars.count > Self.headlineMaxLength {
                setHeadlineText(Self.truncatedHeadline(plain))
                headlineField.selectedRange = NSRange(location: headlineField.attributedText?.length ?? 0, length: 0)
                // 112：此前超长直接取 prefix(30) 是静默截断；本轮首次截断给一次 toast。
                showHeadlineLimitToastIfNeeded()
            } else if plain.unicodeScalars.count < Self.headlineMaxLength {
                // 注意是严格 < 30 才重置：截断落点正好 30 不算回落，见标记处注释。
                headlineLimitToastShown = false
            }
        }
        scheduleDraftSave()
    }

    /// 标题聚焦（2026-11-01 Li 定：点标题只聚焦，不做任何页面滚动/跳动）。
    /// 此前“先上滑、0.35 秒后闪回标题行”正是本函数 + 键盘完成回调的
    /// 标题抵消/守卫复查两路打架所致；本支把标题滚动链整段删掉
    /// （快照/代次/延迟复查/抵消/守卫函数/滚动区 delegate 守卫一并清），
    /// 不留半截逻辑。标题本身是单行输入框，聚焦后光标即在可视区内，
    /// 不需要外层滚动兜底；正文聚焦滚动口径一字不动。
    private func headlineDidBeginEditing() {
        lastFocusedComposerInput = .headline
        refreshHeadlineChrome()
    }

    /// 112：标题超限截断提示，本轮只弹一次（见 headlineLimitToastShown 注释）。
    private func showHeadlineLimitToastIfNeeded() {
        guard !headlineLimitToastShown else { return }
        headlineLimitToastShown = true
        showToast(message: "标题最多 30 字")
    }

    private func buildTextArea() {
        buildHeadlineField()
        textView.delegate = self
        textView.font = bodyFont
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
        textView.typingAttributes = [.font: bodyFont, .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraph]
        // caret 锚定同用该倍数（见 BearyBodyTextView.fixedLineHeightMultiple）：光标处
        // 属性 lookup 在输入法提交文本上不可靠，固定倍数优先，防回退居中致光标偏上。
        textView.fixedLineHeightMultiple = bodyLineMultiple
        textView.backgroundColor = UIColor.clear
        textView.layer.cornerRadius = 0
        textView.isScrollEnabled = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        placeholderLabel.text = "写一点，留一点"
        placeholderLabel.font = bodyFont
        placeholderLabel.textColor = BearyColors.alpha(BearyColors.gray, 0.7)
        textView.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textView)
        textView.addSubview(placeholderLabel)
        let textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 140)
        textViewHeightConstraint = textHeightConstraint
        let placeholderTop = placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: bodyFont.ascender * (bodyLineMultiple - 1))
        placeholderTopConstraint = placeholderTop
        NSLayoutConstraint.activate([
            // 自身滚动开启后 textView 无内在高度：先给下限 140（正式修法前原值），
            // 实际高度由 updateTextViewHeight() 随 contentSize 动态更新（下限 140、上限按 sheet 封顶算）。
            textHeightConstraint,
            // 编辑器批同款（基线对齐）：1.7 倍行高把首行基线推到片段顶 + ascender × 倍数，
            // 占位 label 若贴顶 0，其基线会比打出来的字高 ascender × (倍数 − 1)，
            // 空态占位与落字位置对不上；占位顶下移该量，让两者基线重合。
            placeholderTop,
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
        // 2026-11-01 空白根因修：旧口径按底 sheet 封顶（容器高 ×0.88/0.80）
        // 再减顶栏/工具栏/其他区/键盘高算正文高，但编辑器自 92 包起已是
        // .fullScreen 整页（SceneDelegate.configureComposerPresentation），
        // 0.88 系数本身就是 sheet 时代残留；更关键的是正文高只随内容走，
        // 内容栈顶对齐、短于滚动区时，滚动区剩余高度就成了正文末行与
        // 工具栏之间的死空白——键盘收起实测约 114pt、升起实测约 150pt，
        // 与键盘 inset 无关（收起时 inset 已为 0，升起也有空白）。
        // 新口径：正文区撑满滚动区可用高（滚动区帧底已锚工具栏顶、
        // 工具栏底已锚键盘顶，键盘高不再另减，减了就是 double-count）。
        // 内容短时区高 = 可用高，空白变可点按的正文区（点按落光标到末尾）；
        // 内容长时区高仍 = 可用高，超长走正文内层滚动，工具栏始终可见。
        // 下限仍保 140（可用高不足时外层滚动兜底，口径不变）。
        // 撑满口径下 toolbarHeight 不再参与目标计算（滚动区帧高已含工具栏位置），
        // 仅未布局回退分支仍用它。
        let availableHeight = scrollView.bounds.height
        let target: CGFloat
        if availableHeight > 0 {
            target = max(140, availableHeight - othersHeight)
        } else {
            // 未布局时 bounds 为 0：回退旧封顶口径，布局落定后重算纠正。
            let containerHeight = view.window?.bounds.height ?? UIScreen.main.bounds.height
            let windowWidth = view.window?.bounds.width ?? UIScreen.main.bounds.width
            let sheetCap = containerHeight * (windowWidth >= 821 ? 0.80 : 0.88)
            let cap = sheetCap - 60 - toolbarHeight - othersHeight - currentKeyboardHeight
            target = min(max(contentHeight, 140), max(140, cap))
        }
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
    }

    /// 已填入的正文套 1.7 行高（只换呈现属性，不改文字与光标语义；空文本只留 typingAttributes）。
    private func applyBodyLineHeight() {
        let current = textView.attributedText ?? NSAttributedString()
        guard current.length > 0 else { return }
        let savedRange = textView.selectedRange
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.7
        // 只换呈现属性：附件格原样保留（熊脸图不被纯文本重建吃掉），
        // 文字格换正文字体 + 墨色 + 1.7 行高。
        let styled = NSMutableAttributedString()
        let fullString = current.string as NSString
        current.enumerateAttributes(in: NSRange(location: 0, length: current.length), options: []) { attrs, range, _ in
            if attrs[BearyText.inlineMoodKeyAttribute] != nil {
                styled.append(current.attributedSubstring(from: range))
            } else {
                var newAttrs = attrs
                newAttrs[.font] = bodyFont
                newAttrs[.foregroundColor] = BearyColors.ink
                newAttrs[.paragraphStyle] = paragraph
                styled.append(NSAttributedString(string: fullString.substring(with: range), attributes: newAttrs))
            }
        }
        textView.attributedText = styled
        let maxLocation = styled.length
        let location = min(savedRange.location, maxLocation)
        let length = min(savedRange.length, maxLocation - location)
        textView.selectedRange = NSRange(location: location, length: length)
    }

    // 顶部 @ 提示行：顶栏下方固定 44 高行，内一条与底部 chip 同款的 surface2 条
    //（13 字、“提到 昵称”、圆角 pill）；有收件人才出现，写字时不随正文滚动；
    //点按同底部 chip，走 openToolStrip(.recipient)，在选人条里清除/重选；
    //引用面板打开时同其他编辑器 chrome 一并隐藏。
    private func buildMentionTopRow() {
        mentionTopRow.translatesAutoresizingMaskIntoConstraints = false
        mentionTopRow.isHidden = true
        mentionTopPill.translatesAutoresizingMaskIntoConstraints = false
        mentionTopPill.titleLabel?.font = BearyDynamicType.secondaryFont()
        mentionTopPill.titleLabel?.numberOfLines = 1
        mentionTopPill.titleLabel?.lineBreakMode = .byTruncatingTail
        mentionTopPill.setTitleColor(BearyColors.ink, for: .normal)
        mentionTopPill.backgroundColor = BearyColors.surface2
        mentionTopPill.layer.cornerRadius = 999
        mentionTopPill.layer.masksToBounds = true
        mentionTopPill.contentHorizontalAlignment = .left
        mentionTopPill.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        mentionTopPill.addTarget(self, action: #selector(didTapMentionTopRow), for: .touchUpInside)
        mentionTopPill.bearyAddPressFeedback()
        mentionTopRow.addSubview(mentionTopPill)
        NSLayoutConstraint.activate([
            mentionTopPill.leadingAnchor.constraint(equalTo: mentionTopRow.leadingAnchor, constant: 16),
            mentionTopPill.trailingAnchor.constraint(equalTo: mentionTopRow.trailingAnchor, constant: -16),
            mentionTopPill.centerYAnchor.constraint(equalTo: mentionTopRow.centerYAnchor),
            mentionTopPill.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: - @（写给区：仅已选 chip；空态虚线“@ 谁”钮已删，未选时本区塌为 0 高；
    // 只选一人、不可 @ 自己；@ 提醒无按篇开关；编辑模式可改选可清除，见 refreshRecipientRow 编辑分支）

    private func buildRecipientRow() {
        recipientSection.axis = .vertical
        recipientSection.spacing = 8
        recipientSection.alignment = .fill
        recipientLine.axis = .horizontal
        recipientLine.spacing = 8
        recipientLine.alignment = .center
        // 已选 chip：黑白灰新标准改灰底（与内容区 chip 同口径）；原橙 13% 混色已删。
        recipientChipView.backgroundColor = BearyColors.surface2
        recipientChipView.layer.cornerRadius = 15
        recipientChipView.layer.masksToBounds = true
        recipientChipAvatar.contentMode = .scaleAspectFill
        recipientChipAvatar.clipsToBounds = true
        recipientChipAvatar.layer.cornerRadius = 11
        recipientChipAvatar.layer.masksToBounds = true
        recipientChipFallback.font = UIFont.boldSystemFont(ofSize: 12)
        recipientChipFallback.textColor = BearyColors.ink
        // 首字头像占位与页底同色（跟首页 bg 走，深纯黑／浅白），不再铺 surface 灰块。
        recipientChipFallback.backgroundColor = BearyColors.bg
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
        notifyCheckButton.layer.cornerRadius = 4
        notifyCheckButton.layer.masksToBounds = true
        notifyCheckButton.layer.borderWidth = 1
        notifyCheckButton.layer.bearyDynamicBorderColor = BearyColors.line
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

    /// @ 行状态：新建未选 → 区内无内容（高度塌为 0）；新建已选 → chip + ×；
    /// 编辑模式 → 可改选可清除：已清除且未重选 → 区内无内容；已改选 → 新 chip + ×；
    /// 未动 → 原 @ chip + ×；编辑且无 @ → 区内无内容。@ 提醒无按篇开关，通知行一律隐藏。
    private func refreshRecipientRow() {
        if isEditMode {
            notifyGroup.isHidden = true
            if editMentionCleared, selectedRecipient == nil {
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
                recipientChipView.isHidden = false
                recipientChipAvatar.isHidden = true
                recipientChipFallback.isHidden = false
                recipientChipFallback.text = String(name.prefix(1)).uppercased()
                recipientChipName.text = "@" + name
                recipientClearButton.isHidden = false
            } else {
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
                name = handle
            } else {
                name = "用户"
            }
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
        // 键盘已弹起时打开选人器：编辑器键盘高传给选人器做初始抬升——此时切
        // first responder 不发 WillShow，不传则搜索框会被键盘盖住（见选人器
        // applyInitialKeyboardLiftIfNeeded）；键盘没起时传 0，走正常通知路径。
        picker.initialKeyboardHeight = currentKeyboardHeight
        picker.notifyRecipient = self.notifyRecipient
        picker.onPick = { [weak self] user, notify in
            guard let self = self else { return }
            self.selectedRecipient = user
            // iCity：@ 提醒无按篇开关——面板回传的开关值忽略，不进发布请求。
            _ = notify
            self.editMentionCleared = false
            self.refreshRecipientRow()
            // 选完人立即打开写给条：只刷新时 activeToolStrip 仍不是 .recipient，
            // 显隐门控会把整栈藏住、底部 @ 条选完人不出现；openToolStrip 先收框、
            // 置 activeToolStrip = .recipient 再刷新。
            self.openToolStrip(.recipient)
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
        // 左 3pt 线 / surface2 底随共享卡走。头像/名不加回（lite 卡去头像名口径不变）。
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
        for v in [quoteSection, quoteCardWrap, quoteCard, quoteCardRemoveButton, quoteDeletedRow, quoteDeletedLabel, quoteDeletedRemoveButton, quoteUnavailableRow, quoteUnavailableLabel, quoteUnavailableRemoveButton, quoteFetchFailedRow, quoteFetchFailedLabel, quoteFetchFailedRetryButton] {
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
        quoteDeletedRemoveButton.setTitleColor(BearyColors.ink, for: .normal)
        // 按钮普查：裸 13pt 改 scaledFont，跟随系统字号。
        quoteDeletedRemoveButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        quoteDeletedRemoveButton.titleLabel?.adjustsFontForContentSizeCategory = true
        quoteDeletedRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        quoteDeletedRemoveButton.bearyAddPressFeedback()
        quoteDeletedRow.addArrangedSubview(quoteDeletedLabel)
        let deletedSpacer = UIView()
        quoteDeletedRow.addArrangedSubview(deletedSpacer)
        quoteDeletedRow.addArrangedSubview(quoteDeletedRemoveButton)
        quoteDeletedRow.isHidden = true
        // 暂时看不到行（B6，已删行同款布局）：灰字 + “移除”钮，默认隐藏；见 refreshQuoteSection。
        quoteUnavailableRow.axis = .horizontal
        quoteUnavailableRow.spacing = 8
        quoteUnavailableRow.alignment = .center
        quoteUnavailableRow.isLayoutMarginsRelativeArrangement = true
        quoteUnavailableRow.layoutMargins = UIEdgeInsets(top: 16, left: 2, bottom: 14, right: 2)
        quoteUnavailableLabel.text = "引用的日记暂时看不到"
        quoteUnavailableLabel.font = UIFont.systemFont(ofSize: 13)
        quoteUnavailableLabel.textColor = BearyColors.gray
        quoteUnavailableRemoveButton.setTitle("移除", for: .normal)
        quoteUnavailableRemoveButton.setTitleColor(BearyColors.ink, for: .normal)
        quoteUnavailableRemoveButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        quoteUnavailableRemoveButton.titleLabel?.adjustsFontForContentSizeCategory = true
        quoteUnavailableRemoveButton.addTarget(self, action: #selector(didTapRemoveQuote), for: .touchUpInside)
        quoteUnavailableRemoveButton.bearyAddPressFeedback()
        quoteUnavailableRow.addArrangedSubview(quoteUnavailableLabel)
        let unavailableSpacer = UIView()
        quoteUnavailableRow.addArrangedSubview(unavailableSpacer)
        quoteUnavailableRow.addArrangedSubview(quoteUnavailableRemoveButton)
        quoteUnavailableRow.isHidden = true
        // 补拉失败行（已删行同款布局）：灰字 + “重试”钮，默认隐藏；见 refreshQuoteSection。
        quoteFetchFailedRow.axis = .horizontal
        quoteFetchFailedRow.spacing = 8
        quoteFetchFailedRow.alignment = .center
        quoteFetchFailedRow.isLayoutMarginsRelativeArrangement = true
        quoteFetchFailedRow.layoutMargins = UIEdgeInsets(top: 16, left: 2, bottom: 14, right: 2)
        quoteFetchFailedLabel.text = "引用的日记加载失败"
        quoteFetchFailedLabel.font = UIFont.systemFont(ofSize: 13)
        quoteFetchFailedLabel.textColor = BearyColors.gray
        quoteFetchFailedRetryButton.setTitle("重试", for: .normal)
        quoteFetchFailedRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        quoteFetchFailedRetryButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        quoteFetchFailedRetryButton.addTarget(self, action: #selector(didTapRetryEditQuoteFetch), for: .touchUpInside)
        quoteFetchFailedRetryButton.bearyAddPressFeedback()
        quoteFetchFailedRow.addArrangedSubview(quoteFetchFailedLabel)
        let fetchFailedSpacer = UIView()
        quoteFetchFailedRow.addArrangedSubview(fetchFailedSpacer)
        quoteFetchFailedRow.addArrangedSubview(quoteFetchFailedRetryButton)
        quoteFetchFailedRow.isHidden = true
        contentStack.addArrangedSubview(quoteSection)
        quoteSection.addArrangedSubview(quoteCardWrap)
        quoteSection.addArrangedSubview(quoteDeletedRow)
        quoteSection.addArrangedSubview(quoteUnavailableRow)
        quoteSection.addArrangedSubview(quoteFetchFailedRow)
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
    private func refreshQuoteSection() {
        let quote = isEditMode ? lockedQuote : selectedQuote
        // C6：编辑模式引用可改可删（有引用露共享卡 + ×，无引用则本区塌掉）；
        // 引用改走工具栏引用钮；@ 改走工具栏 @ 钮。
        guard let shown = quote else {
            quoteCardWrap.isHidden = true
            quoteDeletedRow.isHidden = true
            quoteUnavailableRow.isHidden = true
            // 补拉失败态（lockedQuote 尚未回填）才露失败行；在途时暂隐防重复点按，
            // 非失败态（新建未选 / 编辑已删引用已清）本行塌掉不留空位。
            quoteFetchFailedRow.isHidden = !(editQuoteFetchFailed && !editQuoteFetchInFlight)
            updatePreferredContentSize()
            return
        }
        if shown.isDeleted {
            // 已删态：不画共享卡（无作者/正文/图片可信），只留灰字行 + “移除”钮；
            // 已删引用仍占槽位（清除后才可经工具栏引用钮再选）。
            quoteCardWrap.isHidden = true
            quoteDeletedRow.isHidden = false
            quoteFetchFailedRow.isHidden = true
            quoteUnavailableRow.isHidden = true
            updatePreferredContentSize()
            return
        }
        if shown.isUnavailable {
            // B6 暂时看不到：不画共享卡（旧预览正文/缩略图已清），只留灰字行 + “移除”钮；
            // 引用 ID 仍占槽位（清除后才可经工具栏引用钮再选；下次恢复重新校验，可恢复）。
            quoteCardWrap.isHidden = true
            quoteDeletedRow.isHidden = true
            quoteFetchFailedRow.isHidden = true
            quoteUnavailableRow.isHidden = false
            updatePreferredContentSize()
            return
        }
        quoteDeletedRow.isHidden = true
        quoteUnavailableRow.isHidden = true
        quoteFetchFailedRow.isHidden = true
        quoteCardWrap.isHidden = false
        // allowThumbs: true 沿用旧编辑器行为——已选引用在本地草稿预览中恒出图；
        // 列表侧的 isPublic/本人门控不适用于编辑器预览（预览不出公开发布）。
        quoteCard.configure(authorName: shown.authorName ?? "", authorAvatar: shown.authorAvatar, content: shown.content, images: shown.images, dims: shown.imgDims, createdAt: shown.createdAt, allowThumbs: true, authorHandle: shown.authorHandle, sourceTappable: false)
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

    /// 引用规则简化存量提示：编辑已公开篇且其引用仍私密时，作者打开编辑器即提示
    /// 三选一（自己来源三项、他人来源两项）。一并公开即时发原日记 visibility=1
    /// 并刷新编辑器内引用态；删除引用只清编辑器态、保存后才落库（与 × 口径一致）；
    /// 保持私密不改任何状态（本实例不再重弹，下次打开编辑器仍会再提示）。
    private func maybePresentStoredQuotePrompt() {
        guard isEditMode, storedQuotePromptShown == false, let host = editingEntry, BearyEphemeral.isEffectivelyPublic(host), let locked = lockedQuote, locked.isDeleted == false, locked.isPublic != true else { return }
        if composerDidAppear == false {
            storedQuotePromptPending = true
            return
        }
        storedQuotePromptShown = true
        storedQuotePromptPending = false
        let mine = BearyQuoteGate.sourceIsMine(isMine: locked.isMine, authorId: locked.authorId)
        BearyQuoteGate.promptStoredPrivateQuote(from: self, sourceIsMine: mine, sourceIsFriendsOnly: locked.visibility == "friends", onPublishTogether: { [weak self] in
            guard let self = self, let current = self.lockedQuote else { return }
            BearyAPI.shared.setVisibility(id: current.entryId, published: 1) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        if let current = self.lockedQuote {
                            self.lockedQuote = SelectedQuote(entryId: current.entryId, content: current.content, createdAt: current.createdAt, authorName: current.authorName, authorAvatar: current.authorAvatar, authorId: current.authorId, isMine: current.isMine, authorHandle: current.authorHandle, images: current.images, isPublic: true, publishAt: current.publishAt, imgDims: current.imgDims, isDeleted: false, visibility: "public", ephemeralUntil: nil)
                        }
                        self.refreshQuoteSection()
                        self.showToast(message: "原日记已公开")
                    case .failure:
                        self.showToast(message: "原日记公开失败，请重试")
                    }
                }
            }
        }, onDeleteQuote: { [weak self] in
            guard let self = self else { return }
            self.lockedQuote = nil
            self.refreshQuoteSection()
            self.showToast(message: "引用已移除，保存后生效")
        }, onKeepPrivate: {})
    }

    // MARK: - 引用面板 qp-mode（网页 qpEnterMode/qpExitMode 同款整编形态：
    // 打开时只留面板、发布钮隐藏、取消变“返回”只退面板、进出保存/恢复滚动位置）

    private func buildQuotePanel() {
        quotePanel.translatesAutoresizingMaskIntoConstraints = false
        // 自定义 tab 条（网页 qp-seg-in）：容器 padding 3、surface2 底、圆角 999；
        // 钮 13.5/600、padding 6/16；选中墨字 + surface 底（网页滑块指示的静态等价），未选灰字无底。
        // R7(a)：tab 条此前无显式高度、高度全靠钮固有高撑开，任一固有高异常即帧
        // 塌陷成 0 高不可见；现给容器显式高度 36（padding 3×2 + 钮高 30，钮上下
        // 内边距 6×2 + 13.5 字高，栈 fill 拉满不裁字）。surface2 为不透明实色
        // （alpha 1），不是透明/玻璃，选中态文字仍为深色 ink，排除渲染不可见。
        // 预览口径：三段等宽 pill（全部 / 赞过 / 收藏），选中墨底白字、未选 surface2 底灰字；
        // 栈直接挂根视图置顶（顶栏底 +10、左右 16、高 36），面板打开时才显示。
        quoteTabStack.translatesAutoresizingMaskIntoConstraints = false
        quoteTabStack.axis = .horizontal
        quoteTabStack.spacing = 8
        quoteTabStack.alignment = .fill
        quoteTabStack.distribution = .fillEqually
        let tabTitles = ["全部", "赞过", "收藏"]
        for title in tabTitles {
            let tabButton = UIButton(type: .system)
            tabButton.translatesAutoresizingMaskIntoConstraints = false
            tabButton.setTitle(title, for: .normal)
            // 按钮普查：36 高 tab 条，标题走 cappedFont（上限 20，工厂紧凑款同款口径）。
            tabButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
            tabButton.titleLabel?.adjustsFontForContentSizeCategory = true
            tabButton.layer.cornerRadius = BearyCorners.single
            tabButton.layer.masksToBounds = true
            tabButton.addTarget(self, action: #selector(didTapQuoteTab(_:)), for: .touchUpInside)
            tabButton.bearyAddPressFeedback()
            quoteTabButtons.append(tabButton)
            quoteTabStack.addArrangedSubview(tabButton)
        }
        refreshQuoteTabs()
        quoteTabStack.isHidden = true
        view.addSubview(quoteTabStack)
        NSLayoutConstraint.activate([
            quoteTabStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            quoteTabStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            quoteTabStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            quoteTabStack.heightAnchor.constraint(equalToConstant: 36),
        ])
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
        quotePanelRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        // 按钮普查：裸 15pt 改 scaledFont，跟随系统字号。
        quotePanelRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        quotePanelRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        quotePanelRetryButton.isHidden = true
        quotePanelRetryButton.addTarget(self, action: #selector(didTapQuotePanelRetry), for: .touchUpInside)
        quotePanelRetryButton.bearyAddPressFeedback()
        quotePanelRows.translatesAutoresizingMaskIntoConstraints = false
        quotePanelRows.axis = .vertical
        quotePanelRows.spacing = 0
        // 112 v2：列表栈底色同页面底色走（浅白、深黑），行底不再另铺灰块。
        quotePanelRows.backgroundColor = BearyColors.bg
        contentStack.addArrangedSubview(quotePanel)
        quotePanel.addSubview(quotePanelSpinner)
        quotePanel.addSubview(quotePanelLoadingLabel)
        quotePanel.addSubview(quotePanelEmptyLabel)
        quotePanel.addSubview(quotePanelRetryButton)
        quotePanel.addSubview(quotePanelRows)
        NSLayoutConstraint.activate([
            // 2026-10-29 第 26 项：列表顶贴导航栏、无顶隙——tab 条顶距面板顶 0
            //（原 10）、行顶距 tab 条底 0（原 4）；左右 16 仍由 contentStack 边距提供，
            // 容器在面板内居中（网页 qp-seg justify-content:center）。
            quotePanelSpinner.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 16),
            quotePanelSpinner.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelSpinner.widthAnchor.constraint(equalToConstant: 20),
            quotePanelSpinner.heightAnchor.constraint(equalToConstant: 20),
            quotePanelLoadingLabel.topAnchor.constraint(equalTo: quotePanelSpinner.bottomAnchor, constant: 8),
            quotePanelLoadingLabel.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelLoadingLabel.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelEmptyLabel.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 16),
            quotePanelEmptyLabel.leadingAnchor.constraint(equalTo: quotePanel.leadingAnchor),
            quotePanelEmptyLabel.trailingAnchor.constraint(equalTo: quotePanel.trailingAnchor),
            quotePanelRetryButton.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 16),
            quotePanelRetryButton.centerXAnchor.constraint(equalTo: quotePanel.centerXAnchor),
            quotePanelRows.topAnchor.constraint(equalTo: quotePanel.topAnchor, constant: 0),
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
    /// R7(a) 复核：选中态文字为深色 ink（非灰/非透明），在 surface2 实色条上可读。
    /// D-G17：网页选中滑块带阴影（0 1px 6px 黑 12% + 0 0 0 1px 黑 4%）；
    /// App 选中钮补同值阴影（单层 shadow 画不出双层，故 1px 环用同色描边近似，
    /// 描边在内侧 1px）；选中态须关 masksToBounds 否则阴影被裁，未选恢复。
    private func refreshQuoteTabs() {
        for tabIndex in 0..<quoteTabButtons.count {
            let tabButton = quoteTabButtons[tabIndex]
            let isSelected = (tabIndex == 0 && quotePanelTab == "timeline") || (tabIndex == 1 && quotePanelTab == "liked") || (tabIndex == 2 && quotePanelTab == "saved")
            // 预览口径：选中墨底 + 背景色字（深浅模式下自动反色），未选 surface2 底灰字，无阴影无描边。
            tabButton.backgroundColor = isSelected ? BearyColors.ink : BearyColors.surface2
            tabButton.setTitleColor(isSelected ? BearyColors.bg : BearyColors.gray, for: .normal)
            tabButton.layer.masksToBounds = true
            tabButton.layer.shadowOpacity = 0
            tabButton.layer.borderWidth = 0
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
            // 引用面板整编态下正文同藏（109：标题输入区同藏，关闭时同恢复）。
            headlineWrap.isHidden = true
            textView.isHidden = true
            imageScrollView.isHidden = true
            toolbarContainer.isHidden = true
            toolStripStack.isHidden = true
            selectedChipsRow.isHidden = true
            imageUndoBar.isHidden = true
            statusRow.isHidden = true
            // 顶部 @ 行同其他编辑器 chrome 一并隐藏（否则会与面板 tab 条重叠）。
            refreshMentionTopRow()
            updateScrollBottomAnchoring()
            refreshImageUndoBar()
            quoteSection.isHidden = true
            // 间隙修复（只动布局）：滚动归零不影响开头已保存的恢复偏移；面板前各区栈间距显式置 0，
            // 否则隐藏区塌掉后残留 customSpacing 会在面板上方留空隙；tab 条显式可见后先落一次布局，
            // 再显示面板，首帧即按无间隙高度算。
            scrollView.contentOffset = CGPoint.zero
            contentStack.setCustomSpacing(0, after: textView)
            contentStack.setCustomSpacing(0, after: imageScrollView)
            contentStack.setCustomSpacing(0, after: statusRow)
            contentStack.setCustomSpacing(0, after: quoteSection)
            quoteTabStack.isHidden = false
            scrollView.contentInset.top = 46
            view.layoutIfNeeded()
            quotePanel.isHidden = false
            // 录屏批 (b)：面板标题不再沿用“新日记”/“编辑日记”，打开前先存原标题。
            quotePanelSavedTitle = titleLabel.text
            titleLabel.text = "选择引用"
            // 全屏左箭头统一：顶栏钮恒为 icon_back、恒读“返回”，面板打开时点它
            // 仍只退面板（didTapCancel 分支不变）；以下两行与初值相同，仅作显式确认。
            cancelButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
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
                self.quoteTabStack.isHidden = true
                self.scrollView.contentInset.top = 0
                self.quotePanel.isHidden = true
                // 面板关闭：行天气播放器停播摘掉（isHidden 不离窗，播放器自身不停）。
                self.clearQuoteWeatherEmotes()
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
                self.headlineWrap.isHidden = false
                self.textView.isHidden = false
                self.toolbarContainer.isHidden = false
                self.selectedChipsRow.isHidden = false
                self.quoteSection.isHidden = false
                // 全屏左箭头统一：退出面板后图标仍是 icon_back（与 buildTopBar
                // 初值一致），不再换回叉叉；行为仍是 didTapCancel 原流程。
                self.cancelButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
                self.cancelButton.accessibilityLabel = "返回"
                self.publishButton.isHidden = false
                self.draftPillButton.isHidden = false
                self.visibilityButton.isHidden = self.isEditMode
                // 间隙修复的关闭恢复：把打开时置 0 的栈间距按 build 时原值还原（其余区同 build 原值）。
                self.contentStack.setCustomSpacing(12, after: self.textView)
                self.contentStack.setCustomSpacing(4, after: self.imageScrollView)
                // 窄屏 5 项之 4：状态行不再无条件复原 isHidden=false＋间距 8——
                // 新建模式倒计时本就隐藏，复原会把 26pt 空白行带回来；经
                // refreshStatusRowVisibility 按倒计时实际显隐恢复（编辑态显示＋8、
                // 新建态隐藏＋0）。
                self.refreshStatusRowVisibility()
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
                    // 关闭恢复时偏移钳制到 ≥ 0：负偏移叠加滞留的顶 inset 会把整块
                    // 内容往下顶（标题行多出空白）；正常态下偏移本就不应为负。
                    let restoredOffset = self.quotePanelSavedScrollOffset
                    self.scrollView.setContentOffset(CGPoint(x: restoredOffset.x, y: max(0, restoredOffset.y)), animated: false)
                }
                // 关闭完成收敛：若某关闭路径绕过了复位导致顶 inset 滞留（如 46pt），
                // 在此强制归 0，避免整块内容被往下顶。
                if self.scrollView.contentInset.top != 0 {
                    self.scrollView.contentInset.top = 0
                }
                self.updatePreferredContentSize()
            }
            if UIAccessibility.isReduceMotionEnabled {
                applyClose()
            } else {
                UIView.animate(withDuration: 0.18, animations: {
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
    /// 2026-10-31：限时行已删，原“锚限时行顶”档并入工具栏档（心情/天气旧条带
    /// 已删、入口只走弹出框，不再为其预留行高；新建态滚动区因此下探 48pt）。
    private func updateScrollBottomAnchoring() {
        let otherStripOpen = activeToolStrip != nil && activeToolStrip != .mood && activeToolStrip != .weather && !quotePanelOpen
        scrollBottomToToolbarConstraint?.isActive = !quotePanelOpen && !otherStripOpen
        scrollBottomToStripConstraint?.isActive = otherStripOpen
        scrollBottomToViewConstraint?.isActive = quotePanelOpen
    }

    /// 12b：编辑器可见性菜单（系统 UIMenu，不自绘新组件；时间线筛子走系统
    /// actionSheet，本处用 UIMenu 因其原生支持当前档打勾，且锚在钮上、iPad 无需另配 popover）。
    /// 四档直选，取代 #596 的点按四态循环；四档文案与图标沿用现行（私密/仅好友/公开/限时，
    /// 锁/双人锁/地球/限时官方图标，不新造样式、不改文案）。
    /// 当前档仍列出，点按即无操作返回（与时间线筛子“当前档点按无操作”口径一致）。
    private func makeVisibilityMenu() -> UIMenu {
        let current = currentVisibilityChoice()
        let items: [(title: String, icon: String, choice: VisibilityChoice)] = [
            ("私密", "icon_lock", .privateTier),
            ("仅好友", "icon_friends_lock", .friendsTier),
            ("公开", "icon_globe", .publicTier),
            ("限时", "icon_limited", .ephemeralTier),
        ]
        let actions = items.map { item in
            UIAction(title: item.title, image: BearyIconImages.image(named: item.icon, pointSize: 24), state: item.choice == current ? .on : .off) { [weak self] _ in
                self?.applyVisibilityChoice(item.choice)
            }
        }
        return UIMenu(title: "可见性", children: actions)
    }

    /// 三旗标折叠成的当前档：限时优先（限时恒公开），其次仅好友，其次公开，其余私密。
    private func currentVisibilityChoice() -> VisibilityChoice {
        if isEphemeral {
            return .ephemeralTier
        } else if selectedVisibilityFriends {
            return .friendsTier
        } else if selectedVisibilityPublished {
            return .publicTier
        } else {
            return .privateTier
        }
    }

    // case 名避开 private/public 关键字（不用反引号转义，省一处解析风险）。
    private enum VisibilityChoice {
        case privateTier, friendsTier, publicTier, ephemeralTier
    }

    /// 菜单选档：只写三旗标，其余逻辑一律不动——发布门禁（didTapPublish 只认
    /// published 档，故仅好友不触发“一并公开”询问）、草稿恢复、快照生成均读旗标；
    /// 限时档 = 公开 + 限时标记（限时开强制公开：published=true、friends=false，
    /// 与仅好友互斥），切他档即清限时标记，不残留到下一篇普通篇。
    /// （“限时开锁定”沿现行语义：限时恒公开、而非钮禁用——现行冻结只看发布在途态，
    /// 限时态本身按钮仍可点开菜单重选，见 refreshPublishingInputFreeze；本支不新增禁用。）
    private func applyVisibilityChoice(_ choice: VisibilityChoice) {
        guard choice != currentVisibilityChoice() else { return }
        switch choice {
        case .privateTier:
            selectedVisibilityPublished = false
            selectedVisibilityFriends = false
            isEphemeral = false
        case .friendsTier:
            selectedVisibilityPublished = false
            selectedVisibilityFriends = true
            isEphemeral = false
        case .publicTier:
            selectedVisibilityPublished = true
            selectedVisibilityFriends = false
            isEphemeral = false
        case .ephemeralTier:
            selectedVisibilityPublished = true
            selectedVisibilityFriends = false
            isEphemeral = true
        }
        refreshVisibilityButton()
        // 批 E：段位切换时位置行副行（公开后他人仅见区级）同步变，防滞后。
        refreshLocationRow()
        scheduleDraftSave()
        if isEphemeral {
            // 行已删，24 小时规则在编辑器内只剩此处一次提示（恢复草稿进限时态不重复提示）。
            showToast(message: "限时：公开 24 小时后自动转私密")
        }
    }

    /// 顶栏可见性钮图标：锁＝私密、双人锁＝仅好友（官方 icon_friends_lock）、地球＝公开、
    /// 限时＝官方 icon_limited
    /// （熊头 + 外围虚线环，#162 落位的 imageset，#272 删限时行时误删、
    /// 本支从 2bb7df9^ 原样恢复，不自绘、不改图形；纠正：不要 icon_clock）；
    /// 可用态只由发布冻结（refreshPublishingInputFreeze）管，本函数不动 isEnabled。
    /// 菜单随钮状态重建：草稿恢复/清空/门禁回写等一切调本函数的路径都会同步菜单打勾。
    private func refreshVisibilityButton() {
        if isEphemeral {
            visibilityButton.setImage(BearyIconImages.image(named: "icon_limited", pointSize: 24), for: .normal)
            visibilityButton.accessibilityValue = "限时"
        } else if selectedVisibilityFriends {
            visibilityButton.setImage(BearyIconImages.image(named: "icon_friends_lock", pointSize: 24), for: .normal)
            visibilityButton.accessibilityValue = "仅好友"
        } else {
            let published = selectedVisibilityPublished
            visibilityButton.setImage(BearyIconImages.image(named: published ? "icon_globe" : "icon_lock", pointSize: 24), for: .normal)
            visibilityButton.accessibilityValue = published ? "公开" : "私密"
        }
        visibilityButton.menu = makeVisibilityMenu()
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
        // 静态性能修复：引用面板回包补账号代次校验（通知页／#759 同款口径，
        // 只读 BearyAPI.shared.authEpoch／authAccountId，不动 SessionManager 私有成员）。
        // 中央 API 路径只门控 401 通知与重试、不丢弃成功回包，切号后到达的旧回包
        // 原先会进回调写缓存；现先校验代次与账号，失配整单丢弃、不渲染、不写缓存。
        let requestEpoch = BearyAPI.shared.authEpoch
        let requestAccountId = BearyAPI.shared.authAccountId
        // B3：赞过/收藏 tab 先取个人页同范围快照作首批预览（见 loadQuotePanelPreview），
        // 再走网络补齐到 50 条并刷新；本人日记 tab 仍只走 .timeline 网络拉取。
        if tab == "liked" || tab == "saved" {
            loadQuotePanelPreview(tab: tab, seq: seq, requestEpoch: requestEpoch, requestAccountId: requestAccountId)
        }
        BearyAPI.shared.fetchEntries(scope: quotePanelScope(), limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 已有新请求在途时转圈归新请求管，旧回包直接丢弃、不抢清。
                guard seq == self.quotePanelSeq, tab == self.quotePanelTab else { return }
                // 账号代次变了、但旧请求仍占着转圈：主动作废并收起加载态，
                // 旧账号缓存一并清掉，不渲染旧账号数据；面板回到当前账号空闲态，
                // 由用户点重试或切 tab 按新账号重拉。
                if requestEpoch != BearyAPI.shared.authEpoch ||
                    requestAccountId != BearyAPI.shared.authAccountId {
                    self.quotePanelSpinner.stopSpinning()
                    self.quotePanelLoadingLabel.isHidden = true
                    self.quotePanelLoading = false
                    self.quotePanelCache.removeAll()
                    return
                }
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
                case .failure(let error):
                    self.quotePanelFailed = true
                    // 引用面板 401 分流：此前失败分支不分错误，面板内既无登录
                    // 回退、重试也只会再撞 401。401（含 /me 专用的 authFailure）
                    // 走统一登录入口 onRequireLogin（与发布 401 同入口，不另起
                    // 登录 UI）；登录后不自动重拉——由用户点面板重试钮或切 tab
                    // 重试当前面板，避免换号后自动把别号的列表顶进当前面板。
                    // 普通网络/业务错误沿用面板重试钮，不弹登录。
                    let loginExpired: Bool
                    switch error {
                    case .unauthorized, .authFailure:
                        loginExpired = true
                    default:
                        loginExpired = false
                    }
                    if loginExpired {
                        self.quotePanelEmptyLabel.text = "登录已失效，请重新登录后重试"
                        self.quotePanelEmptyLabel.isHidden = false
                        self.quotePanelRetryButton.isHidden = false
                        self.onRequireLogin?()
                    } else {
                        self.quotePanelRetryButton.isHidden = false
                    }
                }
            }
        }
    }

    /// B3：引用面板赞过/收藏 tab 的首批预览——读个人页同范围磁盘快照
    /// （BearyProfileCache：本人页 liked/saved 各首屏 20 条，与面板
    /// .liked/.saved 同范围；仅本人页落盘，他人篇不进桶）。有内容即先渲染、
    /// 再等网络补齐到 50 条；快照为空/缺失时不动作，全程走网络。
    /// 预览只渲染、不写 quotePanelCache：网络补齐回包仍是权威，失败时
    /// 预览行保留、重试钮照常出现；网络已回包时预览不再覆盖。
    /// 预览同样排除正在编的自身篇；选中、发布时仍走现有引用可见性检查。
    private func loadQuotePanelPreview(tab: String, seq: Int, requestEpoch: Int, requestAccountId: Int?) {
        guard let uid = SessionManager.shared.currentUser?.id else { return }
        BearyProfileCache.load(bucket: "\(uid)") { [weak self] snap in
            guard let self = self else { return }
            guard seq == self.quotePanelSeq, tab == self.quotePanelTab, self.quotePanelOpen else { return }
            guard requestEpoch == BearyAPI.shared.authEpoch,
                  requestAccountId == BearyAPI.shared.authAccountId else { return }
            // 网络补齐已到（本 tab 缓存已写）时不拿旧快照覆盖新鲜行。
            guard self.quotePanelCache[tab] == nil else { return }
            guard let snap = snap else { return }
            var entries: [Entry] = (tab == "liked") ? snap.liked : snap.saved
            if let selfId = self.editingEntry?.id, !selfId.isEmpty {
                entries = entries.filter { $0.id != selfId }
            }
            guard !entries.isEmpty else { return }
            self.quotePanelSpinner.stopSpinning()
            self.quotePanelLoadingLabel.isHidden = true
            self.renderQuotePanelRows(entries: entries)
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
    /// 112：行内无动作行（无赞/收藏/分享入口），唯一点按目标是整行选引用；
    /// 头行 stack 与分隔线设不可交互、图条点按走同一选篇路径，行内不留
    /// 第二触摸目标（看不见又能点的半截热区）。
    private func renderQuotePanelRows(entries: [Entry]) {
        for arranged in quotePanelRows.arrangedSubviews {
            quotePanelRows.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        // 行重渲染：旧行天气覆盖层随旧行一并离树，此处清掉持有、不留空转播放器。
        clearQuoteWeatherEmotes()
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
            // 占位主句与引用卡新口径一致（私密档“该日记已设为私密”；仅好友档走 10a 定版
            // “该日记仅好友可见”；picker 行无 published_at 可靠区分，不挂“已转”提醒句）。
            let viewerId = SessionManager.shared.currentUser?.id
            let quoteIsAuthor = entry.isMine == true || (entry.authorId != nil && viewerId != nil && entry.authorId == viewerId)
            if !quoteIsAuthor && !BearyEphemeral.isEffectivelyPublic(entry) {
                let lockedButton = UIButton(type: .custom)
                lockedButton.translatesAutoresizingMaskIntoConstraints = false
                lockedButton.isEnabled = false
                // 112 v2：占位行底色同页面底色走，与可选行一致融为一体。
                lockedButton.backgroundColor = BearyColors.bg
                let lockedLabel = UILabel()
                lockedLabel.translatesAutoresizingMaskIntoConstraints = false
                lockedLabel.font = UIFont.systemFont(ofSize: 15)
                lockedLabel.textColor = BearyColors.gray
                lockedLabel.text = entry.isFriendsOnly ? "该日记仅好友可见" : "该日记已设为私密"
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
            // 预览选中态：已选中的引用行（重进面板时）淡橙底 + 右侧橙色对勾；
            // 未选行仍走页面底色。编辑态比 lockedQuote，新建态比 selectedQuote。
            let currentSelectedQuoteId = isEditMode ? lockedQuote?.entryId : selectedQuote?.entryId
            let isSelectedRow = currentSelectedQuoteId != nil && entry.id == currentSelectedQuoteId
            let rowButton = UIButton(type: .custom)
            rowButton.translatesAutoresizingMaskIntoConstraints = false
            // 112 v2：去掉每行外面的灰色方块感——行底色显式走页面底色
            // BearyColors.bg（浅色白、深色跟页面底色黑），整列表只留行间细分割线；
            // 作者、时间、正文、行内边距、分割线、点按选引用行为均不动。
            rowButton.backgroundColor = isSelectedRow ? BearyColors.alpha(BearyColors.ink, 0.08) : BearyColors.bg
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
            avatarFallback.backgroundColor = BearyColors.surface2
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
            // 112：UIStackView 默认可交互，挂在行钮里会截留名/日期区的点按
            // （点按落到 stack 本身、行钮收不到，行内出现点按无反应的半截区）；
            // 行内唯一点按目标是选引用，故头行 stack 本身不可交互，点按透传行钮。
            headerStack.isUserInteractionEnabled = false
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
            // 112 引用列表 v2：状态 pill 放在作者名与时间之后、同一头行；
            // 三态按真实可见性实时取（不写死）：存活期限时 → 虚线边橙字“限时”，
            // 有效公开 → 实线边橙字“公开”，其余 → 实线边蓝字“私密”。
            // 颜色口径走现行三色制（公开橙 #ff9500、私密蓝 #007aff/#0a84ff），不自创新色；
            // 天气图标仍在 pill 之后，名截断优先、pill 不让步。
            let statusPill = BearyQuoteStatusPillView()
            statusPill.translatesAutoresizingMaskIntoConstraints = false
            if BearyEphemeral.isLive(entry) {
                statusPill.configure(text: "限时", style: .limited)
            } else if BearyEphemeral.isEffectivelyPublic(entry) {
                statusPill.configure(text: "公开", style: .public)
            } else {
                statusPill.configure(text: "私密", style: .private)
            }
            statusPill.setContentHuggingPriority(.required, for: .horizontal)
            statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)
            headerStack.addArrangedSubview(statusPill)
            if let weather = entry.weather {
                let weatherView = UIImageView()
                weatherView.translatesAutoresizingMaskIntoConstraints = false
                weatherView.image = BearyIconImages.image(named: "icon_wx_\(BearyText.weatherStaticKey(for: weather))", pointSize: 15)
                weatherView.tintColor = BearyColors.gray
                weatherView.contentMode = .scaleAspectFit
                weatherView.setContentCompressionResistancePriority(.required, for: .horizontal)
                headerStack.addArrangedSubview(weatherView)
                NSLayoutConstraint.activate([
                    weatherView.widthAnchor.constraint(equalToConstant: 15),
                    weatherView.heightAnchor.constraint(equalToConstant: 15),
                ])
                // 引用行天气图标贴动态 Lottie（底层静态图作 fallback；面板关闭／
                // 行重渲染时由 clearQuoteWeatherEmotes 统一停播摘掉）。
                if let staticImage = weatherView.image {
                    let overlay = BearyEmoteView(key: BearyText.weatherLottieKey(for: weather), animated: true, fallbackImage: staticImage)
                    overlay.translatesAutoresizingMaskIntoConstraints = false
                    weatherView.addSubview(overlay)
                    NSLayoutConstraint.activate([
                        overlay.topAnchor.constraint(equalTo: weatherView.topAnchor),
                        overlay.leadingAnchor.constraint(equalTo: weatherView.leadingAnchor),
                        overlay.trailingAnchor.constraint(equalTo: weatherView.trailingAnchor),
                        overlay.bottomAnchor.constraint(equalTo: weatherView.bottomAnchor),
                    ])
                    quoteWeatherEmoteViews.append(overlay)
                }
            }
            // iCity 倒计时 pill 已废，但 112 v2 起选篇行挂状态 pill（见头行 statusPill，
            // 非倒计时）；私密与公开行此前无 pill，现按真实可见性补齐三态。
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
            // 112：同头行 stack——普通 UIView 默认可交互，2pt 分隔线带会截留点按；
            // 行内唯一点按目标是选引用，分隔线不可交互，点按透传行钮。
            separator.isUserInteractionEnabled = false
            rowButton.addSubview(avatarView)
            rowButton.addSubview(avatarFallback)
            rowButton.addSubview(headerStack)
            rowButton.addSubview(contentLabel)
            // 22:44 引用闪退真因：separator 此前只创建未挂载，约束却锚向 rowButton 子树，
            // 无公共祖先致 activate 在首行当场抛错（与条目内容、Plus、天气、图片全无关）；
            // 必须先挂载再激活，否则每渲染必崩。
            rowButton.addSubview(separator)
            if isSelectedRow {
                let checkView = UIView()
                checkView.translatesAutoresizingMaskIntoConstraints = false
                checkView.backgroundColor = BearyColors.ink
                checkView.layer.cornerRadius = 12
                checkView.layer.masksToBounds = true
                checkView.isUserInteractionEnabled = false
                let checkLabel = UILabel()
                checkLabel.translatesAutoresizingMaskIntoConstraints = false
                checkLabel.font = UIFont.boldSystemFont(ofSize: 14)
                checkLabel.textColor = BearyColors.bg
                checkLabel.textAlignment = .center
                checkLabel.text = "✓"
                checkView.addSubview(checkLabel)
                rowButton.addSubview(checkView)
                NSLayoutConstraint.activate([
                    checkView.topAnchor.constraint(equalTo: rowButton.topAnchor, constant: 16),
                    checkView.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: -2),
                    checkView.widthAnchor.constraint(equalToConstant: 24),
                    checkView.heightAnchor.constraint(equalToConstant: 24),
                    checkLabel.centerXAnchor.constraint(equalTo: checkView.centerXAnchor),
                    checkLabel.centerYAnchor.constraint(equalTo: checkView.centerYAnchor),
                ])
            }
            var lastBottomAnchor: NSLayoutYAxisAnchor = contentLabel.bottomAnchor
            var lastBottomConstant: CGFloat = 14
            let entryImages = entry.images ?? []
            if !entryImages.isEmpty {
                let imagesScrollView = UIScrollView()
                imagesScrollView.translatesAutoresizingMaskIntoConstraints = false
                imagesScrollView.showsHorizontalScrollIndicator = false
                // 112：图条是行钮的子视图 UIScrollView，点按默认被滑条截留、
                // 落不到行钮（图区点按无反应）；补点按手势走同一选篇路径，
                // 横滑仍由 pan 手势接管，点按与滑动不冲突——行内从此只有
                // 一个点按结果：选引用，不存在第二触摸目标。
                let stripTap = UITapGestureRecognizer(target: self, action: #selector(didTapQuotePanelImageStrip(_:)))
                imagesScrollView.addGestureRecognizer(stripTap)
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
                    imageView.layer.cornerRadius = BearyCorners.single
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
                headerStack.trailingAnchor.constraint(lessThanOrEqualTo: rowButton.trailingAnchor, constant: isSelectedRow ? -34 : -2),
                contentLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
                contentLabel.leadingAnchor.constraint(equalTo: rowButton.leadingAnchor, constant: 54),
                contentLabel.trailingAnchor.constraint(equalTo: rowButton.trailingAnchor, constant: isSelectedRow ? -34 : -2),
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
                UIView.animate(withDuration: 0.25, delay: min(Double(animIndex) * 0.03, 0.24), options: [], animations: {
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

    /// 112：图条点按 → 按宿主行钮走同一选篇路径（图条是 UIScrollView 子视图，
    /// 点按默认落不到行钮；横滑仍由 pan 接管，点按与滑动不冲突）。
    @objc private func didTapQuotePanelImageStrip(_ gesture: UITapGestureRecognizer) {
        guard let strip = gesture.view, let rowButton = strip.superview as? UIButton else { return }
        selectQuotePanelRow(rowButton)
    }

    @objc private func didTapQuotePanelRow(_ sender: UIButton) {
        selectQuotePanelRow(sender)
    }

    /// 引用行唯一点按结果：选引用。行内不挂赞/收藏/分享等任何动作入口
    /// （lite 行本来就没有动作行；头行 stack 与分隔线另设不可交互，见渲染处，
    /// 点按不再被行内子视图截留或分流）。
    private func selectQuotePanelRow(_ button: UIButton) {
        var picked: Entry?
        for index in 0..<quotePanelRowButtons.count {
            if index < quotePanelRowEntries.count && quotePanelRowButtons[index] == button {
                picked = quotePanelRowEntries[index]
            }
        }
        guard let entry = picked, let entryId = entry.id, let content = entry.content else { return }
        // 预览“再点取消”口径：点已选中的行即取消引用、留在面板里可另选；
        // 点未选中的行仍走现行唯一路径（应用 + 关面板）。不改行内动作（行内本无赞/收藏钮）。
        let currentSelectedQuoteId = isEditMode ? lockedQuote?.entryId : selectedQuote?.entryId
        if currentSelectedQuoteId != nil && entryId == currentSelectedQuoteId {
            if isEditMode {
                lockedQuote = nil
            } else {
                selectedQuote = nil
                saveDraftNow()
            }
            refreshQuoteSection()
            if let cached = quotePanelCache[quotePanelTab] {
                renderQuotePanelRows(entries: cached)
            } else {
                loadQuotePanelTab()
            }
            return
        }
        let quote = SelectedQuote(entryId: entryId, content: content, createdAt: entry.createdAt, authorName: entry.authorName, authorAvatar: entry.authorAvatar, authorId: entry.authorId, isMine: entry.isMine, authorHandle: entry.authorHandle, images: entry.images ?? [], isPublic: BearyEphemeral.isEffectivelyPublic(entry), publishAt: entry.publishAt, imgDims: entry.imgDims, isDeleted: false, visibility: entry.visibility, ephemeralUntil: entry.ephemeralUntil)
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

    /// [24] 小项 6：面板行日期统一为项目主流口径 M月d日 H:mm（小时不补零；
    /// 旧注“与网页 fmtDate 同款”有误：卡片/详情/通知/时间线引用一律 H:mm，
    /// 本处原 HH:mm 是唯一偏离的日记日期行，已改齐）。
    private func quoteRowDate(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 H:mm"
        return fmt.string(from: date)
    }

    // MARK: - 图片预览（网页 img-preview：无标题、无 + 块，空时整条隐藏）

    private func buildImageRow() {
        imageScrollView.showsHorizontalScrollIndicator = false
        imageScrollView.delaysContentTouches = false
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
        // 第 7 轮属实项 4：六个工具钮均为 24 视觉 + BearyHit44Button（每侧向外扩 10 至 44 热区），
        // 工具间中心距须 ≥44 才零重叠。原间距 16 → 中心距 24+16=40、重叠 44+44−40=4pt，
        // 重叠带按 hitTest 顺序归后一个钮。现间距 20 → 中心距 24+20=44、重叠 44+44−44=0。
        // 只动本行间距：视觉仍 24、Hit44 定义不动、不改全局样式 token、不收进菜单。
        // 109 的 16 是为挤草稿文案微收的旧值；窄屏文案保全改由 applyDraftStatusToolbarFit
        // 只切文案显隐、不再反向收工具间距（收间距即重现重叠）。
        toolRow.spacing = 20
        toolRow.alignment = .center
        imageToolButton.setImage(BearyIconImages.image(named: "icon_image", pointSize: 24), for: .normal)
        // P1-26：工具栏图标钮按功能命名（图标本身无文字，VoiceOver 否则无读法）。
        imageToolButton.accessibilityLabel = "添加图片"
        // D-G7：网页 .icon-btn 默认墨色（editor-tools 的 .nb 灰规则不适用这三个钮），工具钮灰改墨。
        imageToolButton.tintColor = BearyColors.ink
        imageToolButton.addTarget(self, action: #selector(didTapAddImage), for: .touchUpInside)
        imageToolButton.bearyAddPressFeedback()
        // 批 E：定位钮插在图片钮右边、心情钮之前（左组顺序：图片 → 定位 → 心情 → 天气 → @ → 引用）。
        locationToolButton.setImage(BearyLocationIcon.image(pointSize: 24), for: .normal)
        locationToolButton.accessibilityLabel = "添加位置"
        locationToolButton.tintColor = BearyColors.ink
        locationToolButton.addTarget(self, action: #selector(didTapLocationTool), for: .touchUpInside)
        locationToolButton.bearyAddPressFeedback()
        moodToolButton.setImage(BearyIconImages.image(named: "icon_mood", pointSize: 24), for: .normal)
        moodToolButton.accessibilityLabel = "选择心情"
        moodToolButton.tintColor = BearyColors.ink
        moodToolButton.addTarget(self, action: #selector(didTapMoodTool), for: .touchUpInside)
        moodToolButton.bearyAddPressFeedback()
        // 天气钮图标随选中天气变（见 syncWeatherToolButton，网页 syncWxBtn 同款同步）。
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
        for button in [imageToolButton, locationToolButton, moodToolButton, weatherToolButton, recipientToolButton, quoteToolButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        // 容器已由 buildLayout 加到 view 顶栏下方（固定），这里不再进内容栈。
        toolbarContainer.addSubview(toolbarSeparator)
        // 窄屏 5 项之 3：草稿状态独立行（工具栏上方、工具行之上）：文案＋重试钮，
        // 平时隐藏＋0 高（见 setDraftStatusBannerVisible），只在 level 0／1 时启用；
        // 文案与 draftStatusLabel 同源（见 updateDraftStatusLabel），重试只重跑
        // saveDraftNow（见 didTapDraftStatusRetry），不另起保存语义；重试钮只在
        // 写盘失败（level 0）时显示，图片未保存（level 1）时隐藏（见
        // applyDraftStatusToolbarFit，P1-8：重跑保存救不回图，失败图点图片重试）。
        draftStatusBanner.axis = .horizontal
        draftStatusBanner.spacing = 8
        draftStatusBanner.alignment = .center
        draftStatusBanner.translatesAutoresizingMaskIntoConstraints = false
        // P2-12：说明行跟随系统字号（captionFont = 12 regular scaled，规范 §11），
        // 宽度不足时换行、不截尾；横向抗压降到 749（与 draftStatusLabel 同款），
        // 大字号下说明先让宽换行、重试钮（required）另排保全——两者同为 required
        // 时超宽无解、系统任意破一条。横幅高约束显示时即停用（见
        // setDraftStatusBannerVisible），换行可长高。
        draftStatusBannerLabel.font = BearyDynamicType.captionFont()
        draftStatusBannerLabel.adjustsFontForContentSizeCategory = true
        draftStatusBannerLabel.numberOfLines = 0
        draftStatusBannerLabel.lineBreakMode = .byWordWrapping
        draftStatusBannerLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        draftStatusRetryButton.setTitle("重试", for: .normal)
        draftStatusRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        // P2-12：重试钮 13 semibold 跟随系统字号（原字号为默认基准）。
        draftStatusRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        draftStatusRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        draftStatusRetryButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        draftStatusRetryButton.accessibilityLabel = "重试保存草稿"
        draftStatusRetryButton.addTarget(self, action: #selector(didTapDraftStatusRetry), for: .touchUpInside)
        draftStatusRetryButton.bearyAddPressFeedback()
        draftStatusRetryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        draftStatusBanner.addArrangedSubview(draftStatusBannerLabel)
        draftStatusBanner.addArrangedSubview(UIView())
        draftStatusBanner.addArrangedSubview(draftStatusRetryButton)
        draftStatusBanner.isHidden = true
        toolbarContainer.addSubview(draftStatusBanner)
        toolbarContainer.addSubview(toolRow)
        toolRow.addArrangedSubview(imageToolButton)
        toolRow.addArrangedSubview(locationToolButton)
        toolRow.addArrangedSubview(moodToolButton)
        toolRow.addArrangedSubview(weatherToolButton)
        toolRow.addArrangedSubview(recipientToolButton)
        toolRow.addArrangedSubview(quoteToolButton)
        // v6-5：字数圆环并进左侧图标组——不再被 spacer 顶到右端；圆环本身不是按钮，
        // 与引用钮之间无热区重叠问题，故引用→圆环用自定义间距 8（见下方 setCustomSpacing），
        // 不占 toolRow.spacing 的 20；数字已隐藏，只留圆环。
        // v6-6：正文区草稿保存文案组（draftStatusGroup，图标＋文案＋级别逻辑全在 buildStatusRow/
        // updateDraftStatusLabel）挪到工具栏右端（spacer 之后）；109：已保存态文案优先保全、
        // 320 宽兜底只留对勾（见 applyDraftStatusToolbarFit），不再先截断。组本身在 buildStatusRow
        // 里才配好轴向与子项，此处只定它在工具栏里的位置。
        charGroupStack.axis = .horizontal
        charGroupStack.spacing = 6
        charGroupStack.alignment = .center
        charGroupStack.translatesAutoresizingMaskIntoConstraints = false
        charRingView.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.translatesAutoresizingMaskIntoConstraints = false
        charCountLabel.isHidden = true  // 数字平时隐藏，只留圆环（超限时 updateCountLabel 显红字计数，见该函数）。
        charGroupStack.addArrangedSubview(charRingView)
        charGroupStack.addArrangedSubview(charCountLabel)
        toolRow.addArrangedSubview(charGroupStack)
        let spacer = UIView()
        toolRow.addArrangedSubview(spacer)
        toolRow.addArrangedSubview(draftStatusGroup)
        // 第 7 轮属实项 4：只有 5 段工具钮之间的间距参与热区重叠，须为 20（toolRow.spacing）。
        // 其余 3 段不夹两个热区，可收窄以保窄屏装得下，spacer 本身吸 slack：
        // 引用→圆环 8（圆环不可点），圆环→spacer 0、spacer→草稿组 0。
        // 按此算：320 宽容器 288 时只留对勾态总宽 = 6×24 + 5×20 + 8 + 18 + 15 = 285 ≤ 288。
        toolRow.setCustomSpacing(8, after: quoteToolButton)
        toolRow.setCustomSpacing(0, after: charGroupStack)
        toolRow.setCustomSpacing(0, after: spacer)
        toolbarToolRow = toolRow
        // U3：初始间距 20 同步六钮横向热区 cap（= 间距 / 2 = 10，相邻热区相接不叠）。
        setToolbarToolRowSpacing(toolRow.spacing, in: toolRow)
        // 窄屏 5 项之 3：工具行顶锚两档——独立行隐藏时锚分隔线（原 12 间距），
        // 独立行显示时锚独立行底（8 间距）；两档互斥切换，见
        // setDraftStatusBannerVisible（只在显隐翻转时切换，不成布局环）。
        let toolRowTopToSeparator = toolRow.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor, constant: 12)
        toolRowTopToSeparator.isActive = true
        toolbarToolRowTopToSeparatorConstraint = toolRowTopToSeparator
        toolbarToolRowTopToBannerConstraint = toolRow.topAnchor.constraint(equalTo: draftStatusBanner.bottomAnchor, constant: 8)
        let bannerHeight = draftStatusBanner.heightAnchor.constraint(equalToConstant: 0)
        bannerHeight.isActive = true
        draftStatusBannerHeightConstraint = bannerHeight
        NSLayoutConstraint.activate([
            toolbarSeparator.topAnchor.constraint(equalTo: toolbarContainer.topAnchor),
            toolbarSeparator.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolbarSeparator.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolbarSeparator.heightAnchor.constraint(equalToConstant: 1),
            draftStatusBanner.topAnchor.constraint(equalTo: toolbarSeparator.bottomAnchor, constant: 8),
            draftStatusBanner.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            draftStatusBanner.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolRow.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            toolRow.bottomAnchor.constraint(equalTo: toolbarContainer.bottomAnchor, constant: -6),
            // 审计三轮第 1 项：工具行高至少 44——此前行高由 24pt 钮撑着只有 24，
            // Hit44 向外扩的 10pt 超出栈边界、命中测试到不了；行高 44 后扩区全在行内，
            // 图标仍 24；第 7 轮属实项 4：工具间距 16→20（见 buildToolbarRow 开头），
            // 窄屏保全逻辑（applyDraftStatusToolbarFit）只切文案显隐、不再收间距。
            toolRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // 编辑模式：无草稿流，但 pill 可见（DF-3：网页 openDraftBox 在 editingId 时
        // 直接 return，pill 可见但点开无动作；didTapDraftBox 编辑态已直接 return，
        // 故这里不再隐藏 pill）；引用钮保留（C6：编辑模式引用可改可删）。
        // 工具栏已不在内容栈里，不再设栈间距（旧 setCustomSpacing 已删）。
    }

    /// 审计第 25 项：草稿钮已是纯图标（v6-3），计数不再画在钮上，真实计数
    /// 只在草稿箱内可见、由草稿箱自己读取——编辑器侧不再为 pill 读整库：
    /// updateDraftPillCount（ioQueue 整库读 + loadAll().count）与
    /// setDraftPillCount（参数已不使用、只调宽度刷新）整段删除，
    /// 各调用点直接刷固定按钮规格。草稿保存/读取语义本身一字不动；
    /// saveDraftNow 回读循环仍保留——它用于确认本篇是否落盘成功，
    /// 不是 pill 计数（见该处注释）。
    /// 草稿钮显式宽度（v6 纯图标版）：固定 44，与图标热区一致；旧“按标题算宽”
    /// 口径随文字 pill 一并作废（标题算宽曾把 pill 压成“...”的历史教训不再适用）。
    private func refreshDraftPillWidth() {
        draftPillWidthConstraint?.constant = 44
    }

    /// C1：引用唯一入口（工具栏引用钮）开关 qp-mode 面板（C6：编辑模式也可改引用，不再早退）。
    @objc private func didTapQuoteTool() {
        // 编辑器改版：弹出框打开时点其他工具钮，先收起框再走各自处理。
        // 审计 1：切到引用工具时，在途的天气展示意图作废。
        invalidatePendingCalloutPresentation()
        hideCallout(animated: false)
        hideLocationPopover(animated: false)
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

    /// 选择条显隐总口：栈内只剩写给区（心情/天气旧条带已删，入口只走尖角弹出框）；
    /// 面板打开时整栈隐藏。审计 P1-8：显隐不再瞬切——入场先现身再淡入位移归位，
    /// 出场先淡出位移、动画跑完才 isHidden。快速连点：新转场 beginFromCurrentState
    /// 从当前呈现值接管、代次 +1 使旧 completion 作废，只收敛到最后状态；
    /// 减动效与未挂窗（首帧）直接置终值，不播动画。引用面板打开时的瞬藏走
    /// setQuotePanelOpen 专属路径（面板盖住条带、无可见转场），此处不动它。
    private func refreshToolStrip() {
        // 编辑器改版（2026-10-29）：心情/天气旧条已由尖角弹出框取代；
        // 本支删除旧条带后栈内只剩写给区。2026-10-31：限时行底锚三档随行删除
        //（选择条底已直贴工具栏顶）。
        let stackHidden = quotePanelOpen || activeToolStrip != .recipient
        // iCity：编辑模式 @ 可新增——无 @ 时条内无内容（高度塌为 0），不再整区隐藏；
        // 其余态按条开关显隐。
        recipientSection.isHidden = activeToolStrip != .recipient
        updateScrollBottomAnchoring()
        refreshSelectedChips()
        if UIAccessibility.isReduceMotionEnabled || view.window == nil {
            toolStripTransitionGeneration += 1
            toolStripStack.isHidden = stackHidden
            toolStripStack.alpha = 1
            toolStripStack.transform = .identity
            updatePreferredContentSize()
            return
        }
        toolStripTransitionGeneration += 1
        let generation = toolStripTransitionGeneration
        let offset = Self.toolStripTransitionOffset
        var exitingViews: [UIView] = []
        var needsAnimation = false
        for (stripView, shouldHide) in [
            (toolStripStack, stackHidden),
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
                for stripView in [self.toolStripStack]
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
        // 审计第 31 项：框外点按与 VoiceOver 逃离是同一用户主动关闭路径，
        // 关闭后把焦点还给触发钮（hideCallout 的 restoreFocus 分支定落点）。
        calloutDismissView.onTapOutside = { [weak self] in self?.hideCallout(animated: true, restoreFocus: true) }
        moodCallout.onAccessibilityEscape = { [weak self] in self?.hideCallout(animated: true, restoreFocus: true) }
        weatherCallout.onAccessibilityEscape = { [weak self] in self?.hideCallout(animated: true, restoreFocus: true) }
        // 23a：心情框与天气框同款，首位补“无”（清除旧心情）选项，键为 "none"，
        // 图为官方 icon_close 原图（weatherNoneImage，40pt 同尺寸）；其余心情项
        // 仍走插入式，不动。
        moodCallout.configure(
            options: [BearyCalloutPickerView.Option(key: "none", accessibilityLabel: "无")] + moodOrder.map { key in
                BearyCalloutPickerView.Option(key: key, accessibilityLabel: "心情：" + (BearyText.moodNames[key] ?? key))
            },
            onSelect: { [weak self] key in self?.didSelectMoodFromCallout(key) },
            imageProvider: { [weak self] key, dark in
                if key == "none" { return self?.weatherNoneImage() }
                return self?.calloutMoodImage(for: key, dark: dark)
            }
        )
        // v6-8：天气框首位补“无”（清除）选项，键为 "none"，图为官方 icon_close 原图
        //（见 weatherNoneImage；大小与其它天气图标一致 40pt、同色墨色模板）。
        // 选中态口径（审计 E2 第 11 项）：已选天气在框内以 1pt 墨色描边标出
        //（见 CalloutPicker refreshSelectedStates）；打开框时按当前 selectedWeather
        // 同步；无天气时无行高亮。
        weatherCallout.configure(
            options: [BearyCalloutPickerView.Option(key: "none", accessibilityLabel: "无")] + weatherOrder.map { key in
                BearyCalloutPickerView.Option(key: key, accessibilityLabel: "天气：" + (BearyText.weatherNames[key] ?? key))
            },
            onSelect: { [weak self] key in self?.didSelectWeatherFromCallout(key) },
            imageProvider: { [weak self] key, _ in
                if key == "none" { return self?.weatherNoneImage() }
                return BearyIconImages.image(named: "icon_wx_\(key)", pointSize: 40)
            },
            // 天气选项贴动态 Lottie（night→moon；"无"不贴，保持静态）。
            emoteKeyProvider: { key in key == "none" ? nil : BearyText.weatherLottieKey(for: key) },
            selectedKey: selectedWeather
        )
        // [24] 小项 2：气温步进器以附属行身份挂进天气框（不进 chip 行），
        // 框内点按步进器不触发框外收起（附属行在收起层之上、与框同层级）。
        weatherCallout.setAccessoryView(tempStepperStack)
        // 审计四轮 09：天气框脚注——精确位置只用于本次天气查询，会发给
        // 服务接口；日记本身只保存地点文字。位置权限说明（Info.plist）
        // 同步补了同一层意思；服务端是否存储坐标客户端看不出来，不断言。
        weatherCallout.setFooterNote("精确位置只用于本次天气查询，会发送至服务接口；日记本身只保存地点文字。")
        // 收起层先加、框后加：框在收起层之上，框内点按不触发框外收起。
        view.addSubview(calloutDismissView)
        view.addSubview(moodCallout)
        view.addSubview(weatherCallout)
        weatherCalloutHeightConstraint = weatherCallout.heightAnchor.constraint(equalToConstant: Self.calloutHeight)
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
            weatherCalloutHeightConstraint!,
        ])
        updateWeatherCalloutHeight()
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
            hideCallout(animated: true, restoreFocus: true)
        } else {
            // 再点另一工具钮是切换：触发钮即该种类的工具钮（与尖角锚点同口径）。
            showCallout(kind, trigger: kind == .mood ? moodToolButton : weatherToolButton)
        }
    }

    /// Chip 行点按：只打开对应框（不做收起切换，Chip 本身就是“已选”指示；
    /// 与旧 openToolStrip 同口径）。
    /// 审计第 31 项：trigger 须传实际点按者（工具钮或 chip），关闭还焦点认它，
    /// 不靠 kind 猜——心情/天气各有工具钮与 chip 两个入口，猜必错其一。
    private func showCallout(_ kind: CalloutKind, trigger: UIView) {
        if quotePanelOpen { return }
        if activeCallout == kind { return }
        // 审计 1：本次显式展示即为最新意图，在途的天气展示意图作废。
        invalidatePendingCalloutPresentation()
        // 同一时刻只开一个选择器：写给条若开着，先关条再开框（旧时切条即关上一条）。
        if activeToolStrip == .recipient {
            activeToolStrip = nil
            refreshToolStrip()
        }
        calloutTransitionGeneration += 1
        activeCallout = kind
        calloutAccessibilityTrigger = trigger
        // 审计 E2 第 11 项补步：configure 只在搭建时调一次，编辑/草稿的天气
        // 晚于搭建才落定，故每次打开天气框都按当前 selectedWeather 同步一次，
        // 否则重开框或编辑带天气的草稿时选中态仍是旧的。
        if kind == .weather {
            weatherCallout.setSelectedKey(selectedWeather)
            // [24] 小项 2：打开前按当前天气态定框高（有天气则含步进器行）。
            weatherCallout.setAccessoryVisible(selectedWeather != nil)
            updateWeatherCalloutHeight()
        }
        let target = kind == .mood ? moodCallout : weatherCallout
        let other = kind == .mood ? weatherCallout : moodCallout
        other.isHidden = true
        other.setEmoteOverlaysPlaying(false)
        other.alpha = 1
        other.transform = .identity
        calloutDismissView.isHidden = false
        target.isHidden = false
        target.setEmoteOverlaysPlaying(true)
        // 审计第 31 项：收起层盖住编辑器全域（仅工具栏穿透），触摸上背景内容
        // 已不可达；但 VoiceOver 滑动不走 hitTest，不置 modal 仍能滑到被遮的
        // 编辑器内容，故打开时把框体置为模态、只限框内子树（含天气附属行步进器）。
        // modal 只影响 VoiceOver 导航，不改触摸穿透，工具栏点按口径不变；
        // VoiceOver 用户出框走逃离手势（见 buildCallouts 的 onAccessibilityEscape）。
        target.accessibilityViewIsModal = true
        other.accessibilityViewIsModal = false
        view.layoutIfNeeded()
        updateCalloutArrowPositions()
        // 审计第 31 项：打开后把 VoiceOver 焦点送进框内（已选优先、否则首个可见
        // 选项；框内出现是同屏布局变化，用 layoutChanged，不用 screenChanged）。
        // 下一 runloop 再发：若期间已关闭（activeCallout 已变或框已隐藏）则不发，
        // 不把焦点送进已关的框。未开 VoiceOver 时 post 为空操作。
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self = self, let target = target,
                  self.activeCallout == kind, !target.isHidden,
                  let element = target.initialAccessibilityElement else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
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

    /// 审计第 31 项：restoreFocus 只在用户主动关闭时传 true（框外点按、
    /// 逃离手势、同钮再点、点选收起）；换工具/面板/发布/取消/倒计时等程序性
    /// 收起一律默认 false，不把焦点从新界面抢回触发钮。还焦点只在框真正
    /// 隐藏后发（动画路径走 completion，代次过期则不发旧焦点）。
    private func hideCallout(animated: Bool, restoreFocus: Bool = false) {
        guard let kind = activeCallout else { return }
        activeCallout = nil
        calloutTransitionGeneration += 1
        let generation = calloutTransitionGeneration
        let target = kind == .mood ? moodCallout : weatherCallout
        let trigger = calloutAccessibilityTrigger
        calloutAccessibilityTrigger = nil
        if !animated || UIAccessibility.isReduceMotionEnabled || view.window == nil {
            target.isHidden = true
            target.setEmoteOverlaysPlaying(false)
            target.alpha = 1
            target.transform = .identity
            target.accessibilityViewIsModal = false
            calloutDismissView.isHidden = true
            if restoreFocus, let element = calloutFocusReturnElement(kind: kind, trigger: trigger) {
                UIAccessibility.post(notification: .layoutChanged, argument: element)
            }
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
                target.setEmoteOverlaysPlaying(false)
                target.alpha = 1
                target.transform = .identity
                target.accessibilityViewIsModal = false
                self.calloutDismissView.isHidden = true
                if restoreFocus, let element = self.calloutFocusReturnElement(kind: kind, trigger: trigger) {
                    UIAccessibility.post(notification: .layoutChanged, argument: element)
                }
            }
        )
    }

    /// 审计第 31 项：关闭还焦点落点。首选打开时的实际触发钮；触发钮已隐藏
    /// 或离线时（例如经 chip 点“无”清掉心情/天气、chip 行随之隐藏）退到
    /// 同种类的工具钮；两者都不可达时返回 nil，调用方不发焦点通知。
    /// 只读 isHidden/window，不改任何按钮显隐与业务态。
    private func calloutFocusReturnElement(kind: CalloutKind, trigger: UIView?) -> UIView? {
        if let trigger = trigger, !trigger.isHidden, trigger.window != nil {
            return trigger
        }
        let fallback = kind == .mood ? moodToolButton : weatherToolButton
        if !fallback.isHidden, fallback.window != nil {
            return fallback
        }
        return nil
    }

    // MARK: - 批 E 定位行与定位气泡

    /// 编辑器下方定位行：进 contentStack、紧跟已选 chip 行（viewDidLoad 里
    /// buildSelectedChipsRow 之后立即建，顺序即栈顺序）；无位置时整行隐藏，不留空行。
    private func buildLocationRow() {
        locationIconView.translatesAutoresizingMaskIntoConstraints = false
        locationIconView.image = BearyLocationIcon.image(pointSize: 16)
        locationIconView.tintColor = BearyColors.gray
        locationIconView.contentMode = .scaleAspectFit
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        locationLabel.font = UIFont.systemFont(ofSize: 13)
        locationLabel.textColor = BearyColors.gray
        locationLabel.numberOfLines = 1
        locationLabel.lineBreakMode = .byTruncatingTail
        // 清除钮用官方 icon_close（铁律：不用自绘 ×、不用 SF Symbol）。
        locationClearButton.translatesAutoresizingMaskIntoConstraints = false
        locationClearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 16), for: .normal)
        locationClearButton.tintColor = BearyColors.gray
        locationClearButton.accessibilityLabel = "清除位置"
        locationClearButton.addTarget(self, action: #selector(didTapClearLocation), for: .touchUpInside)
        locationNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        locationNoteLabel.font = UIFont.systemFont(ofSize: 12)
        locationNoteLabel.textColor = BearyColors.gray
        locationNoteLabel.numberOfLines = 0
        locationLineRow.axis = .horizontal
        locationLineRow.spacing = 6
        locationLineRow.alignment = .center
        locationLineRow.translatesAutoresizingMaskIntoConstraints = false
        locationLineRow.addArrangedSubview(locationIconView)
        locationLineRow.addArrangedSubview(locationLabel)
        locationLineRow.addArrangedSubview(locationClearButton)
        locationRowStack.axis = .vertical
        locationRowStack.spacing = 2
        locationRowStack.translatesAutoresizingMaskIntoConstraints = false
        locationRowStack.addArrangedSubview(locationLineRow)
        locationRowStack.addArrangedSubview(locationNoteLabel)
        contentStack.addArrangedSubview(locationRowStack)
        NSLayoutConstraint.activate([
            locationIconView.widthAnchor.constraint(equalToConstant: 16),
            locationIconView.heightAnchor.constraint(equalToConstant: 16),
            locationClearButton.widthAnchor.constraint(equalToConstant: 24),
            locationClearButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        refreshLocationRow()
    }

    /// 定位行刷新：行文案 = 精确地点名；公开段位且有区级时加橙色副行
    /// “公开后他人仅见区级（X）”。可见性段位切换时也要调本函数（见
    /// restoreVisibility/可见性切换调用点），否则副行会滞后于段位。
    /// animated 只在确认新地点时传 true：只让位置行 0.18 秒淡入／淡变，
    /// 其余刷新（草稿恢复、可见性切换、清除）直接换字，不带动效。
    private func refreshLocationRow(animated: Bool = false) {
        guard let location = selectedLocation, !location.isEmpty, let name = location.name ?? location.district else {
            locationRowStack.isHidden = true
            locationRowStack.alpha = 1
            locationLabel.text = nil
            locationNoteLabel.text = nil
            locationNoteLabel.isHidden = true
            return
        }
        locationRowStack.isHidden = false
        locationLabel.text = name
        if selectedVisibilityPublished, let district = location.district, district != name {
            locationNoteLabel.text = "公开后他人仅见区级（\(district)）"
            locationNoteLabel.isHidden = false
        } else {
            locationNoteLabel.text = nil
            locationNoteLabel.isHidden = true
        }
        updatePreferredContentSize()
        guard animated, !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            locationRowStack.alpha = 1
            return
        }
        locationRowStack.alpha = 0
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
            self.locationRowStack.alpha = 1
        })
    }

    @objc private func didTapClearLocation() {
        selectedLocation = nil
        refreshLocationRow()
        scheduleDraftSave()
    }

    /// 定位气泡搭建：框体与专属框外收起层常驻 view（隐藏时 isHidden），约束一次激活；
    /// 框左右与工具栏同宽（iPad 居中列下自动跟随），框底贴工具栏顶 8pt 上方；
    /// 框是覆盖层（不推限时行、不改 sheet 高），与心情/天气框同口径。
    private func buildLocationPopover() {
        locationPopover.translatesAutoresizingMaskIntoConstraints = false
        locationDismissView.translatesAutoresizingMaskIntoConstraints = false
        locationPopover.isHidden = true
        locationDismissView.isHidden = true
        locationPopover.delegate = self
        locationDismissView.onTapOutside = { [weak self] in self?.hideLocationPopover(animated: true, restoreFocus: true) }
        view.addSubview(locationDismissView)
        view.addSubview(locationPopover)
        NSLayoutConstraint.activate([
            locationDismissView.topAnchor.constraint(equalTo: view.topAnchor),
            locationDismissView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            locationDismissView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            locationDismissView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            locationPopover.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor),
            locationPopover.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor),
            locationPopover.bottomAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: -8),
        ])
    }

    @objc private func didTapLocationTool() {
        // 同一时刻只开一个选择器：引用面板开着时不抢（与心情/天气框同款守卫）。
        if quotePanelOpen {
            showToast(message: "请先关闭引用面板")
            return
        }
        if isPublishing {
            showToast(message: isEditMode ? "保存中…" : "发布中…")
            return
        }
        // 审计 1：切到定位工具时，在途的天气展示意图作废（定位点按本身
        // 不递增 weatherFetchGeneration、不取消天气请求，只拦末尾抢开）。
        invalidatePendingCalloutPresentation()
        if locationPopoverOpen {
            hideLocationPopover(animated: true, restoreFocus: true)
            return
        }
        hideCallout(animated: false)
        if activeToolStrip != nil {
            activeToolStrip = nil
            refreshToolStrip()
        }
        locationPopoverOpen = true
        locationDismissView.isHidden = false
        locationDismissView.passthroughRects = [toolbarContainer.convert(toolbarContainer.bounds, to: locationDismissView)]
        locationPopover.isHidden = false
        // 无障碍：位置浮层照抄心情／天气框口径——打开置为模态（VoiceOver 不滑
        // 到被遮的编辑器内容；触摸穿透不动，工具栏仍可点），下一 runloop 把
        // 焦点送进框内状态行；期间已关闭则不发。
        locationPopover.accessibilityViewIsModal = true
        view.layoutIfNeeded()
        updateLocationPopoverArrow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.locationPopoverOpen, !self.locationPopover.isHidden else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: self.locationPopover.initialAccessibilityElement)
        }
        if UIAccessibility.isReduceMotionEnabled || view.window == nil {
            locationPopover.alpha = 1
            locationPopover.transform = .identity
        } else {
            locationPopover.alpha = 0
            locationPopover.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
                self.locationPopover.alpha = 1
                self.locationPopover.transform = .identity
            })
        }
        // 已有已确认的地点时先展示它（草稿／已确认的地名与区级），不重新定位；
        // 没有时才自动定位；点气泡里的「重新定位」才取当前位置。
        if let location = selectedLocation, !location.isEmpty {
            locationPopover.showPrefilled(location)
        } else {
            locationPopover.startAutoLocate()
        }
    }

    /// 无障碍：restoreFocus 只在用户主动关闭时传 true（框外点按、同钮再点、
    /// 头部确认落定）；程序性收起（换工具／发布／取消等）默认 false，不把
    /// 焦点从新界面抢回触发钮。还焦点只在框真正隐藏后发。
    private func hideLocationPopover(animated: Bool, restoreFocus: Bool = false) {
        guard locationPopoverOpen else { return }
        locationPopoverOpen = false
        locationPopover.cancelRequests()
        if !animated || UIAccessibility.isReduceMotionEnabled || view.window == nil {
            locationPopover.isHidden = true
            locationPopover.alpha = 1
            locationPopover.transform = .identity
            locationPopover.accessibilityViewIsModal = false
            locationDismissView.isHidden = true
            if restoreFocus, !locationToolButton.isHidden, locationToolButton.window != nil {
                UIAccessibility.post(notification: .layoutChanged, argument: locationToolButton)
            }
            return
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
            self.locationPopover.alpha = 0
            self.locationPopover.transform = CGAffineTransform(translationX: 0, y: 6)
        }, completion: { [weak self] _ in
            guard let self = self, !self.locationPopoverOpen else { return }
            self.locationPopover.isHidden = true
            self.locationPopover.alpha = 1
            self.locationPopover.transform = .identity
            self.locationPopover.accessibilityViewIsModal = false
            self.locationDismissView.isHidden = true
            if restoreFocus, !self.locationToolButton.isHidden, self.locationToolButton.window != nil {
                UIAccessibility.post(notification: .layoutChanged, argument: self.locationToolButton)
            }
        })
    }

    /// 尖角跟随定位钮中心（与 updateCalloutArrowPositions 同款换算）。
    private func updateLocationPopoverArrow() {
        let center = locationToolButton.convert(CGPoint(x: locationToolButton.bounds.midX, y: locationToolButton.bounds.midY), to: locationPopover)
        locationPopover.arrowCenterX = center.x
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

    /// 弹出框点选心情：插入式（取代旧“再点已选项取消”口径）——把熊脸图
    /// 插进光标处；插完不收起，方便连着插多个（数量不限，见
    /// insertMoodImageAtCursor）；单独心情字段一字不动。
    /// 23a 例外：首位“无”（key "none"）不插图，只清单独心情字段（编辑回填 /
    /// 草稿恢复的旧心情）：selectedMood 置空、chip 行同步隐藏、草稿落盘；
    /// 点选即收起（与天气“无”同口径，区别于插入式的不收起）。编辑保存时
    /// selectedMood 为 nil 即按 updateEntry 省略口径发出，与天气清除同款。
    private func didSelectMoodFromCallout(_ key: String) {
        if key == "none" {
            selectedMood = nil
            refreshSelectedChips()
            scheduleDraftSave()
            hideCallout(animated: true, restoreFocus: true)
            return
        }
        insertMoodImageAtCursor(key)
    }

    /// 弹出框点选天气：沿用旧条口径（点即选中、再点不取消）；点选即收起。
    @objc private func didTapTempMinus() {
        adjustTemperature(by: -1)
    }

    @objc private func didTapTempPlus() {
        adjustTemperature(by: 1)
    }

    /// 气温 ±1：无气温时先落到 18°（不以方向猜 17°/19°）；范围钉死 -60…60°。
    /// 手改气温：在途自动填回包即过期作废，不覆盖手改值（见 weatherFetchGeneration）。
    private func adjustTemperature(by delta: Int) {
        guard selectedWeather != nil else { return }
        weatherFetchGeneration += 1
        let next: Int
        if let current = selectedTemperature {
            next = current + delta
        } else {
            next = 18
        }
        selectedTemperature = min(60, max(-60, next))
        refreshSelectedChips()
        scheduleDraftSave()
    }

    /// 点气温数值：系统输入框直输整数（-60…60°）；留空点确定即清除气温（只清气温、不动类型）。
    @objc private func didTapTempLabel() {
        guard selectedWeather != nil else { return }
        let alert = UIAlertController(title: "气温", message: "输入摄氏度整数，留空即清除", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numbersAndPunctuation
            field.placeholder = "例如 18"
            if let temp = self.selectedTemperature {
                field.text = "\(temp)"
            }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive, handler: { [weak self] _ in
            // 手改气温（清除亦算手改）：在途自动填回包过期作废。
            self?.weatherFetchGeneration += 1
            self?.selectedTemperature = nil
            self?.refreshSelectedChips()
            self?.scheduleDraftSave()
        }))
        alert.addAction(UIAlertAction(title: "确定", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            let raw = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty {
                // 手改气温（直输清空亦算手改）：在途自动填回包过期作废。
                self.weatherFetchGeneration += 1
                self.selectedTemperature = nil
            } else if let value = Int(raw) {
                // 手改气温（直输亦算手改）：在途自动填回包过期作废。
                self.weatherFetchGeneration += 1
                self.selectedTemperature = min(60, max(-60, value))
            } else {
                self.showToast(message: "气温请输入整数")
                return
            }
            self.refreshSelectedChips()
            self.scheduleDraftSave()
        }))
        present(alert, animated: BearyMotion.animated(true))
    }

    /// 天气动态图标覆盖层（BearyEmoteView，底层静态图作 fallback；与落点行同款）。
    private var weatherToolEmoteView: BearyEmoteView?
    private var weatherChipEmoteView: BearyEmoteView?
    private var quoteWeatherEmoteViews: [BearyEmoteView] = []

    /// 在宿主视图上贴／刷新天气 Lottie 覆盖层（落点行同款）：同 key 只重播、
    /// 不重建；key 为 nil 或无 fallback 图时摘掉覆盖层。
    private func refreshWeatherEmoteOverlay(_ stored: inout BearyEmoteView?, on host: UIView, lottieKey: String?, fallbackImage: UIImage?) {
        if let lottieKey = lottieKey, let fallbackImage = fallbackImage {
            if let existing = stored, existing.superview === host, existing.emoteKey == lottieKey {
                existing.play()
                return
            }
            stored?.stop()
            stored?.removeFromSuperview()
            let overlay = BearyEmoteView(key: lottieKey, animated: true, fallbackImage: fallbackImage)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: host.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            stored = overlay
        } else {
            stored?.stop()
            stored?.removeFromSuperview()
            stored = nil
        }
    }

    /// 引用面板行天气图标全部停播并摘掉（行重渲染／面板关闭时调）。
    private func clearQuoteWeatherEmotes() {
        for overlay in quoteWeatherEmoteViews {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        quoteWeatherEmoteViews.removeAll()
    }

    /// 工具栏天气钮图标随选中天气变（网页 syncWxBtn 同款）：未选回通用天气图标，
    /// 已选换该天气图标；两态均为墨色。这是旧 refreshWeatherButtons 里唯一现行
    /// 副作用（其余皆为已删旧天气条带的按钮样式），旧条带删除后抽为独立函数。
    private func syncWeatherToolButton() {
        if let weather = selectedWeather {
            if let icon = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.ink
            // 已选态：天气图标贴动态 Lottie（底层静态图作 fallback）。
            if let host = weatherToolButton.imageView {
                refreshWeatherEmoteOverlay(&weatherToolEmoteView, on: host, lottieKey: BearyText.weatherLottieKey(for: weather), fallbackImage: weatherToolButton.image(for: .normal))
            }
        } else {
            if let icon = BearyIconImages.image(named: "icon_weather_tool", pointSize: 24) {
                weatherToolButton.setImage(icon, for: .normal)
            }
            weatherToolButton.tintColor = BearyColors.ink
            // 未选态 icon_weather_tool 保持静态，摘掉覆盖层。
            refreshWeatherEmoteOverlay(&weatherToolEmoteView, on: weatherToolButton, lottieKey: nil, fallbackImage: nil)
        }
    }

    /// v6-8：点首位“无”即清除已选天气（weather 置空），工具栏天气钮经
    /// syncWeatherToolButton 回到无天气态（通用天气图标），chip 行同步隐藏天气 chip。
    private func didSelectWeatherFromCallout(_ key: String) {
        // 手选天气：在途自动填回包即过期作废（见 weatherFetchGeneration），
        // 迟到回包不再覆盖本次手选；再点天气钮重新自动填时仍覆盖手改（#427 口径不变）。
        weatherFetchGeneration += 1
        // 手改类型：换类型气温保留；点“无”清类型时气温同清，不留孤气温。
        if key == "none" {
            selectedWeather = nil
            selectedTemperature = nil
        } else {
            selectedWeather = key
        }
        syncWeatherToolButton()
        refreshSelectedChips()
        scheduleDraftSave()
        hideCallout(animated: true, restoreFocus: true)
    }

    /// v6-8“无”选项图（40pt，与其它天气图标同尺寸）：审计 15 项第 7 项——
    /// 此前虚线圆＋icon_plus 旋 45° 拼叉号属于改造官方图标造型，已改为
    /// 直接用官方 icon_close 原图（模板渲染、由弹出框按钮 tint 着色）。
    private func weatherNoneImage() -> UIImage? {
        BearyIconImages.image(named: "icon_close", pointSize: 40)
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
    /// 22 方向：收件人 chip 改“提到 昵称”。图标只是视觉辅助：accessibilityLabel 一律保留完整表述
    /// （“心情：开心”“天气：晴”“提到：昵称”），不只靠图标传达信息。
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
            let weatherTitle = selectedTemperature != nil ? "\(name) \(selectedTemperature!)°" : name
            weatherChipButton.setTitle(weatherTitle, for: .normal)
            let icon = BearyIconImages.image(named: "icon_wx_\(weather)", pointSize: 16)
            if icon == nil {
                NSLog("[BearyComposer] selected weather chip icon missing key=%@", weather)
            }
            weatherChipButton.setImage(icon, for: .normal)
            weatherChipButton.tintColor = BearyColors.ink
            // 天气 chip 图标贴动态 Lottie（底层静态图作 fallback）。
            if let host = weatherChipButton.imageView {
                refreshWeatherEmoteOverlay(&weatherChipEmoteView, on: host, lottieKey: BearyText.weatherLottieKey(for: weather), fallbackImage: icon)
            }
            weatherChipButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: icon == nil ? 0 : 5, bottom: 0, right: 0)
            weatherChipButton.accessibilityLabel = selectedTemperature != nil ? "天气：\(name) \(selectedTemperature!)°" : "天气：" + name
        } else {
            weatherChipButton.isHidden = true
            weatherChipButton.setImage(nil, for: .normal)
            refreshWeatherEmoteOverlay(&weatherChipEmoteView, on: weatherChipButton, lottieKey: nil, fallbackImage: nil)
        }
        // 气温步进器只跟天气类型走：有类型才显，无类型（“无”）时连气温同清、不留孤气温。
        // [24] 小项 2：步进器在天气框附属行里（见 buildCallouts），此处只管
        // 附属行显隐 + 框高，不再管 chip 行里的步进器。
        weatherCallout.setAccessoryVisible(selectedWeather != nil)
        updateWeatherCalloutHeight()
        tempLabelButton.setTitle(selectedTemperature != nil ? "\(selectedTemperature!)°" : "气温", for: .normal)
        tempLabelButton.accessibilityLabel = selectedTemperature != nil ? "气温：\(selectedTemperature!)°，点按可输入" : "气温：未设置，点按可输入"
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
            // 22 方向：收件人 chip 由“写给 昵称”改“提到 昵称”（纯文本，不另加图标）。
            recipientChipButton.setTitle("提到 " + name, for: .normal)
            recipientChipButton.accessibilityLabel = "提到：" + name
        } else {
            recipientChipButton.isHidden = true
        }
        // 顶部 @ 提示行：与底部 chip 同名同态（编辑态含 lockedRecipientName、已清除为 nil
        // 均复用此处结论）；选人/清除/换人/草稿恢复/编辑恢复全走 refreshRecipientRow →
        // refreshSelectedChips，故此处一处挂钩即全覆盖。
        mentionTopName = recipientName
        refreshMentionTopRow()
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
    /// [24] 小项 2：步进器已收进天气框，首行只剩心情／天气／写给三项，
    /// 窄屏第二行兜底（步进器包壳）已随之删除，不再有步进器换行态。
    /// 只在换行态真正变化时移视图；同态重算不碰层级，不触发布局环。
    /// （移行不改行宽，viewDidLayoutSubviews 的宽门限仍挡得住重入。）
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
        // 写给换行总宽：心情／天气／写给自然宽＋间距。
        // [24] 小项 2：步进器已收进天气框，不再计入首行宽。
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
            chip.button.backgroundColor = BearyColors.surface2
            chip.button.layer.cornerRadius = 999
            chip.button.layer.masksToBounds = true
            chip.button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
            chip.button.addTarget(self, action: chip.action, for: .touchUpInside)
            chip.button.bearyAddPressFeedback()
            chip.button.isHidden = true
            chip.button.translatesAutoresizingMaskIntoConstraints = false
            selectedChipsFirstRow.addArrangedSubview(chip.button)
        }
        // [24] 小项 2：气温步进器不再挂 chip 首行，改挂天气框附属行
        //（buildCallouts 里 setAccessoryView）；只在已选天气时显（见 refreshSelectedChips）。
        tempStepperStack.axis = .horizontal
        tempStepperStack.spacing = 4
        tempStepperStack.alignment = .center
        tempStepperStack.backgroundColor = BearyColors.surface2
        tempStepperStack.layer.cornerRadius = 999
        tempStepperStack.layer.masksToBounds = true
        tempStepperStack.translatesAutoresizingMaskIntoConstraints = false
        tempStepperStack.isHidden = true
        for (button, title, action) in [
            (tempMinusButton, "−", #selector(didTapTempMinus)),
            (tempLabelButton, "气温", #selector(didTapTempLabel)),
            (tempPlusButton, "+", #selector(didTapTempPlus)),
        ] as [(BearyHit44Button, String, Selector)] {
            button.setTitle(title, for: .normal)
            button.setTitleColor(BearyColors.ink, for: .normal)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
            button.addTarget(self, action: action, for: .touchUpInside)
            button.bearyAddPressFeedback()
            button.translatesAutoresizingMaskIntoConstraints = false
            tempStepperStack.addArrangedSubview(button)
        }
        tempStepperStack.setContentHuggingPriority(.required, for: .horizontal)
        tempStepperStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 不进 chip 行：buildCallouts 里以附属行身份挂进天气框。
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
        imageUndoBar.backgroundColor = BearyColors.surface2
        imageUndoBar.layer.cornerRadius = 12
        imageUndoBar.layer.masksToBounds = true
        imageUndoLabel.text = "图片已删除"
        imageUndoLabel.font = UIFont.systemFont(ofSize: 13)
        imageUndoLabel.textColor = BearyColors.ink
        imageUndoButton.setTitle("撤销", for: .normal)
        imageUndoButton.setTitleColor(BearyColors.ink, for: .normal)
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
        // 审计 1：切到心情工具时，在途的天气展示意图作废。
        invalidatePendingCalloutPresentation()
        hideLocationPopover(animated: false)
        toggleCallout(.mood)
    }

    /// [24] 小项 1：天气钮点按即打开天气选择器，不再等自动取数回包才开
    ///（旧口径：先 fetchLocalWeather、回包尾部才 showCallout，网络慢/
    /// 取不到时选择器迟迟不开，看起来像要点两次）。自动取数仍在后台走：
    /// 取到后填类型与气温（手选/手改气温仍凭 weatherFetchGeneration 使
    /// 在途回包过期作废，不覆盖手改）；取不到只 toast，不编假数据。
    /// 回包不再抢开选择器——用户若已手动关框，回包只落数不重开。
    /// 填上之后类型可在选择器里手改、气温在框内步进器里手改（小项 2）；
    /// 再点天气钮会重新自动填（覆盖手改，#427 口径不变）。
    @objc private func didTapWeatherTool() {
        DiagFile.mark("weather-diag didTapWeatherTool")
        hideLocationPopover(animated: false)
        showCallout(.weather, trigger: weatherToolButton)
        weatherFetchGeneration += 1
        let generation = weatherFetchGeneration
        // 天气 GPS（2026-11-04）：点天气钮时才走定位，不在启动时弹权限；一次定位即可。
        // 拒绝/受限/定位失败/超时 → 回落 IP 链路（不传经纬度），回落成功后提示一句；
        // 回落也取不到时沿用旧 toast，不填假数据。代次守卫不变：手改后在途回包一律作废。
        BearyOneShotLocation.request { [weak self] locationResult in
            DispatchQueue.main.async {
                guard let self = self, self.weatherFetchGeneration == generation else { return }
                switch locationResult {
                case .coordinate(let latitude, let longitude):
                    self.fetchWeatherWith(latitude: latitude, longitude: longitude, generation: generation, fallbackTip: nil)
                case .denied:
                    self.fetchWeatherWith(latitude: nil, longitude: nil, generation: generation, fallbackTip: "未获得位置权限，已按网络位置填写天气")
                case .unavailable:
                    self.fetchWeatherWith(latitude: nil, longitude: nil, generation: generation, fallbackTip: "定位失败，已按网络位置填写天气")
                }
            }
        }
    }

    /// 天气取数（GPS 链路与 IP 回落链路共用）：成功填类型与气温、回落成功提示一句；
    /// 失败沿用旧 toast，不编假数据。
    private func fetchWeatherWith(latitude: Double?, longitude: Double?, generation: Int, fallbackTip: String?) {
        BearyAPI.shared.fetchLocalWeather(latitude: latitude, longitude: longitude) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.weatherFetchGeneration == generation else { return }
                switch result {
                case .success(let fetched):
                    if let key = fetched.weatherKey {
                        self.selectedWeather = key
                    }
                    self.selectedTemperature = fetched.temperature
                    self.syncWeatherToolButton()
                    self.refreshSelectedChips()
                    self.scheduleDraftSave()
                    // 框还开着时同步框内选中态与步进器显隐；框已关则不重开。
                    if self.activeCallout == .weather {
                        self.weatherCallout.setSelectedKey(self.selectedWeather)
                    }
                    if let tip = fallbackTip {
                        self.showToast(message: tip)
                    }
                case .failure:
                    self.showToast(message: "没取到当地天气，请手动选")
                }
            }
        }
    }

    @objc private func didTapRecipientTool() {
        // A2：工具栏 @ 直连选人面板，跳过 @ 选择条（选择条仍由正文下方 @ chip
        // 打开，供已选态清除/重选；@ 提醒无按篇开关）。
        // 引用面板打开时工具栏本身已藏，此处不再走 setToolStrip 的面板守卫。
        // 编辑器改版：弹出框打开时点其他工具钮，先收起框再走各自处理。
        // 审计 1：切到写给工具时，在途的天气展示意图作废。
        invalidatePendingCalloutPresentation()
        hideCallout(animated: false)
        hideLocationPopover(animated: false)
        didTapPickRecipient()
    }

    @objc private func didTapMoodChip() {
        showCallout(.mood, trigger: moodChipButton)
    }

    @objc private func didTapWeatherChip() {
        showCallout(.weather, trigger: weatherChipButton)
    }

    @objc private func didTapRecipientChip() {
        openToolStrip(.recipient)
    }

    /// 顶部 @ 行显隐：有收件人且引用面板未开时出现；引用面板打开时同其他 chrome 一并隐藏。
    /// 行高进 sheet 高（updatePreferredContentSize 的非面板分支另加本行高）；面板打开时
    /// 高度走视口档，不在此更新。
    private func refreshMentionTopRow() {
        let visible = mentionTopName != nil && !quotePanelOpen
        if let name = mentionTopName, visible {
            mentionTopPill.setTitle("提到 " + name, for: .normal)
            mentionTopPill.accessibilityLabel = "提到：" + name
        }
        let wasHidden = mentionTopRow.isHidden
        mentionTopRow.isHidden = !visible
        mentionTopRowHeightConstraint?.constant = visible ? Self.mentionTopRowHeight : 0
        if wasHidden != mentionTopRow.isHidden, !quotePanelOpen {
            updatePreferredContentSize()
        }
    }

    @objc private func didTapMentionTopRow() {
        openToolStrip(.recipient)
    }

    // MARK: - 状态行（编辑倒计时 + 草稿状态；字数圆环已移入工具栏右端）

    private func buildStatusRow() {
        editTimerLabel.font = BearyDynamicType.numberFont()
        editTimerLabel.textColor = BearyColors.gray
        editTimerLabel.isHidden = true
        // P2-12：工具栏内联状态行同缺陷一并改——captionFont（12 regular scaled，
        // 规范 §11）＋跟随系统字号，宽度不足时换行、不截尾。
        draftStatusLabel.font = BearyDynamicType.captionFont()
        draftStatusLabel.adjustsFontForContentSizeCategory = true
        draftStatusLabel.textColor = BearyColors.blue
        // 109：压缩阻力默认值仍 749（lvl1/失败长文案窄屏受压时先换行，见 P2-12）；
        // lvl2 已保存态在 updateDraftStatusLabel 里拉到 required、走
        // applyDraftStatusToolbarFit 的保全/只留对勾口径。
        draftStatusLabel.numberOfLines = 0
        draftStatusLabel.lineBreakMode = .byWordWrapping
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
        statusRow.addArrangedSubview(statusRowSpacer)
        // v6-6：草稿保存文案组已挪到工具栏右端（buildToolbarRow），不再进状态行；
        // 状态行只留编辑倒计时。组内图标／文案／级别逻辑（updateDraftStatusLabel）一字不动。
        // C1：字数圆环已移入工具栏左图标组 charGroupStack（数字已隐藏，只留圆环），
        // 圆环尺寸与形层仍在此处创建（视图归属不影响形层）。
        NSLayoutConstraint.activate([
            draftStatusIcon.widthAnchor.constraint(equalToConstant: 15),
            draftStatusIcon.heightAnchor.constraint(equalToConstant: 15),
            charRingView.widthAnchor.constraint(equalToConstant: 18),
            charRingView.heightAnchor.constraint(equalToConstant: 18),
        ])
        // 窄屏 5 项之 4：最低高约束单独存引用——无内容隐藏整行时停用它，
        // 有内容（编辑倒计时）时恢复；不存引用就无法在隐藏态停用，空行塌不掉。
        let statusRowMinHeight = statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        statusRowMinHeight.isActive = true
        statusRowMinHeightConstraint = statusRowMinHeight
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
        // 窄屏 5 项之 4：建完即按实际内容定显隐与间距——新建模式倒计时隐藏，
        // 整行直接隐藏＋间距清零，不留 18＋8＝26pt 空白；编辑模式由 startEditTimer
        // 经本函数恢复（见下）。
        refreshStatusRowVisibility()
    }

    /// 窄屏 5 项之 4：状态行显隐的唯一口径。状态行当前唯一常驻内容是
    /// 编辑倒计时（草稿组已移工具栏、字数圆环已移工具栏左组），故“有内容”
    /// ＝除弹性 spacer 外有可见 arranged 子项；以后若有新内容进本行，
    /// 本判据自动覆盖，不必再为新项另写显隐。
    /// 无内容：整行隐藏＋最低高约束停用＋后间距清零，三处缺一都会残留空白。
    /// 有内容：整行显示＋最低高恢复＋后间距 8。显隐翻转时重算 sheet 高，
    /// 否则正文区高度不变、空白只是换了位置。引用面板打开时由
    /// setQuotePanelOpen 临时整行隐藏（面板态优先），关闭时经本函数恢复。
    private func refreshStatusRowVisibility() {
        let hasVisibleContent = statusRow.arrangedSubviews.contains { $0 !== statusRowSpacer && !$0.isHidden }
        let shouldHide = !hasVisibleContent
        // 间距与最低高约束恒按目标态复核（面板关闭恢复等直接改 isHidden 的
        // 路径可能留下旧间距），显隐本身只在翻转时改、翻转时才重算 sheet 高。
        contentStack.setCustomSpacing(hasVisibleContent ? 8 : 0, after: statusRow)
        statusRowMinHeightConstraint?.isActive = hasVisibleContent
        guard statusRow.isHidden != shouldHide else { return }
        statusRow.isHidden = shouldHide
        updatePreferredContentSize()
    }

    /// 草稿状态文案跟随保存级别：2 草稿已保存 / 1 文字已保存，图片未保存 / 0 失败红字。
    /// 编辑模式不显示（网页编辑态同款：状态行只留倒计时与字数）。
    /// animated 为真时，图标与文字在原位淡变 0.18s——只在最新一版落盘
    /// 的回包里传真，平时调用不重播。
    private func updateDraftStatusLabel(animated: Bool = false) {
        if isEditMode {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            setDraftStatusBannerVisible(false)
            return
        }
        guard let level = draftStatusLevel else {
            draftStatusGroup.isHidden = true
            draftStatusIcon.isHidden = true
            BearyIconMotion.stopSpin(on: draftStatusIcon, key: "bearyDraftSavingSpin")
            setDraftStatusBannerVisible(false)
            return
        }
        draftStatusGroup.isHidden = false
        // D-G14：落盘后停掉保存中转圈、换回对勾图；仅 lvl2 显示图标（lvl1/失败态网页均无图标）。
        BearyIconMotion.stopSpin(on: draftStatusIcon, key: "bearyDraftSavingSpin")
        draftStatusIcon.image = BearyIconImages.image(named: "icon_check", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.blue
        draftStatusIcon.isHidden = level != 2
        if level == 2 {
            // 109：文案缩短为「已保存」（对勾图标已在左侧，合起来即「✓ 已保存」，意思不变），
            // 压缩阻力拉到 required，优先保全文案、不再被左侧图标组与字数圆环挤成「草…」。
            draftStatusLabel.text = "已保存"
            draftStatusLabel.textColor = BearyColors.blue
            draftStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else if level == 1 {
            draftStatusLabel.text = "已保存，图片还没上传完"
            draftStatusLabel.textColor = BearyColors.blue
            draftStatusLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        } else {
            draftStatusLabel.text = "草稿保存失败"
            draftStatusLabel.textColor = BearyColors.red
            draftStatusLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        }
        // 窄屏 5 项之 3：独立行文案与工具行组同源（级别逻辑、文案、颜色一处定，
        // 这里只同步显示值；显隐由 applyDraftStatusToolbarFit 按级别统一分流）。
        draftStatusBannerLabel.text = draftStatusLabel.text
        draftStatusBannerLabel.textColor = draftStatusLabel.textColor
        applyDraftStatusToolbarFit()
        if animated {
            // A4：最新一版落盘后，图标与文字原位淡变 0.18s（与 :3820/:3847
            // 同款缓动；beginFromCurrentState 使新输入改写状态行时不与淡入打架）。
            draftStatusIcon.alpha = 0
            draftStatusLabel.alpha = 0
            draftStatusBannerLabel.alpha = 0
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: {
                self.draftStatusIcon.alpha = 1
                self.draftStatusLabel.alpha = 1
                self.draftStatusBannerLabel.alpha = 1
            })
        }
    }

    /// 窄屏 5 项之 3：独立行显隐＋工具行顶锚两档切换。只在翻转时改约束，
    /// 每轮布局重入（viewDidLayoutSubviews → applyDraftStatusToolbarFit）
    /// 同值不重设、不成环；翻转时工具栏高变了，重算 sheet 高。
    private func setDraftStatusBannerVisible(_ visible: Bool) {
        // 守门读法：isHidden == visible 恰是“尚未到达目标态”
        // （要显示时当前正隐藏、要隐藏时当前正显示），已到达则直接返回。
        guard draftStatusBanner.isHidden == visible else { return }
        draftStatusBanner.isHidden = !visible
        draftStatusBannerHeightConstraint?.isActive = !visible
        toolbarToolRowTopToSeparatorConstraint?.isActive = !visible
        toolbarToolRowTopToBannerConstraint?.isActive = visible
        updatePreferredContentSize()
    }

    /// 窄屏 5 项之 3：独立行重试入口。口径与 #495 草稿失败留页＋再点关闭重试
    /// 一致：只重跑同一条 saveDraftNow——draftId／clientReq 不换、不另写落盘
    /// 路径、不绕级别判定；成功后完成回调经 updateDraftStatusLabel 刷新级别
    /// （成功则独立行自动收起、回到工具行已保存态），失败仍留页、独立行与
    /// 文案不变。唯一区别是本钮不关闭页面（用户点的是重试，不是关闭）；
    /// #495 的关闭重试路径本身一字不动。
    /// P1-8：本钮只用于写盘失败（level 0，独立行只在该级别显示本钮）——
    /// 图片未保存（level 1）时重跑 saveDraftNow 也救不回图（保存不上传，
    /// key 为空的图仍未上传完），不声称重传图片；失败图点图片重试上传（见 didTapImageItem）。
    @objc private func didTapDraftStatusRetry() {
        saveDraftNow()
    }

    /// U3：工具行间距与六钮横向热区联动。热区横向扩量 = 间距 / 2 时，
    /// 相邻热区宽 = 24 + 间距 = 中心距，恰好相接、不互叠（间距 20 → 扩 10、
    /// 热区 44）。只改热区 cap，不改视觉帧；间距每次变更都经本函数，
    /// cap 与间距同步（cap 赋值不触发布局，可每轮直设）。
    /// 第 7 轮属实项 4：工具间距恒为 20、永不为挤文案而收——收间距即重现
    /// 工具热区重叠（旧口径曾收到 8～16，中心距 32～40、重叠 12～4pt）。
    private func setToolbarToolRowSpacing(_ spacing: CGFloat, in toolRow: UIStackView) {
        if toolRow.spacing != spacing { toolRow.spacing = spacing }
        let cap = max(0, spacing / 2)
        for button in [imageToolButton, locationToolButton, moodToolButton, weatherToolButton, recipientToolButton, quoteToolButton] {
            button.maxSideExpansion = cap
        }
    }

    /// 109：草稿状态在工具栏里的宽度适配（只动 lvl2 文案显隐，不动图标与圆环）。
    /// 工具间距恒为 20、永不为挤文案而收，窄屏改由文案显隐兜底。
    /// 390 宽：容器 358，6×24 图标 + 5 段工具间距 20 + 引用→圆环 8 + 圆环 18
    /// + 状态组（对勾 15 + gap 5 + 文案约 39）= 约 329，spacer 吸剩余 slack，可完整排下「✓ 已保存」。
    /// 320 宽：容器 288，只留对勾态 = 6×24 + 5×20 + 8 + 18 + 15 = 285 ≤ 288；
    /// 文案排不下时兜底只留对勾（文案隐藏），绝不留半截字加省略号；
    /// 宽回升时文案自动恢复（viewDidLayoutSubviews 每轮重算，同值不重设、不成环）。
    /// 窄屏 5 项之 3：全部状态共用本函数分流，不再只有 level 2 走适配、
    /// level 1／0 直接恢复间距任由截断——level 0／1 改走工具栏上方独立行
    /// （完整文案＋重试钮，工具行组同步隐藏、工具行间距恒 20），level 2
    /// 仍走下方原口径；编辑态／无级别时独立行隐藏、间距恒 20。
    private func applyDraftStatusToolbarFit() {
        // 工具行改存引用（buildToolbarRow 赋值）；回退旧查找时须跳过独立行
        // （它也是 toolbarContainer 的 UIStackView 子项，first 会误取它）。
        let toolRow: UIStackView
        if let stored = toolbarToolRow {
            toolRow = stored
        } else if let found = toolbarContainer.subviews.first(where: { $0 is UIStackView && $0 !== draftStatusBanner }) as? UIStackView {
            toolRow = found
        } else {
            return
        }
        let width = toolbarContainer.bounds.width
        guard width > 0 else { return }
        guard let level = draftStatusLevel, !isEditMode else {
            setDraftStatusBannerVisible(false)
            setToolbarToolRowSpacing(20, in: toolRow)
            return
        }
        if level == 0 || level == 1 {
            // 独立行承载完整文案＋重试：工具行组不再与图标抢宽，隐藏它；
            // 工具行间距恒 20（不再为挤文案而收间距）。文案本身在独立行
            // 独占整行宽（320 宽下 288，减重试钮后仍远超 11 字文案宽），不截断。
            setDraftStatusBannerVisible(true)
            // P1-8：重试钮只用于写盘失败（level 0）。level 1（文字已保存，图片未保存）
            // 时重跑 saveDraftNow 也救不回图（保存不上传，key 为空的图仍未上传完），不露重试钮；
            // 失败图点图片重试上传（见 didTapImageItem），上传中图等传完自动进下一次保存。
            draftStatusRetryButton.isHidden = (level != 0)
            if !draftStatusGroup.isHidden { draftStatusGroup.isHidden = true }
            setToolbarToolRowSpacing(20, in: toolRow)
            return
        }
        // level 2：独立行收起，工具行组恢复显示，走原保全／只留对勾口径，
        // 但间距不再参与保全——工具间距恒 20，只切文案显隐。
        setDraftStatusBannerVisible(false)
        if draftStatusGroup.isHidden { draftStatusGroup.isHidden = false }
        setToolbarToolRowSpacing(20, in: toolRow)
        let labelWidth = draftStatusLabel.intrinsicContentSize.width
        // 109-fix：CGFloat(整数算式) + CGFloat 的混合表达式曾让 CI 编译器报
        // “unable to type-check in reasonable time”——改拆成显式 CGFloat 分步算式。
        // 圆环组实测宽：空文案时圆环与数字双隐藏 → 0；未超限只留圆环 → 18；
        // 超限红字显形 → 18 + 组内 6 + 数字宽。旧口径恒按 18 算，空文案时多估、文案藏得偏早。
        let charGroupWidth: CGFloat
        if charRingView.isHidden && charCountLabel.isHidden {
            charGroupWidth = 0
        } else if charCountLabel.isHidden {
            charGroupWidth = 18
        } else {
            charGroupWidth = 18 + 6 + charCountLabel.intrinsicContentSize.width
        }
        // 只留对勾态定宽：6×24 图标 + 5 段工具间距 20 + 引用→圆环 8 + 圆环组 + 对勾 15；
        // spacer 两侧自定义间距为 0、spacer 本身吸 slack，不进算式。
        let withoutLabel: CGFloat = 6 * 24 + 5 * 20 + 8 + charGroupWidth + 15
        if width >= withoutLabel + 5 + labelWidth {
            if draftStatusLabel.isHidden { draftStatusLabel.isHidden = false }
        } else {
            if !draftStatusLabel.isHidden { draftStatusLabel.isHidden = true }
        }
    }

    // MARK: - 编辑倒计时（从 editDeadline 算剩余，网页 edit-timer 口径“剩 M:SS”）

    private func startEditTimer() {
        editTimer?.invalidate()
        guard isEditMode, let deadline = editingEntry?.editDeadline else {
            editTimerLabel.isHidden = true
            // 窄屏 5 项之 4：倒计时显隐即状态行显隐，新建模式这里把整行藏掉。
            refreshStatusRowVisibility()
            return
        }
        editTimerLabel.isHidden = false
        refreshStatusRowVisibility()
        // 已因在途保存暂停过关闭：期限已过、编辑器为“保留输入待复制”态，
        // viewWillAppear 重起计时器时也不得再走关闭路径（否则失败后一次
        // 弹窗/切出返回就会把保留的输入连同编辑器一起关掉）。
        if editSaveBlockedAfterDeadline {
            editTimerLabel.text = "编辑时间已结束"
            updatePublishState()
            return
        }
        let tickBlock: () -> Void = { [weak self] in
            guard let self = self else { return }
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            let remain = max(0, Int(ceil(Double(deadline - nowMs) / 1000.0)))
            if remain <= 0 {
                if self.isPublishing {
                    // 在途保存：PUT 请求体在发出前已拼好，删本地临时文件
                    // 不会破坏已发出的请求，丢的是结果回传——容器 dismiss
                    // 后 VC 可能释放，成功回传与失败提示都会因 weak self
                    // 丢失。故暂停自动关闭：不删本地文件、不走 onCancelled、
                    // 不收弹出框；计时器先停，置位后保存钮由
                    // updatePublishState 持续禁用；结果到时成功走原
                    // onUpdated 关闭，失败走 performUpdate 的过期分支。
                    self.editTimerLabel.text = "编辑时间已结束"
                    self.editTimer?.invalidate()
                    self.editTimer = nil
                    self.editSaveBlockedAfterDeadline = true
                    self.updatePublishState()
                    return
                }
                // 审计-编辑器详情：到 0 不再直接关编辑器丢内容。编辑模式不走
                // 草稿流（scheduleDraftSave/saveDraftNow 均拦编辑态），故不虚构
                // “已存为草稿”；改走在途保存失败同款保留态：编辑器留在页上、
                // 输入冻结为只读（见 refreshPublishingInputFreeze 的
                // editSaveBlockedAfterDeadline 分支）、保存钮持续禁用，15 分钟
                // 规则本身不延长；用户可复制内容后手动关闭，关闭时本地临时图
                // 仍按取消路径清理（见 didTapCancel 编辑分支）。
                self.editTimerLabel.text = "编辑时间已结束"
                self.editTimer?.invalidate()
                self.editTimer = nil
                self.editSaveBlockedAfterDeadline = true
                // B 修法：退场前先收起弹出框（无动画）。
                self.hideCallout(animated: false)
                self.updatePublishState()
                self.showToast(message: "编辑时间已结束，内容已保留，可复制后关闭")
                return
            }
            self.editTimerLabel.text = "剩 \(remain / 60):\(String(format: "%02d", remain % 60))"
        }
        tickBlock()
        editTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tickBlock() }
    }


    // MARK: - 正文与字数

    func textViewDidChange(_ textView: UITextView) {
        // 审计二轮 08：组词落字后补执行被跳过的主题换色（两处 marked 都空才补；
        // refresh 内已清标记，程序化重建不触发本回调，不会重入）。
        if inlineMoodRefreshPending, textView.markedTextRange == nil, headlineField.markedTextRange == nil {
            refreshInlineMoodImages()
        }
        if textView === headlineField {
            headlineDidChange()
            return
        }
        // 审计第 26 项：正文变化递增编辑版本（标题分支已由 headlineDidChange 递增）。
        editorEditVersion += 1
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
        let attributed = textView.attributedText ?? NSAttributedString()
        guard let marked = textView.markedTextRange else {
            return BearyText.inlinePlainText(from: attributed)
        }
        let startOffset = textView.offset(from: textView.beginningOfDocument, to: marked.start)
        let endOffset = textView.offset(from: textView.beginningOfDocument, to: marked.end)
        guard startOffset >= 0, endOffset <= attributed.length, startOffset <= endOffset else {
            return BearyText.inlinePlainText(from: attributed)
        }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.deleteCharacters(in: NSRange(location: startOffset, length: endOffset - startOffset))
        return BearyText.inlinePlainText(from: mutable)
    }

    /// 正文回填统一入口：记号转回熊脸附件（与标题 setHeadlineText 同款中间层），
    /// typingAttributes 复位为正文字体 + 1.7 行高，免得附件后打字跟错样式。
    private func bodyParagraphStyle() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.7
        paragraph.lineBreakMode = .byCharWrapping
        return paragraph
    }

    private func setBodyAttributedText(_ plain: String?) {
        textView.attributedText = BearyText.inlineAttributedText(from: plain ?? "", font: bodyFont, color: BearyColors.ink, paragraphStyle: bodyParagraphStyle(), dark: traitCollection.userInterfaceStyle == .dark)
        textView.typingAttributes = [.font: bodyFont, .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraphStyle()]
        updateCountLabel()
    }

    /// 深浅切换时重建内联熊脸的深浅变体：先转记号再转回图，光标按可见格复位
    /// （组词中不做，免得打断输入法；下次打开编辑器自然是新变体）。
    private func refreshInlineMoodImages() {
        guard textView.markedTextRange == nil, headlineField.markedTextRange == nil else {
            // 审计二轮 08：组词期间跳过换色，记待刷新、落字后补执行（见 textViewDidChange）。
            inlineMoodRefreshPending = true
            return
        }
        inlineMoodRefreshPending = false
        // 无内联心情时不重建：重建会把非心情附件（如粘贴进来的图片）
        // 经 inlinePlainText 丢掉，还会把选区压成光标；只有真有熊脸附件
        // 时才需要换深浅变体（动态墨色本身随主题自动解析，无需重建）。
        guard containsInlineMood(textView.attributedText)
            || containsInlineMood(headlineField.attributedText) else { return }
        let bodySelection = textView.selectedRange
        let headlineSelection = headlineField.selectedRange
        setBodyAttributedText(committedContent())
        setHeadlineText(headlineText)
        // 审计二轮 07：选区长度按新文本长度裁定、不写死 0，选中一段文字切主题后仍是选区。
        textView.selectedRange = clampedSelection(bodySelection, in: textView.attributedText.length)
        headlineField.selectedRange = clampedSelection(headlineSelection, in: headlineField.attributedText.length)
    }

    /// 选区按新文本长度裁定（位置与长度都夹在文本内；UTF-16 单位，与 selectedRange 一致）。
    private func clampedSelection(_ selection: NSRange, in length: Int) -> NSRange {
        let location = min(max(selection.location, 0), length)
        let end = min(max(selection.location + selection.length, location), length)
        return NSRange(location: location, length: end - location)
    }

    /// 是否含内联熊脸附件（主题切换重建的守门：无附件时跳过重建）。
    private func containsInlineMood(_ attributed: NSAttributedString?) -> Bool {
        guard let attributed = attributed, attributed.length > 0 else { return false }
        var found = false
        attributed.enumerateAttribute(BearyText.inlineMoodKeyAttribute, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
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
    /// 扫查组：计量单位须与服务端一致——服务端与网页版均按 JS `.length`
    ///（UTF-16 码元数）判 2000 上限，Swift `.count` 是字素簇数：单个
    /// astral 表情占 1 簇、2 码元，表情多的正文会在客户端放行、服务端
    /// 400 content too long。故落字数直接取已落字串的 utf16.count；
    /// 纯中英文下与原值完全一致，圆环进度与超长红环口径随之对齐服务端。
    /// 与提交检查同口径：提交用去首尾空白后的 trimmedContent() 计长，
    /// 故计数器也取 trim 后的长度——旧口径用未 trim 长度，首尾空白会让
    /// 圆环读数与提交判定读数不同（如正文 1999 字加一串尾空格，圆环
    /// 已超红、提交却不判超限）；纯空白正文计 0，与提交“先写点什么”
    /// 的空判定一致。标题仍按码点计，两处单位不同是各自口径，不统一。
    private func committedTextCount() -> Int {
        return trimmedContent().utf16.count
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
        let ratio = min(1.0, CGFloat(count) / CGFloat(BearyComposerViewController.maxLength))
        charProgressLayer?.strokeEnd = ratio
        if count > BearyComposerViewController.maxLength {
            charProgressLayer?.strokeColor = BearyColors.red.cgColor
            // 审计-编辑器详情：超限时数字不再隐藏——只显红环用户算不出超了
            // 多少；未超限时仍只留圆环（原口径不动）。
            charCountLabel.text = "\(count)"
            charCountLabel.textColor = BearyColors.red
            charCountLabel.isHidden = false
        } else {
            charProgressLayer?.strokeColor = BearyColors.blue.cgColor
            charCountLabel.isHidden = true
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

    /// 未上传完的图片数：key 为空即还没上传完（上传中／失败同计；
    /// 本地文件完整的图已随 localFile 进草稿，见 saveDraftNow 组装处）。
    private func unsavedImageCount() -> Int {
        imageItems.filter { $0.key == nil }.count
    }

    private func updatePublishState() {
        // C11：超长时发布钮保持可用（不禁用），点发布时 toast 报当前字数；上传中仍禁用。
        // U13 改真禁用（2026-11-03 Li 定，旧“视觉置灰但可点、点按给‘先写点什么’”口径作废）：
        // 去空白后正文为空时按钮真禁用，有图也一样；空态下点按无反应、无提示。
        // 超长时保持可用的口径不动。
        // 期限已过且在途保存已失败：保存钮持续禁用（防重发），编辑器仅保留输入供复制。
        // 补拉在途/失败时禁发：此时 lockedQuote 与图片条尚未回填，PUT 会把原引用
        // 与原图误清掉（lockedQuote 为空即清 quote_id 的口径，见 didTapRemoveQuote
        // 注释）；重试成功后 setupEditContent 末尾重调此处即恢复。
        // B2：关闭进行中时发布钮亦禁用——关闭保存与发布提交不得并发
        //（发布会另起一条 saveDraftNow + 请求链，与关闭保存抢同一篇草稿）。
        publishButton.isEnabled = !isPublishing && !isClosing && !isDraftExitSaving && !hasUploadingImage() && !editSaveBlockedAfterDeadline && !editQuoteFetchFailed && !editQuoteFetchInFlight && !trimmedContent().isEmpty
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
    /// B2：关闭保存期间同款冻结（isClosing 进 frozen）：保存期间输入框不再可
    /// 输入，点按入口同禁；冻结经 updatePublishState 统一施加/解除，关闭
    /// 成功随编辑器消失、失败或留页时由 performCloseSave 复位 isClosing 后
    /// 再调 updatePublishState() 恢复。版本核对仍保留（见 performCloseSave）：
    /// 冻结只拦键盘与点按，上传完成回写 key、引用校验回填等异步回包仍可能
    /// 在保存期间递增版本，那时接着保存最新版。
    private func refreshPublishingInputFreeze() {
        // 审计-编辑器详情：期限已过保留态与发布在途同冻——正文/标题只读
        // （UITextView 不可编辑时仍可选区复制），各入口钮同禁，保存钮已由
        // updatePublishState 持续禁用；本位只在期限已过后才为真，不影响常态。
        let frozen = isPublishing || editSaveBlockedAfterDeadline || isDraftExitSaving || isClosing
        textView.isEditable = !frozen
        headlineField.isEditable = !frozen
        // 100 包编辑器面修法：发布在途时可见性钮亦冻结——此前冻结清单
        // 漏了它，在途点钮只改旗标不改已发送值（performPublish 已在请求
        // 前捕获 publishVisibility），视觉上“切成功了”实则无效。
        // 2026-10-31：限时开关已删，钮冻结只看在途态（限时态本身不再锁钮，菜单仍可点开重选）。
        visibilityButton.isEnabled = !frozen
        // P1-14：冻结清单补齐全部入口——草稿 pill、引用钮、三枚已选 Chip、
        // @ 清除、引用卡 ×（含已删行“移除”）；其余入口见下。
        draftPillButton.isEnabled = !frozen
        // 窄屏 5 项之 3：独立行重试钮同属发布冻结清单——在途点重试会与
        // 发布流程并发写同一篇草稿，冻结与工具栏其他入口同口径恢复。
        draftStatusRetryButton.isEnabled = !frozen
        quoteToolButton.isEnabled = !frozen
        moodChipButton.isEnabled = !frozen
        weatherChipButton.isEnabled = !frozen
        recipientChipButton.isEnabled = !frozen
        recipientClearButton.isEnabled = !frozen
        // 例外：通知复选框编辑态本就禁用（refreshRecipientRow 的编辑锁定），
        // 冻结恢复时不得误解开；新建态才随冻结恢复。
        notifyCheckButton.isEnabled = !frozen && !isEditMode
        quoteCardRemoveButton.isEnabled = !frozen
        quoteDeletedRemoveButton.isEnabled = !frozen
        weatherToolButton.isEnabled = !frozen
        moodToolButton.isEnabled = !frozen
        recipientToolButton.isEnabled = !frozen
        // quote-freeze：气温步进/直输与标题清除钮此前不在冻结清单——
        // 快照已保证改动不进载荷，但冻结清单按任务口径补齐，免得用户
        // 在途改了却以为本次提交会带上。位置工具钮同理补齐（其 handler
        // 本就有 isPublishing 第二道守卫，此处是第一道禁用）。
        tempMinusButton.isEnabled = !frozen
        tempPlusButton.isEnabled = !frozen
        tempLabelButton.isEnabled = !frozen
        headlineClearButton.isEnabled = !frozen
        headlineClearHitButton.isEnabled = !frozen
        locationToolButton.isEnabled = !frozen
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
            publishButton.setImage(BearyIconImages.image(named: "icon_send", pointSize: 24), for: .normal)
            publishButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)
            publishRingView.isHidden = true
            BearyIconMotion.stopSpin(on: publishRingView, key: "bearyPublishSpin")
        }
        // 标题/图标/边距三处每次变化都重算显式宽度（标题只在这里与 buildTopBar 改，
        // 故此处是唯一需要跟进的运行时更新点；updatePublishState 每次都走这里）。
        refreshPublishButtonWidth()
    }

    /// 心情插入式（熊脸图版）：点选心情不再改单独心情字段，也不再插名文本，
    /// 而是把熊脸图片附件直接插进光标处。标题与正文都是 UITextView，都能放
    /// 附件（标题换单行 UITextView 就是为此）；插完光标在图后面、焦点留在该框。
    /// 落库中间层：附件发出/存草稿时转记号 `[mood:<key>]`（见 BearyText），
    /// 读回时再转回图；附件在 attributed 里占 1 格，字数与 30 字标题封顶都按
    /// 可见格算。光标处理与旧名文本版同款：标题获焦插标题、正文获焦插正文，
    /// 两框都没焦点时按上次焦点框兜底、从未获焦插正文末尾；组词先提交落字再插。
    /// 数量不限：每次点选新插一段，不替换、不设上限，同心情可重复、不同心情
    /// 可混插；弹出框点选后不收起，可连着插多个。旧心情字段一字不动。
    private func insertMoodImageAtCursor(_ key: String) {
        guard BearyText.bearMoodKeys.contains(key) else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        if headlineField.isFirstResponder || lastFocusedComposerInput == .headline {
            if !headlineField.isFirstResponder {
                headlineField.becomeFirstResponder()
                headlineField.selectedRange = NSRange(location: headlineField.attributedText.length, length: 0)
            }
            if headlineField.markedTextRange != nil {
                headlineField.unmarkText()
            }
            insertMoodAttachment(into: headlineField, key: key, font: headlineFont, dark: dark)
            headlineDidChange()
            return
        }
        if textView.isFirstResponder || lastFocusedComposerInput == .body {
            if !textView.isFirstResponder {
                textView.becomeFirstResponder()
            }
            if textView.markedTextRange != nil {
                textView.unmarkText()
            }
            insertMoodAttachment(into: textView, key: key, font: bodyFont, dark: dark)
            textViewDidChange(textView)
            return
        }
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
        insertMoodAttachment(into: textView, key: key, font: bodyFont, dark: dark)
        textViewDidChange(textView)
    }

    /// 把一个熊脸附件插进指定 UITextView 的当前选区（有选区则替换选区），
    /// 插完光标落在图后 1 格，并把 typingAttributes 复位回该框的正文字体，
    /// 免得图后打字跟了附件字体。
    private func insertMoodAttachment(into textView: UITextView, key: String, font: UIFont, dark: Bool) {
        guard let attachment = BearyText.inlineAttachment(for: key, font: font, dark: dark) else { return }
        let range = textView.selectedRange
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString())
        let safeLocation = min(range.location, mutable.length)
        let safeLength = min(range.length, mutable.length - safeLocation)
        mutable.replaceCharacters(in: NSRange(location: safeLocation, length: safeLength), with: attachment)
        textView.attributedText = mutable
        if textView === headlineField {
            textView.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
        } else {
            textView.typingAttributes = [.font: bodyFont, .foregroundColor: BearyColors.ink, .paragraphStyle: bodyParagraphStyle()]
        }
        textView.selectedRange = NSRange(location: safeLocation + 1, length: 0)
    }

    // MARK: - 图片条

    private func createImageItem(localImage: UIImage?, key: String?, uploading: Bool, localFile: String?, failed: Bool) -> ComposerImageItem {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // 网页 thumb 本身无容器底：单项背后不再铺 faint 底，圆角 10 由容器裁剪提供。
        container.backgroundColor = UIColor.clear
        container.layer.cornerRadius = BearyCorners.single
        container.layer.masksToBounds = true
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = localImage
        container.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapImageItem(_:)))
        container.addGestureRecognizer(tap)
        // 图片上传转圈改网页同款圆环（不再用下拉刷新那套 icon_refresh）。
        let spinner = BearyWebRingSpinnerView()
        // 失败态：行内红底块（网页 thumb-fail 同款：红 10% 底 + 图标 + “上传失败，点按重试”），
        // 点块重试，不弹全局框；发布时有失败图直接 toast 拦截（决议第 5 项 A），不弹框。
        let failView = UIView()
        failView.translatesAutoresizingMaskIntoConstraints = false
        failView.backgroundColor = BearyColors.red.withAlphaComponent(0.10)
        failView.layer.cornerRadius = BearyCorners.single
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
        failLabel.text = "上传失败，点按重试"
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
        // 审计-编辑器详情：新建即上传态的项，× 同为取消入口。
        removeButton.accessibilityLabel = uploading ? "取消上传" : "删除图片"
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
        // 审计-编辑器详情：上传中 × 即取消入口，VoiceOver 明说。
        item.removeButton.accessibilityLabel = "取消上传"
        refreshAttachmentAccessibilityLabels()
    }

    private func markUploaded(_ item: ComposerImageItem, key: String) {
        item.key = key
        item.uploading = false
        item.failed = false
        // B2：key 落袋即改草稿快照内容（上传完成是异步回包）：保存期间
        // 到达时关闭流程须凭版本变化续存最新版（见 performCloseSave），
        // 故这里递增编辑版本；紧随其后的 liveVideoKey 赋值是同一主线程
        // turn，不另增。
        editorEditVersion += 1
        item.failView.isHidden = true
        item.imageView.isHidden = false
        item.imageView.alpha = 1.0
        item.spinner.stopSpinning()
        item.removeButton.accessibilityLabel = "删除图片"
        refreshAttachmentAccessibilityLabels()
    }

    private func markFailed(_ item: ComposerImageItem) {
        item.uploading = false
        item.failed = true
        // B2：与 markUploaded 同口径递增编辑版本，供关闭流程核对
        //（上传失败同样是内容变化；与 B1 合入后失败态进草稿快照，
        // 本支单看时重存一次只是幂等复写，无害）。
        editorEditVersion += 1
        item.failView.isHidden = false
        item.imageView.isHidden = true
        item.spinner.stopSpinning()
        item.removeButton.accessibilityLabel = "删除图片"
        refreshAttachmentAccessibilityLabels()
    }

    /// 无障碍：附件删除钮按条内顺序编号（“删除图片 1”／“取消上传 2”），
    /// 多图时 VoiceOver 不再读出多个同名按钮；增删、撤销恢复、上传态变化
    /// 后都重算，序号始终与条内实际顺序一致，删除行为本身不动。
    private func refreshAttachmentAccessibilityLabels() {
        for (index, item) in imageItems.enumerated() {
            item.removeButton.accessibilityLabel = item.uploading ? "取消上传 \(index + 1)" : "删除图片 \(index + 1)"
        }
    }

    @objc private func didTapImageItem(_ gesture: UITapGestureRecognizer) {
        guard let tappedView = gesture.view else { return }
        for item in imageItems {
            if item.container === tappedView {
                if item.failed {
                    if let name = item.localFile {
                        // 失败图重试：读盘解码也走后台队列，解完回主线程再起上传。
                        let ownerAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
                        imagePrepQueue.async { [weak self, weak item] in
                            let image = BearyDraftImageStore.image(for: name, accountId: ownerAccountId)
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
                // 上传中不进（裁剪源未落定）。
                if item.uploading { return }
                openCropEditorForImageItem(item)
                return
            }
        }
    }

    /// C11：裁剪源解析：优先本地原图，其次条内图。
    private func openCropEditorForImageItem(_ item: ComposerImageItem) {
        if presentedViewController != nil { return }
        if let name = item.localFile {
            let ownerAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
            imagePrepQueue.async { [weak self, weak item] in
                let diskImage = BearyDraftImageStore.image(for: name, accountId: ownerAccountId)
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
        // 审计第 26 项：图片增减同样是字段变化——append 是否触发 didSet
        // 不作依赖，这里显式递增；删除/重置走 imageItems 整体赋值，由 didSet 覆盖。
        editorEditVersion += 1
        imageItems.append(item)
        imageStackView.addArrangedSubview(item.container)
        refreshAttachmentAccessibilityLabels()
        refreshImageStripVisibility()
        updatePublishState()
        updatePreferredContentSize()
    }



    /// 审计-编辑器详情：取消在途上传——cancel 任务 + 代次 +1（迟到回包
    /// 由代次守卫丢弃）+ 清任务句柄与发起账号。上传中缩略图的 × 即取消入口
    /// （进度区，见 markUploading 的无障碍文案）；撤销恢复时
    /// didTapUndoRemovedImage 已会为仍上传态的项重起上传，故取消不丢图。
    /// R22-#6：任务取消、代次 +1、发起账号清掉三者在同一把锁内原子完成；
    /// 仍在后台编码的任务尚未建出，编码完成后的起传门控只认发起时捕获的
    /// 令牌，令牌已作废即不起传。
    private func cancelUpload(for item: ComposerImageItem) {
        uploadStateLock.lock()
        defer { uploadStateLock.unlock() }
        item.uploadTask?.cancel()
        item.uploadTask = nil
        item.uploadGeneration += 1
        item.uploadAccountId = nil
    }

    private func removeImageItem(_ item: ComposerImageItem) {
        cancelUpload(for: item)
        var kept: [ComposerImageItem] = []
        for existing in imageItems {
            if existing !== item {
                kept.append(existing)
            }
        }
        imageItems = kept
        if let name = item.localFile {
            // P2-11：删图走后台队列（本篇记录随后由 scheduleDraftSave 重写，
            // 内存态里该文件已无引用，见 deletePairsIfUnreferencedAsync）。
            BearyDraftImageStore.deletePairsIfUnreferencedAsync([name], excludingDraftId: currentDraftId, forAccount: composerOriginAccountId ?? BearyDraftStore.currentAccountId)
        }
        imageStackView.removeArrangedSubview(item.container)
        item.container.removeFromSuperview()
        refreshAttachmentAccessibilityLabels()
        refreshImageStripVisibility()
        updatePublishState()
        scheduleDraftSave()
        updatePreferredContentSize()
    }

    /// C11：删图不再弹确认：先入单槽缓冲、条内即时消失、撤销条可见 10 秒。
    /// 期间草稿已按删除后状态落盘（scheduleDraftSave），本地文件暂不删；
    /// 点撤销即按原位恢复（含 key/localFile/上传态），恢复后重新落盘。
    private func deleteImageItemWithUndo(_ item: ComposerImageItem) {
        // 审计-编辑器详情：删图即取消在途上传（网络任务不继续跑、回包不回写）。
        cancelUpload(for: item)
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
        refreshAttachmentAccessibilityLabels()
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
        refreshAttachmentAccessibilityLabels()
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
            let ownerAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
            imagePrepQueue.async { [weak self, weak item] in
                let image = BearyDraftImageStore.image(for: name, accountId: ownerAccountId)
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
    /// 切草稿时调用。本地文件后台删除（不堵退场）、key 丢弃（不调服务端，与旧直接删除同款
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
            // P2-11：删图走后台队列；本篇记录随后由 saveDraftNow 按删除后状态
            // 重写，内存态里该文件已无引用，见 deletePairsIfUnreferencedAsync。
            BearyDraftImageStore.deletePairsIfUnreferencedAsync([name], excludingDraftId: currentDraftId, forAccount: composerOriginAccountId ?? BearyDraftStore.currentAccountId)
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

    /// Mantis 裁剪回调转接的持有：delegate 是 weak，须强持有直到回调跑完，
    /// 回调结束由 onFinished 清掉（见下方 presentCropEditor）。
    private var mantisCropHandler: BearyMantisCropHandler?

    private func presentCropEditor(for item: ComposerImageItem, source: UIImage) {
        // 磁盘读图是异步的：回到主线程时若已有弹窗在上（草稿箱等），不再叠页。
        if presentedViewController != nil { return }
        // Mantis 裁剪（3.1.1）：固定 1:1、确认先退场再回调；回调体（applyCroppedImage）未动。
        let cropVC = BearyMantisCrop.makeCropViewController(image: source, aspectRatio: 1)
        let handler = BearyMantisCropHandler(onCrop: { [weak self, weak item] cropped in
            guard let self = self, let item = item else { return }
            self.applyCroppedImage(cropped, to: item)
        }, onFinished: { [weak self] in
            self?.mantisCropHandler = nil
        })
        mantisCropHandler = handler
        cropVC.delegate = handler
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
        // A6：裁剪确认时固定账号与草稿 ID——后台落盘、删旧对与回填一律用这份身份。
        let pickAccountId = BearyDraftStore.currentAccountId
        let pickDraftId = currentDraftId
        imagePrepQueue.async { [weak self, weak item] in
            guard let full = BearyImagePrep.jpegData(cropped, maxSide: 1600, quality: 0.85),
                  let thumb = BearyImagePrep.thumbData(cropped, maxSide: 480) else {
                DispatchQueue.main.async {
                    self?.showToast(message: "裁剪保存失败，原图未改")
                }
                return
            }
            let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb, forAccount: pickAccountId)
            DispatchQueue.main.async {
                guard let self = self, let item = item else {
                    // 项已不在：本次落盘的临时文件清掉，不留孤文件。
                    if let saved = saved {
                        BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                    }
                    return
                }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                if !stillThere {
                    if let saved = saved {
                        BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                    }
                    return
                }
                if let saved = saved {
                    // A6：回填只认裁剪时固定的身份——切号/切篇后不把新图引用写进别的草稿，
                    // 本次临时文件直接清理（旧图、旧 key、旧预览一律不动）。
                    if BearyDraftStore.currentAccountId != pickAccountId || (pickDraftId != nil && self.currentDraftId != pickDraftId) {
                        BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                        return
                    }
                    // 落盘成功才替换预览、清旧 key、删旧本地对（旧 key 指向未裁剪
                    // 原图，不可复用；孤 key 残留与移除同款已知可接受）。
                    // 裁剪同样丢实况：帧已变，旧视频不再对应新帧，继续带旧视频
                    // 会播出与静态帧对不上的实况，故两字段同清、裁后按纯静态重传。
                    // B1：待传视频文件随旧本地对一起删（deletePair 按同 stem
                    // 删 mov，见 BearyDraftImageStore），字段与缺失旗标同清。
                    item.imageView.image = cropped
                    item.key = nil
                    item.liveVideoData = nil
                    item.liveVideoKey = nil
                    item.liveVideoFile = nil
                    item.liveVideoMissing = false
                    item.failed = false
                    item.localFile = saved
                    if let oldName = oldName, oldName != saved {
                        // P2-11：旧图走后台队列删（新图已替换进 imageItems，
                        // 随后 saveDraftNow 按替换后状态落盘）。
                        BearyDraftImageStore.deletePairsIfUnreferencedAsync([oldName], excludingDraftId: self.currentDraftId, forAccount: self.composerOriginAccountId ?? BearyDraftStore.currentAccountId)
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
                // R22-#6：裁剪重传同样先发令牌：编码期间删图作废令牌后，
                // 编码完成也不起传。
                let token = self.issueUploadToken(for: item)
                self.imagePrepQueue.async { [weak self, weak item] in
                    self?.uploadPrepared(for: item, token: token, full: full, thumbData: thumb, image: cropped)
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
        // 实况：filter 含 livePhotos，实况资产才能以 PHLivePhoto 取到视频部分；
        // 非实况资产仍走原 UIImage 路径（见 picker 分流），filter 本身不改上限与顺序。
        config.filter = .any(of: [.images, .livePhotos])
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
            // 实况分流：能取 PHLivePhoto 的资产先走实况路（视频部分经
            // PHAssetResource 导出 mov，静态帧仍走下面同款 JPEG 路径）；
            // 取不到 PHLivePhoto 的资产一律走原静态路，下面的静态分支一字不动。
            // 实况视频读不出 / 超 10MB 时占位项直接移除 + toast，不静默降级
            // 为静态图（降级需用户确认，本处不擅自加降级 UI，失败即不发实况）。
            if provider.canLoadObject(ofClass: PHLivePhoto.self) {
                let item = createImageItem(localImage: nil, key: nil, uploading: true, localFile: nil, failed: false)
                insertImageItem(item)
                provider.loadObject(ofClass: PHLivePhoto.self) { [weak self, weak item] object, _ in
                    guard let livePhoto = object as? PHLivePhoto else {
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else { return }
                            self.removeImageItem(item)
                            self.showToast(message: "未能读取实况视频，未添加")
                        }
                        return
                    }
                    let resources = PHAssetResource.assetResources(for: livePhoto)
                    guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else { return }
                            self.removeImageItem(item)
                            self.showToast(message: "未能读取实况视频，未添加")
                        }
                        return
                    }
                    // R22 #9：实况视频流式写临时文件 + 提前截断——dataReceivedHandler
                    // 每收到一块就追加写盘、只记字节数，整段视频不再常驻内存；
                    // 累计超 10MB 立即取消资源请求，不等读完；临时文件只活到本次
                    // 读取结束，各出口都删。10MB 上限本身不动（仍是上传接受上限）。
                    let videoTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("beary-live-\(UUID().uuidString).mov")
                    guard FileManager.default.createFile(atPath: videoTempURL.path, contents: nil),
                          let videoHandle = try? FileHandle(forWritingTo: videoTempURL) else {
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else { return }
                            self.removeImageItem(item)
                            self.showToast(message: "实况视频读取失败，未添加")
                        }
                        return
                    }
                    var videoBytes = 0
                    var videoOverLimit = false
                    var videoRequestID: PHAssetResourceDataRequestID = 0
                    // iCloud 照片：默认 options 不允许联网，原图只在本地时才
                    // 读得出；开了「优化储存空间」的实况会直接读失败、整张图被
                    // 移除。显式允许联网（PHPicker 的 loadObject 本就自动下载，
                    // 这里须手动开），失败口径与 toast 不变。
                    let videoOptions = PHAssetResourceRequestOptions()
                    videoOptions.isNetworkAccessAllowed = true
                    videoRequestID = PHAssetResourceManager.default().requestData(for: videoResource, options: videoOptions, dataReceivedHandler: { chunk in
                        guard !videoOverLimit else { return }
                        videoHandle.write(chunk)
                        videoBytes += chunk.count
                        if videoBytes > BearyLivePhoto.maxVideoBytes {
                            videoOverLimit = true
                            try? FileManager.default.removeItem(at: videoTempURL)
                            PHAssetResourceManager.default().cancelDataRequest(videoRequestID)
                        }
                    }, completionHandler: { [weak self, weak item] error in
                        // 读盘在后台线程做（completionHandler 本就不在主线程）：
                        // 先关句柄再读文件，超限/失败/读完都删临时文件。
                        try? videoHandle.close()
                        let videoData: Data? = videoOverLimit ? nil : try? Data(contentsOf: videoTempURL)
                        try? FileManager.default.removeItem(at: videoTempURL)
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
                            if videoOverLimit {
                                self.removeImageItem(item)
                                self.showToast(message: "实况视频超过 10MB，未添加")
                                return
                            }
                            if error != nil {
                                self.removeImageItem(item)
                                self.showToast(message: "实况视频读取失败，未添加")
                                return
                            }
                            guard let videoData = videoData, !videoData.isEmpty else {
                                self.removeImageItem(item)
                                self.showToast(message: "实况视频读取失败，未添加")
                                return
                            }
                            if videoData.count > BearyLivePhoto.maxVideoBytes {
                                self.removeImageItem(item)
                                self.showToast(message: "实况视频超过 10MB，未添加")
                                return
                            }
                            item.liveVideoData = videoData
                            // 静态帧：与静态分支同款 UIImage 加载 + 编码落盘，
                            // 唯一差别是上传时附带 liveVideoData（见 uploadPrepared）。
                            provider.loadObject(ofClass: UIImage.self) { [weak self, weak item] stillObject, _ in
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
                                    guard let image = stillObject as? UIImage else {
                                        self.removeImageItem(item)
                                        return
                                    }
                                    item.imageView.image = image
                                    // A6：选图时固定账号与草稿 ID——后台落盘与回填一律用这份身份。
                                    let pickAccountId = BearyDraftStore.currentAccountId
                                    let pickDraftId = self.currentDraftId
                                    // R22-#6：实况路先发令牌再编码：编码期间删图
                                    // 作废令牌后，编码完成也不起传。
                                    let token = self.issueUploadToken(for: item)
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
                                        let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb, forAccount: pickAccountId)
                                        // B1：实况视频随静图落盘（与静图同 stem 的 <uuid>.mov，
                                        // 在 imagePrepQueue 上写盘，不占主线程；只写一次，
                                        // 之后 saveDraftNow 即带上 liveVideoFile，杀 App
                                        // 后仍可从草稿读回续传。写盘失败时 liveVideoFile
                                        // 留空，本轮仍凭内存 liveVideoData 上传。
                                        let videoFile: String?
                                        if let saved = saved, let videoData = item?.liveVideoData {
                                            videoFile = BearyDraftImageStore.saveVideo(data: videoData, forStill: saved)
                                        } else {
                                            videoFile = nil
                                        }
                                        DispatchQueue.main.async {
                                            guard let self = self, let item = item else {
                                                if let saved = saved {
                                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                                }
                                                return
                                            }
                                            var stillThere = false
                                            for existing in self.imageItems {
                                                if existing === item {
                                                    stillThere = true
                                                }
                                            }
                                            if !stillThere {
                                                if let saved = saved {
                                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                                }
                                                return
                                            }
                                            if let saved = saved {
                                                // A6：回填只认选图时固定的身份——切号/切篇后不把引用写进别的草稿，
                                                // 本次临时文件直接清理。
                                                if BearyDraftStore.currentAccountId != pickAccountId || (pickDraftId != nil && self.currentDraftId != pickDraftId) {
                                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                                    return
                                                }
                                                item.localFile = saved
                                            }
                                            if let videoFile = videoFile {
                                                item.liveVideoFile = videoFile
                                            }
                                            self.saveDraftNow()
                                        }
                                        self?.uploadPrepared(for: item, token: token, full: full, thumbData: thumb, image: image, liveVideoData: item?.liveVideoData)
                                    }
                                }
                            }
                        }
                    })
                }
                continue
            }
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
                    // A6：选图时固定账号与草稿 ID——后台落盘与回填一律用这份身份。
                    let pickAccountId = BearyDraftStore.currentAccountId
                    let pickDraftId = self.currentDraftId
                    // 先落盘再上传：选完图立刻有本地文件，杀 App 也不丢图。
                    // 落盘失败则按无本地文件降级（与旧行为一致，草稿里只有 key）。
                    // 编码 + 落盘 + 上传序列化全走后台队列，只编一次（旧写法落盘编一次、
                    // startUpload 又编一次）；主线程只填图与更新 UI。
                    // R22-#6：静态路先发令牌再编码：编码期间删图作废令牌后，
                    // 编码完成也不起传。
                    let token = self.issueUploadToken(for: item)
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
                        let saved = BearyDraftImageStore.save(fullData: full.data, thumbData: thumb, forAccount: pickAccountId)
                        DispatchQueue.main.async {
                            guard let self = self, let item = item else {
                                if let saved = saved {
                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                }
                                return
                            }
                            var stillThere = false
                            for existing in self.imageItems {
                                if existing === item {
                                    stillThere = true
                                }
                            }
                            if !stillThere {
                                if let saved = saved {
                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                }
                                return
                            }
                            if let saved = saved {
                                // A6：回填只认选图时固定的身份——切号/切篇后不把引用写进别的草稿，
                                // 本次临时文件直接清理。
                                if BearyDraftStore.currentAccountId != pickAccountId || (pickDraftId != nil && self.currentDraftId != pickDraftId) {
                                    BearyDraftImageStore.deletePair(fullName: saved, accountId: pickAccountId)
                                    return
                                }
                                item.localFile = saved
                            }
                            self.saveDraftNow()
                        }
                        // 上传用同一份编码结果，不再重编（uploadPrepared 内 base64 与
                        // BearyAPI 的 JSON 序列化都在本后台线程上，不占主线程）。
                        self?.uploadPrepared(for: item, token: token, full: full, thumbData: thumb, image: image)
                    }
                }
            }
        }
    }

    /// 上传入口（重试/续传）：主线程只置上传态，编码 + base64 + 上传序列化走后台队列。
    private func startUpload(for item: ComposerImageItem, image: UIImage) {
        // B1：实况视频已丢的项不起传——无视频重传会把实况静默降级为静态，
        // 须用户重新选择；续传入口已跳过本态，此处是点图重试的第二道守卫。
        if item.liveVideoMissing {
            showToast(message: "这张实况需重新选择")
            return
        }
        markUploading(item)
        // 扫一遍同款（4c）：置上传态即改发布启用态，旧代码只在上传完成回调里
        // 同步，续传/重试起传后到完成前发布态是陈旧的（应禁用时仍显可用）。
        updatePublishState()
        // B4：重试/续传先复用已落盘的 JPEG——账号在主线程捕获（与读图同一身份），
        // 两份文件齐全时直接读已有字节与尺寸，不再对已压缩过的图重编一次。
        let retryAccountId = BearyDraftStore.currentAccountId
        let retryLocalFile = item.localFile
        // R22-#6：重试/续传入口同样先发令牌：编码期间删图作废令牌后，
        // 编码完成也不起传。
        let token = issueUploadToken(for: item)
        imagePrepQueue.async { [weak self, weak item] in
            if let retryLocalFile = retryLocalFile,
               let prepared = BearyDraftImageStore.existingPreparedJPEG(fullName: retryLocalFile, accountId: retryAccountId) {
                self?.uploadPrepared(for: item, token: token, full: prepared.full, thumbData: prepared.thumb, image: image, liveVideoData: item?.liveVideoData)
                return
            }
            // 旧草稿缺文件/读不出时走现有编码兜底。
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
            // 重试/续传：实况项带上内存里的 liveVideoData 一起重传；静态项
            // liveVideoData 为 nil，uploadPrepared 内不附带视频，路径不动。
            self?.uploadPrepared(for: item, token: token, full: full, thumbData: thumb, image: image, liveVideoData: item?.liveVideoData)
        }
    }

    /// 用已编好的数据上传（调用方已在后台线程上；base64 与 BearyAPI 的 JSON 序列化
    /// 都发生在本线程，回调回主线程后只更新 UI 与落盘）。
    /// R22-#6：起传门控——编码完成后、建网络任务前，先校验发起时捕获的
    /// 令牌（代次）与所属账号（发起时绑定的鉴权账号 vs 当前鉴权账号）：
    /// 删图/取消已作废令牌、或切号后账号已变时一律不起传。校验与建任务
    /// 在上传锁内原子完成，取消无法插进两者之间；代次认领改在发起时
    /// （issueUploadToken），此处不再递增。
    private func uploadPrepared(for item: ComposerImageItem?, token: (generation: Int, accountId: Int?), full: (data: Data, w: Int, h: Int), thumbData: Data, image: UIImage, liveVideoData: Data? = nil) {
        guard let item = item else { return }
        let dataUrl = BearyImagePrep.dataURL(full.data)
        let thumbDataUrl = BearyImagePrep.dataURL(thumbData)
        let videoDataUrl = liveVideoData.map { BearyLivePhoto.videoDataURL($0) }
        // 门控 + 建任务原子段：锁内校验令牌与当前鉴权账号，通过才建任务
        // 并持有句柄；取消（同锁内作废令牌 + cancel 任务）无法插进校验与
        // 建任务之间，故删图后编码完成必不发起上传。实况超限口径在门控
        // 之后：已取消的项先由门控静默拦下，不再 toast、不改态。
        // 锁内只做整数校验与任务创建（authAccountId 的读走 authStateQueue，
        // 不回调编辑器，无死锁环；uploadImage 只建任务，不同步回主线程）。
        uploadStateLock.lock()
        defer { uploadStateLock.unlock() }
        guard token.generation == item.uploadGeneration,
              token.accountId == nil || BearyAPI.shared.authAccountId == token.accountId else { return }
        // 实况上传失败口径（防静默降级）：视频超限在选图时已拒收，这里再守
        // 一道；上传失败、或回包缺 live_key（后端未上线/不匹配）时一律按失败
        // 处理——亮红底重试块 + toast，发布亦被失败图拦截，绝不把实况当静态
        // 图发出；点图重试走 startUpload，仍带 liveVideoData 重传。
        if let liveVideoData = liveVideoData, liveVideoData.count > BearyLivePhoto.maxVideoBytes {
            DispatchQueue.main.async {
                // uploadPrepared 入口已解包 item、self 本就是强引用，
                // 此处再 guard let 会因“非 Optional 不能条件绑定”编译失败，
                // 故直接用已解包的 item/self（与本函数其他同步段同款）。
                self.markFailed(item)
                self.showToast(message: "实况视频超过 10MB，未上传")
                self.saveDraftNow()
                self.updatePublishState()
            }
            return
        }
        let uploadGeneration = token.generation
        item.uploadTask = BearyAPI.shared.uploadImage(dataUrl: dataUrl, width: full.w, height: full.h, thumbDataUrl: thumbDataUrl, videoDataUrl: videoDataUrl) { [weak self, weak item] result in
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                var stillThere = false
                for existing in self.imageItems {
                    if existing === item {
                        stillThere = true
                    }
                }
                // 代次门控：取消/删图/重传已推高代次时，过期回包直接丢弃，
                // 不得把旧 key 写回新一轮上传的项（9 图竞态即此类）。代次
                // 在上传锁内读、任务句柄在上传锁内清，与主线程取消/后台
                // 认领走同一同步边界。
                if !stillThere || uploadGeneration != self.lockedUploadGeneration(of: item) {
                    return
                }
                self.lockedClearUploadTask(of: item)
                switch result {
                case .success(let resp):
                    if let key = resp.key {
                        // 实况回包缺 live_key = 视频没落下：按失败处理（见函数头），
                        // 不 markUploaded、不进草稿、不让发布把这张当静态图发出。
                        if liveVideoData != nil, resp.liveKey == nil || resp.liveKey?.isEmpty == true {
                            self.markFailed(item)
                            self.showToast(message: "实况视频上传失败，请点图重试")
                            self.saveDraftNow()
                            self.updatePublishState()
                        } else {
                            self.markUploaded(item, key: key)
                            item.liveVideoKey = resp.liveKey
                            item.liveVideoData = nil
                            // B1：视频已在服务端，本地 mov 不再需要，随即删掉；
                            // 草稿随 scheduleDraftSave 重存为 liveVideoKey、
                            // 不再引用该文件。重存恰好失败又杀 App 的极窄
                            // 窗口里，旧版草稿仍指已删的 mov，恢复时按
                            // “视频已丢”提示重新选择，不静默变静态。
                            if let videoFile = item.liveVideoFile {
                                item.liveVideoFile = nil
                                BearyDraftImageStore.deleteVideo(videoFile)
                            }
                            item.imageView.image = image
                            self.scheduleDraftSave()
                            self.updatePublishState()
                        }
                    } else {
                        self.markFailed(item)
                        self.saveDraftNow()
                        self.updatePublishState()
                    }
                case .failure:
                    // 失败只亮重试态：图留在条里，点图重试；不弹全局框、不删项。
                    // 实况失败多一句 toast（实况是用户明确选中的内容，失败须明说，
                    // 静态失败口径不动；发布时失败图拦截 toast 仍在）。
                    if liveVideoData != nil {
                        self.showToast(message: "实况视频上传失败，请点图重试")
                    }
                    self.markFailed(item)
                    self.saveDraftNow()
                    self.updatePublishState()
                }
            }
        }
    }

    /// B1：恢复草稿的后台解码（restoreDraft 与 loadDraftFromBox 共用）：
    /// 静图按 localFile 解码（失败态不解码，重试点图时再读盘）；待传实况
    /// 视频按 liveVideoFile 读回内存——失败态的视频也要读（点图重试须带
    /// 上视频重传，否则失败的实况会被静默降级为静态重传）。
    /// liveVideoKey 已有时视频已在服务端，不读本地 mov。回调在主线程。
    private func decodeRestoredImages(_ images: [BearyDraftImageItem], accountId: Int? = BearyDraftStore.currentAccountId, completion: @escaping (_ decodedStills: [(name: String, image: UIImage?)], _ liveVideos: [(videoName: String, data: Data?)]) -> Void) {
        imagePrepQueue.async {
            var decoded: [(name: String, image: UIImage?)] = []
            var liveVideos: [(videoName: String, data: Data?)] = []
            for img in images {
                if img.state != .failed, let name = img.localFile {
                    decoded.append((name: name, image: BearyDraftImageStore.image(for: name, accountId: accountId)))
                }
                if img.liveVideoKey == nil, let videoName = img.liveVideoFile {
                    liveVideos.append((videoName: videoName, data: BearyDraftImageStore.videoData(for: videoName)))
                }
            }
            DispatchQueue.main.async {
                completion(decoded, liveVideos)
            }
        }
    }

    /// B1：把解码结果填回图片条：静图填预览（解码失败且有 key 时退回远程
    /// 缩略图）；实况视频填回内存供续传，读不到的记 liveVideoMissing
    ///（保留预览、不自动续传、不静默降级）并提示重新选择。
    /// 调用方在填完后再调 resumePendingUploads。
    private func applyRestoredImages(decoded: [(name: String, image: UIImage?)], liveVideos: [(videoName: String, data: Data?)]) {
        for entry in decoded {
            for item in imageItems {
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
        var missing = false
        for entry in liveVideos {
            for item in imageItems {
                if item.liveVideoFile == entry.videoName {
                    if let data = entry.data {
                        item.liveVideoData = data
                    } else {
                        item.liveVideoMissing = true
                        missing = true
                    }
                }
            }
        }
        if missing {
            showLiveVideoMissingToast()
        }
    }

    /// 重开编辑器时续传：有本地文件、无 key、非失败态的项自动重新上传。
    /// 失败态的项不自动续传，等用户点图重试；本地文件读不出的项置失败态。
    /// B1：实况视频已丢的项（liveVideoMissing）不自动续传——无视频重传
    /// 会把实况静默降级为静态，须用户重新选择。
    /// 一律后台读盘解码（不复用条内图：解码失败时条内可能是远程缩略图，复用会把
    /// 缩略图当原图上传）。
    private func resumePendingUploads() {
        let pending = imageItems
        for item in pending {
            if item.key != nil || item.uploading || item.failed || item.liveVideoMissing {
                continue
            }
            guard let name = item.localFile else { continue }
            let ownerAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
            imagePrepQueue.async { [weak self, weak item] in
                let image = BearyDraftImageStore.image(for: name, accountId: ownerAccountId)
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

    /// 已上传实况映射：静态图 key → 视频 key；无实况的图不进映射。
    /// 只有 key 与 liveVideoKey 双全的项才算实况已就绪（上传中/失败项本
    /// 就被发布拦截，不会走到这里；裁剪/删图后 liveVideoKey 已清）。
    private func uploadedLiveVideos() -> [String: String] {
        var map: [String: String] = [:]
        for item in imageItems {
            if let key = item.key, let liveKey = item.liveVideoKey, !liveKey.isEmpty {
                map[key] = liveKey
            }
        }
        return map
    }

    // MARK: - 编辑模式回填（只读原值，不碰草稿）

    /// C12：编辑回填带加载态与失败路径。quote 体缺失（quote 为空但有 quoteId、
    /// 或 quote 有 id 无正文）时补拉单篇（详情同款 fetchEntry）：拉取中标题为
    /// “加载日记…”，成功后以新 entry 重填；失败则编辑器留在页上、引用区露
    /// “引用的日记加载失败 + 重试”行、保存钮禁用，点重试重新补拉（见
    /// fetchEditEntryForMissingQuote / didTapRetryEditQuoteFetch），不再关编辑器、
    /// 不再发无入口的“请重试”toast。补拉只做一次自动请求（重试由用户点按触发，
    /// 不计入该一次），已删引用（gone 只有 id、无正文）补拉后仍无正文时不再反复请求。
    private func setupEditContent() {
        guard let entry = editingEntry else { return }
        // 录屏批 (b) 同款：面板打开时标题归面板（“选择引用”），回填不许把它顶回
        // “编辑日记”；只把关闭后要还原的标题改成“编辑日记”，关闭时还原即正确。
        if quotePanelOpen {
            quotePanelSavedTitle = "编辑日记"
        } else {
            titleLabel.text = "编辑日记"
        }
        // 正文/标题/心情/天气只首次回填：补拉二次调用 setupEditContent 时用户可能已在
        // 加载期间改过，补拉在途输入未冻结（见 refreshPublishingInputFreeze），无条件重填
        // 会把手改静默盖回服务端旧值；与气温/位置/@ 的 editQuoteFetchAttempted 守卫同款口径。
        if !editQuoteFetchAttempted {
            setBodyAttributedText(entry.content)
            applyBodyLineHeight()
            // 109：编辑回填标题进新输入框（15 分钟内可改，见门控注释）；
            // 无标题时字段留空。
            setHeadlineText(entry.title)
            selectedMood = entry.mood
            selectedWeather = entry.weather
        }
        // 气温只首次回填：补拉二次调用 setupEditContent 时用户可能已在加载
        // 期间手改气温，无条件重填会把手改静默盖回服务端旧值；与正文/标题/
        // 心情/天气/位置/@ 的 editQuoteFetchAttempted 守卫同款口径。
        if !editQuoteFetchAttempted {
            selectedTemperature = entry.temperatureC
        }
        syncWeatherToolButton()
        refreshSelectedChips()
        // 批 E：编辑回填位置（首次回填才以服务端原值为准；补拉二次调用时用户可能已改选，
        // 不覆盖——与 @ 的 editQuoteFetchAttempted 守卫同款口径）。
        if !editQuoteFetchAttempted {
            let editLocation = DiaryLocation(entry: entry)
            originalLocation = editLocation.isEmpty ? nil : editLocation
            selectedLocation = originalLocation
        }
        refreshLocationRow()
        // 补拉重填（setupEditContent 二次调用）不碰 @ 态：用户可能已在加载期间改选/清除，
        // 首次回填时才以服务端原 @ 为准（editQuoteFetchAttempted 此时仍为 false）。
        if !editQuoteFetchAttempted {
            // 32 注销口径：被 @ 者已注销时，编辑器“写给” chip 显“写给 用户已注销”。
            lockedRecipientName = bearyDeletedAuthorDisplayName(entry.mentionedName)
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
            fetchEditEntryForMissingQuote(entryId: entryId)
            return
        }
        if let quote = entry.quote, let quoteId = quote.id, let content = quote.content {
            // 内容为空的引用 = 已删（服务端 gone 只剩 id，网页版同款：已删引用不回填，保存时即丢弃）。
            // 审计 2026-11-02 第十节：编辑锁定同样走有效态（Quote 已补 ephemeral_until
            // 字段；过期存量篇进编辑器时 locked.isPublic 为 false，宿主公开时即触发
            // 下方 maybePresentStoredQuotePrompt 的三选一提示）。
            lockedQuote = SelectedQuote(entryId: quoteId, content: content, createdAt: quote.createdAt, authorName: quote.authorName, authorAvatar: quote.authorAvatar, authorId: quote.authorId, isMine: quote.isMine, authorHandle: quote.authorHandle, images: quote.images ?? [], isPublic: quote.isEffectivelyPublic, publishAt: nil, imgDims: nil, isDeleted: false, visibility: quote.visibility, ephemeralUntil: quote.ephemeralUntil)
        }
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        maybePresentStoredQuotePrompt()
        startEditTimer()
        for key in entry.images ?? [] {
            let item = createImageItem(localImage: nil, key: key, uploading: false, localFile: nil, failed: false)
            // 编辑回填带实况：原图实况 key 随项带回，不动的图 PUT 时原样
            // 发回 live_videos；删图/裁剪会清掉对应项，PUT 映射随之变。
            item.liveVideoKey = entry.liveVideos?[key]
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
        // 审计四轮增量 09：回填完成后查一次编辑检查点（引用缺失补拉时提前
        // return，钩子只在完整回填后跑；每实例只弹一次见 maybeOfferEditCheckpointRestore）。
        maybeOfferEditCheckpointRestore()
    }

    /// 编辑回填补拉单篇（详情同款 fetchEntry），首次自动补拉与失败行“重试”共用：
    /// 拉取中标题为“加载日记…”、失败行暂隐、保存钮禁用；成功后以新 entry 重填
    /// （setupEditContent 二次调用，editQuoteFetchAttempted 仍为 true，故正文/标题/心情/
    /// 天气/气温/位置/@ 的守卫口径不变，不覆盖用户在加载期间的手改）；失败则标题还原为“编辑日记”、
    /// 置 editQuoteFetchFailed 并露失败行、保存钮继续禁用，编辑器不关闭——toast
    /// 直接指到页内重试入口，不再是无入口的“请重试”。重试不重置
    /// editQuoteFetchAttempted：已删引用补拉后仍无正文时走正常回填，不再自动重拉。
    private func fetchEditEntryForMissingQuote(entryId: String) {
        editQuoteFetchInFlight = true
        if quotePanelOpen {
            quotePanelSavedTitle = "加载日记…"
        } else {
            titleLabel.text = "加载日记…"
        }
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        updatePublishState()
        BearyAPI.shared.fetchEntry(id: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.editQuoteFetchInFlight = false
                switch result {
                case .success(let fetched):
                    self.editQuoteFetchFailed = false
                    self.editingEntry = fetched
                    self.setupEditContent()
                case .failure:
                    self.editQuoteFetchFailed = true
                    if self.quotePanelOpen {
                        self.quotePanelSavedTitle = "编辑日记"
                    } else {
                        self.titleLabel.text = "编辑日记"
                    }
                    self.refreshQuoteSection()
                    self.updatePublishState()
                    self.showToast(message: "引用的日记加载失败，点引用区“重试”再试一次")
                }
            }
        }
    }

    /// 补拉失败行“重试”：只在失败态重拉，不碰其他编辑器功能；点击时若已在途
    /// （失败行在途暂隐，正常点按到不了这里）或已非编辑态，直接返回。
    @objc private func didTapRetryEditQuoteFetch() {
        guard isEditMode, editQuoteFetchFailed, !editQuoteFetchInFlight,
              let entryId = editingEntry?.id, !entryId.isEmpty else { return }
        fetchEditEntryForMissingQuote(entryId: entryId)
    }

    /// 回填后原引用的有效 id（setup 时 content 为空的引用视为已删、不算原引用，
    /// 否则改动判定会把“没改过”误判为改过）。
    private func originalQuoteId() -> String? {
        guard let quote = editingEntry?.quote, let quoteId = quote.id, quote.content != nil else { return nil }
        return quoteId
    }

    /// 编辑期内的本地文件（本轮新选的图）：取消/保存成功后删本地文件，不留孤文件；
    /// 原日记的图 localFile 为 nil，不受影响。失败时不删，留着给重试用。
    /// P2-11：主线程只收文件名，删图走后台队列，不堵退场。
    private func deleteEditLocalFiles() {
        let names = imageItems.compactMap { $0.localFile }
        BearyDraftImageStore.deletePairsIfUnreferencedAsync(names, forAccount: composerOriginAccountId ?? BearyDraftStore.currentAccountId)
    }

    // P2：isEditDirty() 为死代码（无调用点），直接删除，不接入其比较口径。

    // MARK: - 草稿

    private func scheduleDraftSave() {
        // 审计四轮增量 09：编辑模式不走草稿流，但走独立检查点（防崩溃丢修改，
        // 见 saveEditCheckpointNow；防抖 400ms 与新建态同款）。
        if isEditMode {
            draftTimer?.invalidate()
            draftTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.saveEditCheckpointNow()
            }
            return
        }
        // R14 P1-6：退出保存进行中不另起防抖保存——退出保存已在调用时拍下
        // 最新快照，待保存计时器亦已由 setDraftExitSaving(true) 失效；此处
        // 再排一笔只会多写一轮、并把状态行刷回“保存中…”盖住退出态。
        // 程序性变化（图片上传完成等）仍由退出保存的版本复核兜底重存。
        if isDraftExitSaving { return }
        // 防抖等待期先显“保存中…”（网页 queueSaveDraft 同款），落盘后由保存级别覆盖。
        // D-G14：网页保存中态带 15px beary-loading 转圈图标（queueSaveDraft 的
        // spin 图标 + “保存中…”），原 App 只出文字无图标；此处换 icon_refresh 图并转圈，
        // 落盘后 updateDraftStatusLabel 会停转并换回对勾。
        draftStatusGroup.isHidden = false
        draftStatusIcon.image = BearyIconImages.image(named: "icon_refresh", pointSize: 15)
        draftStatusIcon.tintColor = BearyColors.gray
        draftStatusIcon.isHidden = false
        // 审计二轮 10：该 key 的转圈已在转时不重加——每次输入都删了重起会把
        // 旋转相位反复归零；落盘后 updateDraftStatusLabel 的 stopSpin 不动。
        if draftStatusIcon.layer.animation(forKey: "bearyDraftSavingSpin") == nil {
            BearyIconMotion.startSpin(on: draftStatusIcon, duration: 0.9, key: "bearyDraftSavingSpin")
        }
        draftStatusLabel.text = "保存中…"
        draftStatusLabel.textColor = BearyColors.blue
        draftTimer?.invalidate()
        // 网页 queueSaveDraft 防抖 400ms（原先 500ms）。
        // R14 P1-7：发火即清引用——此前一次性计时器发火后引用仍非空，
        // draftTimer != nil 不能当“有待保存输入”的信号；清掉后它才是
        // 真正的待保存标志（退后台补存只看它，见 flushPendingDraftSaveForBackground）。
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.draftTimer = nil
            self.saveDraftNow()
        }
    }

    /// 审计四轮 07：失活/入后台时立即冲刷一次未落盘的草稿——防抖 timer 只有
    /// 400ms，进程若在窗口内被终止，最后输入会丢。防抖本身不动，只在这里把
    /// 待触发的 timer 取消、直接调 saveDraftNow（已有串行队列＋原子写＋失败回传，
    /// 不重做保存链路）。后台执行时间不足时用后台任务兜底：保存完成（或系统
    /// 到期）即结束任务；版本未变说明冲刷后无新输入，不重复写盘。
    @objc private func flushDraftBeforeBackground() {
        // 审计四轮增量 09：编辑模式不写草稿，但冲刷检查点（防最后 400ms
        // 窗口内切后台/被杀丢修改；与新建态同款后台任务兜底）。
        if isEditMode {
            flushEditCheckpointBeforeBackground()
            return
        }
        guard editorEditVersion != lastBackgroundFlushVersion else { return }
        lastBackgroundFlushVersion = editorEditVersion
        draftTimer?.invalidate()
        draftTimer = nil
        if backgroundDraftTask == .invalid {
            backgroundDraftTask = UIApplication.shared.beginBackgroundTask(withName: "draft-flush") { [weak self] in
                guard let self = self else { return }
                if self.backgroundDraftTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundDraftTask)
                    self.backgroundDraftTask = .invalid
                }
            }
        }
        saveDraftNow { [weak self] _ in
            guard let self = self else { return }
            if self.backgroundDraftTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundDraftTask)
                self.backgroundDraftTask = .invalid
            }
        }
    }

    /// 编辑检查点入后台冲刷：取消防抖 timer、直接写一次检查点；版本未变
    /// 说明冲刷后无新输入，不重复写盘（与新建态 flush 同款守卫）。
    private func flushEditCheckpointBeforeBackground() {
        guard editorEditVersion != lastBackgroundFlushVersion else { return }
        lastBackgroundFlushVersion = editorEditVersion
        draftTimer?.invalidate()
        draftTimer = nil
        if backgroundDraftTask == .invalid {
            backgroundDraftTask = UIApplication.shared.beginBackgroundTask(withName: "beary_edit_checkpoint_flush") { [weak self] in
                guard let self = self else { return }
                if self.backgroundDraftTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundDraftTask)
                    self.backgroundDraftTask = .invalid
                }
            }
        }
        saveEditCheckpointNow { [weak self] _ in
            guard let self = self else { return }
            if self.backgroundDraftTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundDraftTask)
                self.backgroundDraftTask = .invalid
            }
        }
    }

    /// saveDraftNow 完成结果（主线程回调）。
    /// - succeeded：本次落盘是否成功。编辑模式走检查点（见 saveEditCheckpointNow），
    ///   检查点写成功/与原文一致无可写均记成功（无新输入待保存，关闭不拦）；
    ///   无内容删篇成功亦记成功；删篇失败、写盘失败、回读不到本篇均记失败。
    /// - hadPreviousSavedVersion：只在失败时用于文案区分——写盘前库里是否已有本篇旧版。
    ///   save 是原子写，失败时旧文件原样保留，故失败后回读仍命中本篇即等价于旧版在；
    ///   成功时该位恒真、无意义，调用方只在失败时读它。
    struct DraftSaveResult {
        let succeeded: Bool
        let hadPreviousSavedVersion: Bool
    }

    /// R14 P1-6：退出保存进行态开关（关闭／保留并新建两路共用）。
    /// 置位：待保存防抖计时器失效（退出保存调用时已拍下最新快照，计时器
    /// 再触发只是重复写同一版），状态行显“保存中…”＋转圈（与
    /// scheduleDraftSave 同款视觉），refreshPublishingInputFreeze 冻住
    /// 全部输入与入口钮；清位：停转、按保存级别刷新状态行、解冻。
    /// 只在终态调用（成功／失败），版本复核的重存中途保持置位。
    private func setDraftExitSaving(_ saving: Bool) {
        guard isDraftExitSaving != saving else { return }
        isDraftExitSaving = saving
        if saving {
            draftTimer?.invalidate()
            draftTimer = nil
            draftStatusGroup.isHidden = false
            draftStatusIcon.image = BearyIconImages.image(named: "icon_refresh", pointSize: 15)
            draftStatusIcon.tintColor = BearyColors.gray
            draftStatusIcon.isHidden = false
            BearyIconMotion.startSpin(on: draftStatusIcon, duration: 0.9, key: "bearyDraftSavingSpin")
            draftStatusLabel.text = "保存中…"
            draftStatusLabel.textColor = BearyColors.blue
        } else {
            BearyIconMotion.stopSpin(on: draftStatusIcon, key: "bearyDraftSavingSpin")
            updateDraftStatusLabel()
        }
        refreshPublishingInputFreeze()
    }

    /// R14 P1-6：带版本＋身份复核的退出保存（保留并新建路径；关闭路径的
    /// 版本复核由 #1002 的 performCloseSave 负责，本支不重复，
    /// 合入 rebase 时把本方法的冻结／状态接入 #1002 的 helper 终态分支）。
    /// 调用前记下 editorEditVersion；身份以调用前确认的 currentDraftId 为
    /// 准（为空时按 saveDraftNow 同款当场生成，事后无法反推）。成功回包时：
    /// 身份变了（已切到另一篇）按失败口径留页，绝不清空别人的篇；身份为空
    /// 是空内容删篇路径的正常终态（saveDraftNow 已清槽位），放行；版本变
    /// 了说明保存期间有新输入，首拍快照已过期，以最新内容再存一轮（冻结
    /// 已拦住手动输入，再存只为兜底程序性变化；最多重存 3 轮，停笔后收敛）。
    /// 失败仍按原口径留页重试；冻结／状态只在终态清，不在重存中途清。
    private func saveDraftVersionedForExit(attempt: Int = 0, completion: @escaping (DraftSaveResult) -> Void) {
        let snapshotVersion = editorEditVersion
        if currentDraftId == nil {
            currentDraftId = BearyDraftStore.newDraftId()
            clearedCurrentDraftId = nil
        }
        let snapshotDraftId = currentDraftId
        setDraftExitSaving(true)
        saveDraftNow { [weak self] result in
            guard let self = self else { return }
            guard result.succeeded else {
                self.setDraftExitSaving(false)
                completion(result)
                return
            }
            // 身份校验：保存期间已切篇时回包属于旧篇，不得按新篇成功处理。
            guard self.currentDraftId == snapshotDraftId || self.currentDraftId == nil else {
                self.setDraftExitSaving(false)
                completion(DraftSaveResult(succeeded: false, hadPreviousSavedVersion: true))
                return
            }
            // 版本校验：保存期间有新输入，再存一轮最新内容再走调用方终态。
            if self.editorEditVersion != snapshotVersion, attempt < 3 {
                self.saveDraftVersionedForExit(attempt: attempt + 1, completion: completion)
                return
            }
            self.setDraftExitSaving(false)
            completion(result)
        }
    }

    /// R14 P1-7：记一笔草稿写盘在途（入队时调）；回包时调 endDraftSaveFlight，
    /// 计数归零即放行排队等候的退后台补存回调。计数只在主线程读写。
    private func beginDraftSaveFlight() {
        draftSaveInFlightCount += 1
    }

    private func endDraftSaveFlight() {
        draftSaveInFlightCount = max(0, draftSaveInFlightCount - 1)
        guard draftSaveInFlightCount == 0 else { return }
        let waiting = draftSaveDrainCompletions
        draftSaveDrainCompletions = []
        waiting.forEach { $0() }
    }

    /// R14 P1-7：退后台前立即提交待保存版本（SceneDelegate 的
    /// sceneWillResignActive / sceneDidEnterBackground 调）。
    /// 只丢最后 400ms 防抖窗口内、计时器还没触发的那一段：计时器待触发
    /// 时当场失效并立即拍快照落盘（快照在 saveDraftNow 调用时主线程同步建，
    /// 已落字全在里面）；计时器已空、但写盘仍在途时不重复写，只等在途那笔
    /// 回包；无待保存内容时同步回调用。完成回调一律主线程。
    /// 注意：计时器发火后 draftTimer 已置 nil（见 scheduleDraftSave），
    /// 故 draftTimer != nil 即等价于“有待保存输入”；编辑模式不走草稿流，
    /// 直接回调用。调用方（SceneDelegate）持后台任务等完成回调，过期
    /// handler 兜底；编辑器已释放时回包不触发、由过期 handler 收尾。
    func flushPendingDraftSaveForBackground(completion: @escaping () -> Void) {
        guard !isEditMode else {
            completion()
            return
        }
        if draftTimer != nil {
            draftTimer?.invalidate()
            draftTimer = nil
            saveDraftNow { _ in completion() }
            return
        }
        if draftSaveInFlightCount > 0 {
            draftSaveDrainCompletions.append(completion)
            return
        }
        completion()
    }

    /// 立即落盘（主线程只拍快照，整库读/写走 BearyDraftStore.ioQueue；写盘本身已是原子替换）。
    /// completion 在主线程回调（存完才开草稿箱 / 保留后才关编辑器等顺序敏感路径用），
    /// 回调带 DraftSaveResult：关闭路径须按 succeeded 决定是否走 onCancelled，
    /// 失败时不关闭、留页提示重试（P0：此前无条件关闭，失败红字随页面消失）。
    private func saveDraftNow(completion: ((DraftSaveResult) -> Void)? = nil) {
        // 审计四轮增量 09：编辑模式不写草稿，但写独立检查点（防崩溃丢修改）。
        // 此处不再假装成功——回传检查点的真实成败，关闭/保留路径按它决定
        // 是否留页重试（新建态同款口径）；写盘按入队账号分桶（见 saveEditCheckpointNow）。
        if isEditMode {
            saveEditCheckpointNow { succeeded in
                completion?(DraftSaveResult(succeeded: succeeded, hadPreviousSavedVersion: false))
            }
            return
        }
        // P1-4：已发布守卫——成功回包后待执行的自动保存若触发，
        // 不得把已发布内容当新草稿落盘；按成功回传（内容已发布，无新输入待保存）。
        if publishedCurrentDraft {
            completion?(DraftSaveResult(succeeded: true, hadPreviousSavedVersion: false))
            return
        }
        // 发布发起账号失配：不写盘、不生成新 draftId/clientReq、不碰
        // 当前账号的草稿桶。旧代码只在入队时捕获账号防“排队期间切号”，
        // 挡不住 401 重登后再次调用 saveDraftNow（此时当前账号已是新号，
        // 捕获到的就是新号，旧内容会原样写进新号文件）。失配时按失败回传，
        // 关闭/保留路径沿旧口径留页重试；状态行置红，不谎称已保存。
        // P0-1：首次发布前 publishOriginAccountId 未定，此时
        // isPublishOriginMismatch 认打开时绑定的 composerOriginAccountId，
        // 同样拦下——重登后自动保存不再把旧内容写进新号桶。
        // hadPreviousSavedVersion 计真：发布起点 didTapPublish 已落盘一次，
        // 原账号桶里已有本次发布前的版本，旧版未被本次调用覆盖。
        if isPublishOriginMismatch() {
            draftStatusLevel = 0
            updateDraftStatusLabel()
            completion?(DraftSaveResult(succeeded: false, hadPreviousSavedVersion: true))
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
            // 上文刚生成过两者，此分支实际不可达；沿旧口径照常回调，不拦后续流程。
            completion?(DraftSaveResult(succeeded: true, hadPreviousSavedVersion: false))
            return
        }
        // C10 空判定（心情不算内容）：正文 trim 为空、且无图、无天气、无 @、
        // 无引用时，整篇视为空——已有草稿删篇并隐藏状态，不新建空草稿。
        // 审计四轮增量 08（新口径）：本地文件完整的未上传图也算内容、也进草稿
        // （pending 态，重进时续传/重试），故空判定与落盘图片都看“有 key 或有
        // 本地文件”的图；连本地文件都没有的内存项仍不进草稿。
        var hasRealContent = !trimmedContent().isEmpty
            || selectedWeather != nil || selectedRecipient != nil || selectedQuote != nil
            || selectedLocation != nil || !headlineText.isEmpty
        if !hasRealContent {
            for item in imageItems {
                if item.key != nil || item.localFile != nil {
                    hasRealContent = true
                    break
                }
            }
        }
        if !hasRealContent {
            let deletingId = draftIdValue
            currentDraftId = nil
            clearedCurrentDraftId = nil
            draftClientReq = nil
            // 删篇走 deleteAsyncReporting（ioQueue 内删，完成后回主线程刷新状态与 pill，
            // 并回传成败——此前 deleteAsync 不回传，删篇失败会被关闭路径当成功关掉）。
            // 状态只在仍是空篇时清：删盘期间用户已开始写新篇（currentDraftId 已换）
            // 时不碰新篇的状态行，pill 宽度刷新无妨（审计第 25 项：纯图标固定 44，无计数）；删篇失败时置红，与写盘失败同口径。
            // R14 P1-7：在途计数（回包时 endDraftSaveFlight，退后台补存据此等）。
            self.beginDraftSaveFlight()
            BearyDraftStore.deleteAsyncReporting(draftId: deletingId, forAccount: composerOriginAccountId ?? BearyDraftStore.currentAccountId) { [weak self] deleted in
                guard let self = self else { return }
                if self.currentDraftId == nil {
                    self.draftStatusLevel = deleted ? nil : 0
                    self.updateDraftStatusLabel()
                }
                self.refreshDraftPillWidth()
                // 删篇失败时旧文件原样保留（见 deleteAsyncReporting 注释），
                // 故失败即按“旧版还在”计，关闭文案不夸大成整篇已丢。
                self.endDraftSaveFlight()
                completion?(DraftSaveResult(succeeded: deleted, hadPreviousSavedVersion: !deleted))
            }
            return
        }
        var images: [BearyDraftImageItem] = []
        for item in imageItems {
            guard item.key != nil || item.localFile != nil else { continue }
            // 审计四轮增量 08：已上传图 state .uploaded；本地文件完整、未上传
            // 成功的图 state .pending（失败态 .failed），随 localFile 进草稿，
            // 重进时按 state 续传/重试（见 restoreDraft/loadDraftFromBox）。
            // 实况已上传项随 liveVideoKey 进草稿：杀 App 后恢复仍能重建
            // live_videos 映射；B1：待传实况随 liveVideoFile 进草稿（视频
            // 已落盘），杀 App 后从草稿读回 liveVideoData 再续传（见
            // decodeRestoredImages），不再静默变静态。
            let state: BearyDraftImageState
            if item.key != nil {
                state = .uploaded
            } else if item.failed {
                state = .failed
            } else {
                state = .pending
            }
            images.append(BearyDraftImageItem(localFile: item.localFile, serverKey: item.key, state: state, liveVideoKey: item.liveVideoKey, liveVideoFile: item.liveVideoFile))
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
            title: headlineForCreate,
            mood: selectedMood,
            images: images,
            clientReq: req,
            updatedAt: Date().timeIntervalSince1970,
            weather: selectedWeather,
            temperature: selectedTemperature,
            locationName: selectedLocation?.name,
            locationDistrict: selectedLocation?.district,
            visibilitySegmentIndex: selectedVisibilityFriends ? 2 : (selectedVisibilityPublished ? 1 : 0),
            ephemeralEnabled: isEditMode ? false : isEphemeral,
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
            quoteVisibility: selectedQuote?.visibility,
            quoteEphemeralUntil: selectedQuote?.ephemeralUntil,
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
        // P0-1：优先用打开编辑器时绑定的账号（composerOriginAccountId），
        // 未绑定（老路径/游客）时退回全局当前账号；失配已在函数开头拦下，
        // 到这里的绑定账号与当前账号一致或当前账号未定。
        let saveAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
        // 审计二轮 05：保存发起时拍下编辑版本，落盘期间继续输入会使版本 +1；
        // 完成回调须同时校验版本，旧保存不把新内容提前标成“已保存”。
        let saveBaselineVersion = editorEditVersion
        // R14 P1-7：在途计数（回包时 endDraftSaveFlight，退后台补存据此等）。
        beginDraftSaveFlight()
        BearyDraftStore.ioQueue.async { [weak self] in
            let writeSucceeded = BearyDraftStore.save(draft, forAccount: saveAccountId)
            // 保存级别跟随图片状态：有失败/未上传的图 = 1（已保存，图片还没上传完），否则 2；
            // 落盘失败 = 0（失败红字）。saveAll 是原子写，失败时旧库原样保留，
            // 故已有草稿更新失败时回读仍命中旧版本——必须以 save 的 Bool 为准，
            // 回读只作辅助确认（save 成功仍回读不到本篇同样判失败），不得以回读
            // 命中掩盖写失败；多槽下必须按 draftId 查本篇，不能用“库非空”当成功信号。
            // 审计第 25 项：回读循环只确认本篇是否存在（foundCurrentDraft），
            // 不再计总数——总数此前只供已删除的 setDraftPillCount 使用。
            var foundCurrentDraft = false
            for savedDraft in BearyDraftStore.loadAll(forAccount: saveAccountId) {
                if savedDraft.draftId == draftIdValue {
                    foundCurrentDraft = true
                }
            }
            // 成功 = 写盘成功且回读确认本篇存在；任一不成立均为失败。
            let savedCurrentDraft = writeSucceeded && foundCurrentDraft
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 状态只在三项全对时写：仍是本篇、仍是入队时的账号、入队后
                // 无新输入（版本未变）。任一失配都说明这份回包已过期——
                // 新一轮保存已入队/在途，或排队期间已切号；旧回包不碰状态行，
                // “保存中…”留给新一轮的回包去覆盖成“已保存”。
                // pill 宽度刷新与 completion 照常：pill 与内容无关，本次落盘
                // 本身的成败关闭路径仍须知道。
                if self.currentDraftId == draftIdValue,
                   BearyDraftStore.currentAccountId == saveAccountId,
                   self.editorEditVersion == saveBaselineVersion {
                    if savedCurrentDraft == false {
                        self.draftStatusLevel = 0
                    } else {
                        self.draftStatusLevel = hasUnsavedImageSnapshot ? 1 : 2
                    }
                    self.updateDraftStatusLabel(animated: true)
                }
                self.refreshDraftPillWidth()
                // 原子写：失败时旧文件原样保留，故失败后回读仍命中本篇
                // 即等价于写盘前已有旧版；成功时该位恒真、无意义，关闭文案只在失败时读它。
                self.endDraftSaveFlight()
                completion?(DraftSaveResult(succeeded: savedCurrentDraft, hadPreviousSavedVersion: foundCurrentDraft))
            }
        }
    }

    /// FAB 打开时的草稿恢复（E1-3）：整库读 + 无主文件回收走 BearyDraftStore.ioQueue，
    /// 本地图解码走图片后台队列，主线程只填字段与建项；恢复完成 350ms 后 toast（网页同款）。
    private func restoreDraft() {
        // 审计第 26 项：打开编辑器时记下编辑版本与草稿身份基线（主线程、
        // 入队前拍定）。读盘在后台队列，落地时任一基线变化都说明用户已
        // 动过编辑器或已切篇，整单跳过恢复，不覆盖已填字段。
        let restoreBaselineVersion = editorEditVersion
        let restoreBaselineDraftId = currentDraftId
        let restoreBaselineClearedDraftId = clearedCurrentDraftId
        // P0-1：恢复读盘认打开时绑定的账号（入队前捕获，执行中不再重读
        // 全局值，与 saveDraftNow 的捕获口径一致）；两次读都用同一捕获值，
        // 重登后不把新号桶的草稿恢复进旧编辑器。
        let restoreAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
        BearyDraftStore.ioQueue.async { [weak self] in
            // P2-10：一次 loadAll 同时取最新草稿与引用集合——旧代码先 load()
            // （内部又是一次完整 loadAll 再取首项）再 loadAll()，两次读盘
            // 两倍成本；且两份结果独立，第二次读失败时 sweep 只保留最新一
            // 篇的图片、误删其他篇图片。恢复与清理现用同一份数据。
            let allDrafts = BearyDraftStore.loadAll(forAccount: restoreAccountId)
            guard let draft = allDrafts.first else { return }
            // 回收无主文件（杀 App 后、首存前产生的孤文件）：多槽下必须保留全部草稿的
            // 引用并集，只留本篇会误删其他篇的本地图片。
            var referenced = Set<String>()
            for otherDraft in allDrafts {
                for img in otherDraft.images {
                    if let name = img.localFile {
                        referenced.insert(name)
                    }
                }
            }
            BearyDraftImageStore.sweep(keeping: referenced, accountId: restoreAccountId)
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 52 批补充：恢复竞态门——恢复是异步读盘，落地时用户可能已经打过字；
                // 此时整段覆盖会抹掉刚打的字（拼音组词中还会被 attributedText 重设打散）。
                // 用户已打字时整单跳过恢复（旧草稿仍在草稿箱，不丢），只字为空时才应用。
                // 审计第 26 项：正文空门只拦正文——已填标题/天气/位置等此前仍会被
                // 下文整单覆盖，故再加版本与身份双门：读盘期间任何字段变化
                // （didSet/正文/标题/图片入口均已递增版本）或草稿身份变化
                // （切篇、删正在写篇、保存建新篇）都整单跳过；旧草稿仍在箱里，不丢。
                guard self.editorEditVersion == restoreBaselineVersion,
                      self.currentDraftId == restoreBaselineDraftId,
                      self.clearedCurrentDraftId == restoreBaselineClearedDraftId else { return }
                let wasEmptyBeforeRestore = self.textView.text.isEmpty
                guard wasEmptyBeforeRestore else { return }
                self.currentDraftId = draft.draftId
                self.clearedCurrentDraftId = nil
                self.draftClientReq = draft.clientReq
                self.setBodyAttributedText(draft.content)
                self.applyBodyLineHeight()
                // 恢复后光标置末尾（接着写）：未出现时由 viewDidAppear 兜底，已聚焦且
                // 恢复前为空时也置末尾；恢复前已有用户输入时不抢光标。
                if self.view.window == nil || (wasEmptyBeforeRestore && self.textView.isFirstResponder) {
                    // 同 viewDidAppear 兜底：selectedRange 用 UTF-16 单位，
                    // 含 emoji 的草稿用 .count 会把光标落在正文中间。
                    self.textView.selectedRange = NSRange(location: self.textView.attributedText.length, length: 0)
                }
                // 109：草稿标题回填进新输入框。
                self.setHeadlineText(draft.title)
                self.selectedMood = draft.mood
                self.selectedWeather = draft.weather
                self.selectedTemperature = draft.temperature
                // 草稿恢复先赋值后刷新：先刷新时天气还是旧值（nil），步进器与
                // 天气 chip 会被刷成隐藏、随后赋值却不再刷新（与草稿箱打开路径一致）。
                self.refreshSelectedChips()
                self.syncWeatherToolButton()
                self.restoreVisibility(index: draft.visibilitySegmentIndex, ephemeral: draft.ephemeralEnabled)
                self.selectedRecipient = self.restoredRecipient(from: draft)
                self.notifyRecipient = draft.notifyRecipient
                self.selectedQuote = self.restoredQuote(from: draft)
                // 批 E：草稿位置恢复（两段文本，无坐标）；双空即无位置，不留空行。
                let restoredLocation = DiaryLocation(name: draft.locationName, district: draft.locationDistrict)
                self.selectedLocation = restoredLocation.isEmpty ? nil : restoredLocation
                self.refreshRecipientRow()
                self.refreshQuoteSection()
                self.refreshLocationRow()
                for img in draft.images {
                    let failed = (img.state == .failed)
                    let item = self.createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
                    item.liveVideoKey = img.liveVideoKey
                    // B1：待传实况才带本地视频文件名（已上传项只留 liveVideoKey，
                    // 视频已在服务端，不再读本地 mov）；pending/failed 项按
                    // state 原样建项，续传/重试走下文解码后的同一格。
                    if img.liveVideoKey == nil {
                        item.liveVideoFile = img.liveVideoFile
                    }
                    self.insertImageItem(item)
                    // 只有 key 的老项（v1 迁移而来）走远程缩略图；有本地文件的项等后台解码后填图。
                    if img.localFile == nil, let key = img.serverKey,
                       let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                        item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
                    }
                }
                self.updateCountLabel()
                self.refreshToolStrip()
                self.refreshDraftPillWidth()
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
                // B1：待传实况视频同批读回内存（见 decodeRestoredImages），
                // 读不到的记 liveVideoMissing，续传时跳过、不静默变静态。
                let decodingImages = draft.images
                self.decodeRestoredImages(decodingImages, accountId: restoreAccountId) { [weak self] decoded, liveVideos in
                    guard let self = self else { return }
                    self.applyRestoredImages(decoded: decoded, liveVideos: liveVideos)
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

    /// v3 @ 快照还原为选人对象：id 为空即无 @；展示名/头像只供 chip 显示。
    private func restoredRecipient(from draft: BearyDraft) -> SearchUser? {
        guard let recipientUserId = draft.recipientId else { return nil }
        return SearchUser(id: recipientUserId, displayName: draft.recipientName, handle: nil, avatarUrl: draft.recipientAvatar, coverUrl: nil)
    }

    /// 草稿可见性恢复：index 与 selectedVisibilityPublished 同步写（发布
    /// 即读后者，只写 index 不动它仍会发出私密）；ephemeral=true 时恢复为
    /// 限时态（公开 + 限时标记），老草稿无限时键时缺省 false，走旧私密/公开态；
    /// 好友第一期：index=2 恢复为仅好友档；非法 index 一律按私密兜底。restoreDraft 与 loadDraftFromBox 两路共用。
    /// （旧“限时开时钮锁死”口径随开关删除而作废：恢复后菜单仍可点开重选。）
    private func restoreVisibility(index: Int, ephemeral: Bool = false) {
        if ephemeral {
            selectedVisibilityPublished = true
            selectedVisibilityFriends = false
            isEphemeral = true
        } else if index == 2 {
            selectedVisibilityPublished = false
            selectedVisibilityFriends = true
            isEphemeral = false
        } else {
            let restoredIndex = index == 1 ? 1 : 0
            selectedVisibilityPublished = restoredIndex == 1
            selectedVisibilityFriends = false
            isEphemeral = false
        }
        refreshVisibilityButton()
        refreshLocationRow()
    }

    /// v3 引用快照还原为选引用对象：quoteId 为空即无引用；已删标记照原样带回，
    /// 快照正文在已删态下不展示（见 refreshQuoteSection 的已删行）。
    private func restoredQuote(from draft: BearyDraft) -> SelectedQuote? {
        guard let quoteEntryId = draft.quoteId else { return nil }
        // 审计 2026-11-02 第十节：草稿还原同样走有效态——存量限时篇过期后
        // 还原即私密，不再沿用草稿保存时的原始 isPublic。
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let restoredIsPublic: Bool? = {
            guard let pub = draft.quoteIsPublic else { return nil }
            if let until = draft.quoteEphemeralUntil, until <= nowMs { return false }
            return pub
        }()
        return SelectedQuote(entryId: quoteEntryId, content: draft.quoteContent ?? "", createdAt: draft.quoteCreatedAt, authorName: draft.quoteAuthorName, authorAvatar: draft.quoteAuthorAvatar, authorId: nil, isMine: nil, authorHandle: nil, images: draft.quoteImages, isPublic: restoredIsPublic, publishAt: nil, imgDims: nil, isDeleted: draft.quoteDeleted, visibility: draft.quoteVisibility, ephemeralUntil: draft.quoteEphemeralUntil)
    }

    /// 恢复后校验引用是否还在：快照只能证明“选过”，不能证明“还在”。
    /// 只读单篇接口；仅 notFound 才翻为已删态并落盘标记（下次恢复直接显已删，
    /// 不再请求），其他失败（离线/未登录/服务端错）一律保留快照，不误判已删。
    /// 回包时若引用已被用户换掉或清除，不碰当前引用。
    /// B6：回包占位/明确无权限时收起旧预览（清正文/缩略图，ID 与移除入口保留）。
    private func verifyRestoredQuote() {
        guard let quote = selectedQuote, quote.isDeleted == false else { return }
        let quoteEntryId = quote.entryId
        BearyAPI.shared.fetchEntry(id: quoteEntryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentQuote = self.selectedQuote, currentQuote.entryId == quoteEntryId, currentQuote.isDeleted == false else { return }
                switch result {
                case .success(let fetched):
                    // B6：回包占位或明确无权限时收起旧预览；仅好友档走互关校验
                    // （与详情门 / BearyQuoteGate 同口径）；可预览时按 #6 同步
                    // 刷新正文/图片/createdAt（见 applyRestoredQuoteVerified）。
                    let viewerId = SessionManager.shared.currentUser?.id
                    let viewerIsAuthor = fetched.isMine == true || (fetched.authorId != nil && viewerId != nil && fetched.authorId == viewerId)
                    if fetched.placeholder == true || (!viewerIsAuthor && !BearyEphemeral.isEffectivelyPublic(fetched) && !fetched.isFriendsOnly) {
                        self.applyRestoredQuoteUnavailable(currentQuote: currentQuote, fetched: fetched)
                        return
                    }
                    if fetched.isFriendsOnly, !viewerIsAuthor {
                        if SessionManager.shared.isLoggedIn, let authorId = fetched.authorId {
                            BearyAPI.shared.fetchFollowState(userId: authorId) { [weak self] stateResult in
                                DispatchQueue.main.async {
                                    guard let self = self else { return }
                                    guard let currentQuote = self.selectedQuote, currentQuote.entryId == quoteEntryId, currentQuote.isDeleted == false else { return }
                                    let mutual: Bool = {
                                        if case .success(let state) = stateResult {
                                            return (state.mutual ?? false) || ((state.following ?? false) && (state.followedBy ?? false))
                                        }
                                        return false
                                    }()
                                    if mutual {
                                        self.applyRestoredQuoteVerified(currentQuote: currentQuote, fetched: fetched)
                                    } else {
                                        self.applyRestoredQuoteUnavailable(currentQuote: currentQuote, fetched: fetched)
                                    }
                                }
                            }
                        } else {
                            // 未登录看不到仅好友篇（与详情门同口径 fail-closed）。
                            self.applyRestoredQuoteUnavailable(currentQuote: currentQuote, fetched: fetched)
                        }
                        return
                    }
                    self.applyRestoredQuoteVerified(currentQuote: currentQuote, fetched: fetched)
                    return
                case .failure(let fetchError):
                    if case .notFound = fetchError {
                        self.selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: "", createdAt: nil, authorName: nil, authorAvatar: nil, authorId: nil, isMine: nil, authorHandle: nil, images: [], isPublic: nil, publishAt: nil, imgDims: nil, isDeleted: true)
                        self.refreshQuoteSection()
                        self.refreshToolStrip()
                        self.saveDraftNow()
                    }
                }
            }
        }
    }

    /// 恢复校验：回包可预览时刷新可见性等字段，并按 #6（第十轮）同步刷新正文/
    /// 图片/createdAt——引用是实时引用，草稿预览与发布后一致；来源后来改了正文
    /// 或图片，草稿里不再留旧预览。占位回包缺省时 ?? 兜底留旧快照；图片尺寸随
    /// 图片同刷（缺省留旧）。notFound→已删、离线→保留快照的口径不动。
    /// 补缺 P3-41：恢复后以最新有效可见性刷新快照并重算角标（原直接 return，快照恒旧）；
    /// 落盘使刷新跨杀 App 生效（已删分支同款 saveDraftNow）。
    private func applyRestoredQuoteVerified(currentQuote: SelectedQuote, fetched: Entry) {
        selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: fetched.content ?? currentQuote.content, createdAt: fetched.createdAt ?? currentQuote.createdAt, authorName: currentQuote.authorName, authorAvatar: currentQuote.authorAvatar, authorId: fetched.authorId, isMine: fetched.isMine, authorHandle: fetched.authorHandle, images: fetched.images ?? currentQuote.images, isPublic: BearyEphemeral.isEffectivelyPublic(fetched), publishAt: currentQuote.publishAt, imgDims: fetched.imgDims ?? currentQuote.imgDims, isDeleted: false, visibility: fetched.visibility, ephemeralUntil: fetched.ephemeralUntil)
        refreshQuoteSection()
        saveDraftNow()
    }

    /// B6 恢复校验：回包占位或明确无权限时收起旧预览——清掉正文和缩略图，
    /// 保留引用 ID 与移除入口（isDeleted 仍 false，下次恢复重新校验，可恢复）。
    private func applyRestoredQuoteUnavailable(currentQuote: SelectedQuote, fetched: Entry) {
        selectedQuote = SelectedQuote(entryId: currentQuote.entryId, content: "", createdAt: currentQuote.createdAt, authorName: currentQuote.authorName, authorAvatar: currentQuote.authorAvatar, authorId: fetched.authorId, isMine: fetched.isMine, authorHandle: fetched.authorHandle, images: [], isPublic: BearyEphemeral.isEffectivelyPublic(fetched), publishAt: currentQuote.publishAt, imgDims: nil, isDeleted: false, visibility: fetched.visibility, ephemeralUntil: fetched.ephemeralUntil, isUnavailable: true)
        refreshQuoteSection()
        refreshToolStrip()
        saveDraftNow()
    }

    /// 发布成功 / 丢弃草稿时：只清本篇草稿 + 本篇全部本地图片文件 + 换掉 clientReq。
    /// 多槽下绝不能整库清，否则会误删其他篇。服务端孤 key 无删除接口，残留是已知可接受项（见文末注）。
    /// 第九轮 05：删库走带成败回传的 deleteAsyncReporting，确认记录删除成功后
    /// 再清图——删库失败时记录仍在，图片必须保留（未上传的草稿图没有服务端 key，
    /// 删了无法恢复）；清理失败可留孤文件。发布成功路径传 notifyOnDeleteFailure: false：
    /// 发布已成功，失败 toast 会与“已发布”冲突，残留草稿仍在草稿箱可见、可手动删。
    /// P2-11：图片删除同样走 ioQueue——确认记录已删后把删图入队（删前再核对引用），
    /// 退场不再等删图；无记录时同样走后台队列。
    private func clearDraftAndFiles(notifyOnDeleteFailure: Bool = true) {
        // 本地文件名先快照：删库是异步的，回调时 imageItems 可能已被重置。
        let localNames = imageItems.compactMap { $0.localFile }
        let draftIdValue = currentDraftId
        // 归属账号先捕获再清绑定：删记录与删图须删打开时绑定账号的桶（清绑定后 composerOriginAccountId 已是 nil）。
        let clearAccountId = composerOriginAccountId ?? BearyDraftStore.currentAccountId
        currentDraftId = nil
        clearedCurrentDraftId = nil
        draftClientReq = nil
        // 发布绑定与打开时绑定随篇清掉：丢弃/发布成功后不再有“本篇发起账号”，
        // 下一篇发布重新捕获，不被旧绑定误拦。
        publishOriginAccountId = nil
        composerOriginAccountId = nil
        publishTogetherPublishedSourceId = nil
        draftStatusLevel = nil
        updateDraftStatusLabel()
        if let draftIdValue = draftIdValue {
            BearyDraftStore.deleteAsyncReporting(draftId: draftIdValue, forAccount: clearAccountId) { [weak self] deleted in
                guard let self = self else { return }
                if deleted {
                    // P2-11：记录已确认删除，删图走 ioQueue（删前再核对引用），不在主线程同步删。
                    BearyDraftImageStore.deletePairsIfUnreferencedAsync(localNames, excludingDraftId: nil, forAccount: clearAccountId)
                } else if notifyOnDeleteFailure {
                    self.showToast(message: "草稿删除失败，草稿仍在草稿箱，图片已保留")
                }
                self.refreshDraftPillWidth()
            }
        } else {
            // 无草稿记录：只有未落盘的本地图，同样走后台队列清掉。
            BearyDraftImageStore.deletePairsIfUnreferencedAsync(localNames, excludingDraftId: nil, forAccount: clearAccountId)
            refreshDraftPillWidth()
        }
    }

    /// P0-2：发布成功只清理提交时快照记录的那一篇（草稿 id、账号、附件）。
    /// 回包时编辑器可能已切到另一篇：按现值清会删掉新篇的草稿与图片。
    /// 内存槽位（currentDraftId / draftClientReq / 发布绑定 / 状态行）只在
    /// 仍是提交的那篇时清；已切篇时原样保留新篇状态。
    private func clearPublishedDraft(snapshot: PublishSnapshot) {
        // #1033 收尾：删图走后台队列，不堵发布成功退场；被清记录正在删除，
        // 引用核对时排除它（磁盘记录尚未落盘删除），其他篇引用仍保护文件。
        BearyDraftImageStore.deletePairsIfUnreferencedAsync(snapshot.imageLocalFiles, excludingDraftId: snapshot.draftId)
        if let draftIdValue = snapshot.draftId {
            BearyDraftStore.deleteAsync(draftId: draftIdValue, forAccount: snapshot.accountId) { [weak self] in
                self?.refreshDraftPillWidth()
            }
        } else {
            refreshDraftPillWidth()
        }
        guard currentDraftId == snapshot.draftId else { return }
        currentDraftId = nil
        clearedCurrentDraftId = nil
        draftClientReq = nil
        publishOriginAccountId = nil
        // P0-1（变基整合）：打开时绑定随发布绑定一并清掉——与
        // clearDraftAndFiles／resetEditorToBlank 同款口径，否则成功后
        // 同一编辑器再写新篇会沿用旧绑定。
        composerOriginAccountId = nil
        publishTogetherPublishedSourceId = nil
        draftStatusLevel = nil
        updateDraftStatusLabel()
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
            // P0-2：落盘排队期间用户已点发布（发布在途），此时不开箱——
            // 箱内切篇会换掉在途发布的那篇，之后回包清理就与新篇交错。
            if self.isPublishing {
                self.showToast(message: "发布中…")
                return
            }
            if self.presentedViewController != nil || self.isDraftBoxPresenting { return }
            self.isDraftBoxPresenting = true
            // 弹窗审计 E1-18：草稿箱内部已统一退场——新建/打开先播同一
            // 0.25s 退场、dismiss 后再调回调，故编辑器侧不再另行 dismiss
            // （旧 dismiss 经 BearyDraftBoxInstantAnimator 瞬时消失，绕过了退场动画）。
            let box = BearyDraftBoxViewController(
                onNew: { [weak self] in
                    self?.openBlankDraftFromBox()
                },
                onOpen: { [weak self] draft in
                    self?.loadDraftFromBox(draft)
                }
            )
            // DF-2 接线（收尾）：箱内删正在写草稿时通知编辑器，编辑器清 currentDraftId，
            // 下次落盘不再复活已删草稿；箱内“正在写”标记以 currentDraftId 为准。
            box.currentDraftId = self.currentDraftId
            // 无障碍：草稿箱纯关闭后焦点回草稿钮（新建／打开走回调时不发）。
            box.accessibilityFocusReturnElement = self.draftPillButton
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
                    // 审计 P1-9：幂等键成对绑回——只绑 draftId 不绑 clientReq 时，
                    // 下次自动保存（draftClientReq == nil 即生成新键）会以新键
                    // 落盘，覆盖箱内撤销刚写回的旧键；与 loadDraftFromBox /
                    // restoreDraft 的成对绑回一致。
                    self.draftClientReq = draft.clientReq
                }
            }
            self.present(box, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.isDraftBoxPresenting = false
            }
        }
        if hasEditorContent() {
            // 完成回调现带 DraftSaveResult；开箱不依赖保存成败（箱在编辑器之上，
            // 输入仍在编辑器里不丢），故忽略结果、行为不变。
            saveDraftNow { _ in openBox() }
        } else {
            openBox()
        }
    }

    /// 草稿箱“新建日记”：有内容先走守卫（继续写 / 保留并新建 / 丢弃并新建），
    /// 无内容直接重置。v3 多槽下“保留并新建”成立：先落盘当前篇，再开空白新篇，
    /// 当前篇留在箱里不删；取消与发布逻辑不在这里，不动。
    private func openBlankDraftFromBox() {
        if isEditMode { return }
        // P0-2：发布在途不切篇，等回包后再切。
        if isPublishing {
            showToast(message: "发布中…")
            return
        }
        if hasEditorContent() {
            let sheet = UIAlertController(title: nil, message: "当前内容还没发布，换成空白新日记吗？", preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "继续写", style: .cancel, handler: nil))
            sheet.addAction(UIAlertAction(title: "保留并新建", style: .default) { [weak self] _ in
                guard let self = self else { return }
                // 落盘走后台队列：存完回调里再重置（快照在 saveDraftNow 调用时已拍，
                // 存完前切篇的状态守卫见 saveDraftNow 完成回调）。
                // R14 P1-6：走带版本＋身份复核的退出保存（saveDraftVersionedForExit）——
                // 等待期间输入的字若没进首拍快照，回包时版本已变就以最新内容再存一轮
                // 再清空，清空前再比对 currentDraftId，确认保存的是最新版本才清空；
                // 等待期间编辑器冻结＋状态行显“保存中…”，冲突操作被锁住。
                // 完成回调带 DraftSaveResult：失败时不重置、内容原样保留并 toast
                // 明示重试（关闭路径同款口径：拒绝震动＋拒绝音＋状态行已置红）；
                // 成功才开空白新篇。
                self.saveDraftVersionedForExit { [weak self] result in
                    guard let self = self else { return }
                    guard result.succeeded else {
                        BearyHaptics.rejectionWarning()
                        BearySoundPlayer.play(.refuseBonk)
                        if !UIAccessibility.isReduceMotionEnabled {
                            self.cancelButton.layer.removeAnimation(forKey: "bearyDenyShake")
                            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                            shake.values = [0, -8, 8, -5, 5, 0]
                            shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                            shake.duration = 0.4
                            self.cancelButton.layer.add(shake, forKey: "bearyDenyShake")
                        }
                        self.showToast(message: result.hadPreviousSavedVersion
                            ? "草稿保存失败，当前内容仍保留在此页，上次保存的草稿未受影响，再点一次保留并新建重试"
                            : "草稿保存失败，当前内容仍保留在此页，再点一次保留并新建重试")
                        return
                    }
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
        if !headlineText.isEmpty { return true }
        if !trimmedContent().isEmpty { return true }
        if selectedWeather != nil { return true }
        if selectedRecipient != nil { return true }
        if selectedQuote != nil { return true }
        // 批 E：只选了位置也算有内容（与天气/@/引用同口径），防丢弃流程把位置篇当空白扔掉。
        if selectedLocation != nil { return true }
        if !imageItems.isEmpty { return true }
        return false
    }

    /// 重置为空白新日记：清字段与图片视图、当前篇槽位与 clientReq（存储删除由调用方决定：
    /// 丢弃路径先调 clearDraftAndFiles 删本篇，保留路径先调 saveDraftNow 落盘本篇，
    /// 这里只清视图与槽位，不重复删存文件）。
    private func resetEditorToBlank() {
        draftTimer?.invalidate()
        setBodyAttributedText("")
        // 空白新日记：标题输入框同清（按无标题处理）。
        setHeadlineText("")
        selectedMood = nil
        selectedWeather = nil
        selectedTemperature = nil
        selectedRecipient = nil
        notifyRecipient = true
        selectedQuote = nil
        // 批 E：重置为空白时位置与编辑原快照同清，行随之隐藏。
        selectedLocation = nil
        originalLocation = nil
        refreshLocationRow()
        // 112：空白新日记不得继承上一篇的可见性/限时态——编辑器每次
        // 默认私密、不记住上次选择。
        selectedVisibilityPublished = false
        selectedVisibilityFriends = false
        isEphemeral = false
        refreshVisibilityButton()
        setQuotePanelOpen(false)
        removeAllImageViews()
        // 只清视图与槽位，不碰存储：删篇由调用方决定（丢弃路径先调 clearDraftAndFiles
        // 删本篇，保留路径先调 saveDraftNow 落盘本篇）；这里再整库清会误删其他篇。
        currentDraftId = nil
        draftClientReq = nil
        // P1-4：空白新篇重新计，已发布标记清掉。
        publishedCurrentDraft = false
        // 空白新篇不再继承上一篇的发布绑定与部分成功态。
        publishOriginAccountId = nil
        composerOriginAccountId = nil
        publishTogetherPublishedSourceId = nil
        draftStatusLevel = nil
        updateCountLabel()
        updatePublishState()
        syncWeatherToolButton()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        updateDraftStatusLabel()
        refreshDraftPillWidth()
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
        // P0-2：发布在途不切篇，等回包后再切——在途发布成功后只清提交的那篇，
        // 切篇本身须等回包，否则清理与新篇状态交错。
        if isPublishing {
            showToast(message: "发布中…")
            return
        }
        // 109：切篇先重置草稿状态——此前全程不碰 draftStatusLevel、不调
        // updateDraftStatusLabel()，工具栏状态行残留上一篇文案；对照组
        // resetEditorToBlank()/clearDraftAndFiles() 都会清状态并刷新。
        // 只清状态行，不改草稿保存逻辑（currentDraftId 等恢复原样走下文）。
        draftStatusLevel = nil
        updateDraftStatusLabel()
        draftTimer?.invalidate()
        removeAllImageViews()
        // 切篇即换发布绑定：上一篇的发起账号与部分成功态不带到新篇，
        // 新篇首次点发布时重新捕获。
        publishOriginAccountId = nil
        // P0-1：切篇即按箱内草稿所属的当前账号重绑打开时绑定——箱内
        // 草稿来自当前账号桶，之后自动保存写该账号的桶，不沿用旧绑定。
        composerOriginAccountId = currentAccountIdForPublish()
        publishTogetherPublishedSourceId = nil
        // P1-4：切到新篇，已发布标记清掉。
        publishedCurrentDraft = false
        currentDraftId = draft.draftId
        draftClientReq = draft.clientReq
        setBodyAttributedText(draft.content)
        applyBodyLineHeight()
        // 草稿续写：标题回填进新输入框。
        setHeadlineText(draft.title)
        selectedMood = draft.mood
        selectedWeather = draft.weather
        selectedTemperature = draft.temperature
        refreshSelectedChips()
        restoreVisibility(index: draft.visibilitySegmentIndex, ephemeral: draft.ephemeralEnabled)
        selectedRecipient = restoredRecipient(from: draft)
        notifyRecipient = draft.notifyRecipient
        selectedQuote = restoredQuote(from: draft)
        // 批 E：草稿箱打开某篇时位置同款恢复。
        let boxLocation = DiaryLocation(name: draft.locationName, district: draft.locationDistrict)
        selectedLocation = boxLocation.isEmpty ? nil : boxLocation
        refreshLocationRow()
        setQuotePanelOpen(false)
        for img in draft.images {
            let failed = (img.state == .failed)
            let item = createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: failed)
            item.liveVideoKey = img.liveVideoKey
            // B1：待传实况才带本地视频文件名（已上传项只留 liveVideoKey，
            // 视频已在服务端，不再读本地 mov）；pending/failed 项按
            // state 原样建项，续传/重试走下文解码后的同一格。
            if img.liveVideoKey == nil {
                item.liveVideoFile = img.liveVideoFile
            }
            insertImageItem(item)
            // 只有 key 的老项走远程缩略图；有本地文件的项等后台解码后填图。
            if img.localFile == nil, let key = img.serverKey,
               let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
            }
        }
        refreshImageStripVisibility()
        // 本地图后台解码（失败态不解码，重试点图时再读盘），解完再续传。
        // B1：待传实况视频同批读回内存（见 decodeRestoredImages），
        // 读不到的记 liveVideoMissing，续传时跳过、不静默变静态。
        let decodingImages = draft.images
        decodeRestoredImages(decodingImages, accountId: composerOriginAccountId ?? BearyDraftStore.currentAccountId) { [weak self] decoded, liveVideos in
            guard let self = self else { return }
            self.applyRestoredImages(decoded: decoded, liveVideos: liveVideos)
            self.resumePendingUploads()
            // 录屏批 (c) 同款：草稿箱恢复的异步解码收尾时同步一次发布态。
            self.updatePublishState()
        }
        updateCountLabel()
        syncWeatherToolButton()
        refreshRecipientRow()
        refreshQuoteSection()
        refreshToolStrip()
        refreshDraftPillWidth()
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

    // MARK: - 编辑检查点（审计四轮增量 09）

    /// 当前编辑与服务端原文是否不一致（正文/标题/心情/天气/气温/位置/图片/实况）。
    /// 与原文一致时不写检查点（已有的也清掉），避免无意义的恢复提示。
    private func isEditDirtyVsOriginal() -> Bool {
        guard let entry = editingEntry else { return false }
        if committedContent() != (entry.content ?? "") { return true }
        if headlineText != (entry.title ?? "") { return true }
        if selectedMood != entry.mood { return true }
        if selectedWeather != entry.weather { return true }
        if selectedTemperature != entry.temperatureC { return true }
        if selectedLocation != originalLocation { return true }
        if uploadedImageKeys() != (entry.images ?? []) { return true }
        if imageItems.contains(where: { $0.key == nil && $0.localFile != nil }) { return true }
        if uploadedLiveVideos() != (entry.liveVideos ?? [:]) { return true }
        return false
    }

    /// 按当前编辑器状态拍检查点快照（图片条按 08 同款口径：有 key 或有本地文件
    /// 的项都进快照，未上传图 pending 态、失败图 failed 态）。
    private func buildEditCheckpoint(entryId: String, accountId: Int) -> BearyDraftStore.BearyEditCheckpoint {
        var images: [BearyDraftImageItem] = []
        for item in imageItems {
            guard item.key != nil || item.localFile != nil else { continue }
            let state: BearyDraftImageState
            if item.key != nil {
                state = .uploaded
            } else if item.failed {
                state = .failed
            } else {
                state = .pending
            }
            images.append(BearyDraftImageItem(localFile: item.localFile, serverKey: item.key, state: state, liveVideoKey: item.liveVideoKey))
        }
        return BearyDraftStore.BearyEditCheckpoint(
            entryId: entryId,
            accountId: accountId,
            content: committedContent(),
            title: headlineText.isEmpty ? nil : headlineText,
            mood: selectedMood,
            weather: selectedWeather,
            temperature: selectedTemperature,
            locationName: selectedLocation?.name,
            locationDistrict: selectedLocation?.district,
            images: images,
            updatedAt: Date().timeIntervalSince1970)
    }

    /// 立即写检查点（主线程只拍快照，写盘走 BearyDraftStore.ioQueue，主线程回传
    /// 真实成败）。与原文一致时不写盘、清掉旧检查点并回传成功。
    private func saveEditCheckpointNow(completion: ((Bool) -> Void)? = nil) {
        guard let entryId = editingEntry?.id, !entryId.isEmpty else {
            completion?(false)
            return
        }
        guard isEditDirtyVsOriginal() else {
            BearyDraftStore.clearEditCheckpointAsync(entryId: entryId)
            completion?(true)
            return
        }
        guard let accountId = BearyDraftStore.currentAccountId else {
            completion?(false)
            return
        }
        let checkpoint = buildEditCheckpoint(entryId: entryId, accountId: accountId)
        BearyDraftStore.ioQueue.async {
            let ok = BearyDraftStore.saveEditCheckpoint(checkpoint, forAccount: accountId)
            DispatchQueue.main.async {
                completion?(ok)
            }
        }
    }

    /// 编辑器回填完成后查一次检查点（每实例只弹一次；补拉二次调用时回填
    /// 未完成不查，末尾钩子天然只在完整回填后跑）。检查点与服务端原文
    /// 一致时不提示、直接清掉；不一致才挂起提示（viewDidAppear 后弹）。
    /// 回包时若用户已开始改（editorEditVersion 已变），不再提示——新改动
    /// 已由防抖检查点接管，旧检查点已被覆盖，提示只会问用户自己的新输入。
    private func maybeOfferEditCheckpointRestore() {
        guard isEditMode, !editCheckpointPromptShown, pendingEditCheckpoint == nil,
              let entryId = editingEntry?.id, !entryId.isEmpty else { return }
        let accountId = BearyDraftStore.currentAccountId
        let baselineVersion = editorEditVersion
        BearyDraftStore.ioQueue.async { [weak self] in
            let checkpoint = BearyDraftStore.loadEditCheckpoint(entryId: entryId, forAccount: accountId)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let checkpoint = checkpoint else { return }
                guard self.isEditMode, self.editingEntry?.id == entryId,
                      self.editorEditVersion == baselineVersion,
                      self.pendingEditCheckpoint == nil else { return }
                guard self.editCheckpointDiffersFromOriginal(checkpoint) else {
                    BearyDraftStore.clearEditCheckpointAsync(entryId: entryId)
                    return
                }
                self.editCheckpointPromptRetries = 0
                self.pendingEditCheckpoint = checkpoint
                self.maybePresentEditCheckpointPrompt()
            }
        }
    }

    /// 检查点与当前服务端原文是否不一致（与 isEditDirtyVsOriginal 同口径，
    /// 只是比对对象是检查点快照而非编辑器现场值）。
    private func editCheckpointDiffersFromOriginal(_ checkpoint: BearyDraftStore.BearyEditCheckpoint) -> Bool {
        guard let entry = editingEntry else { return false }
        if checkpoint.content != (entry.content ?? "") { return true }
        if (checkpoint.title ?? "") != (entry.title ?? "") { return true }
        if checkpoint.mood != entry.mood { return true }
        if checkpoint.weather != entry.weather { return true }
        if checkpoint.temperature != entry.temperatureC { return true }
        let checkpointLocation = DiaryLocation(name: checkpoint.locationName, district: checkpoint.locationDistrict)
        let checkpointLocationValue: DiaryLocation? = checkpointLocation.isEmpty ? nil : checkpointLocation
        if checkpointLocationValue != originalLocation { return true }
        let checkpointKeys = checkpoint.images.compactMap { $0.serverKey }
        if checkpointKeys != (entry.images ?? []) { return true }
        if checkpoint.images.contains(where: { $0.serverKey == nil && $0.localFile != nil }) { return true }
        let checkpointLiveVideos = Dictionary(uniqueKeysWithValues: checkpoint.images.compactMap { img -> (String, String)? in
            guard let key = img.serverKey, let liveKey = img.liveVideoKey else { return nil }
            return (key, liveKey)
        })
        if checkpointLiveVideos != (entry.liveVideos ?? [:]) { return true }
        return false
    }

    /// 弹恢复提示（viewDidAppear 后；存量引用提示在上时等 1 秒重试、最多 3 次，
    /// 仍被挡时放弃本次提示、检查点留盘，下次进编辑器再问）。
    private func maybePresentEditCheckpointPrompt() {
        guard isEditMode, !editCheckpointPromptShown, let checkpoint = pendingEditCheckpoint else { return }
        guard composerDidAppear else { return }
        guard presentedViewController == nil else {
            guard editCheckpointPromptRetries < 3 else { return }
            editCheckpointPromptRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.maybePresentEditCheckpointPrompt()
            }
            return
        }
        editCheckpointPromptShown = true
        pendingEditCheckpoint = nil
        let deadlinePassed = editSaveBlockedAfterDeadline
        let message = deadlinePassed
            ? "上次编辑这篇日记时还没保存，找到了当时的修改。编辑时间已结束，只能查看和复制，不能再保存。"
            : "上次编辑这篇日记时还没保存，找到了当时的修改，要恢复吗？"
        // 底部弹窗口径（#932）：新弹窗一律走通用确认底 sheet，不再新写居中 Alert。
        BearyConfirmSheet.show(from: self, title: "恢复未提交的修改？", message: message, actions: [
            BearyConfirmSheet.Action(title: "恢复", style: .default, handler: { [weak self] in
                guard let self = self else { return }
                self.applyEditCheckpoint(checkpoint)
            }),
            BearyConfirmSheet.Action(title: "放弃", style: .destructive, handler: { [weak self] in
                guard let self = self else { return }
                if let entryId = self.editingEntry?.id, !entryId.isEmpty {
                    BearyDraftStore.clearEditCheckpointAsync(entryId: entryId)
                }
            }),
        ])
    }

    /// 把检查点内容应用回编辑器（正文/标题/心情/天气/气温/位置/图片条）。
    /// 期限已过时由已跑起的计时器冻结为只读（见 startEditTimer），应用后
    /// updatePublishState 会再次冻结；检查点本身不清——仍是未提交的修改，
    /// 再崩溃仍可恢复；提交成功（performUpdate）或取消时才清。
    private func applyEditCheckpoint(_ checkpoint: BearyDraftStore.BearyEditCheckpoint) {
        setBodyAttributedText(checkpoint.content)
        setHeadlineText(checkpoint.title)
        selectedMood = checkpoint.mood
        selectedWeather = checkpoint.weather
        selectedTemperature = checkpoint.temperature
        let checkpointLocation = DiaryLocation(name: checkpoint.locationName, district: checkpoint.locationDistrict)
        selectedLocation = checkpointLocation.isEmpty ? nil : checkpointLocation
        syncWeatherToolButton()
        refreshSelectedChips()
        refreshLocationRow()
        rebuildImageItemsFromCheckpoint(checkpoint.images)
        refreshImageStripVisibility()
        updateTextViewHeight()
        updatePublishState()
        showToast(message: "已恢复上次没保存的修改")
    }

    /// 按检查点重建图片条：原图与未上传本地图都建项；本地缩略图后台解码后
    /// 贴回，随后按草稿恢复同款 resumePendingUploads（有本地文件、无 key、
    /// 非失败态自动重传；失败态等用户点图重试）。
    private func rebuildImageItemsFromCheckpoint(_ images: [BearyDraftImageItem]) {
        removeAllImageViews()
        for img in images {
            let item = createImageItem(localImage: nil, key: img.serverKey, uploading: false, localFile: img.localFile, failed: img.state == .failed)
            item.liveVideoKey = img.liveVideoKey
            insertImageItem(item)
            if img.localFile == nil, let key = img.serverKey, let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
            }
        }
        let decodingImages = images
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
                            } else if let key = item.key, let url = BearyImageURLs.imageURL(key: key, thumb: true) {
                                item.imageView.bearySetImage(url: url, placeholder: nil, downsampleToWidth: 84 * UIScreen.main.scale)
                            }
                        }
                    }
                }
                self.resumePendingUploads()
                self.updatePublishState()
            }
        }
    }

    // MARK: - 取消与发布

    /// 边缘右滑开拖前的预检谓词（与 didTapCancel 的三道即时拒绝门控同口径，
    /// 供 BearyEdgeDismiss 在手势 .began 调用）：发布/保存进行中、引用面板
    /// 开着、已有弹层在上时都返回 false，此时手势不启动跟手。
    /// 草稿保存失败只能在松手走原流程时才知道，预检拦不住——松手时被拒，
    /// 视图滑回原位（见 didTapCancel 保存失败分支的 transform 复位）。
    func canBeginEdgeCancel() -> Bool {
        // B2：关闭已在途时不启动第二段边缘关闭（与 didTapCancel 的守卫同口径）。
        if isClosing { return false }
        if isPublishing { return false }
        // R14 P1-6：退出保存进行中不另起一条边缘退出——第一笔退出已在等
        // 写盘回包，新手势进来只会与它抢同一篇快照；返回 false 让手势
        // 把视图滑回原位，第一笔退出照常走完。
        if isDraftExitSaving { return false }
        if quotePanelOpen { return false }
        if presentedViewController != nil { return false }
        return true
    }

    /// R14 P2-13：边缘返回的保存等待反馈入口（SceneDelegate 的
    /// onEdgeSwipeCompleted 改走这里，不再直调 didTapCancel）。
    /// 松手过阈值后编辑器维持偏移等写盘回包，旧流程等待期无任何可读反馈；
    /// 等待期的冻结＋状态行“保存中…”＋转圈由 didTapCancel 自身在新建态
    /// 调 performCloseSave 之前立态（setDraftExitSaving），
    /// 成功时随关页消失，失败时由 performCloseSave 的终态分支
    /// 清态、按保存级别刷新状态行（停转、红字“草稿保存失败”）；多轮重存
    /// （#1002 式版本复核）的等待同样覆盖，因为状态只在最终回包时才被刷新。
    /// 注意：这里不预立退出保存态——预立会在 didTapCancel 里撞上 P1-6
    /// 守卫（isDraftExitSaving 时只 toast、直接返回 true），保存根本没跑、
    /// 清态分支又因 proceeding 为 true 不触发，编辑器卡死在偏移位置
    /// （只能强退）。
    /// 编辑态取消是同步的（清临时文件后立即 onCancelled），无等待、不立反馈。
    /// 被拒（发布在途／面板开着／已有弹层）时没进保存流程，清态、不留反馈。
    @objc func didTapCancelFromEdgeSwipe() -> Bool {
        let proceeding = didTapCancel()
        if !proceeding && isDraftExitSaving {
            // 被拒（发布在途／面板开着／已有弹层）：没进保存流程，不留反馈。
            setDraftExitSaving(false)
        }
        return proceeding
    }

    /// 供容器边缘手势调用：与取消钮同一流程（发布在途只 toast、引用面板
    /// 开着只退面板、其余存草稿/清临时文件后经 onCancelled 关页），不得另起
    /// 一条直接 dismiss 的关闭路径。
    /// 返回值：true 表示退出已在进行（即将关页，或草稿保存已提交、关页随后发生），
    /// false 表示本次取消被拒，边缘手势应在 false 时把跟手滑走的视图滑回原位。
    /// 审计 M2：三道即时拒绝门控另见 canBeginEdgeCancel（手势 .began 预检同口径）。
    /// B2：关闭进行中守卫（isClosing）与 canBeginEdgeCancel 同口径。
    @objc func didTapCancel() -> Bool {
        // B2：关闭进行中守卫（取消钮与边缘关闭共用同一入口）：快速连点
        // 只接一次关闭流程；在途关闭再次点按直接忽略，不重走保存、
        // 不重复调 onCancelled。成功关闭随编辑器消失，不复位；失败或
        // 留页时由 performCloseSave 复位，之后再点关闭可重走流程。
        if isClosing { return false }
        // P1-7：发布/保存进行中时取消键不走取消流程，给进行中提示（与 didTapPublish
        // 首行 isPublishing 守卫同口径；真取消在途请求属结构改动，本批不做）。
        // quote-freeze：isPublishing 在“一并公开”点按瞬间即置（见
        // beginPublishTogether），故 setVisibility 在途时取消键同样只 toast、
        // 不关编辑器——半截退出（原日记已公开、本篇未发）已被这道守卫堵死。
        // 编辑器为全屏 present、无下滑关闭手势，容器侧 onCancelled 在新建态
        // 只从本函数触发，故不存在另一条在途关闭路径。
        if isPublishing {
            showToast(message: isEditMode ? "保存中…" : "发布中…")
            return false
        }
        // R14 P1-6：退出保存进行中再点取消不重走取消流程——第一笔退出已在
        // 等写盘回包，重入只会多写一轮、并可能把 onCancelled 调两次；只给
        // 进行中提示（状态行已显“保存中…”＋转圈）。返回 true 表示退出已在
        // 进行，边缘手势不复位、等第一笔走完。
        if isDraftExitSaving {
            showToast(message: "保存中…")
            return true
        }
        // qp-mode 下取消键是“返回”，只退面板，不走整编取消流程（网页同款）。
        if quotePanelOpen {
            setQuotePanelOpen(false)
            return false
        }
        // presented 守卫（选人器/裁剪/草稿箱同款）：已有弹层在上时不动作。
        if presentedViewController != nil { return false }
        // B2：到此已确定退出，立下进行中标记（编辑态同步关、新建态异步
        // 保存关，两分支都走本标记）。
        isClosing = true
        // B 修法：取消退场前先收起未收的弹出框（无动画，退场不带它滑）；到此已确定退出
        //（编辑态与新建态两分支随后都走 onCancelled），守卫分支（发布在途／面板态／已有弹层）已在上文返回。
        hideCallout(animated: false)
        if isEditMode {
            // 决议第 4 项 B：取消直接关，不弹确认；只清本地临时图文件，不删原日记、不碰草稿。
            // 审计四轮增量 09：用户明确放弃编辑，检查点一并清掉（不留恢复提示）。
            commitPendingRemoval()
            deleteEditLocalFiles()
            if let entryId = editingEntry?.id, !entryId.isEmpty {
                BearyDraftStore.clearEditCheckpointAsync(entryId: entryId)
            }
            onCancelled?()
            return true
        }
        // 决议第 4 项 B：取消不再弹三选、无丢弃路径，直接关 + 静默存草稿。
        // 草稿规则不动：saveDraftNow 原样走分级保存、纯心情不保存的现有逻辑。
        // C10：关闭时仍有 key 为空的图片（上传中／失败同算）——toast 挂 presenting 方，
        // 关编辑器后仍可见。审计四轮增量 08：本地文件完整的未上传图已随 localFile
        // 进草稿（pending／failed 态，重进续传／重试），故文案不说“没存进草稿”；
        // 新文案按未上传完的图数提示（见成功分支，P1-8：失败图计入，有失败图时
        // 指到点图重试上传）。
        // 该 toast 只在真正关闭时发（见成功分支）：保存失败留页时不发到
        // 看不见的 presenting 方，失败提示另由本页 toast 给。
        // 关闭即提交缓冲删除（草稿随即按删除后状态落盘，见 saveDraftNow）。
        commitPendingRemoval()
        // R14 P1-6：等待期间冻结输入＋状态行显“保存中…”；终态在
        // performCloseSave 的失败分支与版本复核通过后清，
        // 不在版本复核的重存中途清（重存期间用户已冻住）。
        // B2：关闭绑定当前内容版本并冻结输入（updatePublishState 施加冻结，
        // 见 refreshPublishingInputFreeze）：保存期间输入框不再可输入，
        // 发布钮同禁；版本核对与续存在 performCloseSave 里。
        setDraftExitSaving(true)
        updatePublishState()
        performCloseSave(closeVersion: editorEditVersion, retriesLeft: Self.closeSaveMaxRetries)
        return true
    }

    /// 审计 R13-02：取消退出保存草稿前复核编辑版本。
    /// 取消保存是异步落盘（快照主线程拍、写盘走 ioQueue），写盘期间编辑器
    /// 未冻结，用户继续输入会使首拍快照过期；旧代码成功回包即 onCancelled，
    /// 期间的新输入既没进快照、又随关页丢失。
    /// 修法以版本复核为主：每次保存前记下 editorEditVersion（正文/标题/
    /// 心情/天气/位置/@/引用/可见性/图片变化均已递增，见第 26 项；saveDraftNow
    /// 自身只改无 didSet 的草稿身份与状态字段，不递增、不误触发），成功回包
    /// 时再比对；版本变了说明保存期间有新输入，以最新内容再存一次再关；
    /// 失败仍留页，拒绝动效 + toast 不变（再点关闭即重试）。
    /// 再存只发生在异步完成回调里，不占调用栈；用户停笔后即收敛关页。
    /// 发布冻结逻辑不动：本方法不碰 refreshPublishingInputFreeze。
    /// B2：关闭保存重试上限——保存期间内容连续变化时最多再保存 3 次；
    /// 超过即留页（不再无声关掉丢新输入），由用户确认后再关。
    private static let closeSaveMaxRetries = 3

    /// B2：关闭流程的版本绑定保存。saveDraftNow 的快照在调用时拍下，
    /// 完成时 editorEditVersion 变了说明保存期间有新内容到达（键盘输入
    /// 已由冻结拦住，但上传完成回写 key、引用校验回填、天气自动填等
    /// 异步回包仍会递增版本），接着保存最新版，直到版本稳定才走
    /// onCancelled；失败沿旧口径留页重试；重试耗尽同样留页。
    /// 留页分支一律复位 isClosing 并调 updatePublishState() 解冻输入，
    /// 否则再点关闭会被守卫挡住；成功关闭随编辑器消失，不复位。
    private func performCloseSave(closeVersion: Int, retriesLeft: Int) {
        saveDraftNow { [weak self] result in
            guard let self = self else { return }
            guard result.succeeded else {
                self.setDraftExitSaving(false)
                // P0：保存失败不再无条件走 onCancelled——编辑器与输入原样保留，
                // 状态行已由 saveDraftNow 置红（level 0），这里补拒绝动效 + toast
                // 明示重试（再点一次关闭即重走保存）；文案按原子写语义区分，
                // 旧版在时只说“本次修改没存上”，不夸大成整篇已丢。
                // 拒绝动效口径与详情页/卡片一致：摇头 + warning 震动 + refuse 音，
                // 减动效只跳过视觉抖动，震动与音照常。
                // B2：留页即复位关闭标记并解冻输入（见函数头）。
                self.isClosing = false
                self.updatePublishState()
                BearyHaptics.rejectionWarning()
                BearySoundPlayer.play(.refuseBonk)
                if !UIAccessibility.isReduceMotionEnabled {
                    self.cancelButton.layer.removeAnimation(forKey: "bearyDenyShake")
                    let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                    shake.values = [0, -8, 8, -5, 5, 0]
                    shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                    shake.duration = 0.4
                    self.cancelButton.layer.add(shake, forKey: "bearyDenyShake")
                }
                // 审计 M2：保存失败留页——边缘跟手若已把视图滑出，滑回原位
                //（与 BearyEdgeDismiss 的复位同口径：拖拽收尾统一弹簧 0.30s／
                // damping 0.7；保存回调里无松手速度可传，初速度取 0；减动效瞬时归位）。
                if self.view.transform != .identity {
                    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
                        self.view.transform = .identity
                    })
                }
                self.showToast(message: result.hadPreviousSavedVersion
                    ? "草稿保存失败，本次修改没存上，旧版还在，再点一次关闭重试"
                    : "草稿保存失败，这篇草稿还没存上，再点一次关闭重试")
                return
            }
            if self.editorEditVersion != closeVersion {
                if retriesLeft > 0 {
                    self.performCloseSave(closeVersion: self.editorEditVersion, retriesLeft: retriesLeft - 1)
                    return
                }
                // 上限耗尽：留在编辑器，解冻输入，让用户确认后再关。
                self.isClosing = false
                self.updatePublishState()
                self.showToast(message: "关闭时内容还在变化，已留在编辑器，再点一次关闭重试")
                return
            }
            // P1-8：按未上传完的图片数提示：key 为空的图都还没上传完
            // （本地文件完整的图已随 localFile 进草稿，pending／failed 态，
            // 重进续传／重试，见 saveDraftNow 组装处）；失败图与上传中图同计；
            // 有失败图时指到页内现有重试入口（点失败的图重传，见 didTapImageItem），
            // 纯上传中时只说还没传完（上传中点图不可重试）。
            let unsavedImageCount = self.unsavedImageCount()
            if unsavedImageCount > 0 {
                if self.hasFailedImage() {
                    self.showToastAfterClose(message: "有 \(unsavedImageCount) 张图片上传失败，点图片可重试上传")
                } else if self.imageItems.contains(where: { $0.uploading && $0.localFile == nil })
                    && !self.imageItems.contains(where: { $0.uploading && $0.localFile != nil }) {
                    // B1：只有连本地文件都没有的占位项（仍在读图/编码）才存不进
                    // 草稿，文案不说“已存进草稿”，仍走旧文案。
                    self.showToastAfterClose(message: "图片还没上传完，不会存进草稿")
                } else {
                    self.showToastAfterClose(message: "有 \(unsavedImageCount) 张图片还没上传完，已存进草稿")
                }
            }
            // R14 P1-6：版本复核通过后、关页前清退出保存态（解冻＋状态行
            // 按保存级别刷新）；重存走递归 performCloseSave 提前
            // return，不会在此清冻结。
            self.setDraftExitSaving(false)
            self.onCancelled?()
        }
    }

    @objc private func didTapPublish() {
        if isPublishing {
            return
        }
        // R14 P1-6：退出保存进行中不发发布——发布钮已由 updatePublishState
        // 禁用，此处再拦一道（防启用态竞态），免得发布流与退出保存抢同一篇。
        if isDraftExitSaving {
            showToast(message: "保存中…")
            return
        }
        // 期限已过且在途保存已失败：保存钮已由 updatePublishState 禁用，
        // 此处再拦一道（防按钮态竞态），不发 PUT、不清输入。
        if isEditMode && editSaveBlockedAfterDeadline {
            showAlert(message: "编辑时间已过，无法再保存，可复制内容后关闭")
            return
        }
        // 补拉在途/失败：保存钮已由 updatePublishState 禁用，此处再拦一道
        // （防按钮态竞态），不发 PUT——此时回填未完成，发 PUT 会误清原引用与原图。
        if isEditMode && (editQuoteFetchFailed || editQuoteFetchInFlight) {
            showToast(message: editQuoteFetchFailed ? "引用的日记还没加载成功，点引用区“重试”后再保存" : "引用的日记正在加载，稍后再保存")
            return
        }
        // 批 E：发布/保存时先收定位气泡，防气泡确认与发布请求竞态。
        hideLocationPopover(animated: false)
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
            // 空正文安全网：按钮现为真禁用（见 updatePublishState），正常流程到不了
            // 这里；仅防启用态竞态下仍能点到，拦住不发请求。
            showToast(message: "先写点什么")
            updatePublishState()
            return
        }
        // D-G5：网页发布先 trim 再量长（editorText.value.trim() 后 c.length>2000）；
        // 此处原用未 trim 长度，首尾空白会误判超长。改用已 trim 的 trimmed 计长。
        // 扫查组：c.length 是 UTF-16 码元数，Swift .count 是字素簇数，
        // 此处改 utf16.count，与服务端 400 口径一致（见 committedTextCount 注释）。
        if trimmed.utf16.count > BearyComposerViewController.maxLength {
            showToast(message: "最多 2000 字，现在 \(trimmed.utf16.count) 字")
            return
        }
        // 决议第 5 项 A：有上传失败的图片时拦截不发（网页 beary.html 编辑器发布口径，
        // 文案逐字取自网页拦截 toast），出 toast 并停留在编辑器，不发请求。
        if hasFailedImage() {
            showToast(message: "有图片上传失败，点失败的图重试或移除后再发布")
            return
        }
        // B1：实况视频已丢的图拦截不发（与失败图同口径）：视频不在了还发，
        // 等于把用户明确选中的实况静默降级为静态图；须重新选择后再发布。
        if hasLiveVideoMissingImage() {
            showToast(message: "有实况视频已丢失，重新选择该图片后再发布")
            return
        }
        // 决议第 3 项 B：去掉发布/保存确认弹框，点发布/保存直接发（网页口径：
        // 网页 editorPublish 直接走校验与请求，无确认弹框）。
        if isEditMode {
            performUpdate(trimmed: trimmed)
            return
        }
        // quote-freeze：新建发布先拍完整快照（胶囊校验失败即返回，不进门禁）。
        // 快照后落盘一次草稿（原 performPublish 首步的 clientReq 落盘，现移到
        // 请求链起点）；P1-5：等落盘成功回调再走请求链，使门禁路径的
        // setVisibility 之前幂等键已持久化（不只是入队）。
        guard let snapshot = makePublishSnapshot(trimmed: trimmed) else { return }
        // 发布发起账号校验（本支新增，须在落盘与代次递增之前）：已有发起
        // 绑定且当前账号已变时，中止发布、不落盘、不递增代次——旧弹框的
        // “只重试新篇”回调仍认旧代次，不会被本次递增作废；同账号重登
        // id 不变，直接通过。首次发布在此定下绑定，之后重试不改写。
        if isPublishOriginMismatch() {
            showPublishAccountMismatchAlert()
            return
        }
        if publishOriginAccountId == nil {
            publishOriginAccountId = snapshot.originAccountId
        }
        publishGeneration += 1
        let generation = publishGeneration
        // P1-5：等本次快照的 clientReq 确认落盘，再发首个会改变服务端状态
        // 的请求（门禁的 setVisibility / performPublish 的 publishEntry）。
        // 落盘失败就停在编辑器、保留输入并提示重试，不发请求。
        let proceedAfterPersist: () -> Void = { [weak self] in
            guard let self = self else { return }
            // 一并公开部分成功后重按发布：原日记已公开，不再走门禁与
            // setVisibility，只发新篇（publishTogetherPublishedSourceId 在
            // setVisibility 成功时记下，发布成功/清草稿/切篇时清掉）。
            if self.selectedVisibilityPublished, let pendingQuote = self.selectedQuote,
               let publishedSourceId = self.publishTogetherPublishedSourceId,
               publishedSourceId == pendingQuote.entryId {
                self.performPublish(snapshot: snapshot, generation: generation, sourceAlreadyPublished: true)
                return
            }
            // 引用规则简化（2026-10-31）：新建将公开且含私密引用时先拦截，不直接发。
            // 自己来源三选一、他人来源两项（见 BearyQuoteGate.gateEditorPublish）；
            // 一并公开先发原日记 visibility=1，成功才发本篇；失败停在编辑器、不发本篇。
            // 保持私密发布即把本篇改回私密再发（引用保留）；删除引用即清引用再公开。
            // 门禁弹框本身是模态 alert，框在时编辑器动不了；三条出路提交的都是
            // 本快照（删除/保持私密只改快照副本对应字段，现场值改动不进载荷）。
            if self.selectedVisibilityPublished, let pendingQuote = self.selectedQuote, pendingQuote.isDeleted == false, pendingQuote.isPublic != true {
                let mine = BearyQuoteGate.sourceIsMine(isMine: pendingQuote.isMine, authorId: pendingQuote.authorId)
                BearyQuoteGate.gateEditorPublish(from: self, sourceIsMine: mine, sourceIsFriendsOnly: pendingQuote.visibility == "friends", onPublishTogether: { [weak self] in
                    guard let self = self else { return }
                    self.beginPublishTogether(snapshot: snapshot, generation: generation)
                }, onDeleteQuote: { [weak self] in
                    guard let self = self else { return }
                    self.selectedQuote = nil
                    self.refreshQuoteSection()
                    var gated = snapshot
                    gated.quoteId = nil
                    self.performPublish(snapshot: gated, generation: generation)
                }, onKeepPrivate: { [weak self] in
                    guard let self = self else { return }
                    self.selectedVisibilityPublished = false
                    self.selectedVisibilityFriends = false
                    self.isEphemeral = false
                    self.refreshVisibilityButton()
                    // 门禁改档与常规切档同口径：位置行副行（公开后他人仅见区级）
                    // 须同步变，否则发布失败留在编辑器时位置行仍留公开说明。
                    self.refreshLocationRow()
                    var gated = snapshot
                    gated.published = 0
                    gated.visibility = "private"
                    gated.ephemeral = nil
                    self.performPublish(snapshot: gated, generation: generation)
                })
                return
            }
            self.performPublish(snapshot: snapshot, generation: generation)
        }
        saveDraftNow { [weak self] result in
            guard let self = self else { return }
            guard result.succeeded else {
                BearyHaptics.rejectionWarning()
                self.showAlert(message: "草稿保存失败，本篇未发布，请重试")
                return
            }
            proceedAfterPersist()
        }
    }

    /// 一并公开出路（quote-freeze）：用户点“一并公开”的瞬间即进入发布态——
    /// isPublishing = true + updatePublishState() 冻结全部输入与发布钮，
    /// 取消键由 didTapCancel 的 isPublishing 守卫拦下（只 toast、不关），
    /// 故 setVisibility 在途期间不存在“关编辑器后原日记已公开、本篇未发”
    /// 的半截流程；setVisibility 失败则解冻、停在编辑器、原日记未动。
    private func beginPublishTogether(snapshot: PublishSnapshot, generation: Int) {
        guard generation == publishGeneration else { return }
        guard let sourceId = snapshot.quoteId, !sourceId.isEmpty else { return }
        // setVisibility 发出前再校验发起账号：门禁弹框在途期间账号若已变，
        // 不把原日记以新账号公开（isPublishing 尚未置位，直接中止即可）。
        if isPublishOriginMismatch() {
            showPublishAccountMismatchAlert()
            return
        }
        isPublishing = true
        updatePublishState()
        BearyAPI.shared.setVisibility(id: sourceId, published: 1) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.publishGeneration else { return }
                switch result {
                case .success:
                    // 原日记已公开：先记部分成功态，再发新篇。此后新篇
                    // 失败不回滚原日记（见 performPublish 部分成功分支）。
                    self.publishTogetherPublishedSourceId = sourceId
                    self.performPublish(snapshot: snapshot, generation: generation, sourceAlreadyPublished: true)
                case .failure:
                    self.isPublishing = false
                    self.updatePublishState()
                    self.showToast(message: "原日记公开失败，请重试")
                }
            }
        }
    }

    /// 一并公开部分成功提示：原日记已公开、新篇发布失败。原日记不回滚：
    /// 用户已明确同意一起公开，且公开后可能已被看到/引用，回滚既收不回
    /// 可见性、又会把已同意的公开态悄悄改回私密，故部分成功即为终态，
    /// 新篇单独重试。401 时不直接重发新篇（必再撞 401），改给重新登录；
    /// 登录后用户再点发布即走部分成功跳门禁路径，只发新篇。
    private func showPartialPublishFailureAlert(snapshot: PublishSnapshot, generation: Int, error: APIError) {
        if let sourceId = snapshot.quoteId, !sourceId.isEmpty {
            publishTogetherPublishedSourceId = sourceId
        }
        var message = "原日记已公开，新篇发布失败"
        let isUnauthorized: Bool
        if case .unauthorized = error {
            isUnauthorized = true
            message += "，登录已失效，请重新登录后只重试新篇"
        } else if case .network = error {
            isUnauthorized = false
            message += "，网络不可用，已保存为草稿，联网后可只重试新篇"
        } else {
            isUnauthorized = false
            message += "，请只重试新篇"
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if isUnauthorized {
            alert.addAction(UIAlertAction(title: "重新登录", style: .default) { [weak self] _ in
                self?.onRequireLogin?()
            })
        } else {
            // 同一代次内只重试新篇：不走门禁、不再 setVisibility。
            // 代次已变（用户已另起一轮发布）时 performPublish 入口守卫
            // 会丢弃本次回调，不碰在途流程。
            alert.addAction(UIAlertAction(title: "只重试新篇", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.performPublish(snapshot: snapshot, generation: generation, sourceAlreadyPublished: true)
            })
        }
        alert.addAction(UIAlertAction(title: "知道了", style: .cancel, handler: nil))
        present(alert, animated: BearyMotion.animated(true))
    }

    private func hasFailedImage() -> Bool {
        for item in imageItems {
            if item.failed {
                return true
            }
        }
        return false
    }

    /// B1：条里是否有实况视频已丢的图（草稿里有 liveVideoFile 但磁盘文件
    /// 不在）：发布须拦截，不静默降级为静态（见 didTapPublish）。
    private func hasLiveVideoMissingImage() -> Bool {
        for item in imageItems {
            if item.liveVideoMissing {
                return true
            }
        }
        return false
    }

    /// B1：实况视频已丢的提示——恢复流程的“已恢复上次的草稿”toast 在
    /// 0.35s 后才发，直接当场发会被它盖掉，故延后 0.5s 再发；草稿箱
    /// 打开路径无此竞争，同款延后无害。
    private func showLiveVideoMissingToast() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.view.window != nil else { return }
            self.showToast(message: "这张实况需重新选择")
        }
    }

    /// 新建发布（quote-freeze）：提交载荷只读 snapshot，不再重读正文、
    /// 图片、标题、天气、气温、引用等现场值。clientReq 落盘与胶囊校验
    /// 已在 makePublishSnapshot/didTapPublish 做完，本处不再重复；
    /// 失败分支的 saveDraftNow 只是草稿兜底（保留失败篇），不进请求。
    /// 代次过期（新一轮发布已开始）的回调直接丢弃，不碰 isPublishing、
    /// 不覆盖新流程状态。
    /// - sourceAlreadyPublished：一并公开的原日记已公开成功，本次只发新篇；
    ///   失败分支走部分成功提示、不回滚原日记（见 showPartialPublishFailureAlert）。
    private func performPublish(snapshot: PublishSnapshot, generation: Int, sourceAlreadyPublished: Bool = false) {
        guard generation == publishGeneration else { return }
        // 发布请求发出前再校验发起账号：快照发起账号或本篇发起绑定
        // 任一失配即中止、不发请求。部分成功态下失配用部分成功口径
        // 提示（原日记已公开仍要明说），不给“只重试新篇”按钮——换号
        // 重发仍会被本守卫拦下，须先回到原账号。
        if isPublishOriginMismatch()
            || (snapshot.originAccountId != nil && snapshot.originAccountId != currentAccountIdForPublish()) {
            isPublishing = false
            updatePublishState()
            showPublishAccountMismatchAlert()
            return
        }
        isPublishing = true
        updatePublishState()
        // 109：新建标题取快照（空 = nil 省略不传，按无标题创建）。
        // iCity：可见性值即 visibility（published 0/1）；@ 以 mentioned_user_id 发出，无按篇通知开关。
        // 限时：限时态时可见性必为公开，ephemeral=1 随新建发出（服务端写 24 小时到期）。
        // 已删引用不传 quoteId：快照生成时已按“已删 → nil”定格（只剩 id 的
        // 引用服务端会拒，发布应按无引用走，展示态仍保留到发布成功清草稿为止）。
        let publishVisibility = snapshot.published
        BearyAPI.shared.publishEntry(content: snapshot.content, images: snapshot.imageKeys, mood: snapshot.mood, weather: snapshot.weather, quoteId: snapshot.quoteId, published: publishVisibility, mentionedUserId: snapshot.mentionedUserId, title: snapshot.title, ephemeral: snapshot.ephemeral, clientReq: snapshot.clientReq, locationName: snapshot.locationName, locationDistrict: snapshot.locationDistrict, temperature: snapshot.temperature, liveVideos: snapshot.liveVideos.isEmpty ? nil : snapshot.liveVideos, visibility: snapshot.visibility) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, generation == self.publishGeneration else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success(let resp):
                    if let entryId = resp.id {
                        // 只有拿到 entry id 才清草稿与本地图片。发布已成功，删库
                        // 失败时不弹 toast（会与“已发布”冲突），残留草稿仍在草稿
                        // 箱可见、可手动删；图片随记录保留，不丢。
                        // P1-4：先使待执行的自动保存失效，再清理并退场——
                        // 否则清理后、析构前计时器触发会把内存里已发布的内容
                        // 当全新草稿落盘（saveDraftNow 的已发布守卫是第二道）。
                        self.draftTimer?.invalidate()
                        self.draftTimer = nil
                        self.publishedCurrentDraft = true
                        // P0-2：只清提交时快照记录的那一篇；切篇后 pending 撤销
                        // 属于新篇，不在此提交。
                        let stillOnPublishedDraft = self.currentDraftId == snapshot.draftId
                        self.clearPublishedDraft(snapshot: snapshot)
                        if stillOnPublishedDraft {
                            self.commitPendingRemoval()
                        }
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
                        self.showToastAfterClose(message: (snapshot.ephemeral == 1 ? "已发布 · 限时公开" : (snapshot.visibility == "friends" ? "已发布 · 仅好友可见" : (publishVisibility == 1 ? "已发布 · 已公开" : "已发布 · 已设为私密"))))
                        BearyHaptics.publishSuccess()
                        BearySoundPlayer.play(.publishSuccess)
                        // B 修法：发布成功退场前先收起弹出框（无动画）。
                        self.hideCallout(animated: false)
                        self.onPublished?(entryId)
                    } else {
                        self.saveDraftNow()
                        BearyHaptics.rejectionWarning()
                        if !self.publishButton.isHidden, !UIAccessibility.isReduceMotionEnabled {
                            self.publishButton.layer.removeAnimation(forKey: "bearyDenyShake")
                            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                            shake.values = [0, -8, 8, -5, 5, 0]
                            shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                            shake.duration = 0.4
                            self.publishButton.layer.add(shake, forKey: "bearyDenyShake")
                        }
                        self.showAlert(message: "发布失败，请重试")
                    }
                case .failure(let error):
                    // 失败一律保留草稿；离线/网络错误给明确文案。
                    // saveDraftNow 受发起账号守卫约束：账号已变时不写新号桶，
                    // 原账号旧版仍在，失败提示仍按本分支出（不因保存被拦而改口径）。
                    // 两边都保：部分成功先行（原日记已公开，不回滚、给只重试新篇
                    // 的路径，401 时给重新登录）；网络分支按落盘成败分文案。
                    if sourceAlreadyPublished {
                        // 部分成功：原日记已公开，不回滚、不走通用“发布失败”
                        // 文案，弹框给只重试新篇的路径（401 时给重新登录）。
                        self.saveDraftNow()
                        self.showPartialPublishFailureAlert(snapshot: snapshot, generation: generation, error: error)
                    } else if case .network = error {
                        // 网络分支：草稿兜底须按落盘成败分文案——此前无条件称“已保存为
                        // 草稿”，落盘失败时即谎称；现接 saveDraftNow 的 DraftSaveResult，
                        // 成功才称已保存，失败明示草稿也未保存、请保留内容后重试。
                        // 非网络分支（未授权/通用）口径不动，仍沿用原 fire-and-forget 调用。
                        self.saveDraftNow { [weak self] result in
                            guard let self = self else { return }
                            if result.succeeded {
                                self.showAlert(message: "网络不可用，已保存为草稿，联网后可重试")
                            } else {
                                self.showAlert(message: "发布失败，草稿也未保存，请保留当前内容后重试")
                            }
                        }
                    } else if case .unauthorized = error {
                        self.saveDraftNow()
                        self.onRequireLogin?()
                    } else {
                        self.saveDraftNow()
                        BearyHaptics.rejectionWarning()
                        if !self.publishButton.isHidden, !UIAccessibility.isReduceMotionEnabled {
                            self.publishButton.layer.removeAnimation(forKey: "bearyDenyShake")
                            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
                            shake.values = [0, -8, 8, -5, 5, 0]
                            shake.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
                            shake.duration = 0.4
                            self.publishButton.layer.add(shake, forKey: "bearyDenyShake")
                        }
                        self.showAlert(message: self.message(forPublishError: error))
                    }
                }
            }
        }
    }

    private func message(forPublishError error: APIError) -> String {
        if case .server(let code, _) = error {
            switch code {
            case "create_gap":
                return "发布太频繁，请稍后再试"
            case "create_day_limit":
                return "今日发布次数已达上限，请明天再试"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "content too long":
                return "正文最多 2000 字"
            case "title too long":
                // 扫查组兜底：旧草稿/他端标题超码点上限时发布仍可能撞上
                // 服务端 400，不再落通用“发布失败”，直说标题超长。
                return "标题最多 30 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
            case "recipient_invalid", "mentioned_user_invalid":
                return "无法提到这位用户，请重新选择"
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
        // 109：编辑 PUT 带输入框标题（清空发显式空串，服务端归一化为 NULL 即清标题；
        // 有值发值；本支不再用“nil 省略保留原值”绕过清空——清空就是清标题）。
        // iCity：编辑 @ 三态——已改选发新 id；已清除发 clearMentioned；未动则两者皆空、服务端保留原值。
        let updateMentionedId: Int? = selectedRecipient?.id
        let updateClearMentioned: Bool = (selectedRecipient == nil && editMentionCleared)
        // 批 E：编辑位置——与原快照比对，未动省略、改选两键算清（有值发值、无值发 null）、清除两键皆 null。
        let locationChanged = selectedLocation != originalLocation
        // 编辑实况映射：新映射非空即发；新映射为空但原篇有实况时发显式
        // 空映射清掉原实况；原篇本就无实况且新映射为空时省略（纯静态编辑
        // body 不变）。uploadedLiveVideos() 算两次是同一内存快照，无副作用。
        let editLiveVideos: [String: String]? = uploadedLiveVideos().isEmpty
            ? ((editingEntry?.liveVideos?.isEmpty == false) ? [:] : nil)
            : uploadedLiveVideos()
                BearyAPI.shared.updateEntry(id: entryId, content: trimmed, images: uploadedImageKeys(), mood: selectedMood, weather: selectedWeather, quoteId: lockedQuote?.entryId, title: headlineText, mentionedUserId: updateMentionedId, clearMentioned: updateClearMentioned, locationName: locationChanged ? selectedLocation?.name : nil, locationDistrict: locationChanged ? selectedLocation?.district : nil, clearLocationName: locationChanged && selectedLocation?.name == nil, clearLocationDistrict: locationChanged && selectedLocation?.district == nil, temperature: selectedTemperature, liveVideos: editLiveVideos) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isPublishing = false
                self.updatePublishState()
                switch result {
                case .success:
                    self.deleteEditLocalFiles()
                    self.commitPendingRemoval()
                    // 审计四轮增量 09：提交成功，检查点已无意义，清掉。
                    BearyDraftStore.clearEditCheckpointAsync(entryId: entryId)
                    // D2：把编辑器终态写回原 Entry 副本传给容器（引用已清时 quoteId/quote
                    /// 均为 nil，容器据此清行内引用卡；已删引用不按正常 quote 回传）。
                    if var updated = self.editingEntry {
                        updated.content = trimmed
                        // 109：本地副本跟随输入框标题（空 = nil，与服务端归一化一致）。
                        updated.title = self.headlineText.isEmpty ? nil : self.headlineText
                        updated.images = self.uploadedImageKeys()
                        updated.liveVideos = self.uploadedLiveVideos().isEmpty ? nil : self.uploadedLiveVideos()
                        updated.mood = self.selectedMood
                        updated.weather = self.selectedWeather
                        updated.temperatureC = self.selectedTemperature
                        // 批 E：编辑成功后本地副本跟随位置终态，列表行不靠重拉才变。
                        updated.locationName = self.selectedLocation?.name
                        updated.locationDistrict = self.selectedLocation?.district
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
                                authorPlus: nil,
                                authorId: locked.authorId,
                                isMine: locked.isMine,
                                authorHandle: locked.authorHandle
                            )
                        } else {
                            updated.quote = nil
                        }
                        // B 修法：编辑保存成功退场前先收起弹出框（无动画；编辑器不关闭时本分支不跑，不误收）。
                        self.hideCallout(animated: false)
                        self.onUpdated?(updated)
                    }
                case .failure(let error):
                    if self.editSaveBlockedAfterDeadline {
                        // 在途保存赶上期限、服务端已判失败：不再允许重发
                        // （期限已过，重发同样会被服务端拒绝；保存钮已由
                        // updatePublishState 持续禁用，didTapPublish 亦拦）。
                        // 不删本地文件、不关编辑器、不清正文/标题，输入原样
                        // 保留供复制；关闭仍走用户手动取消（与正常取消同语义，
                        // 关闭前请先复制）。注意：此处不走 onRequireLogin——
                        // 登录页盖上来也救不回已过的期限，反而会挡住复制
                        // 输入的机会；非过期态的登录失效仍走原分支。
                        // 失败原因常驻 alert（不用一闪而过的 toast），确保看得到。
                        if case .server(let code, _) = error, code == "edit window expired" {
                            self.showAlert(message: "超过 15 分钟，已无法编辑；内容仍在编辑器里，可复制后关闭")
                        } else if case .network = error {
                            self.showAlert(message: "网络不可用，修改未保存；编辑时间已过，无法再保存，可复制内容后关闭")
                        } else if case .unauthorized = error {
                            self.showAlert(message: "登录已失效，修改未保存；编辑时间已过，无法再保存，可复制内容后关闭")
                        } else {
                            self.showAlert(message: "\(self.message(forUpdateError: error))；编辑时间已过，无法再保存，可复制内容后关闭")
                        }
                    } else if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .server(let code, _) = error, code == "edit window expired" {
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
        if case .server(let code, _) = error {
            switch code {
            case "content too long":
                return "正文最多 2000 字"
            case "title too long":
                return "标题最多 30 字"
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
    func textViewDidBeginEditing(_ textView: UITextView) {
        if textView === headlineField {
            headlineDidBeginEditing()
            return
        }
        lastFocusedComposerInput = .body
        if currentKeyboardHeight > 0 {
            // 键盘动画在途时不另起一路滚动：系统 caret 滚动＋键盘 inset
            // 动画＋本回调三路抢偏移正是闪回的来源之一；只记 pending，
            // 由 applyKeyboard 完成回调统一做一次带键盘曲线的修正。
            if keyboardAnimationInFlight {
                pendingFocusScrollAfterKeyboard = true
                return
            }
            _ = scrollFocusedFieldIntoView(animated: BearyMotion.animated(true))
        }
    }

    // 标题行已去掉：ensureTitleRowVisibleOnEntry（进页拉回）已整段删除，
    // 不再为不存在的标题行做进页滚动；焦点滚动只剩正文 caret 口径（见下）。
    // 2026-11-01：标题行已退出滚动口径（点标题只聚焦、不滚动），
    // 焦点滚动只剩正文口径（见 scrollFocusedFieldIntoView）。

    /// 可见性滚动留白：目标离可视区顶的距离（2026-10-30 滚动留白口径，
    /// 贴边改留白；已完整可见时仍不动）。
    private static let focusVisibleTopMargin: CGFloat = 16

    /// 2026-10-29 第 28 项：只滚到刚好让焦点框完整可见的最小滚动——焦点框在可视区
    /// 上方时上滚到其顶离可视区顶留 16pt（绝不顶出顶部），在可视区下方时下滚到其底恰贴
    /// 键盘顶；已完整可见时不动。109 改口径（见函数内注释）：焦点框改取正文帧
    /// 本身（不再取 caretRect），可视底不再减键盘 inset；目标偏移 clamp 到
    /// 内容合法范围。
    /// duration/curveRaw 非空时按给定键盘曲线做动效（applyKeyboard 完成
    /// 回调专用）；否则走默认 UIView 动画。animated:false 的瞬时修正是
    /// 闪回的另一来源——键盘动画刚把内容顶上去，完成回调又无动效地
    /// 把偏移改回去，看起来就是“上滑后闪回来”，故此处不再有无动效修正。
    /// 返回值：是否实际动了外层偏移（标题聚焦的默认滚动抵消逻辑凭它判定 no-op）。
    private func scrollFocusedFieldIntoView(animated: Bool, duration: TimeInterval? = nil, curveRaw: UInt? = nil) -> Bool {
        // 109：输入时去掉外层自动上滑。根因两处重复计算（2026-10-31 真机报
        // “输入上滑就看不到光标和打的文字”）：
        // ① 旧口径以 caretRect（内层 textView 内容坐标，长文时内层已滚动）
        //    直接换算到外层 contentView——内层滚动被重复计入外层偏移，
        //    长文末行时外层被多滚一段，正文整体被顶出顶栏上方，光标与
        //    正在打的字随之出可视区。
        // ② 外层 scrollView 底已锚工具栏顶（工具栏底锚键盘顶，即滚动区帧底
        //    本就在键盘上方），旧口径又在可视底再减一份 contentInset.bottom
        //    （= 键盘高），可视底被低估约一个键盘高——正文帧底恒被判定
        //    “在可视区下方”，键盘弹起完成回调几乎每次都触发一次外层上滑。
        // 修法（只改本函数，不动键盘 inset 动画、可见性三态、字数圆环等）：
        // 外层只负责“正文帧本身是否在可视区内”，光标在帧内的可见性交
        // 给内层 textView 自身滚动（isScrollEnabled=true、高度封顶在键盘
        // 上方，系统标准 caret 滚动只在打到帧内可视区外时动内层）。
        // 正常输入时正文帧恒在可视区内 → 本函数 no-op，外层不再上滑，
        //    光标与文字始终留在帧内可见；手动把外层滑走后，焦点/键盘
        //    事件仍按帧顶/帧底最小量把帧拉回可视区，不丢光标。
        // 2026-11-01 Li 定：标题聚焦不滚动——本函数只守正文，
        // 标题为焦点方时直接返回 false（键盘完成回调、焦点回调
        // 走到这里都不再为标题动外层偏移）。
        guard !headlineField.isFirstResponder else { return false }
        let fieldFrameInContent: CGRect
        if textView.isFirstResponder {
            // textView 是 contentStack 的 arranged 子视图：frame 在 contentStack
            // 坐标系内，经 superview 换算到 contentView 才是外层滚动的坐标口径；
            // 不直接用 caretRect，避免内层滚动被重复计入外层偏移。
            fieldFrameInContent = contentView.convert(textView.frame, from: textView.superview ?? contentView)
        } else {
            return false
        }
        let topInset = scrollView.contentInset.top
        let bottomInset = scrollView.contentInset.bottom
        let visibleTop = scrollView.contentOffset.y + topInset
        // 滚动区帧底已在键盘上方（底锚工具栏顶），可视底不再减键盘 inset；
        // bottomInset 只保留在下方 maxY 合法范围计算里，不参与可见判定。
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
        var targetY = scrollView.contentOffset.y
        if fieldFrameInContent.minY < visibleTop {
            targetY = fieldFrameInContent.minY - topInset - Self.focusVisibleTopMargin
        } else if fieldFrameInContent.maxY > visibleBottom {
            targetY = fieldFrameInContent.maxY - scrollView.bounds.height
        } else {
            return false
        }
        let minY = -topInset
        let maxY = max(minY, scrollView.contentSize.height + bottomInset - scrollView.bounds.height)
        targetY = min(max(targetY, minY), maxY)
        // 2pt 死区：目标与现偏移差不到 2pt 时不动，防键盘帧微变、
        // 内层 caret 微移引发的反复微跳（视觉上也是闪）。
        if abs(targetY - scrollView.contentOffset.y) < 2 { return false }
        if animated, let duration = duration, let curveRaw = curveRaw {
            let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
            UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: {
                self.scrollView.setContentOffset(CGPoint(x: self.scrollView.contentOffset.x, y: targetY), animated: false)
            })
        } else if animated {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: BearyMotion.animated(true))
        } else {
            // 仅内部调用方明确要求时才瞬时改（现行调用方已全部改为动效，
            // 本分支保留作兜底，不再是键盘路径的默认行为）。
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
        }
        return true
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

    /// 手势代理：落在正文 textView（含占位 label 子视图）内的点按
    /// 不触发收键盘，交给输入框正常聚焦/选区；其余空白与控件点按照常收键盘
    /// （cancelsTouchesInView=false，控件自身点按不受影响）。
    /// 109：标题输入框（headlineField）点按同样排除，见函数内分支。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let touchedView = touch.view, touchedView.isDescendant(of: textView) || touchedView === textView {
            return false
        }
        // 109：标题输入框点按同样不触发收键盘，交给输入框正常聚焦。
        if let touchedView = touch.view, touchedView.isDescendant(of: headlineWrap) || touchedView === headlineField {
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
                    // iPad 浮动键盘：键盘框底未贴到视图底边时，底部并未被遮挡，
                    // 旧口径 view 底减键盘顶会把键盘下方的空隙也算成遮挡，工具栏
                    // 被多顶一截；只有键盘贴底（框底到达或超出视图底边）时，才按
                    // 旧口径算遮挡高度，贴底键盘行为与现行一致；1pt 容差防浮点
                    // 舍入把贴底误判成浮动（真浮动悬空都是几十 pt 以上的间隙）。
                    if frame.maxY >= view.bounds.maxY - 1 {
                        height = max(0, view.bounds.maxY - frame.minY)
                    } else {
                        height = 0
                    }
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
        // 2026-10-31 闪回去重：WillShow 与 WillChangeFrame 对同一次出现
        // 各发一次，高度与可见态都未变时第二遍直接跳过——不重跑 inset
        // 动画、不重跑完成回调的偏移修正，否则两遍动画＋瞬时修正打架。
        if showing && height > 0 && keyboardVisible && (height == lastAppliedKeyboardHeight || height == currentKeyboardHeight) {
            return
        }
        keyboardAnimationInFlight = true
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
        // 2026-11-01：标题抵消逻辑已随标题滚动链删除，弹出前原位
        // 不再单独取一份；收起恢复仍走 keyboardSavedContentOffset 原逻辑。
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
            self.keyboardAnimationInFlight = false
            if showing && height > 0 {
                self.lastAppliedKeyboardHeight = height
            } else if isHiding {
                self.lastAppliedKeyboardHeight = -1
            }
            // 2026-10-31：inset 落定后的修正只做一次、且一律带键盘曲线
            // 动效——旧代码这里是 animated:false 的瞬时修正，键盘动画刚
            // 把内容顶上去、完成回调又无动效改回去，就是“上滑后闪回来”。
            // 收起恢复原位同样带曲线动效，不再瞬时跳回。
            if isHiding {
                if let saved = self.keyboardSavedContentOffset {
                    self.keyboardSavedContentOffset = nil
                    let minY = -self.scrollView.contentInset.top
                    let maxY = max(minY, self.scrollView.contentSize.height + self.scrollView.contentInset.bottom - self.scrollView.bounds.height)
                    let restoredY = min(max(saved.y, minY), maxY)
                    if abs(restoredY - self.scrollView.contentOffset.y) >= 2 {
                        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
                        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: {
                            self.scrollView.setContentOffset(CGPoint(x: self.scrollView.contentOffset.x, y: restoredY), animated: false)
                        })
                    }
                }
            } else {
                // 光标已在可视区时 scrollFocused 内部 no-op；键盘在途
                // 中点按记下的 pending 在此统一消化，只做一次。
                self.pendingFocusScrollAfterKeyboard = false
                // 2026-11-01：标题抵消与守卫复查已随标题滚动链删除；
                // 标题为焦点方时 scrollFocusedFieldIntoView 直接返回 false，
                // 这里只剩正文路径。
                _ = self.scrollFocusedFieldIntoView(animated: BearyMotion.animated(true), duration: duration, curveRaw: curveRaw)
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
    /// 审计-编辑器详情：上传代次 + 在途任务 + 发起账号。每次发起上传
    /// （编码开始）代次 +1 并绑定当前鉴权账号，由回包认领；取消/删图
    /// 时再 +1 并 cancel 任务，过期回包（代次不符或已不在条里）一律丢弃，
    /// 不得覆盖更新的上传态。代次与发起账号只在上传锁内读写（见
    /// BearyComposerViewController.uploadStateLock），编码完成后的起传
    /// 门控只认发起时捕获的（代次，账号），两者任一不符即不起传。
    var uploadGeneration = 0
    /// 本次上传发起时绑定的鉴权账号（BearyAPI.authAccountId 快照）；
    /// 取消时清掉。只在上传锁内读写。
    var uploadAccountId: Int?
    var uploadTask: URLSessionTask?
    var localFile: String?
    var failed: Bool
    /// 实况（待传视频已落盘 + 已上传 key）：
    /// liveVideoData = 本轮新选实况待上传的 mov（上传成功后清掉，只留 key）；
    /// liveVideoKey = 服务端视频 key（上传回包 live_key，或编辑回填的原实况）。
    /// liveVideoFile = 待传 mov 的本地文件名（<uuid>.mov，静图同 stem，
    /// B1：随静图一起落盘，杀 App 后从草稿读回 liveVideoData 再续传）；
    /// 上传成功/裁剪/删图时随静图一起清（见 deletePair）。
    /// liveVideoMissing = 草稿里有 liveVideoFile 但磁盘文件不在：静图预览
    /// 保留，不自动续传、不随发布静默降级为静态，须用户重新选择。
    var liveVideoData: Data?
    var liveVideoKey: String?
    var liveVideoFile: String?
    var liveVideoMissing = false
    let container: UIView
    let imageView: UIImageView
    let spinner: BearyWebRingSpinnerView
    let failView: UIView
    let removeButton: UIButton

    init(key: String?, uploading: Bool, localFile: String?, failed: Bool, container: UIView, imageView: UIImageView, spinner: BearyWebRingSpinnerView, failView: UIView, removeButton: UIButton) {
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
// 2. @：新建模式只选一人（搜索接口 users 组），仅已选 chip（空态虚线钮已删）；
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
//    上传失败图为行内红底块（红 10% 底 + “上传失败，点按重试”），发布时有失败图 toast 拦截不发。
//    其余白字只出现在恒定橙底上（心情 chip 回退名）与墨底上（发布 pill），浅深皆可读。
// 8. C1：段落顺序改为正文 → 已选 Chip 行 → 图片 → 状态行 → 引用 → 规则框；
//    工具栏贴键盘上方，心情/天气/@ 为工具栏上方单行选择条（旧附加选项栏已删）；
//    草稿 pill 计数按 v3 多槽篇数，0 篇时只留“草稿”二字、计数段隐藏；
//    引用面板为网页 qp-mode 整编形态（打开只留面板、发布钮隐藏、取消变“返回”只退面板、
//    进出保存/恢复滚动位置、每 tab 缓存 + 序号守卫、选篇立即落盘）；
//    编辑倒计时到 0 显示“编辑时间已结束”，编辑器留页保留内容、可复制后关闭，
//    不走 onCancelled 关闭编辑器（旧“编辑已结束＋关闭”口径已废止；
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

// MARK: - 112 引用列表 v2 状态 pill（预览 preview-quote-list-status-v2-20261031.html）
//
// 裸字 + 细边、无底色块：公开橙实线、私密蓝实线、限时橙虚线；字 12、内边距 2/8。
// 虚线用 CAShapeLayer 自画（1.5pt、dash [4, 3]），
// 布局时按当前 bounds 重画；深浅切换时重解动态蓝（orange 为固定色，无需重解）。
// 仅展示、不拦截点按（行按钮的点按选引用行为不动）。
private final class BearyQuoteStatusPillView: UIView {

    enum Style {
        case `public`
        case `private`
        case limited
    }

    private let label = UILabel()
    private let dashedLayer = CAShapeLayer()
    private var style: Style = .public

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 12)
        label.numberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        layer.cornerRadius = 999
        layer.masksToBounds = true
        dashedLayer.fillColor = UIColor.clear.cgColor
        dashedLayer.lineWidth = 1.5
        dashedLayer.lineDashPattern = [4, 3]
        layer.addSublayer(dashedLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: Style) {
        self.style = style
        label.text = text
        applyColors()
        setNeedsLayout()
    }

    private func applyColors() {
        let color: UIColor = (style == .private) ? BearyColors.blue : BearyColors.orange
        label.textColor = (style == .private) ? BearyColors.blue : BearyColors.deepOrangeText
        if style == .limited {
            layer.borderWidth = 0
            dashedLayer.strokeColor = color.cgColor
            dashedLayer.isHidden = false
        } else {
            dashedLayer.isHidden = true
            layer.borderWidth = 1.5
            layer.bearyDynamicBorderColor = color
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if style == .limited {
            dashedLayer.frame = bounds
            dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }
}

// MARK: - 批 E 定位气泡回调

extension BearyComposerViewController: BearyLocationPopoverDelegate {
    func locationPopover(_ popover: BearyLocationPopoverView, didConfirm location: DiaryLocation) {
        // 确认即落定（点建议也是直接落定，不再等头部确认钮）；气泡关闭、行显示、草稿跟随保存。
        selectedLocation = location
        hideLocationPopover(animated: true, restoreFocus: true)
        refreshLocationRow(animated: true)
        scheduleDraftSave()
    }

    func locationPopoverDidFail(_ popover: BearyLocationPopoverView, message: String) {
        // 权限被拒/定位失败：只 toast，绝不关气泡——气泡已原地转手动输入，
        // 关掉会把用户刚切到的输入框一起关掉；失败本身不产生位置值，
        // 已确认过的位置不被失败清掉（见 selectedLocation 注释），从未确认过时行即隐藏。
        showToast(message: message)
    }
}


extension BearyComposerViewController {
    // 2026-11-01：标题聚焦守卫复查函数已随标题滚动链删除。
    /// 标题失焦只刷新标题 chrome（原 textFieldDidEndEditing，
    /// 改走 textViewDidEndEditing）；正文失焦不走本分支。
    func textViewDidEndEditing(_ textView: UITextView) {
        guard textView === headlineField else { return }
        refreshHeadlineChrome()
    }

    /// 标题单行守卫（原 textFieldShouldReturn + shouldChangeCharacters，改走
    /// UITextViewDelegate）：回车跳正文；粘贴里的换行压成空格；30 字封顶按
    /// 最终序列化标题的码点算（与 headlineDidChange / truncatedHeadline 的
    /// 服务端口径一致，附件按记号全长计、非 1 格），组词中不拦；正文一律放行。
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === headlineField else { return true }
        if headlineField.markedTextRange != nil { return true }
        if text == "\n" {
            self.textView.becomeFirstResponder()
            return false
        }
        let sanitized = text.replacingOccurrences(of: "\n", with: " ")
        let current = headlineField.attributedText ?? NSAttributedString()
        // 长度口径统一（旧公式混用三者是本修法的根因）：
        // 选区与 NSRange 一律 UTF-16（current.length、range.length、(String as NSString).length）；
        // 业务限长一律对最终序列化标题（附件已还原为记号的 inlinePlainText）按码点计，
        // 与 headlineDidChange / truncatedHeadline 的服务端口径一致，同一公式里不混用 .length 与 .count。
        // 旧公式 current.length - range.length + sanitized.count 把 UTF-16 长与字素簇数相加：
        // 20 个普通 emoji 时 UTF-16 已 40、码点才 20，继续敲普通字会误走超限分支被吞还弹提示。
        // 基数 = 删掉待替换段后的序列化标题码点数；被替换段里的熊脸附件按记号全长计（非 1 格），
        // 删它能腾出的格数旧公式（按 attributed 1 格算）会算少。
        let base = NSMutableAttributedString(attributedString: current)
        base.deleteCharacters(in: range)
        let baseCodePoints = BearyText.inlinePlainText(from: base).unicodeScalars.count
        if baseCodePoints + sanitized.unicodeScalars.count <= Self.headlineMaxLength {
            if sanitized == text { return true }
            let mutable = NSMutableAttributedString(attributedString: current)
            mutable.replaceCharacters(in: range, with: sanitized)
            // 手动塞入的纯文本绝不能带心情记号属性：replaceCharacters 塞纯
            // 字符串时会继承落点旁的字符属性，紧贴熊脸附件粘贴时粘入的文字
            // 可能带上 inlineMoodKeyAttribute，发出时整段会被转成一个记号、
            // 原文字静默丢失；此处把插入段清成标题正文属性。
            // 插入段与光标一律 UTF-16：emoji 一个字素簇占 2 个 UTF-16 单位，
            // 用 .count 会让属性清理短一截、光标落在插入段中间。
            let insertedLength = (sanitized as NSString).length
            let inserted = NSRange(location: range.location, length: insertedLength)
            if inserted.length > 0 {
                mutable.removeAttribute(BearyText.inlineMoodKeyAttribute, range: inserted)
                mutable.addAttributes([.font: headlineFont, .foregroundColor: BearyColors.ink], range: inserted)
            }
            headlineField.attributedText = mutable
            headlineField.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
            headlineField.selectedRange = NSRange(location: range.location + insertedLength, length: 0)
            headlineDidChange()
            return false
        }
        // 超限：只塞进剩下的码点数，余下丢掉并弹一次提示（原 shouldChange 同款口径）。
        // 按字素簇逐个取、按码点累计，永不拆散一个组合表情：
        // ZWJ 全家福 1 簇计 7 码点（见 truncatedHeadline 注释），占满剩余格即停，
        // 不像旧 prefix(remaining) 那样把“剩余格”当成簇数/UTF-16 长混算。
        let remaining = max(0, Self.headlineMaxLength - baseCodePoints)
        var kept = ""
        var keptCodePoints = 0
        for character in sanitized {
            let characterCodePoints = character.unicodeScalars.count
            guard keptCodePoints + characterCodePoints <= remaining else { break }
            kept.append(character)
            keptCodePoints += characterCodePoints
        }
        let mutable = NSMutableAttributedString(attributedString: current)
        mutable.replaceCharacters(in: range, with: kept)
        // 同上：超限分支手动塞入段同样清掉可能继承的心情记号属性；长度用 UTF-16。
        let insertedLength = (kept as NSString).length
        let inserted = NSRange(location: range.location, length: insertedLength)
        if inserted.length > 0 {
            mutable.removeAttribute(BearyText.inlineMoodKeyAttribute, range: inserted)
            mutable.addAttributes([.font: headlineFont, .foregroundColor: BearyColors.ink], range: inserted)
        }
        headlineField.attributedText = mutable
        headlineField.typingAttributes = [.font: headlineFont, .foregroundColor: BearyColors.ink]
        headlineField.selectedRange = NSRange(location: range.location + insertedLength, length: 0)
        showHeadlineLimitToastIfNeeded()
        headlineDidChange()
        return false
    }
}

// 2026-11-01：外层滚动区 UIScrollViewDelegate 扩展已随标题聚焦守卫删除
// （它只为守卫清快照服务；delegate 赋值亦已在 buildLayout 撤掉）。

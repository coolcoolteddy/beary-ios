import Foundation
import UIKit

// MARK: - 与过去的自己对话（不新开页，不走 AI）
//
// 口径（预览 preview-past-self-and-wordprint.html 对话部分 + 任务书）：
// - 入口只在我的页「那年今日」卡片内；送达卡只出现在本人我的页模块栈顶，
//   不新开页、不进广场、不发通知、不公开。
// - 全程无 AI 代笔：只出现用户自己写过的原篇与自己写的留话。
// - 留话驱动送达：没有留话就不推（一年没写不硬推）；送达日当天没打开也不丢，
//   送达态一直保留到用户「再回一句」为止。
// - 年份链：chainId 恒等于原篇 id；「再回一句」只追加，不改旧行，链不丢。
// - 原篇状态联动（见 viewerVisibility）：删 = 全串只留「原篇已删除」占位，
//   正文与留话一律不残留；翻回私密 = 仅作者可见，他人只见占位；
//   存储行本身不因删除/私密而抹掉——回收站恢复后原篇重回语料，串自动重现。
// - 本文件只用 Foundation + UIKit + 已有的 BearyColors / BearyDynamicType
//  （#555 起已引用 BearyColors，本处不再声称不引用；BearyColors 的
//   定义与 target 注册不在本文件动，另有专线处理）。
// - 后端未上线前：本地存储即事实来源；后端上线后见 BearyAPI 的
//   past-self 端点（创建先落本地、后台再同步，失败静默留本地待下次同步）。

// MARK: - 对话记录模型（后端字段口径，见 PR 描述）

/// 一条留话。服务端字段与此一一对应（snake_case；created_at 为毫秒）：
/// id / origin_entry_id（原篇 id）/ chain_id（恒等于原篇 id）/
/// author_id / body（留话内容）/ created_at（留话时间，毫秒）/
/// deliver_on（目标推送日期，本地日 YYYY-MM-DD）/
/// revoked_at（撤回时间，毫秒；nil = 未撤回）/
/// reply_to_message_id（接续的上条留话 id；首条为 nil）。
struct PastSelfMessage: Codable, Equatable {
    var id: String
    var originEntryId: String
    var chainId: String
    var authorId: Int
    var body: String
    var createdAtMs: Int
    var deliverOn: String
    var revokedAtMs: Int?
    var replyToMessageId: String?
    /// 仅本地：true = 尚未同步到服务端（后端 404 / 断网时先落本地）。
    /// 服务端不下发该字段，缺失时按 false 计。
    var localOnly: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case originEntryId = "origin_entry_id"
        case chainId = "chain_id"
        case authorId = "author_id"
        case body
        case createdAtMs = "created_at"
        case deliverOn = "deliver_on"
        case revokedAtMs = "revoked_at"
        case replyToMessageId = "reply_to_message_id"
        case localOnly = "local_only"
    }
}

// MARK: - PastSelfMessage 解码（放 extension，不顶掉逐字段构造器）
//
// 服务端不下发 local_only（见上 struct 注释），缺失时按 false 计；
// 但合成 Decodable 对带默认值的非可选字段仍要求 key 在场，缺失即
// keyNotFound，故此处手写 init(from:)，仅 localOnly 用 decodeIfPresent
// 兜底 false，其余字段与合成版一致。encode 仍走合成版（写 snake 键）。
// 本 init 不改变解码器选择：服务端/单测仍走 plain 解码器（见 BearyAPI
// pastSelfDecoder），convert 解码器下 snake 显式键依旧不匹配——那是
// 解码器侧的既定口径，不在此处绕。
extension PastSelfMessage {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        originEntryId = try container.decode(String.self, forKey: .originEntryId)
        chainId = try container.decode(String.self, forKey: .chainId)
        authorId = try container.decode(Int.self, forKey: .authorId)
        body = try container.decode(String.self, forKey: .body)
        createdAtMs = try container.decode(Int.self, forKey: .createdAtMs)
        deliverOn = try container.decode(String.self, forKey: .deliverOn)
        revokedAtMs = try container.decodeIfPresent(Int.self, forKey: .revokedAtMs)
        replyToMessageId = try container.decodeIfPresent(String.self, forKey: .replyToMessageId)
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
    }
}

// MARK: - 日期与串状态（纯逻辑，可单测）

enum PastSelfLogic {

    /// 留话字数上限（字符数；超限拒绝提交，不静默截断）。
    static let maxBodyLength = 500

    /// 本地日字符串 YYYY-MM-DD（设备日历与时区，不走 UTC）。
    static func localDateString(fromMs ms: Int, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return localDateString(from: date, calendar: calendar)
    }

    static func localDateString(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 明年同一天（本地日）。次年同月同日无效时退到当月最后一天：
    /// 2 月 29 日 → 下一年 2 月 28 日（不跳 3 月 1 日，不丢推送）。
    /// 注意：calendar.date(from:) 会把无效日归一化（如 2025-02-29 → 2025-03-01）
    /// 而不是返回 nil，故不能先构造再判空；必须先算目标月最后一天再截断。
    static func nextYearDateString(fromMs ms: Int, calendar: Calendar) -> String? {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        var firstParts = DateComponents()
        firstParts.year = year + 1
        firstParts.month = month
        firstParts.day = 1
        guard let firstOfMonth = calendar.date(from: firstParts),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return nil }
        var target = DateComponents()
        target.year = year + 1
        target.month = month
        target.day = min(day, dayRange.count)
        guard let next = calendar.date(from: target) else { return nil }
        return localDateString(from: next, calendar: calendar)
    }

    /// 是否已到送达日（含当天；YYYY-MM-DD 字典序即时间序）。
    static func isDue(deliverOn: String, today: String) -> Bool {
        !deliverOn.isEmpty && !today.isEmpty && deliverOn <= today
    }

    /// 同一链的未撤回留话（createdAt 升序；同毫秒按 id 稳定）。
    static func liveChainMessages(_ messages: [PastSelfMessage], chainId: String) -> [PastSelfMessage] {
        messages.filter { $0.chainId == chainId && $0.revokedAtMs == nil }.sorted {
            if $0.createdAtMs != $1.createdAtMs { return $0.createdAtMs < $1.createdAtMs }
            return $0.id < $1.id
        }
    }

    /// 该链最新一条未撤回留话是否仍在等待送达（即最新行 deliverOn > 今天）。
    static func waitingMessage(_ messages: [PastSelfMessage], chainId: String, today: String) -> PastSelfMessage? {
        guard let latest = liveChainMessages(messages, chainId: chainId).last else { return nil }
        return isDue(deliverOn: latest.deliverOn, today: today) ? nil : latest
    }

    /// 串状态（调用方先算可见性：deleted 时整串只显占位，不进此状态机）。
    enum ThreadState {
        /// 从未留过话。
        case none
        /// 最新行未到送达日，且此前无已送达行（那年今日卡内显示「已留话 · 明年见」）。
        case waiting(PastSelfMessage)
        /// 最新行已送达（模块栈顶送达卡 + 「再回一句」）。
        case due(messages: [PastSelfMessage], latest: PastSelfMessage)
        /// 已回过一句：最新行在等明年，此前有已送达行（送达卡保留为「已回一句」态，
        /// 不再出「再回一句」按钮，避免同一天内重复接话把链堆乱）。
        case answered(waiting: PastSelfMessage, messages: [PastSelfMessage])
    }

    static func threadState(_ messages: [PastSelfMessage], chainId: String, today: String) -> ThreadState {
        let chain = liveChainMessages(messages, chainId: chainId)
        guard let latest = chain.last else { return .none }
        if isDue(deliverOn: latest.deliverOn, today: today) {
            return .due(messages: chain, latest: latest)
        }
        let hasDelivered = chain.dropLast().contains { isDue(deliverOn: $0.deliverOn, today: today) }
        if hasDelivered {
            return .answered(waiting: latest, messages: chain)
        }
        return .waiting(latest)
    }
}

// MARK: - 原篇状态联动（可见性，fail-closed）

enum PastSelfContentVisibility: Equatable {
    /// 作者看全文（原篇公开，或作者本人看自己的私密原篇）。
    case full
    /// 作者视角：原篇已翻回私密，串仍可见但带「仅你可见」提示。
    case privateNote
    /// 原篇已删（语料到齐仍找不到原篇）：全串只留「原篇已删除」占位，
    /// 正文与留话一律不渲染；存储行保留，回收站恢复后自动重现。
    case deleted
    /// 非作者视角占位：对话只推本人，他人永远看不到内容（即使原篇公开）。
    case authorOnly
}

enum PastSelfVisibility {
    /// 语料未到齐时返回 nil：调用方不渲染、不猜（半截语料的「已删」是假结论）。
    /// - origin: 语料中的原篇；nil = 到齐后仍无此篇。
    /// - viewerIsAuthor: 是否为作者本人。
    static func viewerVisibility(origin: Entry?, viewerIsAuthor: Bool, corpusComplete: Bool) -> PastSelfContentVisibility? {
        guard corpusComplete else { return nil }
        guard let origin = origin else { return .deleted }
        guard viewerIsAuthor else { return .authorOnly }
        if origin.placeholder == true { return .privateNote }
        if origin.isPublic == true { return .full }
        return .privateNote
    }
}

// MARK: - 本地存储（按用户 id 隔离，防串号）

final class PastSelfStore {
    private let defaults: UserDefaults
    private let userId: Int
    /// 单用户留话上限（防无界增长；超限时先丢最旧的已撤回行，再丢最旧的已送达行）。
    static let maxStoredMessages = 200

    init(userId: Int, defaults: UserDefaults = .standard) {
        self.userId = userId
        self.defaults = defaults
    }

    private var storageKey: String { "beary.pastSelf.v1.\(userId)" }

    func loadAll() -> [PastSelfMessage] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([PastSelfMessage].self, from: data) else { return [] }
        return decoded
    }

    private func save(_ messages: [PastSelfMessage]) {
        var capped = messages
        if capped.count > Self.maxStoredMessages {
            let overflow = capped.count - Self.maxStoredMessages
            let revoked = capped.indices.filter { capped[$0].revokedAtMs != nil }.sorted {
                capped[$0].createdAtMs < capped[$1].createdAtMs
            }
            var drop = Set<Int>()
            for index in revoked.prefix(overflow) { drop.insert(index) }
            if drop.count < overflow {
                let delivered = capped.indices.filter { !drop.contains($0) }.sorted {
                    capped[$0].createdAtMs < capped[$1].createdAtMs
                }
                for index in delivered.prefix(overflow - drop.count) { drop.insert(index) }
            }
            capped = capped.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
        }
        guard let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// 新增留话。nil = 拒绝：正文空 / 超 500 字 / 原篇 id 空 / 该链已有等待中的留话
    /// （一链同一时间只留一句，防同一天堆出两条同日送达）。
    func add(originEntryId: String, body: String, createdAtMs: Int, calendar: Calendar) -> PastSelfMessage? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originEntryId.isEmpty, !text.isEmpty, text.count <= PastSelfLogic.maxBodyLength else { return nil }
        guard let deliverOn = PastSelfLogic.nextYearDateString(fromMs: createdAtMs, calendar: calendar) else { return nil }
        var all = loadAll()
        let today = PastSelfLogic.localDateString(fromMs: createdAtMs, calendar: calendar)
        if PastSelfLogic.waitingMessage(all, chainId: originEntryId, today: today) != nil { return nil }
        let previous = PastSelfLogic.liveChainMessages(all, chainId: originEntryId).last
        let message = PastSelfMessage(
            id: "ps_" + UUID().uuidString.lowercased(),
            originEntryId: originEntryId,
            chainId: originEntryId,
            authorId: userId,
            body: text,
            createdAtMs: createdAtMs,
            deliverOn: deliverOn,
            revokedAtMs: nil,
            replyToMessageId: previous?.id,
            localOnly: true
        )
        all.append(message)
        save(all)
        return message
    }

    /// 撤回：仅限该链最新一条、且未到送达日的留话（送达后已成链，不撤回旧年；
    /// 要改写只能「再回一句」往后接）。成功返回 true。
    func revoke(messageId: String, nowMs: Int, today: String) -> Bool {
        var all = loadAll()
        guard let index = all.firstIndex(where: { $0.id == messageId && $0.revokedAtMs == nil }) else { return false }
        let message = all[index]
        guard PastSelfLogic.liveChainMessages(all, chainId: message.chainId).last?.id == messageId else { return false }
        guard !PastSelfLogic.isDue(deliverOn: message.deliverOn, today: today) else { return false }
        all[index].revokedAtMs = nowMs
        save(all)
        return true
    }

    /// 服务端同步合并：服务端行覆盖同 id 本地行，但本地已撤回的标记不被
    /// 服务端旧态冲掉（撤回先落本地、后台再补推，见 ProfileVC 同步）。
    /// 本地未同步行（localOnly）原样保留。
    func mergeServerRows(_ server: [PastSelfMessage]) {
        var all = loadAll()
        var byId: [String: PastSelfMessage] = [:]
        for row in all { byId[row.id] = row }
        for var row in server {
            row.localOnly = false
            if let local = byId[row.id], local.revokedAtMs != nil, row.revokedAtMs == nil {
                row.revokedAtMs = local.revokedAtMs
            }
            byId[row.id] = row
        }
        // 服务端已删的行不在回包里时不主动清本地（服务端未承诺全量下发），
        // 只做并集覆盖，避免一次分页缺失误删整串。
        save(Array(byId.values))
    }

    /// 用服务端行替换一条本地行（创建成功后去 localOnly 化）。
    func replaceLocalRow(localId: String, with serverRow: PastSelfMessage) {
        var all = loadAll()
        guard let index = all.firstIndex(where: { $0.id == localId }) else { return }
        var row = serverRow
        row.localOnly = false
        // 本地已撤回过的行不被创建回包复活。
        if all[index].revokedAtMs != nil { row.revokedAtMs = all[index].revokedAtMs }
        all[index] = row
        save(all)
    }

    func removeLocalRow(id: String) {
        save(loadAll().filter { $0.id != id })
    }
}

// MARK: - 图标占位视图（只引用 imageset 名，不自绘、不用 SF Symbol）
//
// 待注册资产（Li 补官方包后零改动自动生效）：
// - 对话入口：imageset 名 "icon_past_present"
// - 并排推送屏：imageset 名 "icon_compare"
// 资产未到时：显示带 imageset 名的占位标注（虚线框 + 名称），不画替代图标，
// 不用 SF Symbol 顶位；文字按钮本身始终可用，图标缺失不阻塞功能。

final class PastSelfIconView: UIView {
    init(imagesetName: String, pointSize: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let base = UIImage(named: imagesetName) {
            let size = CGSize(width: pointSize, height: pointSize)
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let drawn = renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: size)) }
            let imageView = UIImageView(image: drawn.withRenderingMode(.alwaysTemplate))
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(equalToConstant: pointSize),
                heightAnchor.constraint(equalToConstant: pointSize),
            ])
            accessibilityLabel = imagesetName
        } else {
            // 占位标注：资产未注册前明确标出缺失项，不伪装成正式图标。
            layer.borderWidth = 1
            layer.cornerRadius = 10
            layer.bearyDynamicBorderColor = BearyColors.line
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.systemFont(ofSize: 9)
            label.textColor = BearyColors.gray
            label.text = imagesetName + " 待注册"
            label.textAlignment = .center
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                heightAnchor.constraint(equalToConstant: 20),
            ])
            accessibilityLabel = imagesetName + " 图标待官方注册"
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

// MARK: - 留话输入框（自带占位文案，不依赖调用方实现 delegate）

final class PastSelfComposeView: UIView, UITextViewDelegate {
    let textView = UITextView()
    private let placeholderLabel = UILabel()
    var onTextChange: ((String) -> Void)?

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            placeholderLabel.isHidden = !newValue.isEmpty
        }
    }

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = BearyColors.ink
        textView.backgroundColor = BearyColors.faint
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 1
        textView.layer.bearyDynamicBorderColor = BearyColors.line
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.delegate = self
        textView.isScrollEnabled = false
        addSubview(textView)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = UIFont.systemFont(ofSize: 15)
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.text = placeholder
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        onTextChange?(textView.text ?? "")
    }
}

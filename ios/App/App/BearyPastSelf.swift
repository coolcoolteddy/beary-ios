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
// - 存储取舍（审计登录杂项，2026-11-02）：留话全文现以 JSON 明文存 UserDefaults
//   （beary.pastSelf.v1.<userId>），未迁 Keychain / 未加密，原因：Keychain 迁移
//   须同时改写存量 200 条行的编解码、mergeServerRows 与 replaceLocalRow 的
//   双向同步、以及钥匙串单条容量与同步失败回落，风险面大于单次审计小修；
//   App 沙盒本身已隔离（他 App 读不到本沙盒文件），且留话仅作者本人可见、
//   服务端同步后以服务端为准。若后续要做，应走“新行写 Keychain、存量行惰性
//   迁移”的独立方案，不在本支顺手改。

// MARK: - 对话记录模型（后端字段口径，见 PR 描述）

/// 一条留话。服务端字段与此一一对应（snake_case；created_at 为毫秒）：
/// id / origin_entry_id（原篇 id）/ chain_id（恒等于原篇 id）/
/// author_id / body（留话内容）/ created_at（留话时间，毫秒）/
/// deliver_on（目标推送日期，本地日 YYYY-MM-DD）/
/// revoked_at（撤回时间，毫秒；nil = 未撤回）/
/// reply_to_message_id（接续的上条留话 id；首条为 nil）/
/// client_req（#37 完整修复：创建时生成的稳定客户端请求 ID，服务端
/// 按（作者，client_req）幂等重放已存在的那行，列表回包也带回它）。
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
    /// 稳定客户端请求 ID（UUID）：创建本地行时生成，随行持久化保存；
    /// 创建与重试都带同一个，App 重启后仍是它，否则幂等不成立。
    /// 服务端存进 beary_dialogues.client_req 并在回包里带回；本支
    /// 之前创建的老行没有该字段，解码为 nil，同步时由
    /// ensureClientRequestId 现生成一个并落盘（之后不再变）。
    var clientRequestId: String? = nil
    /// 仅本地：true = 尚未同步到服务端（后端 404 / 断网时先落本地）。
    /// 服务端不下发该字段，缺失时按 false 计。
    var localOnly: Bool = false
    /// 仅本地：撤回已获服务端确认（撤回回包成功，或服务端下发已带 revoked_at）。
    /// 确认后同步循环不再重发该行的撤回请求；服务端不下发该字段，缺失时按 false 计。
    var revokeSynced: Bool = false

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
        case clientRequestId = "client_req"
        case localOnly = "local_only"
        case revokeSynced = "revoke_synced"
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
        clientRequestId = try container.decodeIfPresent(String.self, forKey: .clientRequestId)
        localOnly = try container.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        revokeSynced = try container.decodeIfPresent(Bool.self, forKey: .revokeSynced) ?? false
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
    /// 单用户留话上限（防无界增长）。
    /// 审计登录杂项丢弃顺序：已撤回 → 已送达旧串 → 绝不丢等待中与各链最新
    /// 已送达行（等待中的留话是未来的送达，丢了即静默丢未来留话；最新已送
    /// 达行是待回复的锚点，裁掉即丢“去年的对话”展示）；未同步行（localOnly）
    /// 同样绝不丢——服务端从未见过它，裁掉即永久丢失；若只剩不可丢行仍
    /// 超限，save 不再硬砍（宁可暂时超 cap），新增由 add 的超限拒绝挡下。
    /// 同步合并时跳过裁剪（见 mergeServerRows）：刚从服务端拉回的行不立刻
    /// 再裁，恢复才持久；上限只在本地新增时执行。
    static let maxStoredMessages = 200

    /// 新增留话被拒的原因（调用方据此给行内提示，见 ProfileVC 两处提交）。
    enum AddRejection {
        /// 该链已有等待中的留话（一链同一时间只留一句）。
        case alreadyWaiting
        /// 存储已满且只剩等待中行（无已撤回 / 已送达行可丢）。
        case waitingCapped
        /// 审计新一轮 05：本地存储读取失败（原始数据还在、解码不出）——
        /// 拒绝新留话，不覆盖旧存储（见 loadOutcome 与 isStoreCorrupt）。
        case storeCorrupt
    }

    /// 最近一次 add 返回 nil 的原因（成功时为 nil）。
    private(set) var lastRejection: AddRejection?

    init(userId: Int, defaults: UserDefaults = .standard) {
        self.userId = userId
        self.defaults = defaults
    }

    private var storageKey: String { "beary.pastSelf.v1.\(userId)" }

    /// 审计新一轮 05：上一份好数据的备份 key。UserDefaults 里没有文件，
    /// 备份不用文件 .bak，另用独立 key 存上一次成功写入前的原始数据
    /// （只存能解码的；损坏的原始数据不进备份，它原样留在主 key 里）。
    private var backupKey: String { "beary.pastSelf.v1.\(userId).bak" }

    /// 审计新一轮 05：读取结果——“确实没有记录”和“原始记录读取失败”
    /// 必须分开，此前两条路径都回 []，调用方分不出来。
    enum LoadOutcome {
        /// 主 key 无数据：确实没有记录。
        case empty
        /// 解码成功。
        case loaded([PastSelfMessage])
        /// 主 key 有数据但解码失败：原始数据还在，只读不出来。
        case corrupt
    }

    /// 读盘并区分空与损坏（写路径一律走它，不走 loadAll）。
    func loadOutcome() -> LoadOutcome {
        guard let data = defaults.data(forKey: storageKey) else { return .empty }
        guard let decoded = try? JSONDecoder().decode([PastSelfMessage].self, from: data) else { return .corrupt }
        return .loaded(decoded)
    }

    /// 本地存储是否读取失败。true 时所有写路径都拒绝覆盖：原始数据保留
    /// 在主 key，上一份好数据在备份 key，可 restoreFromBackup 恢复。
    var isStoreCorrupt: Bool {
        if case .corrupt = loadOutcome() { return true }
        return false
    }

    /// 用备份 key 的上一份好数据覆盖回主 key（损坏态的恢复入口）。
    /// 备份不存在或同样解码失败时返回 false，主 key 原样不动。
    @discardableResult
    func restoreFromBackup() -> Bool {
        guard let data = defaults.data(forKey: backupKey),
              (try? JSONDecoder().decode([PastSelfMessage].self, from: data)) != nil else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    /// 展示用读盘：损坏时回 []（只读不写，不动原始数据）。
    /// 写路径禁止用它判断，必须走 loadOutcome。
    func loadAll() -> [PastSelfMessage] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([PastSelfMessage].self, from: data) else { return [] }
        return decoded
    }

    /// 未同步行数（localOnly）：创建尚未获服务端确认的行；含已撤回未同步行
    /// （撤回本身也未同步——同步扫描先补推创建、回包一到再补推撤回）。
    /// 数据状态页「留话」分项用。
    var unsyncedCount: Int {
        loadAll().filter { $0.localOnly }.count
    }

    /// 存储已满且无可丢行时为 true，新增应拒绝并行内提示。可丢行 = 已撤回行，
    /// 或已被取代的已送达旧串（不含未同步行）；只剩等待中行与各链最新已送达行（待回复锚点）
    /// 时无行可丢——与 save() 的淘汰口径一致。
    var isWaitingCapped: Bool {
        let all = loadAll()
        guard all.count >= Self.maxStoredMessages else { return false }
        let today = PastSelfLogic.localDateString(from: Date(), calendar: .current)
        guard !all.contains(where: { $0.revokedAtMs != nil }) else { return false }
        return Self.droppableDeliveredIndices(all, today: today).isEmpty
    }

    /// 各链最新一条已送达行之外的已送达行下标（按 createdAt 升序；即“已被
    /// 后行取代的旧串”，淘汰时可丢）。最新一条已送达行是待回复的锚点——
    /// 送达卡按它渲染“去年的对话”，裁掉即丢展示，故永不参与淘汰。
    /// 未同步行（localOnly）同样永不参与淘汰：一条已送达但从未同步过的
    /// 本地留话，服务端从未见过它，裁掉即永久丢失、无法恢复（同步成功后
    /// replaceLocalRow 去 localOnly 化，才可丢）。
    private static func droppableDeliveredIndices(_ messages: [PastSelfMessage], today: String) -> [Int] {
        let delivered = messages.indices.filter {
            messages[$0].revokedAtMs == nil && !messages[$0].localOnly && PastSelfLogic.isDue(deliverOn: messages[$0].deliverOn, today: today)
        }
        var latestByChain: [String: Int] = [:]
        for index in delivered {
            let chainId = messages[index].chainId
            if let current = latestByChain[chainId],
               (messages[index].createdAtMs, messages[index].id) <= (messages[current].createdAtMs, messages[current].id) {
                continue
            }
            latestByChain[chainId] = index
        }
        let protected = Set(latestByChain.values)
        return delivered.filter { !protected.contains($0) }.sorted {
            messages[$0].createdAtMs < messages[$1].createdAtMs
        }
    }

    /// 最近一次 save 裁掉的行数（0 = 没裁）。调用方用 takeTrimmedCount
    /// 读一次即清零，裁剪发生时给一次提示用；裁剪不再全程静默。
    private(set) var lastTrimmedCount = 0

    /// 读走并清零最近一次的裁剪计数（只给一次提示用，见上）。
    func takeTrimmedCount() -> Int {
        let count = lastTrimmedCount
        lastTrimmedCount = 0
        return count
    }

    private func save(_ messages: [PastSelfMessage], skipTrim: Bool = false) {
        var capped = messages
        if !skipTrim, capped.count > Self.maxStoredMessages {
            let today = PastSelfLogic.localDateString(from: Date(), calendar: .current)
            let overflow = capped.count - Self.maxStoredMessages
            // 先丢最旧的已撤回且撤回已同步行，再丢最旧的、已被取代的已送达旧串
            //（不含 localOnly 行：未同步的已送达行裁掉即永久丢失）；
            // 未同步的撤回行（revokeSynced == false）绝不丢——丢了补推循环就
            // 再无记录可发，服务端旧留话下次拉取即重新出现；等待中行与各链
            // 最新已送达行（待回复锚点）同样绝不丢——若可丢行不够填 overflow，
            // 剩余超限部分原样保留（不砍受保护行）。
            let revoked = capped.indices.filter { capped[$0].revokedAtMs != nil && capped[$0].revokeSynced }.sorted {
                capped[$0].createdAtMs < capped[$1].createdAtMs
            }
            var drop = Set<Int>()
            for index in revoked.prefix(overflow) { drop.insert(index) }
            if drop.count < overflow {
                let droppable = Self.droppableDeliveredIndices(capped, today: today).filter { !drop.contains($0) }
                for index in droppable.prefix(overflow - drop.count) { drop.insert(index) }
            }
            capped = capped.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
            lastTrimmedCount = drop.count
        } else {
            lastTrimmedCount = 0
        }
        guard let data = try? JSONEncoder().encode(capped) else { return }
        // 审计新一轮 05：覆盖主 key 之前，先把当前能解码的原始数据存进
        // 独立备份 key（上一份好数据）；损坏的原始数据不进备份，它原样
        // 留在主 key 里——save 只在写路径确认存储未损坏后才被调用。
        if let old = defaults.data(forKey: storageKey),
           (try? JSONDecoder().decode([PastSelfMessage].self, from: old)) != nil {
            defaults.set(old, forKey: backupKey)
        }
        defaults.set(data, forKey: storageKey)
    }

    /// 新增留话。nil = 拒绝：正文空 / 超 500 字 / 原篇 id 空 / 该链已有等待中的留话
    /// （一链同一时间只留一句，防同一天堆出两条同日送达）。
    func add(originEntryId: String, body: String, createdAtMs: Int, calendar: Calendar) -> PastSelfMessage? {
        lastRejection = nil
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originEntryId.isEmpty, !text.isEmpty, text.count <= PastSelfLogic.maxBodyLength else { return nil }
        guard let deliverOn = PastSelfLogic.nextYearDateString(fromMs: createdAtMs, calendar: calendar) else { return nil }
        // 审计新一轮 05：存储读取失败时拒绝新留话（lastRejection = .storeCorrupt，
        // 调用方行内提示），绝不拿空数组覆盖整库。
        var all: [PastSelfMessage]
        switch loadOutcome() {
        case .corrupt:
            lastRejection = .storeCorrupt
            return nil
        case .empty:
            all = []
        case .loaded(let rows):
            all = rows
        }
        let today = PastSelfLogic.localDateString(fromMs: createdAtMs, calendar: calendar)
        if PastSelfLogic.waitingMessage(all, chainId: originEntryId, today: today) != nil {
            lastRejection = .alreadyWaiting
            return nil
        }
        // 审计登录杂项：等待中超限时拒绝新留话（行内提示由调用方按 lastRejection 给）。
        if isWaitingCapped {
            lastRejection = .waitingCapped
            return nil
        }
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
            // #37 完整修复：创建本地行时生成稳定客户端请求 ID，随行持久化；
            // 创建与之后所有重试都带同一个，服务端按它幂等重放。
            clientRequestId: UUID().uuidString,
            localOnly: true
        )
        all.append(message)
        save(all)
        return message
    }

    /// 撤回：仅限该链最新一条、且未到送达日的留话（送达后已成链，不撤回旧年；
    /// 要改写只能「再回一句」往后接）。成功返回 true。
    func revoke(messageId: String, nowMs: Int, today: String) -> Bool {
        // 审计新一轮 05：存储读取失败时无法核验 id 与作者，直接拒绝，
        // 不拿空数组覆盖（找不到 id 提前返回的安全口径保留）。
        guard case .loaded(var all) = loadOutcome() else { return false }
        // 审计登录杂项：补 authorId == userId 校验（防御性缺口：越界混入的行不得撤回他人留话）。
        guard let index = all.firstIndex(where: { $0.id == messageId && $0.authorId == userId && $0.revokedAtMs == nil }) else { return false }
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
        // 审计新一轮 05：本地存储损坏时不合并——服务端并集覆盖会抹掉
        // 损坏的本地库（含未同步行）；跳过本次同步，下次再试。
        // 回炉：空库（.empty）不是损坏，按 [] 处理继续合并——新设备
        // 首次同步要能从服务端拉回留话；只拦 .corrupt。
        var all: [PastSelfMessage]
        switch loadOutcome() {
        case .corrupt:
            return
        case .empty:
            all = []
        case .loaded(let rows):
            all = rows
        }
        var byId: [String: PastSelfMessage] = [:]
        for row in all { byId[row.id] = row }
        // #37 完整修复：先按客户端请求 ID 认领服务端 id，再走主循环的 id 合并。
        // 创建回包丢了时本地 ps_… 行仍 localOnly；服务端行带回的 client_req
        // 与本地行创建时生成的 ID 一致即为同一条：把本地行的 id 换成服务端
        // id、清 localOnly，之后主循环按 id 的撤回保留逻辑把本地撤回标记
        // 带进服务端行，不丢撤回。认领在三元组兜底（#1923）之前：请求 ID
        // 是创建时唯一确定的键，三元组（同原篇同正文同送达日）只在请求 ID
        // 对不上时才用——#1923 的三元组块按 byId[row.id] == nil 判断，
        // 认领过的行不会再被三元组认。放主循环之前、与 #1923 的插入点
        // （循环内 revokeSynced 行之后）不重叠，两支合入顺序不影响变基。
        // 同 id 的行（服务端行就是本地行的新态）不走这里，主循环的精确
        // id 逻辑已处理；服务端 id 已在库里时本地行是重复残留，直接去掉。
        for serverRow in server where serverRow.authorId == userId {
            guard let reqId = serverRow.clientRequestId, !reqId.isEmpty else { continue }
            guard let dup = byId.values.first(where: { $0.localOnly && $0.clientRequestId == reqId && $0.id != serverRow.id }) else { continue }
            if byId[serverRow.id] == nil {
                byId.removeValue(forKey: dup.id)
                var adopted = dup
                adopted.id = serverRow.id
                adopted.localOnly = false
                byId[serverRow.id] = adopted
            } else {
                // 防御：服务端 id 已在库里，本地行是重复残留，直接去掉；
                // 本地有而库里没有的撤回标记补进库里那行，同步循环会补推撤回。
                byId.removeValue(forKey: dup.id)
                if var existing = byId[serverRow.id], existing.revokedAtMs == nil, let revoked = dup.revokedAtMs {
                    existing.revokedAtMs = revoked
                    byId[serverRow.id] = existing
                }
            }
        }
        // 审计登录杂项：过滤他人行（服务端混入的非本人 authorId 行不进本用户存储）。
        for var row in server where row.authorId == userId {
            row.localOnly = false
            // 服务端下发已带 revoked_at = 撤回已确认；本地此前已确认的同样保留。
            // 注意：本地撤回标记被保留进来的行不算确认——服务端尚未见过该撤回。
            let serverConfirmedRevoke = row.revokedAtMs != nil
            if let local = byId[row.id], local.revokedAtMs != nil, row.revokedAtMs == nil {
                row.revokedAtMs = local.revokedAtMs
            }
            row.revokeSynced = serverConfirmedRevoke || (byId[row.id]?.revokeSynced ?? false)
            // #37 回包丢失兜底：创建回包丢了时，本地 ps_… 行仍 localOnly，
            // 下次同步会把服务端行与本地行并存、再重推创建造重复。
            // 本地行从未成功回包、且 origin_entry_id + body + deliver_on
            // 与服务端行全等时视为同一条：本地行认领服务端 id、清
            // localOnly，不再重推。取舍：同一原篇同一正文同一送达日的
            // 两条真实留话会被合并为一条；完整修复（创建请求加稳定
            // 客户端请求 ID、列表回传它）须服务端改动，见 PR 描述。
            if byId[row.id] == nil {
                let dups = byId.values.filter {
                    $0.localOnly && $0.originEntryId == row.originEntryId
                        && $0.body == row.body && $0.deliverOn == row.deliverOn
                }
                if !dups.isEmpty {
                    if row.revokedAtMs == nil {
                        row.revokedAtMs = dups.compactMap { $0.revokedAtMs }.first
                    }
                    if dups.contains(where: { $0.revokeSynced }) {
                        row.revokeSynced = true
                    }
                    for dup in dups { byId.removeValue(forKey: dup.id) }
                }
            }
            byId[row.id] = row
        }
        // 服务端已删的行不在回包里时不主动清本地（服务端未承诺全量下发），
        // 只做并集覆盖，避免一次分页缺失误删整串。
        // 合并路径跳过裁剪：服务端是全量事实来源，刚拉回的最旧可丢行若
        // 立刻再裁，恢复不持久（下次同步又拉回、又裁掉）；上限只在本地
        // 新增时执行（add 的 save），超 cap 态暂留，等下次新增再裁。
        save(Array(byId.values), skipTrim: true)
    }

    /// 用服务端行替换一条本地行（创建成功后去 localOnly 化）。
    /// 第 13 轮审计 2：列表回包先到时 mergeServerRows 已插过同服务端 id 的行，
    /// 替换须按服务端 id 去重——只留替换后的这一行，否则同 id 存两份。
    func replaceLocalRow(localId: String, with serverRow: PastSelfMessage) {
        // 审计新一轮 05：存储读取失败时找不到 id，直接返回（原安全口径保留）。
        guard case .loaded(var all) = loadOutcome() else { return }
        guard let index = all.firstIndex(where: { $0.id == localId }) else { return }
        let local = all[index]
        var row = serverRow
        row.localOnly = false
        // 本地已撤回过的行不被创建回包复活。
        if local.revokedAtMs != nil { row.revokedAtMs = local.revokedAtMs }
        // 同 id 副本的撤回态并入替换行：副本若已带服务端确认的撤回（服务端行
        // 自带 revoked_at、或副本 revokeSynced），替换后不再重发；否则
        // revokeSynced 不继承——新服务端 id 的撤回尚未推送，须由同步循环补推。
        var duplicateRevokedAtMs: Int?
        var duplicateConfirmed = false
        for other in all where other.id == serverRow.id && other.id != localId {
            if other.revokedAtMs != nil { duplicateRevokedAtMs = other.revokedAtMs }
            if other.revokeSynced { duplicateConfirmed = true }
        }
        if row.revokedAtMs == nil { row.revokedAtMs = duplicateRevokedAtMs }
        if serverRow.id != localId {
            row.revokeSynced = serverRow.revokedAtMs != nil || duplicateConfirmed
        }
        // 去重：删掉其他同服务端 id 的行，再在本地行原位置写入替换行（顺序不变）。
        all.removeAll { $0.id == serverRow.id && $0.id != localId }
        guard let target = all.firstIndex(where: { $0.id == localId }) else { return }
        all[target] = row
        save(all)
    }

    /// #37 完整修复：取本地行的稳定客户端请求 ID（创建时生成、随行持久化）。
    /// 本支之前创建的老行没有该字段时，现生成一个并落盘保存，之后所有
    /// 重试都复用它；App 重启后仍是同一个 ID，否则幂等不成立。
    /// 存储损坏或行不存在时返回 nil，调用方按无 client_req 的旧口径发。
    func ensureClientRequestId(forLocalId localId: String) -> String? {
        guard case .loaded(var all) = loadOutcome() else { return nil }
        guard let index = all.firstIndex(where: { $0.id == localId }) else { return nil }
        if let existing = all[index].clientRequestId, !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        all[index].clientRequestId = fresh
        save(all)
        return fresh
    }

    /// 撤回回包成功：记该行撤回已确认，同步循环不再重发。
    func markRevokeSynced(id: String) {
        var all = loadAll()
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].revokeSynced else { return }
        all[index].revokeSynced = true
        save(all)
    }

    func removeLocalRow(id: String) {
        // 审计新一轮 05：存储读取失败时不动——损坏时 loadAll 是 []，
        // 直接存 [] 等于删一条清整库。
        guard case .loaded(let all) = loadOutcome() else { return }
        save(all.filter { $0.id != id })
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
            // 审计登录杂项：模板图 tint 显式定死为 ink，不再依赖父视图 tint 链
            //（此前未显式设 tint，实际颜色随父视图 tint 走，未证实即为隐患）。
            imageView.tintColor = BearyColors.ink
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
            layer.cornerRadius = BearyCorners.single
            layer.bearyDynamicBorderColor = BearyColors.line
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.systemFont(ofSize: 10)
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
    private let placeholderLabel: UILabel
    var onTextChange: ((String) -> Void)?

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            placeholderLabel.isHidden = !newValue.isEmpty
        }
    }

    init(placeholder: String) {
        placeholderLabel = BearyPlaceholderLabel.make(text: placeholder, numberOfLines: 0, isUserInteractionEnabled: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = BearyColors.ink
        textView.backgroundColor = BearyColors.surface2
        textView.layer.cornerRadius = 12
        textView.layer.borderWidth = 0
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.delegate = self
        textView.isScrollEnabled = false
        // 审计登录杂项：输入框补最大高度 240（触顶后滚动，见 updateScrollState），
        // 不再随 500 字无限撑高、把调用方容器顶穿。
        addSubview(textView)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            textView.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
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
        updateScrollState()
        onTextChange?(textView.text ?? "")
    }

    /// 触顶滚动：内容超过 240 上限时开滚动（此前 isScrollEnabled 恒 false，
    /// 超高时高度只取决于调用方容器是否兜底）；回落到上限内时关滚动。
    private func updateScrollState() {
        let shouldScroll = textView.contentSize.height > 240
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
        }
    }
}

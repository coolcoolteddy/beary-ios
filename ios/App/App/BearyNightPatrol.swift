import UIKit

// ===== 小熊夜巡（仅 Plus 会员；App 端模板版 + AI 节点占位）=====
// 位置：个人主页小熊回应墙顶部（不是新 tab、不是首页 banner），见
// BearyProfileViewController 的 nightContainer（回应墙上方、统计行下方）。
// 预览对照：~/workspace/new-features-preview/beary-preview-05-night-patrol-06-blindbox.html
// （功能 ⑤；盲盒 ⑥ 不在本批）。
//
// 门控（App 端 + 服务端双层，缺一层即不可信）：
// - App 端：只在本人主页（isOwnProfile）且服务端回包有夜巡记录时显示；
//   非会员无记录时整个入口隐藏（不放 Plus 推销卡）；他人主页一律不显示；
//   未登录时 isOwnProfile 为 false，入口天然隐藏。
// - 服务端（待后端实现，见下方“后端字段”）：接口必须只返回调用者本人的记录，
//   私密日记的夜巡只对本人可见；App 端再做一道防御过滤——凡 isPrivate 为真
//   却不是本人主页的记录一律丢弃、不计数、不渲染（见 sanitized()）。
// - 夜巡计数与普通小熊回应严格分开：脚印数绝不计入 emotesTotal /
//   回应墙“共收到 N 只”，也不走回应聚合接口。
//
// 计费口径（后端作业，App 端不调 AI）：
// - 模板脚印版为主、每晚都有、零 token：只按心情 / 天气 / 字数等元数据匹配
//   手写语料（见 BearyNightPatrolTemplate），绝不读正文、绝不把正文发给 AI。
// - AI 短评只留给“当天写了日记的会员”这一节点：每会员每夜至多 1 次，
//   走已有 DeepSeek-V3 省 token 口径；不要全量会员每晚随机读旧篇。
//   App 端只渲染服务端下发的 source（template / ai），不自己发起 AI 调用。
//
// 失败与占位：
// - 后端接口未上线（404）/ 401 / 网络失败 / 解码失败时入口静默隐藏，
//   不编造脚印、不留“0 枚脚印”空行（与回应墙“空墙隐藏”同哲学）。
// - 模板短评缺文案时才用本地模板匹配补文案（见 displayNote）；App 端
//   永远不凭空合成一条脚印记录——没有服务端记录就没有入口。
//
// 图标（只引用 imageset 名，不自绘、不拿 SF Symbol 做主图标）：
// - 入口：icon_paw_trail（新图标，待 Li 补）；未到货时回退 icon_paw。
// - AI 短评角标：icon_ai_paw（新图标，待 Li 补），套在脚印按钮右上角；
//   未到货时回退为 9pt 橙色“AI”文字角标（文字不是图标，不冒充官方资产）。
// - 停跑态：icon_night_paused（新图标，待 Li 补）；未到货时回退 icon_moon。
// - 其余一律官方包已有：icon_moon、icon_paw、icon_chevron_right、
//   crown（Plus 标识，在名字旁既有）、icon_lock、icon_eye_off（本批未用上，
//   私密态以文案“仅你可见”标示，不另加图标）。
// - 三个新 imageset 只有 Contents.json 占位（无 PNG），到货后按既有
//   icon_* 三档（72 / 144 / 216）补图即可，代码无需改动。
//
// 未定口径（需 Li / 后端定，不擅自定，见 PR 回报）：
// 1. 脚印保留时长、入口是否只显示最近一夜：本批入口只渲染 nights[0]
//    （最近一夜），旧夜数据模型已保留、暂不设历史浏览入口。
// 2. 到期停跑时序：plus 到期日当天是否含当夜、plus_until 是否含到期日、
//    作业时区（默认按 Asia/Shanghai 理解，待后端确认）；App 端以服务端
//    patrol_paused 为准，缺失时才以 profile.plus 为 false 回退为停跑态。
// 3. AI 短评失败（DeepSeek 异常 / 超时）时当夜是否回退模板短评：
//    App 端按回包渲染，AI 记录缺文案时显示“暂不可用”文案，不替补模板。

// MARK: - 后端字段（服务端待实现；App 端按此解码，字段全 optional）
//
// GET /beary/api/night-patrol（登录态必需；只返回调用者本人记录）
// {
//   "nights": [
//     {
//       "night_date": "2026-10-29",            // 夜巡之夜的日期（作业日，非打开日）
//       "footprints": [
//         {
//           "entry_id": "123" | 123 | null,     // 该夜巡到的日记；无日记之夜为 null
//           "source": "template" | "ai",        // 短评来源；未知值一律按 template 计
//           "note": "…",                        // 短评正文；模板缺文案时 App 端补匹配
//           "is_private": true | false,         // 私密日记夜巡：只给本人看
//           "mood": "happy" | null,            // 模板匹配用元数据（非正文）
//           "weather": "rain" | null,           // 模板匹配用元数据（非正文）
//           "word_count": 120 | null,           // 模板匹配用元数据（字数，非正文）
//           "patrolled_at": 1761772800000 | null // 脚印时间（毫秒时间戳）
//         }
//       ]
//     }
//   ],
//   "patrol_paused": false                    // true = 已停跑（Plus 到期后）
// }
// 服务端校验清单：① 会话校验（未登录 401）；② 只查调用者本人 user_id，
// ③ 私密记录不对他人返回（他人调接口不得透传 is_private 记录）；
// ④ 夜间作业跑批前校验 Plus 有效期（到期次日凌晨起停跑，已留记录保留）；
// ⑤ 模板生成只读 mood / weather / 字数，不读正文；⑥ AI 节点只对当天
// 写了日记的会员触发，DeepSeek-V3，每会员每夜至多 1 次。

// MARK: - 模型

/// 单枚脚印（一条夜巡短评）。entryId 兼容服务端下发 String / Int 两种写法。
struct NightPatrolFootprint: Decodable {
    var entryId: String?
    var source: String?
    var note: String?
    var isPrivate: Bool?
    var mood: String?
    var weather: String?
    var wordCount: Int?
    var patrolledAt: Int?

    var isAI: Bool { source == "ai" }
    var hasDiary: Bool {
        guard let entryIdValue = entryId, !entryIdValue.isEmpty else { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case entryId
        case source
        case note
        case isPrivate
        case mood
        case weather
        case wordCount
        case patrolledAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .entryId) {
            entryId = text
        } else if let number = try? container.decode(Int.self, forKey: .entryId) {
            entryId = String(number)
        } else {
            entryId = nil
        }
        source = try? container.decode(String.self, forKey: .source)
        note = try? container.decode(String.self, forKey: .note)
        isPrivate = try? container.decode(Bool.self, forKey: .isPrivate)
        mood = try? container.decode(String.self, forKey: .mood)
        weather = try? container.decode(String.self, forKey: .weather)
        wordCount = try? container.decode(Int.self, forKey: .wordCount)
        patrolledAt = try? container.decode(Int.self, forKey: .patrolledAt)
    }
}

/// 一夜的夜巡（可能多枚脚印；无日记之夜 footprints 仍可有模板脚印）。
struct NightPatrolNight: Decodable {
    var nightDate: String?
    var footprints: [NightPatrolFootprint]?
}

/// 夜巡回包：nights 按夜倒序（最近一夜在前）；App 端只渲染 nights[0]。
struct NightPatrolResponse: Decodable {
    var nights: [NightPatrolNight]?
    var patrolPaused: Bool?

    /// 防御过滤：非本人视角下私密记录一律丢弃（服务端漏防时的第二道门）。
    /// 调用方必须传 isOwnProfile；本人视角原样返回。
    func sanitized(isOwnProfile: Bool) -> [NightPatrolNight] {
        let all = nights ?? []
        guard !isOwnProfile else { return all }
        return all.map { night in
            var copy = night
            copy.footprints = (night.footprints ?? []).filter { $0.isPrivate != true }
            return copy
        }.filter { ($0.footprints ?? []).isEmpty == false }
    }
}

// MARK: - 接口（只用 BearyAPI 既有 request 风格，不自创网络层）

extension BearyAPI {
    /// GET /beary/api/night-patrol（仅登录本人；后端未上线前 404 → 调用方隐藏入口）。
    func fetchNightPatrol(completion: @escaping (Result<NightPatrolResponse, APIError>) -> Void) {
        request("/beary/api/night-patrol", completion: completion)
    }
}

// MARK: - 新图标占位（imageset 名；到货前 UIImage(named:) 为 nil，调用方回退）

enum NightPatrolIcons {
    /// 入口图标：脚印轨迹串（新图标，待 Li 补；未到货回退 icon_paw）。
    static let pawTrail = "icon_paw_trail"
    /// AI 短评角标（新图标，待 Li 补；未到货回退 9pt 橙色“AI”文字角标）。
    static let aiPaw = "icon_ai_paw"
    /// 停跑态图标（新图标，待 Li 补；未到货回退 icon_moon）。
    static let nightPaused = "icon_night_paused"

    /// 按目标 pt 重绘（与 BearyIconImages 同口径）；占位 imageset 无图时返回 nil。
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        return BearyIconImages.image(named: name, pointSize: pointSize)
    }
}

// MARK: - 模板语料（手写；只按心情 / 天气 / 字数匹配，不读正文）
//
// 本匹配既是服务端模板生成的 App 端镜像，也是模板记录缺文案时的补位：
// 调用方只在“服务端已下发该脚印记录、且 source 为 template、note 为空”时
// 调用 pick，绝不用它凭空合成脚印。同一组输入恒定输出同一句（稳定哈希取模），
// 同一夜反复打开不换文案。

enum BearyNightPatrolTemplate {
    private static let generic: [String] = [
        "夜里风很轻，你写下的那几行，小熊都认真看过啦。",
        "小熊昨夜轻轻走过这里，脚印留在这一页，明天也写一点，留一点。",
        "夜深了，小熊替你守着这些日子，晚安。",
    ]
    private static let sleepy: [String] = [
        "昨夜你大概很困了，小熊放轻脚步，没吵醒你。",
        "困意的那一夜，小熊也陪你慢慢走过去了。",
    ]
    private static let rainy: [String] = [
        "雨夜里，小熊的脚印沾了一点雨，还是走到了这里。",
        "昨夜下着雨，小熊替你把这一页好好收着。",
    ]
    private static let short: [String] = [
        "短短几行也很好，小熊都替你记住了。",
        "昨夜那几句很轻，小熊听得很清楚。",
    ]
    private static let long: [String] = [
        "昨夜你写了很长一段，小熊一字一句慢慢走完了。",
        "长长的一页，小熊昨夜认真读完才离开。",
    ]

    /// Deterministically pick：心情 sleepy / goodnight → 困意池；天气 rain →
    /// 雨夜池；否则按字数分短 / 长 / 通用池；输入缺失时走通用池。
    static func pick(mood: String?, weather: String?, wordCount: Int?) -> String {
        let pool: [String]
        if mood == "sleepy" || mood == "goodnight" {
            pool = sleepy
        } else if weather == "rain" {
            pool = rainy
        } else if let count = wordCount, count > 0, count < 50 {
            pool = short
        } else if let count = wordCount, count >= 200 {
            pool = long
        } else {
            pool = generic
        }
        var hash = wordCount ?? 0
        for scalar in (mood ?? "").unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        for scalar in (weather ?? "").unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        // 不用 abs(hash)：hash wraparound 到 Int.min 时 abs 会陷阱；双取模恒为正。
        let index = ((hash % pool.count) + pool.count) % pool.count
        return pool[index]
    }

    /// 脚印短评展示文案：服务端文案优先；模板缺文案时补匹配；AI 缺文案时
    /// 明示暂不可用（不替补模板，避免把模板冒充 AI）。
    static func displayNote(for footprint: NightPatrolFootprint) -> String {
        if let note = footprint.note, !note.isEmpty {
            return note
        }
        if footprint.isAI {
            return "AI 短评暂不可用，下次夜巡再来看看。"
        }
        return pick(mood: footprint.mood, weather: footprint.weather, wordCount: footprint.wordCount)
    }

    /// “M月d日夜”：nightDate 解析失败时原样回显，不编造日期。
    static func nightLabel(for nightDate: String?) -> String? {
        guard let nightDateValue = nightDate, !nightDateValue.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: nightDateValue) else { return nightDateValue }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日夜"
        return formatter.string(from: date)
    }
}

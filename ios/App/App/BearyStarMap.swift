import Foundation

// ===== 日记星图 · 纯逻辑（2026-10-30；预览：日记星图屏）=====
// 本文件只依赖 Entry（BearyAPI.swift）与 Foundation，不依赖 UIKit、
// 不依赖 BearyNativeCommon / BearyLocation / SessionManager——
// 因此可同时编进 App target 与 BearyCoreTests target，单测直接覆盖。
// UI（BearyDiaryStarMapViewController）只渲染本文件算出的模型，不自算过滤与连线。
//
// 口径（与预览一致，偏离处有注）：
// - 星：过滤后每篇一篇。大小 = 字数，亮度 = 心情，位置 = 日记 id 确定性哈希。
// - 连线：同心情 / 同地点 / 同词，三者可并存于一对篇之间（一条边带多条原因）。
// - 他人视角 fail-closed：过滤与连线都在过滤后的集合上算，私密篇连同它的
//   连线一并消失；他人地点键只用区级，精确名永远不作兜底、不进原因文案。
// - 草稿与回收站篇不进：数据源是作者日记列表（已发布篇），本文件不再二次区分。
// - “同词”无服务端关键词字段：由标题 + 正文现场派生（见 keywords 注释），
//   是近似匹配不是分词，原因文案只展示共享词本身，不展示正文。

/// 星图边的原因种类（过滤 chips 与原因文案共用）。
enum StarMapEdgeKind: String {
    case mood
    case place
    case word
}

/// 一条连线原因。detail 的含义按 kind 而定：mood = 心情 key，place = 地点键，
/// word = ""（共享词放 tokens）。展示层据此翻译成中文，纯逻辑层不绑
/// BearyText（BearyNativeCommon 不进测试 target），避免测试 target 依赖膨胀。
struct StarMapEdgeReason: Equatable {
    let kind: StarMapEdgeKind
    /// mood/place 的键；word 时为空串。
    let detail: String
    /// word 时的共享词（已按字符串排序、展示层再截断）；其余 kind 为空。
    let tokens: [String]
}

/// 一颗星：位置是 0...1 归一化坐标（渲染层按 sky bounds + 边距换算成 pt，
/// 同一篇在任何尺寸、任何分片里都落在同一相对位置，不随机飘）。
struct StarMapStar {
    let entry: Entry
    let x: Double
    let y: Double
    /// 半径 pt：6...20，见 radius(forWordCount:)。
    let radius: CGFloat
    /// 亮度 0.40...1.0，见 brightness(forMoodKey:)。
    let brightness: CGFloat
    let wordCount: Int
}

/// 一条边：连接两篇（firstId < secondId 字典序，作稳定边 id 用）。
struct StarMapEdge {
    let firstId: String
    let secondId: String
    let reasons: [StarMapEdgeReason]

    var id: String { firstId + "|" + secondId }
}

/// 星空模型：stars 与 edges 只含过滤后的篇；entryById 供点星/点线后取详情用。
struct StarMapModel {
    let stars: [StarMapStar]
    let edges: [StarMapEdge]
    let entryById: [String: Entry]
}

/// 分片选择：全部（只在篇数少时出现）/ 某年全年 / 某年某月 / 未标日期。
enum StarMapSlice: Equatable {
    case all
    case year(Int)
    case month(year: Int, month: Int)
    case undated

    var title: String {
        switch self {
        case .all: return "全部"
        case .year(let y): return "\(y)年"
        case .month(let y, let m): return "\(y)年\(m)月"
        case .undated: return "未标日期"
        }
    }
}

enum BearyStarMap {

    /// 分片阈值：过滤后总数 ≤ 该值时不分片、直接画全部；超过则强制按年/月分片，
    /// 不提供“全部”选项（不一次性铺全量；年内全年仍受 500 篇拉取上限约束，见 VC）。
    static let sliceThreshold = 80

    // MARK: - 过滤（fail-closed；调用方漏过滤时 buildModel 会再滤一次）

    /// 有效公开判定：与 BearyEphemeral.isEffectivelyPublic 同公式（isPublic 且
    /// 限时未过期），此处本地复写一行以保持本文件测试 target 可独立编译；
    /// 公式若改，两处须同步（见 VC 头注）。
    static func isEffectivelyPublic(_ entry: Entry, nowMs: Int? = nil) -> Bool {
        guard entry.isPublic == true else { return false }
        if let until = entry.ephemeralUntil {
            let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
            if until <= now { return false }
        }
        return true
    }

    /// 单篇是否可成星。排除项（任一命中即不出星、不出线）：
    /// - id 缺失/空白：星位哈希与详情锚点都无从确定；
    /// - 私密占位（placeholder）：服务端只下发占位壳，无内容可画；
    /// - 他人视角下非有效公开篇（含 isPublic 缺失、限时过期）：缺失按非公开算；
    /// - 纯心情未写字项（无正文、无标题、无图、无引用）：与主页展示层同口径。
    static func isStarVisible(_ entry: Entry, viewerIsAuthor: Bool) -> Bool {
        guard let id = entry.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if entry.placeholder == true { return false }
        if !viewerIsAuthor && !isEffectivelyPublic(entry) { return false }
        let text = (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = (entry.images ?? []).contains(where: { !$0.isEmpty })
        let hasQuote = (entry.quoteId ?? "").isEmpty == false
        return !text.isEmpty || !title.isEmpty || hasImages || hasQuote
    }

    static func visibleEntries(_ entries: [Entry], viewerIsAuthor: Bool) -> [Entry] {
        entries.filter { isStarVisible($0, viewerIsAuthor: viewerIsAuthor) }
    }

    // MARK: - 字数 / 大小 / 亮度

    /// 字数 = 标题 + 正文去空白后的字符数（grapheme 计数；中文一字一数，
    /// 不是分词词数）。无标题无正文的纯图篇为 0，仍成星、取最小半径。
    static func wordCount(_ entry: Entry) -> Int {
        let joined = (entry.title ?? "") + (entry.content ?? "")
        return joined.filter { !$0.isWhitespace }.count
    }

    /// 半径 pt：6 + 字数/40，上限 20（预览：5 + 字数/60、上限 16 的同形映射，
    /// 放大一档以保证小屏上最小星仍可点；字数 0 → 6）。
    static func radius(forWordCount count: Int) -> CGFloat {
        6 + min(14, CGFloat(max(0, count)) / 40)
    }

    /// 亮度：预览四档（开心 1 / 平静 .75 / 想念 .55 / 低落 .4）映射到
    /// App 的 40 个心情 key。无心情与未知 key 一律回中档 0.70——
    /// 不冒充最亮、也不打到最暗；亮度只是展示分层，不作任何门控。
    static func brightness(forMoodKey key: String?) -> CGFloat {
        guard let key = key, !key.isEmpty else { return 0.70 }
        switch key {
        case "happy", "love", "cheer", "applause", "proud", "thanks", "zap",
             "wave", "wink", "kiss", "hug", "pat", "comfort", "determined":
            return 1.0
        case "cry", "angry":
            return 0.40
        case "lonely", "confused", "facepalm", "sorry", "sleepy":
            return 0.55
        default:
            return 0.75
        }
    }

    // MARK: - 星位：FNV-1a 64 位确定性哈希（不用 Swift Hasher）

    /// Swift 的 Hasher 每次启动随机种子，同一 id 两次运行会飘——
    /// 星位必须跨启动、跨设备稳定，故用 FNV-1a 手写哈希。
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    /// 归一化星位：x 由 id 哈希，y 由 id + "|star-y" 哈希（两路独立，
    /// 避免 x/y 相关造成的斜线聚集）。同一 id 在任何集合、任何尺寸下同位。
    static func position(forEntryId id: String) -> (x: Double, y: Double) {
        let x = Double(fnv1a(id) % 1000) / 1000.0
        let y = Double(fnv1a(id + "|star-y") % 1000) / 1000.0
        return (x, y)
    }

    // MARK: - 地点键（viewer-aware；与 BearyLocationMap 同口径的本地版）

    /// 本人：精确名优先、无名退区级；他人：只用区级，无区级则 nil——
    /// 精确名在他人视角下永远不进键、不进原因文案、不作兜底。
    static func placeKey(_ entry: Entry, viewerIsAuthor: Bool) -> String? {
        let name = (entry.locationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let district = (entry.locationDistrict ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if viewerIsAuthor {
            if !name.isEmpty { return name }
            if !district.isEmpty { return district }
            return nil
        }
        return district.isEmpty ? nil : district
    }

    // MARK: - 同词：标题 + 正文现场派生（无服务端关键词字段）

    private static let latinStopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "are", "was", "were", "you", "your", "but", "not", "all", "can", "just",
    ]

    /// 中文单字停用字：派生二元词前先剔除（剔除后相邻字拼成的二元词是近似
    /// 匹配，可能把“我的猫”与“我猫”算成同词——可接受的模糊，不作精确分词宣称）。
    private static let cjkStopChars: Set<Character> = [
        "的", "了", "是", "在", "有", "和", "就", "也", "都", "把", "被", "对",
        "为", "与", "或", "但", "而", "着", "过", "得", "吗", "呢", "吧", "啊",
        "哦", "嗯", "呀",
    ]

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
            || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
    }

    /// 关键词集：拉丁词（≥3 字母、去停用词、小写）+ 中文二元词
    /// （连续中文串去停用字后取相邻二字；单字串不成词）。
    static func keywords(_ entry: Entry) -> Set<String> {
        let text = (entry.title ?? "") + "\n" + (entry.content ?? "")
        var out = Set<String>()
        var cjkRun = ""
        func flushCJKRun() {
            let kept = cjkRun.filter { !cjkStopChars.contains($0) }
            let chars = Array(kept)
            if chars.count >= 2 {
                for i in 0..<(chars.count - 1) {
                    out.insert(String(chars[i...i + 1]))
                }
            }
            cjkRun = ""
        }
        var latinRun = ""
        func flushLatinRun() {
            let word = latinRun.lowercased()
            if word.count >= 3 && !latinStopwords.contains(word) {
                out.insert(word)
            }
            latinRun = ""
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flushLatinRun()
                cjkRun.append(Character(scalar))
            } else if scalar.properties.isAlphabetic {
                flushCJKRun()
                latinRun.append(Character(scalar))
            } else {
                flushCJKRun()
                flushLatinRun()
            }
        }
        flushCJKRun()
        flushLatinRun()
        return out
    }

    // MARK: - 分片（年/月；createdAt 缺失 → 未标日期）

    static func sliceYearMonth(_ entry: Entry) -> (year: Int, month: Int)? {
        guard let ms = entry.createdAt, ms > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = comps.year, let month = comps.month else { return nil }
        return (year, month)
    }

    static func years(in entries: [Entry]) -> [Int] {
        var set = Set<Int>()
        for entry in entries {
            if let ym = sliceYearMonth(entry) { set.insert(ym.year) }
        }
        return set.sorted(by: >)
    }

    static func months(in entries: [Entry], year: Int) -> [Int] {
        var set = Set<Int>()
        for entry in entries {
            if let ym = sliceYearMonth(entry), ym.year == year { set.insert(ym.month) }
        }
        return set.sorted(by: >)
    }

    static func hasUndated(in entries: [Entry]) -> Bool {
        entries.contains { sliceYearMonth($0) == nil }
    }

    /// 取分片内的篇：.all 全量；.year 全年；.month 当月；.undated 无日期篇。
    static func entries(in entries: [Entry], slice: StarMapSlice) -> [Entry] {
        switch slice {
        case .all:
            return entries
        case .year(let year):
            return entries.filter { sliceYearMonth($0)?.year == year }
        case .month(let year, let month):
            return entries.filter {
                guard let ym = sliceYearMonth($0) else { return false }
                return ym.year == year && ym.month == month
            }
        case .undated:
            return entries.filter { sliceYearMonth($0) == nil }
        }
    }

    /// 默认分片：总数 ≤ 阈值 → 全部；否则最新年 + 该年最新月
    /// （篇数多时默认不铺全量；用户仍可手动切到某年全年）。
    static func defaultSlice(for entries: [Entry]) -> StarMapSlice {
        guard entries.count > sliceThreshold else { return .all }
        guard let latestYear = years(in: entries).first else { return .undated }
        guard let latestMonth = months(in: entries, year: latestYear).first else { return .year(latestYear) }
        return .month(year: latestYear, month: latestMonth)
    }

    // MARK: - 建模（过滤 → 星 → 边；边在过滤后集合上算）

    /// 建模入口：内部先按 viewer 过滤一次（调用方即使传了未过滤列表，
    /// 私密篇也不会成星、更不会出线）。同词边另做全片文档频率抑制：
    /// 共享词在超过半数篇里出现时不算连线原因（防“今天/我们”类高频词
    /// 把整片星空连成毛线团）；半数下限 2，保证两篇小片仍能连线。
    static func buildModel(entries: [Entry], viewerIsAuthor: Bool) -> StarMapModel {
        let visible = visibleEntries(entries, viewerIsAuthor: viewerIsAuthor)
        var entryById: [String: Entry] = [:]
        var stars: [StarMapStar] = []
        for entry in visible {
            guard let id = entry.id else { continue }
            let count = wordCount(entry)
            let pos = position(forEntryId: id)
            stars.append(StarMapStar(
                entry: entry,
                x: pos.x,
                y: pos.y,
                radius: radius(forWordCount: count),
                brightness: brightness(forMoodKey: entry.mood),
                wordCount: count
            ))
            entryById[id] = entry
        }
        // 文档频率：词 → 含该词的篇数（只在过滤后集合上算）。
        var docFreq: [String: Int] = [:]
        var keywordsById: [String: Set<String>] = [:]
        for entry in visible {
            guard let id = entry.id else { continue }
            let keys = keywords(entry)
            keywordsById[id] = keys
            for key in keys { docFreq[key, default: 0] += 1 }
        }
        let freqCap = max(2, visible.count / 2)
        var edges: [StarMapEdge] = []
        for i in visible.indices {
            for j in visible.indices where j > i {
                guard let a = visible[i].id, let b = visible[j].id else { continue }
                var reasons: [StarMapEdgeReason] = []
                let moodA = (visible[i].mood ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let moodB = (visible[j].mood ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !moodA.isEmpty, moodA == moodB {
                    reasons.append(StarMapEdgeReason(kind: .mood, detail: moodA, tokens: []))
                }
                if let placeA = placeKey(visible[i], viewerIsAuthor: viewerIsAuthor),
                   let placeB = placeKey(visible[j], viewerIsAuthor: viewerIsAuthor),
                   placeA == placeB {
                    reasons.append(StarMapEdgeReason(kind: .place, detail: placeA, tokens: []))
                }
                let shared = (keywordsById[a] ?? []).intersection(keywordsById[b] ?? [])
                    .filter { (docFreq[$0] ?? 0) <= freqCap }
                    .sorted()
                if !shared.isEmpty {
                    reasons.append(StarMapEdgeReason(kind: .word, detail: "", tokens: shared))
                }
                if !reasons.isEmpty {
                    let (first, second) = a < b ? (a, b) : (b, a)
                    edges.append(StarMapEdge(firstId: first, secondId: second, reasons: reasons))
                }
            }
        }
        return StarMapModel(stars: stars, edges: edges, entryById: entryById)
    }
}

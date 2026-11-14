import UIKit
import NaturalLanguage

// MARK: - 批 D：我的页个性化模块（纯逻辑，与 UI 解耦）
//
// 口径（2026-10-30 批 D 任务书 + 两份预览）：
// - 数据只走已有字段聚合（日记日期 / 心情 / 天气 / 正文 / 创建时间），不新增表、不新增高频写库。
// - 他人页一律公开口径：visibleEntries 在客户端再做一次 fail-closed 过滤
//   （他人页 isPublic != true 的条目全部排除，私密当天按空白/不计入/不泄露；
//   服务端是否已过滤不影响本层结论——服务端漏发私密条目时本层同样挡住）。
// - 占位条目（placeholder == true，iCity 私密占位）永远排除；无 id 条目排除。
// - 空态塌掉：调用方（ProfileVC renderModules）按本层返回的空信号整卡隐藏，
//   不留空标题；唯一例外是「那年今日」空态——预览明确要求显示解释性空态卡
//   （「往年今天还没有日记，不编造」），那不是空标题，是有文案的空态。
// - 年度回顾入口卡仍只本人可见；但词汇指纹（年报首屏主视觉 + 写作统计卡
//   紧凑版）本人与他人均可见：他人态只按公开篇统计并标注「仅公开篇」，
//   见 BearyWordprint.swift 与本文件 wordprint() 的双层 fail-closed 过滤。
// - 主题氛围不是一张卡：见 BearyProfileThemeTint（默认墨色现行，不新增 theme_tint 列，
//   可自选功能待 Li 另定后再把该列绑到 applyProfileThemeTint 的入参上）。

/// 主题氛围三档（预览示意值）。默认 .ink = 现行底色，视觉零变化；
/// 选色 UI 与 theme_tint 列均未开通——本枚举只是把「底色取哪」收敛到一处，
/// 以后开通时只改调用方传入的档位，不动卡片布局。
enum BearyProfileThemeTint {
    case ink
    case warmOrange
    case calmBlue

    var headerBackground: UIColor {
        switch self {
        case .ink:
            return BearyColors.bg
        case .warmOrange:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 42.0 / 255.0, green: 23.0 / 255.0, blue: 0, alpha: 1)
                    : UIColor(red: 1, green: 0.945, blue: 0.878, alpha: 1)
            }
        case .calmBlue:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 10.0 / 255.0, green: 26.0 / 255.0, blue: 46.0 / 255.0, alpha: 1)
                    : UIColor(red: 0.918, green: 0.953, blue: 1, alpha: 1)
            }
        }
    }
}

enum BearyProfilePersonalLogic {

    // MARK: - 可见口径

    /// 本人：全部非占位日记（公开 + 私密）；他人：有效公开篇，或互关时的仅好友篇。
    /// 草稿 / 回收站条目服务端 author scope 本就不下发；本地若混入无 id 条目一律排除。
    /// 审计-个人页设置（与主列表 isProfileDiaryDisplayable 统一口径）：旧口径
    /// 他人态一律排除仅好友篇，与主列表“只要 friends 就放行”分裂；现统一为
    /// 非作者视角仅好友篇只在互关时放行（isMutualFriend 由调用方按实时
    /// followState 传，未拉到状态时按非互关 fail-closed）。服务端 scope 口径
    /// 仍需抓包核对，App 侧不依赖服务端单点过滤。
    static func visibleEntries(_ entries: [Entry], isOwn: Bool, isMutualFriend: Bool = false) -> [Entry] {
        entries.filter { entry in
            guard let id = entry.id, !id.isEmpty else { return false }
            guard entry.placeholder != true else { return false }
            if isOwn { return true }
            // 扫荡 C：他人态按有效公开判定（BearyEphemeral 全 App 唯一口径），
            // 而非裸 isPublic——限时日记过期后按普通私密算（读时判定、无 sweep），
            // 旧口径会把“已公开但限时已过期”的篇计入他人统计 / 词汇指纹 / 年度回顾。
            // 当前调用链（个人模块语料仅本人页拉取、他人页模块不拉语料；作者
            // scope 服务端已滤过期篇）下此改不改变线上行为，属纵深防御：
            // 语料在过期前拉取、过期后仍在内存时，他人聚合不再把过期篇算进去。
            if BearyEphemeral.isEffectivelyPublic(entry) { return true }
            return entry.isFriendsOnly && isMutualFriend
        }
    }

    /// 北京日（北京时间日历，Asia/Shanghai）起点的 Date，用作 streak 去重键。
    static func startOfDay(for timestampMs: Int, calendar: Calendar) -> Date? {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        return calendar.startOfDay(for: date)
    }

    // MARK: - 写作统计

    struct WritingStats {
        var total: Int
        /// 正文字符数（content.count；标题不计；中英字符各计 1，与编辑器字数口径的字符计数一致）。
        var totalChars: Int
        /// 最常写时段：2 小时桶（00–02 … 22–24）中条数最多者；无条目时为 nil。
        /// 平手取最早时段（稳定、不随字典序抖动）。
        var bestSlotStartHour: Int?
        var currentStreakDays: Int
        var topMoodKey: String?
        var topWeatherKey: String?
    }

    static func writingStats(entries: [Entry], now: Date, calendar: Calendar) -> WritingStats {
        // 时间胶囊 v1：胶囊篇不进写作统计（总数／字数／时段／心情／天气／
        // 连续天数一律先滤掉 isCapsule==1 的篇再算）。
        let entries = entries.filter { $0.isCapsuleBuried != true }
        let total = entries.count
        let totalChars = entries.reduce(0) { $0 + ($1.content ?? "").count }
        // 2 小时桶。
        var slotCounts = [Int: Int](minimumCapacity: 12)
        var moodCounts: [String: Int] = [:]
        var weatherCounts: [String: Int] = [:]
        var writtenDays = Set<Date>()
        for entry in entries {
            guard let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            let hour = calendar.component(.hour, from: date)
            slotCounts[(hour / 2) * 2, default: 0] += 1
            if let mood = entry.mood, !mood.isEmpty { moodCounts[mood, default: 0] += 1 }
            if let weather = entry.weather, !weather.isEmpty { weatherCounts[weather, default: 0] += 1 }
            writtenDays.insert(calendar.startOfDay(for: date))
        }
        var bestSlot: Int?
        var bestSlotCount = 0
        for startHour in stride(from: 0, through: 22, by: 2) {
            let count = slotCounts[startHour] ?? 0
            if count > bestSlotCount {
                bestSlotCount = count
                bestSlot = startHour
            }
        }
        if bestSlotCount == 0 { bestSlot = nil }
        return WritingStats(
            total: total,
            totalChars: totalChars,
            bestSlotStartHour: bestSlot,
            currentStreakDays: currentStreak(from: now, writtenDays: writtenDays, calendar: calendar),
            topMoodKey: topKey(moodCounts),
            topWeatherKey: topKey(weatherCounts)
        )
    }

    /// 众数：计数最高者；平手取字典序最小 key（稳定，与插入序无关）。
    private static func topKey(_ counts: [String: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        var bestKey: String?
        var bestCount = 0
        for key in counts.keys.sorted() {
            let count = counts[key] ?? 0
            if count > bestCount {
                bestCount = count
                bestKey = key
            }
        }
        return bestKey
    }

    /// 当前连续天数：今天已写则从今天往回数，否则昨天已写则从昨天往回数，
    /// 两天皆无则为 0（「今天还没写不算断」与「断了就是 0」分开处理，避免把
    /// 今天未写误判为连续中断、也避免把昨天断档误算进今天）。
    static func currentStreak(from now: Date, writtenDays: Set<Date>, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: now)
        var cursor: Date?
        if writtenDays.contains(today) {
            cursor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  writtenDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }
        var streak = 0
        var day = cursor
        while let current = day, writtenDays.contains(current) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: current)
        }
        return streak
    }

    /// 最长连续天数（年报首屏用）：对去重后的本地日集合从小到大扫一遍。
    static func longestStreak(writtenDays: Set<Date>, calendar: Calendar) -> Int {
        let sorted = writtenDays.sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for day in sorted {
            if let prev = previous,
               let next = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    // MARK: - 那年今日

    struct ThisDayHistory {
        var year: Int
        /// 该年当天条目（createdAt 降序；卡片主显首篇，多篇时展开列表）。
        var entries: [Entry]
    }

    /// 同月同日、往年（年份 < 今天年份）按年份倒序，只取最近一年。
    static func thisDayInHistory(entries: [Entry], today: Date, calendar: Calendar) -> ThisDayHistory? {
        let todayParts = calendar.dateComponents([.year, .month, .day], from: today)
        guard let todayYear = todayParts.year,
              let todayMonth = todayParts.month,
              let todayDay = todayParts.day else { return nil }
        var byYear: [Int: [Entry]] = [:]
        for entry in entries {
            // 时间胶囊 v1：胶囊篇不进那年今日入口（只在取数处过滤，
            // 不改 PastSelfMessage 逻辑）。
            guard entry.isCapsuleBuried != true else { continue }
            guard let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, year < todayYear,
                  parts.month == todayMonth, parts.day == todayDay else { continue }
            byYear[year, default: []].append(entry)
        }
        guard let latestYear = byYear.keys.max() else { return nil }
        var yearEntries = byYear[latestYear] ?? []
        yearEntries.sort { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
        return ThisDayHistory(year: latestYear, entries: yearEntries)
    }

    // MARK: - 随机漫步

    /// 均匀抽取；excludingId 指定的上一篇排除在外。候选为空时返回 nil，
    /// 调用方保留当前卡片（单篇池里「换一篇」换不出新篇，不是错误，不崩、不跳空卡）。
    static func randomEntry(pool: [Entry], excludingId: String?) -> Entry? {
        let candidates: [Entry]
        if let excluding = excludingId, !excluding.isEmpty {
            candidates = pool.filter { $0.id != excluding }
        } else {
            candidates = pool
        }
        guard !candidates.isEmpty else { return nil }
        return candidates[Int.random(in: 0..<candidates.count)]
    }

    // MARK: - 年度回顾

    /// 当年条目（本地年），createdAt 降序。
    /// 当年条目是年度回顾总篇数、最长连续、心情分布与词汇指纹的共同源头。
    static func yearEntries(entries: [Entry], year: Int, calendar: Calendar) -> [Entry] {
        entries.filter { entry in
            guard let createdAt = entry.createdAt else { return false }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            return calendar.component(.year, from: date) == year
        }.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
    }

    /// 心情分布（年报首屏条形用）：计数降序，平手按 key 升序（稳定）。
    static func moodDistribution(entries: [Entry]) -> [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            if let mood = entry.mood, !mood.isEmpty { counts[mood, default: 0] += 1 }
        }
        return counts.map { (key: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.key < $1.key
        }
    }

    /// 停用词（中文高频虚词 + 人称代词 + 时间副词骨架；只拦虚词，不拦实词——
    /// 「秋天」「路上」这类内容词不在表里）。
    static let stopwords: Set<String> = [
        "的", "了", "在", "是", "我", "和", "有", "就", "这", "那", "不", "也", "都", "还",
        "被", "对", "与", "或", "但", "而", "个", "为", "从", "到", "给", "让", "向", "用",
        "比", "跟", "及", "若", "如", "因", "所以", "然", "则", "且", "并", "却", "当",
        "会", "能", "可以", "要", "应", "着", "过", "得", "地", "之", "其", "所", "此",
        "些", "每", "各", "自己", "我们", "你们", "他们", "她", "他", "它", "怎么", "什么",
        "为什么", "时候", "今天", "明天", "昨天", "现在", "然后", "之后", "之前", "已经",
        "正在", "一起", "一点", "一些", "没有", "不是", "不要", "不能", "不会", "可是",
        "还是", "就是", "只有", "除了", "如果", "虽然", "尽管", "因为", "于是", "接着",
        "首先", "其次", "最后", "总共", "其实", "特别", "非常", "很", "太", "更", "最",
        "一个", "这个", "那个", "这里", "那里", "这样", "那样", "怎么", "什么", "谁",
        "哪", "吗", "吧", "呢", "啊", "呀", "哦", "嗯", "哈哈",
    ]

    // MARK: - 词汇指纹

    /// 词汇指纹单条：月份分布按「篇数」计（同一篇内词出现多次，当月只计 1 篇），
    /// 故 12 个月篇数之和恒等于 docCount；该不变量由构造方式保证（见 wordprint）。
    struct WordprintItem {
        var word: String
        var docCount: Int
        var totalCount: Int
        var monthDocCounts: [Int: Int]
    }

    struct Wordprint {
        var year: Int
        var entryCount: Int
        var items: [WordprintItem]
    }

    /// 有词条目的年份（降序）：只取年份数字，不算任何一年的词表——
    /// 看当年不触发旧年重算；切到旧年时只算旧年那一张。
    static func availableYears(entries: [Entry], isOwn: Bool, calendar: Calendar) -> [Int] {
        var years = Set<Int>()
        for entry in visibleEntries(entries, isOwn: isOwn) {
            guard let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            years.insert(calendar.component(.year, from: date))
        }
        return years.sorted(by: >)
    }

    /// 词汇指纹：只算指定 year 一年，排序按出现篇数降序（不是总次数），
    /// 平手时总次数降序、再按首次出现顺序；默认取前 15（任务书 10-20 的中值），
    /// 紧凑版调用方再取前 4。分词与过滤口径沿用批 D 常出现的词：当年正文走
    /// 系统 NLTokenizer（zh-Hans，词单位），过滤停用词 / 标点 / 单字 / 纯数字 /
    /// emoji（见 isCountableWord）；同一篇内重复按实际次数计入总次数，
    /// 出现篇数与月份分布按篇计（每篇每词每月各计 1 次）。
    /// fail-closed：入参即使是未过滤的全量语料，本函数也先走 visibleEntries
    /// 再过滤一次——他人态私密篇独有的词进不了词表，私密篇集中的月份也不会
    /// 在他人月份分布里冒头；无 createdAt 的条目无法归属年份，不计入。
    /// 不新增写库：纯内存计算，调用方传入的已是内存语料；切年份只重算当选年份。
    /// 注意：NLTokenizer 是设备端分词，无网络、无新依赖；分词质量以系统为准，
    /// 不自写二元切分（自写切分会把「秋天」切成「秋」「天」或拼出不存在的词）。
    /// 批 D 的 frequentWords（仅总次数、无篇数、无月份、无他人过滤）已被本函数
    /// 取代：其唯一调用方年报首屏已改走本函数，故直接删除，不留两套词表。
    static func wordprint(entries: [Entry], year: Int, isOwn: Bool, limit: Int = 15, calendar: Calendar) -> Wordprint {
        let visible = visibleEntries(entries, isOwn: isOwn)
        let yearEntriesValue = yearEntries(entries: visible, year: year, calendar: calendar)
        var totalCounts: [String: Int] = [:]
        var docCounts: [String: Int] = [:]
        var monthDocCounts: [String: [Int: Int]] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        for entry in yearEntriesValue {
            guard let content = entry.content, !content.isEmpty,
                  let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            let month = calendar.component(.month, from: date)
            var entryCounts: [String: Int] = [:]
            tokenizer.string = content
            tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
                let token = String(content[range])
                order += 1
                guard isCountableWord(token) else { return true }
                if firstSeen[token] == nil { firstSeen[token] = order }
                entryCounts[token, default: 0] += 1
                return true
            }
            for (word, count) in entryCounts {
                totalCounts[word, default: 0] += count
                docCounts[word, default: 0] += 1
                var months = monthDocCounts[word] ?? [:]
                months[month, default: 0] += 1
                monthDocCounts[word] = months
            }
        }
        let effectiveLimit = max(0, limit)
        let items = docCounts.map { (word: $0.key, docCount: $0.value, totalCount: totalCounts[$0.key] ?? 0, months: monthDocCounts[$0.key] ?? [:]) }.sorted {
            if $0.docCount != $1.docCount { return $0.docCount > $1.docCount }
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            return (firstSeen[$0.word] ?? 0) < (firstSeen[$1.word] ?? 0)
        }.prefix(effectiveLimit).map {
            WordprintItem(word: $0.word, docCount: $0.docCount, totalCount: $0.totalCount, monthDocCounts: $0.months)
        }
        return Wordprint(year: year, entryCount: yearEntriesValue.count, items: items)
    }

    /// 可计词：长度 ≥2 字符；全部 scalar 为字母（CJK 与拉丁字母均属字母，
    /// 标点 / 数字 / emoji / 空白至此已排除）；不在停用词表里。
    private static func isCountableWord(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        guard !stopwords.contains(token) else { return false }
        for scalar in token.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { return false }
        }
        return true
    }

    // MARK: - 词汇指纹后台计算与缓存
    //
    // 问题：wordprint() 逐篇跑 NLTokenizer，调用方（个人页 renderStats、
    // 年报 renderSelectedYear）都在主线程；日记多时进个人页 / 切年份会
    // 卡住界面。本节只动线程与缓存，同步 wordprint() 一字不动——口径、
    // 排序、文案的唯一事实来源仍是它；后台算的是同一个函数、同一输入
    // 顺序，故结果与同步计算完全一致。
    // 缓存键 = 账号 + 年份 + limit + isOwn + 语料指纹。服务端没有给这份
    // 内存语料下发数据版本号，故指纹即数据版本：取影响结果的全部字段
    // （按计算顺序排列的当年可见条目的 id / createdAt / 正文 / 可见性
    // 字段），增删改篇、可见性翻转、限时过期都会换键；切号、切年本来
    // 就换键。指纹只做 Hasher 哈希，不存正文、不写库、不落盘。
    // 完成回调一律回主线程；缓存命中时同步回调（调用方在主线程时即
    // 本次渲染内回填，无闪烁）。调用方另以代次号 + 年份丢弃过期回调——
    // 本层不替调用方判定“当前年份 / 当前账号”，因为本层不知道界面状态。

    private static let wordprintQueue = DispatchQueue(label: "com.beary.wordprint", qos: .userInitiated)
    private static let wordprintCacheLock = NSLock()
    private static var wordprintCache: [WordprintCacheKey: Wordprint] = [:]
    private static var wordprintCacheOrder: [WordprintCacheKey] = []
    private static let wordprintCacheLimit = 16

    struct WordprintCacheKey: Hashable {
        var accountKey: String
        var year: Int
        var limit: Int
        var isOwn: Bool
        var fingerprint: Int
    }

    /// 语料指纹：与 wordprint() 内部完全相同的过滤顺序
    /// （visibleEntries → yearEntries），只喂影响结果的字段；时区也喂入，
    /// 设备时区变化导致年份归属变化时同样换键。
    static func wordprintFingerprint(entries: [Entry], year: Int, isOwn: Bool, calendar: Calendar) -> Int {
        var hasher = Hasher()
        hasher.combine(calendar.timeZone.identifier)
        let yearEntriesValue = yearEntries(entries: visibleEntries(entries, isOwn: isOwn), year: year, calendar: calendar)
        hasher.combine(yearEntriesValue.count)
        for entry in yearEntriesValue {
            hasher.combine(entry.id)
            hasher.combine(entry.createdAt)
            hasher.combine(entry.content)
            hasher.combine(entry.isPublic)
            hasher.combine(entry.ephemeralUntil)
            hasher.combine(entry.placeholder)
        }
        return hasher.finalize()
    }

    /// 后台算 wordprint：指纹与缓存查键都在后台队列，命中 / 未命中一律
    /// 回主线程回调。调用方必须在回调里凭自己的代次号与年份复核“仍是
    /// 当前请求”，过期结果一律丢弃。缓存键字段（accountKey / 年 /
    /// limit / isOwn / 指纹）与失效语义与同步版一字不差。
    static func wordprintAsync(
        accountKey: String,
        entries: [Entry],
        year: Int,
        isOwn: Bool,
        limit: Int = 15,
        calendar: Calendar,
        completion: @escaping (Wordprint) -> Void
    ) {
        // 12：指纹遍历（逐篇哈希）不再在主线程同步做——连同缓存查键一起
        // 进后台队列；键组成与失效语义不变，只是回填改为一律异步回主线程
        // （调用方本就按异步回调守卫代次与年份）。entries 是值类型数组，
        // 闭包捕获即快照，后台只读快照，调用方后续改动不影响本次计算。
        wordprintQueue.async {
            let key = WordprintCacheKey(
                accountKey: accountKey,
                year: year,
                limit: limit,
                isOwn: isOwn,
                fingerprint: wordprintFingerprint(entries: entries, year: year, isOwn: isOwn, calendar: calendar)
            )
            wordprintCacheLock.lock()
            let cached = wordprintCache[key]
            wordprintCacheLock.unlock()
            if let cached = cached {
                DispatchQueue.main.async {
                    completion(cached)
                }
                return
            }
            // Entry 是值类型、wordprint 内 tokenizer 现建现用不共享，
            // 后台只读语料，故跨线程安全；结果同样是值类型。
            let value = wordprint(entries: entries, year: year, isOwn: isOwn, limit: limit, calendar: calendar)
            wordprintCacheLock.lock()
            if wordprintCache[key] == nil {
                wordprintCacheOrder.append(key)
                if wordprintCacheOrder.count > wordprintCacheLimit {
                    let evicted = wordprintCacheOrder.removeFirst()
                    wordprintCache.removeValue(forKey: evicted)
                }
            }
            wordprintCache[key] = value
            wordprintCacheLock.unlock()
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }

    // MARK: - 写作统计后台计算与缓存（审计 08，与词汇指纹同款口径）
    //
    // 问题：renderStats 在主线程同步调 writingStats()，逐篇 reduce 算字符数
    // ＋ 2 小时桶／心情／天气／连续天数，日记多时进个人页会卡住界面。本节只动
    // 线程与缓存，同步 writingStats() 一字不动——口径的唯一事实来源仍是它；
    // 后台算的是同一个函数、同一输入顺序，故结果与同步计算完全一致。
    // 缓存键 = 账号 + isOwn + 当日起点 + 语料指纹。指纹喂影响结果的全部字段
    // （可见条目的 id / createdAt / 正文 / 心情 / 天气 / 可见性字段）：内容改、
    // 可见性翻转、删篇、恢复、限时过期都会换键；点赞／收藏字段（likeCount /
    // likedByMe / bookmarkCount / bookmarkedByMe）不参与统计，故不喂入——
    // 点赞／收藏变化不重新统计。连续天数依赖“今天”，故键内另含当日起点，
    // 跨天后旧缓存不再命中。指纹只做 Hasher 哈希，不存正文、不写库、不落盘。
    // 完成回调一律回主线程；缓存命中时同步回调（调用方在主线程时即本次渲染
    // 内回填，无闪烁）。调用方另以代次号丢弃过期回调——本层不替调用方判定
    // “当前账号”，因为本层不知道界面状态。

    private static let writingStatsQueue = DispatchQueue(label: "com.beary.writingstats", qos: .userInitiated)
    private static let writingStatsCacheLock = NSLock()
    private static var writingStatsCache: [WritingStatsCacheKey: WritingStats] = [:]
    private static var writingStatsCacheOrder: [WritingStatsCacheKey] = []
    private static let writingStatsCacheLimit = 16

    struct WritingStatsCacheKey: Hashable {
        var accountKey: String
        var isOwn: Bool
        var dayStart: Date
        var fingerprint: Int
    }

    /// 语料指纹：只喂 writingStats() 读到的字段与可见性字段；点赞／收藏
    /// 字段不喂入（见上）。时区也喂入，设备时区变化导致时段桶／连续天数
    /// 归属变化时同样换键。调用方传入的已是可见语料（renderStats 的 visible），
    /// 故此处不再重复 visibleEntries 过滤。
    static func writingStatsFingerprint(entries: [Entry], calendar: Calendar) -> Int {
        var hasher = Hasher()
        hasher.combine(calendar.timeZone.identifier)
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.id)
            hasher.combine(entry.createdAt)
            hasher.combine(entry.content)
            hasher.combine(entry.mood)
            hasher.combine(entry.weather)
            hasher.combine(entry.isPublic)
            hasher.combine(entry.visibility)
            hasher.combine(entry.ephemeralUntil)
            hasher.combine(entry.placeholder)
            // 时间胶囊 v1：writingStats 先滤胶囊篇，指纹须含胶囊态，
            // 否则埋／取消埋藏后指纹不变、旧统计缓存会继续命中。
            hasher.combine(entry.isCapsule)
        }
        return hasher.finalize()
    }

    /// 后台算 writingStats：缓存命中同步回调，未命中则在后台队列算完、
    /// 写缓存、回主线程回调。调用方必须在回调里凭自己的代次号复核
    /// “仍是当前请求”，过期结果一律丢弃。
    static func writingStatsAsync(
        accountKey: String,
        entries: [Entry],
        isOwn: Bool,
        calendar: Calendar,
        completion: @escaping (WritingStats) -> Void
    ) {
        let now = Date()
        let key = WritingStatsCacheKey(
            accountKey: accountKey,
            isOwn: isOwn,
            dayStart: calendar.startOfDay(for: now),
            fingerprint: writingStatsFingerprint(entries: entries, calendar: calendar)
        )
        writingStatsCacheLock.lock()
        let cached = writingStatsCache[key]
        writingStatsCacheLock.unlock()
        if let cached = cached {
            completion(cached)
            return
        }
        // Entry 与 WritingStats 均为值类型，后台只读语料，故跨线程安全。
        writingStatsQueue.async {
            let value = writingStats(entries: entries, now: now, calendar: calendar)
            writingStatsCacheLock.lock()
            if writingStatsCache[key] == nil {
                writingStatsCacheOrder.append(key)
                if writingStatsCacheOrder.count > writingStatsCacheLimit {
                    let evicted = writingStatsCacheOrder.removeFirst()
                    writingStatsCache.removeValue(forKey: evicted)
                }
            }
            writingStatsCache[key] = value
            writingStatsCacheLock.unlock()
            DispatchQueue.main.async {
                completion(value)
            }
        }
    }
}

// MARK: - 年报最小版（点年度回顾入口后呈现；定版第 8 条：只含四项＋页脚）
//
// 只本人可见（入口卡只本人渲染，故本页不可达他人态）。内容全部来自调用方
// 传入的当年可见条目，不拉新接口：总篇数 / 最长连续 / 心情分布 / 常出现的词。
// 无词时词一节整节省略（不留空标题）。

// MARK: - 年报最小版（词汇指纹为主视觉）
//
// 可达性：本人经年度回顾入口卡，他人经写作统计卡（点整卡进本页）——
// 两路传入的都是调用方已按 visibleEntries 过滤的语料，本页再以
// filteredEntries（构造时过滤一次）+ wordprint 内部过滤一次兜底；
// 他人页通篇只按公开篇统计，首屏指纹徽标行明确标注「仅公开篇」。
// 每年一张：年份选择器只列有词条目的年份（availableYears），切年份时
// renderSelectedYear 先清空动态栈再重建——旧年词行绝不残留到新年；
// 每次只算当选年份。同一次打开内切回看过的年份，聚合结果取缓存、
// 阅读位置恢复到上次离开处；年份选择器固定在顶部，不随内容滚动；
// 首次进入另一年摘要按切换方向短距移入，词行后到时单独淡入并保住锚点。
// 词汇指纹走后台算 + 内存缓存（键 = 账号 / 年份 /
// 语料指纹，不写库）：其余各节同步建好立即呈现，词行算完后插回栈顶，
// 顺序与同步版最终一致；快速连点年份时旧年结果凭代次丢弃。
// 无词时指纹一节整节省略（不留空标题），但口径徽标行仍单独出现，
// 避免他人页在无词年里丢了「仅公开篇」标注。

final class BearyYearReviewViewController: UIViewController {

    private let filteredEntries: [Entry]
    private let isOwnFlag: Bool
    private let availableYearValues: [Int]
    private var selectedYear: Int
    /// 按年聚合结果缓存（同一次打开内有效）：摘要文案／心情分布只算一次，
    /// 切回看过的年份直接复用，不再从 filteredEntries 重算。
    /// 词汇指纹不另造缓存——它已有静态缓存（上限 16，按年＋指纹查）。
    private struct YearReviewAggregate {
        let summaryText: String
        let moodDistribution: [(key: String, count: Int)]
    }
    private var yearAggregateCache: [Int: YearReviewAggregate] = [:]
    /// 各年上次的阅读位置（contentOffset.y）：切年时保存离开的年份，
    /// 切回时恢复；首次进入的年份无记录，回到顶部。
    private var yearScrollOffsets: [Int: CGFloat] = [:]
    /// 本次渲染已恢复到的偏移（nil = 本次渲染尚未恢复）：词汇指纹
    /// 后到回调凭此判断恢复是否已跑过——跑过才做锚点补偿，未跑过
    /// （缓存命中同步插回）则由渲染末尾的恢复一次到位，不再重复补。
    private var yearRestoreAppliedOffset: CGFloat?
    /// 词汇指纹在途代次：renderSelectedYear 每调一次即 +1；过期回调
    /// （旧年 / 旧语料）到达时凭此丢弃，最终只留最后选中的年份。
    private var wordprintRequest = 0
    /// 词汇指纹缓存的账号键：语料作者 id；取不到时退 isOwn 口径。
    /// 账号键只是纵深防御——语料指纹（篇 id + 正文）本身已区分不同
    /// 作者的语料，跨号串结果还须指纹也撞上才可能发生。
    private var wordprintAccountKey: String {
        if let authorId = filteredEntries.compactMap({ $0.authorId }).first {
            return "author:\(authorId)"
        }
        return isOwnFlag ? "own:unknown" : "other:unknown"
    }

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 22, weight: .heavy))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        return label
    }()

    private let yearLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        return label
    }()

    // Hit44：两钮已有 44×44 约束，point(inside:) 不再外扩（零行为变化）；类型统一为 Hit44 以防约束日后收窄。
    private lazy var prevYearButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_arrow_left", pointSize: 16), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "前一年"
        buttonValue.addTarget(self, action: #selector(prevYearTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private lazy var nextYearButton: BearyHit44Button = {
        let buttonValue = BearyHit44Button(type: .system)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_arrow_right", pointSize: 16), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "后一年"
        buttonValue.addTarget(self, action: #selector(nextYearTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let pickerRow: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }()

    private let dynamicStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        return stack
    }()

    /// 年份选择器固定头（标题＋年份行）：直接挂在 view 上，不随内容滚动；
    /// 内容滚动视图顶边改锚到它底部，内容再长选择器也不被顶走。
    private let yearHeaderStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        return stack
    }()

    /// 内容滚动视图：提为属性，供切年保存／恢复各年阅读位置用。
    private let contentScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private let wordprintView = BearyWordprintView(mode: .hero)

    init(year: Int, allEntries: [Entry], isOwn: Bool) {
        self.filteredEntries = BearyProfilePersonalLogic.visibleEntries(allEntries, isOwn: isOwn)
        self.isOwnFlag = isOwn
        let years = BearyProfilePersonalLogic.availableYears(entries: allEntries, isOwn: isOwn, calendar: .current)
        self.availableYearValues = years
        self.selectedYear = years.contains(year) ? year : (years.first ?? year)
        super.init(nibName: nil, bundle: nil)
        wordprintView.onSelect = { [weak self] item in
            self?.presentWordDetail(item: item)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)

        view.addSubview(contentScrollView)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        contentScrollView.addSubview(stack)
        // 年份选择器固定头：标题＋年份行挂 view 上、不进滚动栈；
        // 滚动视图顶边锚到头底部，首屏视觉位置与原来一致（标题仍在安全区 +56）。
        view.addSubview(yearHeaderStack)
        yearHeaderStack.addArrangedSubview(titleLabel)
        yearHeaderStack.addArrangedSubview(pickerRow)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            yearHeaderStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            yearHeaderStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            yearHeaderStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            contentScrollView.topAnchor.constraint(equalTo: yearHeaderStack.bottomAnchor, constant: 20),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: contentScrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentScrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentScrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentScrollView.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor, constant: -40),
        ])

        let calendarIconView = UIImageView(image: BearyIconImages.image(named: "icon_calendar", pointSize: 16))
        calendarIconView.translatesAutoresizingMaskIntoConstraints = false
        calendarIconView.contentMode = .scaleAspectFit
        calendarIconView.tintColor = BearyColors.gray
        pickerRow.addArrangedSubview(calendarIconView)
        pickerRow.addArrangedSubview(yearLabel)
        let pickerSpacer = UIView()
        pickerSpacer.translatesAutoresizingMaskIntoConstraints = false
        pickerRow.addArrangedSubview(pickerSpacer)
        pickerRow.addArrangedSubview(prevYearButton)
        pickerRow.addArrangedSubview(nextYearButton)
        NSLayoutConstraint.activate([
            calendarIconView.widthAnchor.constraint(equalToConstant: 16),
            calendarIconView.heightAnchor.constraint(equalToConstant: 16),
            prevYearButton.widthAnchor.constraint(equalToConstant: 44),
            prevYearButton.heightAnchor.constraint(equalToConstant: 44),
            nextYearButton.widthAnchor.constraint(equalToConstant: 44),
            nextYearButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        stack.addArrangedSubview(dynamicStack)
        renderSelectedYear()
    }

    private var scopeValue: BearyWordprintScope {
        return isOwnFlag ? .own : .other
    }

    /// [24] 小项 5：年报脚注唯一出处（空年与非空年共用，防两处文案漂移）。
    private func makeYearReviewFootnote() -> UILabel {
        let footnote = UILabel()
        footnote.numberOfLines = 0
        footnote.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        footnote.adjustsFontForContentSizeCategory = true
        footnote.textColor = BearyColors.gray
        footnote.text = "词汇指纹只按当年正文统计，不展示正文。今年先给这些，明年更完整。"
        return footnote
    }

    /// 当年聚合计算（摘要文案／心情分布）：纯计算，
    /// 结果进 yearAggregateCache，同一次打开内切回该年直接复用。
    private func yearAggregate(for yearEntriesValue: [Entry], year: Int, calendar: Calendar) -> YearReviewAggregate {
        // 总篇数 / 最长连续（当年）。
        var writtenDays = Set<Date>()
        for entry in yearEntriesValue {
            if let createdAt = entry.createdAt {
                let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
                writtenDays.insert(calendar.startOfDay(for: date))
            }
        }
        let longest = BearyProfilePersonalLogic.longestStreak(writtenDays: writtenDays, calendar: calendar)
        let summary = "\(year) 年共写 \(yearEntriesValue.count) 篇 · 最长连续 \(longest) 天"
        return YearReviewAggregate(
            summaryText: summary,
            moodDistribution: BearyProfilePersonalLogic.moodDistribution(entries: yearEntriesValue)
        )
    }

    /// 恢复当前年的阅读位置：有记录回上次离开处，无记录回顶部；
    /// 超出内容高度时夹到可滚范围；记下本次恢复到的偏移，供词汇指纹
    /// 后到回调判断用户是否已滚动（见 wordprint 回调）。
    private func restoreYearScrollOffset() {
        view.layoutIfNeeded()
        let savedOffset = yearScrollOffsets[selectedYear] ?? 0
        let maxOffset = max(0, contentScrollView.contentSize.height - contentScrollView.bounds.height)
        let targetOffset = min(max(savedOffset, 0), maxOffset)
        contentScrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        yearRestoreAppliedOffset = targetOffset
    }

    /// 切年渲染。slideDirection：摘要首次移入方向（-1 = 左箭头进更早的年，
    /// 从左来；+1 = 右箭头进更晚的年，从右来；0 = 不滑入，如首次打开）。
    /// 摘要只在首次进入另一年时滑入；切回看过的年份走位置恢复，不再滑入。
    private func renderSelectedYear(slideDirection: CGFloat = 0) {
        // 代次先 +1：空年提前返回的分支同样作废在途旧请求，旧词行
        // 绝不插进新年的栈。
        wordprintRequest += 1
        let request = wordprintRequest
        yearRestoreAppliedOffset = nil
        titleLabel.text = "\(selectedYear) 年度回顾"
        yearLabel.text = "\(selectedYear) 年"
        // 只有一年时整行选择器隐藏（年份已在标题里）；多年前后箭头按年份数组
        // 下标走，不按 year ± 1 算——缺少年份时 ± 1 会指到空年。
        pickerRow.isHidden = availableYearValues.count <= 1
        if let index = availableYearValues.firstIndex(of: selectedYear) {
            // 数组降序：左箭头 = 前一年（更早，下标 +1），右箭头 = 后一年（更晚，下标 -1）。
            prevYearButton.isEnabled = index + 1 < availableYearValues.count
            nextYearButton.isEnabled = index > 0
        } else {
            prevYearButton.isEnabled = false
            nextYearButton.isEnabled = false
        }
        prevYearButton.alpha = prevYearButton.isEnabled ? 1 : 0.3
        nextYearButton.alpha = nextYearButton.isEnabled ? 1 : 0.3

        // 先清空再重建：旧年词行、心情条、摘要绝不残留到新年。
        for arrangedView in dynamicStack.arrangedSubviews {
            dynamicStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }

        let calendar = Calendar.current
        let yearEntriesValue = BearyProfilePersonalLogic.yearEntries(entries: filteredEntries, year: selectedYear, calendar: calendar)
        guard !yearEntriesValue.isEmpty else {
            dynamicStack.addArrangedSubview(bearyMakeWordprintScopeBadge(scope: scopeValue))
            let emptyLabel = UILabel()
            emptyLabel.numberOfLines = 0
            emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
            emptyLabel.adjustsFontForContentSizeCategory = true
            emptyLabel.textColor = BearyColors.gray
            emptyLabel.text = "这一年还没有日记"
            dynamicStack.addArrangedSubview(emptyLabel)
            // [24] 小项 5：空年分支原先没有脚注，只剩口径徽标行；补与非空年
            // 同一条脚注（同文案、同字号同灰色，见 makeYearReviewFootnote），
            // 避免空年页丢了页脚口径说明。
            dynamicStack.addArrangedSubview(makeYearReviewFootnote())
            // 空年同样恢复该年上次的位置（无聚合结果可缓存，只恢复偏移）。
            restoreYearScrollOffset()
            return
        }

        // 主视觉词汇指纹不在此处同步算（NLTokenizer 逐篇分词会卡住
        // 年份按钮事件）：其余各节先同步建好，词行在函数末尾后台请求，
        // 算完插回栈顶——最终顺序与同步版一致（词行在摘要之上）。
        // 同一次打开内切回看过的年份：聚合结果直接取缓存，不重算；
        // 首次进入才算并写入缓存（词汇指纹另有自己的静态缓存，不在此处）。
        let isFirstEntryToYear = yearAggregateCache[selectedYear] == nil
        let aggregate: YearReviewAggregate
        if let cached = yearAggregateCache[selectedYear] {
            aggregate = cached
        } else {
            let computed = yearAggregate(for: yearEntriesValue, year: selectedYear, calendar: calendar)
            yearAggregateCache[selectedYear] = computed
            aggregate = computed
        }
        let summaryLabel = UILabel()
        summaryLabel.numberOfLines = 0
        summaryLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = BearyColors.ink
        summaryLabel.text = aggregate.summaryText
        dynamicStack.addArrangedSubview(summaryLabel)
        // 首次进入另一年：摘要按切换方向短距移入 0.25 秒（左箭头进更早的年
        // 从左来、右箭头进更晚的年从右来）；切回看过的年份走位置恢复，
        // 不再滑入；首次打开与减动效直接落位。
        if slideDirection != 0, isFirstEntryToYear,
           !UIAccessibility.isReduceMotionEnabled, summaryLabel.window != nil {
            summaryLabel.transform = CGAffineTransform(translationX: slideDirection * 16, y: 0)
            summaryLabel.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                summaryLabel.transform = .identity
                summaryLabel.alpha = 1
            })
        }

        // 心情分布（条形按最大值归一，纯 UIView，不引图表库）。
        let distribution = aggregate.moodDistribution
        if let maxCount = distribution.first?.count, maxCount > 0 {
            let moodTitle = UILabel()
            moodTitle.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))
            moodTitle.adjustsFontForContentSizeCategory = true
            moodTitle.textColor = BearyColors.ink
            moodTitle.text = "心情分布"
            dynamicStack.addArrangedSubview(moodTitle)
            for item in distribution.prefix(8) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.alignment = .center
                let nameLabel = UILabel()
                nameLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                nameLabel.adjustsFontForContentSizeCategory = true
                nameLabel.textColor = BearyColors.ink
                nameLabel.text = BearyText.moodNames[item.key] ?? item.key
                // R7-4：名称按内容自然定宽（原 64pt 必需宽在大字号下会截断）；
                // 进度条留一条最小宽兜底，避免大字号名称把它挤到零宽。
                let barBackground = UIView()
                barBackground.backgroundColor = BearyColors.surface2
                barBackground.layer.cornerRadius = 4
                barBackground.clipsToBounds = true
                let barFill = UIView()
                barFill.translatesAutoresizingMaskIntoConstraints = false
                barFill.backgroundColor = BearyColors.orange
                barBackground.addSubview(barFill)
                NSLayoutConstraint.activate([
                    barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
                    barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
                    barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
                    barFill.widthAnchor.constraint(equalTo: barBackground.widthAnchor, multiplier: CGFloat(item.count) / CGFloat(maxCount)),
                ])
                barBackground.heightAnchor.constraint(equalToConstant: 8).isActive = true
                barBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
                let countLabel = UILabel()
                countLabel.font = BearyDynamicType.numberFont()
                countLabel.textColor = BearyColors.gray
                countLabel.text = "\(item.count)"
                row.addArrangedSubview(nameLabel)
                row.addArrangedSubview(barBackground)
                row.addArrangedSubview(countLabel)
                dynamicStack.addArrangedSubview(row)
            }
        }

        dynamicStack.addArrangedSubview(makeYearReviewFootnote())

        // 词汇指纹后台算：指纹与分词都在后台，命中 / 未命中一律回主线程
        // 一次性插回栈顶，最终顺序与同步版一致。代次 + 年份双重守卫，
        // 旧年结果不得覆盖新年。
        let year = selectedYear
        BearyProfilePersonalLogic.wordprintAsync(
            accountKey: wordprintAccountKey,
            entries: filteredEntries,
            year: year,
            isOwn: isOwnFlag,
            calendar: calendar
        ) { [weak self] wordprintValue in
            guard let self = self,
                  self.wordprintRequest == request,
                  self.selectedYear == wordprintValue.year else { return }
            // 栈顶插入会把下方内容顶下去：先插行，再按插入高度补偿，
            // 阅读锚点不动。恢复是否已跑过决定补法——
            // · 同步插回（缓存命中、恢复未跑）：不补，渲染末尾的恢复
            //   会按完整内容一次到位；
            // · 异步后到（恢复已跑）且用户未滚动：按完整内容重算该年
            //   保存的位置（插前恢复值在短内容上可能被夹过）；
            // · 异步后到且用户已滚动：只补插入高度，保住当前阅读行。
            let insertedRow: UIView
            if !wordprintValue.items.isEmpty {
                self.wordprintView.configure(with: wordprintValue, scope: self.scopeValue)
                insertedRow = self.wordprintView
            } else {
                // 无词时整节省略，只留口径行（与同步版一致）。
                insertedRow = bearyMakeWordprintScopeBadge(scope: self.scopeValue)
            }
            self.dynamicStack.insertArrangedSubview(insertedRow, at: 0)
            self.view.layoutIfNeeded()
            let insertedHeight = insertedRow.frame.height + self.dynamicStack.spacing
            if let restoredOffset = self.yearRestoreAppliedOffset {
                if self.contentScrollView.contentOffset.y == restoredOffset {
                    let savedOffset = self.yearScrollOffsets[self.selectedYear] ?? 0
                    let maxOffset = max(0, self.contentScrollView.contentSize.height - self.contentScrollView.bounds.height)
                    let targetOffset = min(max(savedOffset, 0), maxOffset)
                    self.contentScrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
                    self.yearRestoreAppliedOffset = targetOffset
                } else {
                    let maxOffset = max(0, self.contentScrollView.contentSize.height - self.contentScrollView.bounds.height)
                    let compensatedOffset = min(self.contentScrollView.contentOffset.y + insertedHeight, maxOffset)
                    self.contentScrollView.contentOffset.y = compensatedOffset
                    self.yearRestoreAppliedOffset = compensatedOffset
                }
            }
            // 词行单独淡入（减动效或尚未上屏时直接显形）；与偏移补偿互不干扰。
            if UIAccessibility.isReduceMotionEnabled || insertedRow.window == nil {
                insertedRow.alpha = 1
            } else {
                insertedRow.alpha = 0
                UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                    insertedRow.alpha = 1
                })
            }
        }

        // 切回看过的年份恢复上次阅读位置；首次进入的年份回到顶部。
        // 词汇指纹若已同步插回（缓存命中），此时内容已完整，直接一次到位；
        // 若还在后台算，回调里再按锚点补一次，见上。
        restoreYearScrollOffset()
    }

    @objc private func prevYearTapped() {
        guard let index = availableYearValues.firstIndex(of: selectedYear),
              index + 1 < availableYearValues.count else { return }
        // 切走前存下当年的阅读位置，同一次打开内切回时恢复。
        yearScrollOffsets[selectedYear] = contentScrollView.contentOffset.y
        selectedYear = availableYearValues[index + 1]
        renderSelectedYear(slideDirection: -1)
    }

    @objc private func nextYearTapped() {
        guard let index = availableYearValues.firstIndex(of: selectedYear),
              index > 0 else { return }
        // 切走前存下当年的阅读位置，同一次打开内切回时恢复。
        yearScrollOffsets[selectedYear] = contentScrollView.contentOffset.y
        selectedYear = availableYearValues[index - 1]
        renderSelectedYear(slideDirection: 1)
    }

    private func presentWordDetail(item: BearyProfilePersonalLogic.WordprintItem) {
        guard presentedViewController == nil else { return }
        let detail = BearyWordprintDetailViewController(item: item, year: selectedYear, scope: scopeValue)
        detail.modalPresentationStyle = .pageSheet
        present(detail, animated: BearyMotion.animated(true), completion: nil)
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

// MARK: - 模块卡片容器（与墙同口径：圆角 14、1px 边线、标题 14 粗体）
//
// 调用方（ProfileVC）只负责把卡片排进 modulesStack 并按显隐开关 isHidden；
// 卡片自身不决定可见性（可见性由语料口径定，见 renderModules）。

final class BearyProfilePersonalModulesCard: UIView {

    /// 05：VoiceOver 激活回调（统计卡：等价于点按整卡进年度回顾，由调用方注入；
    /// 其余卡不设，走默认行为）。UIView 的 accessibilityActivate 在此转发，
    /// 调用方无需为卡片另建子类。
    var accessibilityActivateHandler: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        if let handler = accessibilityActivateHandler {
            return handler()
        }
        return super.accessibilityActivate()
    }

    let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        return stack
    }()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = BearyColors.surface1
        layer.borderWidth = 0
        layer.cornerRadius = BearyCorners.single
        clipsToBounds = true
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = title
        contentStack.addArrangedSubview(titleLabel)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // 04：四工厂全部改走 Dynamic Type 入口，字号数值一字不动。
    // 12 / 15 有现成同值语义入口（captionFont / smallBodyFont）；16 bold
    // 无同值语义入口，走卡片标题同款 scaledFont 保字号不变（不用 16.5 的
    // cardTitleFont，避免悄悄改字号）。label 侧一律配
    // adjustsFontForContentSizeCategory，字号档变化时自动跟随。
    static func statValueLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        return label
    }

    static func statKeyLabel(text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.captionFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.text = text
        return label
    }

    static func metaLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.captionFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        return label
    }

    static func entryTitleLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.numberOfLines = 0
        return label
    }

    static func bodyLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.smallBodyFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.numberOfLines = 0
        return label
    }
}

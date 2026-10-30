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
// - 年度回顾入口只本人可见；常出现的词并入年报首屏示意（点进后），不单独成卡，
//   故词统计只走本人全口径，不存在他人页公开口径词表。
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

    /// 本人：全部非占位日记（公开 + 私密）；他人：仅 isPublic == true。
    /// 草稿 / 回收站条目服务端 author scope 本就不下发；本地若混入无 id 条目一律排除。
    static func visibleEntries(_ entries: [Entry], isOwn: Bool) -> [Entry] {
        entries.filter { entry in
            guard let id = entry.id, !id.isEmpty else { return false }
            guard entry.placeholder != true else { return false }
            if isOwn { return true }
            return entry.isPublic == true
        }
    }

    /// 本地日（Calendar.current，设备时区）起点的 Date，用作 streak / 月历去重键。
    static func startOfDay(for timestampMs: Int, calendar: Calendar) -> Date? {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        return calendar.startOfDay(for: date)
    }

    // MARK: - 情绪月历

    struct MonthDay {
        var day: Int
        /// 当天代表心情：当天有心情的条目里创建时间最晚的那篇的心情；当天无心情条目时为 nil
        /// （当天仍有日记可点，只是无心情图）。
        var moodKey: String?
        /// 当天全部条目（createdAt 降序），点按取首篇 = 当天最晚一篇。
        var entries: [Entry]
    }

    struct MonthGrid {
        /// 周一起始的月历：1 号前空白格数（0...6）。
        var leadingBlanks: Int
        var days: [MonthDay]
    }

    static func monthGrid(year: Int, month: Int, entries: [Entry], calendar: Calendar) -> MonthGrid {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let firstDay = calendar.date(from: components),
              let dayCount = calendar.range(of: .day, in: .month, for: firstDay)?.count else {
            return MonthGrid(leadingBlanks: 0, days: [])
        }
        // weekday: 1 = 周日 … 7 = 周六；周一起始时 1 号前空白 = (weekday + 5) % 7。
        let weekday = calendar.component(.weekday, from: firstDay)
        let leadingBlanks = (weekday + 5) % 7
        var byDay: [Int: [Entry]] = [:]
        for entry in entries {
            guard let createdAt = entry.createdAt else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard parts.year == year, parts.month == month, let day = parts.day else { continue }
            byDay[day, default: []].append(entry)
        }
        var days: [MonthDay] = []
        for day in 1...dayCount {
            var dayEntries = byDay[day] ?? []
            // createdAt 降序：点按取首篇即当天最晚一篇；代表心情取同序首个有心情者。
            dayEntries.sort { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
            let moodKey = dayEntries.first(where: { ($0.mood ?? "").isEmpty == false })?.mood
            days.append(MonthDay(day: day, moodKey: moodKey, entries: dayEntries))
        }
        return MonthGrid(leadingBlanks: leadingBlanks, days: days)
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

    /// 常出现的词：当年正文走系统 NLTokenizer（zh-Hans，词单位）分词；
    /// 过滤停用词 / 标点 / 单字 / 纯数字 / emoji；同一篇内重复按实际次数计；
    /// 按次数倒序取前 10，平手按首次出现顺序（稳定）。不做词云。
    /// 注意：NLTokenizer 是设备端分词，无网络、无新依赖；分词质量以系统为准，
    /// 不自写二元切分（自写切分会把「秋天」切成「秋」「天」或拼出不存在的词）。
    static func frequentWords(entries: [Entry], limit: Int = 10) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        for entry in entries {
            guard let content = entry.content, !content.isEmpty else { continue }
            tokenizer.string = content
            tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
                let token = String(content[range])
                order += 1
                guard isCountableWord(token) else { return true }
                if firstSeen[token] == nil { firstSeen[token] = order }
                counts[token, default: 0] += 1
                return true
            }
        }
        return counts.map { (word: $0.key, count: $0.value) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return (firstSeen[$0.word] ?? 0) < (firstSeen[$1.word] ?? 0)
        }.prefix(limit).map { $0 }
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
}

// MARK: - 年报首屏示意（点年度回顾入口后呈现；年报本身年底另做）
//
// 只本人可见（入口卡只本人渲染，故本页不可达他人态）。内容全部来自调用方
// 传入的当年可见条目，不拉新接口：总篇数 / 最长连续 / 第一篇日期 / 心情分布
// / 常出现的词。无词时词一节整节省略（不留空标题）。

final class BearyYearReviewViewController: UIViewController {

    private let year: Int
    private let entries: [Entry]

    init(year: Int, entries: [Entry]) {
        self.year = year
        self.entries = entries
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 20), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        view.addSubview(closeButton)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        let calendar = Calendar.current
        let titleLabel = UILabel()
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .heavy)
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "\(year) 年度回顾"
        stack.addArrangedSubview(titleLabel)

        // 总篇数 / 最长连续 / 第一篇。
        var writtenDays = Set<Date>()
        for entry in entries {
            if let createdAt = entry.createdAt {
                let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000)
                writtenDays.insert(calendar.startOfDay(for: date))
            }
        }
        let longest = BearyProfilePersonalLogic.longestStreak(writtenDays: writtenDays, calendar: calendar)
        let first = entries.min(by: { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) })
        let summaryLabel = UILabel()
        summaryLabel.numberOfLines = 0
        summaryLabel.font = UIFont.systemFont(ofSize: 15)
        summaryLabel.textColor = BearyColors.ink
        var summary = "今年已写 \(entries.count) 篇 · 最长连续 \(longest) 天"
        if let firstCreatedAt = first?.createdAt {
            let date = Date(timeIntervalSince1970: TimeInterval(firstCreatedAt) / 1000)
            let parts = calendar.dateComponents([.month, .day], from: date)
            if let month = parts.month, let day = parts.day {
                summary += "\n第一篇：\(month) 月 \(day) 日"
            }
        }
        summaryLabel.text = summary
        stack.addArrangedSubview(summaryLabel)

        // 心情分布（条形按最大值归一，纯 UIView，不引图表库）。
        let distribution = BearyProfilePersonalLogic.moodDistribution(entries: entries)
        if let maxCount = distribution.first?.count, maxCount > 0 {
            let moodTitle = UILabel()
            moodTitle.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            moodTitle.textColor = BearyColors.ink
            moodTitle.text = "心情分布"
            stack.addArrangedSubview(moodTitle)
            for item in distribution.prefix(8) {
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 8
                row.alignment = .center
                let nameLabel = UILabel()
                nameLabel.font = UIFont.systemFont(ofSize: 13)
                nameLabel.textColor = BearyColors.ink
                nameLabel.text = BearyText.moodNames[item.key] ?? item.key
                nameLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
                let barBackground = UIView()
                barBackground.backgroundColor = BearyColors.faint
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
                let countLabel = UILabel()
                countLabel.font = UIFont.systemFont(ofSize: 13)
                countLabel.textColor = BearyColors.gray
                countLabel.text = "\(item.count)"
                row.addArrangedSubview(nameLabel)
                row.addArrangedSubview(barBackground)
                row.addArrangedSubview(countLabel)
                stack.addArrangedSubview(row)
            }
        }

        // 常出现的词（词 + 次数小列表，不做词云；无词时整节省略）。
        let words = BearyProfilePersonalLogic.frequentWords(entries: entries)
        if !words.isEmpty {
            let wordsTitle = UILabel()
            wordsTitle.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            wordsTitle.textColor = BearyColors.ink
            wordsTitle.text = "常出现的词"
            stack.addArrangedSubview(wordsTitle)
            for item in words {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .equalSpacing
                let wordLabel = UILabel()
                wordLabel.font = UIFont.systemFont(ofSize: 14)
                wordLabel.textColor = BearyColors.ink
                wordLabel.text = item.word
                let countLabel = UILabel()
                countLabel.font = UIFont.systemFont(ofSize: 14)
                countLabel.textColor = BearyColors.gray
                countLabel.text = "\(item.count) 次"
                row.addArrangedSubview(wordLabel)
                row.addArrangedSubview(countLabel)
                stack.addArrangedSubview(row)
            }
        }

        let footnote = UILabel()
        footnote.numberOfLines = 0
        footnote.font = UIFont.systemFont(ofSize: 12)
        footnote.textColor = BearyColors.gray
        footnote.text = "完整年度报告年底另做，这里只是今年至今的首屏示意。"
        stack.addArrangedSubview(footnote)
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }
}

// MARK: - 模块卡片容器（与墙 / 徽章架同口径：圆角 14、1px 边线、标题 14 粗体）
//
// 调用方（ProfileVC）只负责把卡片排进 modulesStack 并按显隐开关 isHidden；
// 卡片自身不决定可见性（可见性由语料口径定，见 renderModules）。

final class BearyProfilePersonalModulesCard: UIView {

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
        backgroundColor = BearyColors.bg
        layer.borderWidth = 1
        layer.borderColor = BearyColors.line.cgColor
        layer.cornerRadius = 14
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

    static func statValueLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        label.textColor = BearyColors.ink
        return label
    }

    static func statKeyLabel(text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = BearyColors.gray
        label.text = text
        return label
    }

    static func metaLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = BearyColors.gray
        return label
    }

    static func entryTitleLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        label.textColor = BearyColors.ink
        label.numberOfLines = 0
        return label
    }

    static func bodyLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = BearyColors.ink
        label.numberOfLines = 0
        return label
    }
}

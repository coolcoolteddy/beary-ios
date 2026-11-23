import Foundation

// ===== 日记星图 · 纯逻辑（2026-10-30；预览：日记星图屏）=====
// 本文件只依赖 Entry（BearyAPI.swift）与 Foundation，不依赖 UIKit、
// 不依赖 BearyNativeCommon / BearyLocation / SessionManager——
// 因此可同时编进 App target 与 BearyCoreTests target，单测直接覆盖。
// UI（BearyDiaryStarMapViewController）只渲染本文件算出的模型，不自算过滤与连线。
//
// 口径（与预览一致，偏离处有注）：
// - 星：过滤后每篇一篇。大小 = 字数，亮度固定，位置 = 日记 id 确定性哈希
//   初值经力导向松弛（见 relaxedPositions；2.5D 第 1 支，取代纯哈希定点）。
// - 连线：同地点 / 同词，两者可并存于一对篇之间（一条边带多条原因）。
// - 他人视角 fail-closed：过滤与连线都在过滤后的集合上算，私密篇连同它的
//   连线一并消失；他人地点键只用区级，精确名永远不作兜底、不进原因文案。
// - 草稿与回收站篇不进：数据源是作者日记列表（已发布篇），本文件不再二次区分。
// - “同词”无服务端关键词字段：由标题 + 正文现场派生（见 keywords 注释），
//   是近似匹配不是分词，原因文案只展示共享词本身，不展示正文。

/// 星图边的原因种类（过滤 chips 与原因文案共用）。
/// tag = 日记–标签边（2.5D 第 2 支）：detail 为标签名，一端是日记 id、
/// 一端是标签节点 id（"tag:" + 标签名），不进连线列表（见 VC listedEdges）。
enum StarMapEdgeKind: String {
    case place
    case word
    case tag
}

/// 一条连线原因。detail 的含义按 kind 而定：place = 地点键，
/// word = ""（共享词放 tokens）。展示层据此翻译成中文，纯逻辑层不绑
/// BearyText（BearyNativeCommon 不进测试 target），避免测试 target 依赖膨胀。
struct StarMapEdgeReason: Equatable {
    let kind: StarMapEdgeKind
    /// place 的键；word 时为空串。
    let detail: String
    /// word 时的共享词（已按字符串排序、展示层再截断）；其余 kind 为空。
    let tokens: [String]
}

/// 节点分级（2.5D 第 2 支）：锚点（置顶＋连接数前 3）／标签节点／普通日记。
/// 锚点仍是日记星（StarMapStar.kind），标签节点另建 StarMapTagNode。
enum StarMapNodeKind: String {
    case anchor
    case tag
    case diary
}

/// 一颗星：位置是 0...1 归一化坐标（渲染层按 sky bounds + 边距换算成 pt，
/// 同一篇在任何尺寸、任何分片里都落在同一相对位置，不随机飘）。
struct StarMapStar {
    let entry: Entry
    let x: Double
    let y: Double
    /// 半径 pt：普通日记 6...20（字数），锚点固定 15（见 anchorRadius）。
    let radius: CGFloat
    /// 亮度固定 0.70（心情已去掉，不再按心情分档）。
    let brightness: CGFloat
    let wordCount: Int
    /// 分级：锚点／普通日记（标签节点不在此 struct，见 StarMapTagNode）。
    let kind: StarMapNodeKind
}

/// 一个标签节点（2.5D 第 2 支）：一标签一节点，位置取挂载篇的星位质心，
/// 大小按挂载篇数（见 radius(forTagCount:)）。id 固定 "tag:" + 标签名，
/// 与日记–标签边的端点、渲染层 pointsById 共用同一命名。
struct StarMapTagNode {
    let name: String
    let count: Int
    let x: Double
    let y: Double
    /// 半径 pt：9...18，见 radius(forTagCount:)。
    let radius: CGFloat

    var id: String { "tag:" + name }
}

/// 一条边：连接两篇（firstId < secondId 字典序，作稳定边 id 用），
/// 或一篇日记与一个标签节点（tag 边：firstId < secondId 同样字典序，
/// 一端是日记 id、一端是 "tag:" + 标签名）。
struct StarMapEdge {
    let firstId: String
    let secondId: String
    let reasons: [StarMapEdgeReason]

    var id: String { firstId + "|" + secondId }
}

/// 星空模型：stars 与 edges 只含过滤后的篇；entryById 供点星/点线后取详情用。
/// tagNodes 是过滤后集合的标签节点（2.5D 第 2 支）；edges 含日记–日记边
/// （地点／同词）与日记–标签边（tag 原因）。
struct StarMapModel {
    let stars: [StarMapStar]
    let edges: [StarMapEdge]
    let entryById: [String: Entry]
    let tagNodes: [StarMapTagNode]
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

    /// 缓存键用分片键（与展示标题解耦，标题文案改了不使缓存失效）。
    var cacheKey: String {
        switch self {
        case .all: return "all"
        case .year(let y): return "year-\(y)"
        case .month(let y, let m): return "month-\(y)-\(m)"
        case .undated: return "undated"
        }
    }
}

enum BearyStarMap {

    /// 分片阈值：过滤后总数 ≤ 该值时不分片、直接画全部；超过则强制按年/月分片，
    /// 不提供“全部”选项（不一次性铺全量；年内全年仍受 500 篇拉取上限约束，见 VC）。
    static let sliceThreshold = 80

    /// 建模算法版本：buildModel / 过滤 / 关键词 / 地点键任一口径改了即 +1，
    /// 旧缓存键随之失效，不用手动清盘。缓存键里只认本值，不认 App 版本号。
    /// 3（2.5D 第 2 支）：指纹加 tags＋pinned，节点三级分化＋标签节点。
    static let algorithmVersion = 3

    /// 日记版本指纹：分片内可见篇的建模输入摘要。覆盖 buildModel 消费的
    /// 全部字段——过滤（id / 占位 / 公开态 / 限时到期 / 标题 / 正文 /
    /// 图片 / 引用）、字数（标题 / 正文）、地点键
    /// （精确名 / 区级）、同词（标题 / 正文）与分片归属（createdAt），
    /// 另含 viewer 角色（本人 / 他人地点键与过滤口径不同），
    /// 以及 2.5D 第 2 支新增的标签（tags，排序后拼串）与置顶（pinned，
    /// 锚点判定输入）。标签／置顶变了即整片重建。
    /// 改正文会改整片的词频与文档频率上限，故指纹按整片算，不按单篇失效：
    /// 片内任一篇改了即整片重建。篇按 id 排序后再拼串，同一集合换顺序
    /// 指纹不变；空片指纹固定（空串哈希），不与任何有篇片撞键。
    static func diaryVersion(entries: [Entry], viewerIsAuthor: Bool) -> String {
        let visible = visibleEntries(entries, viewerIsAuthor: viewerIsAuthor)
            .sorted { ($0.id ?? "") < ($1.id ?? "") }
        var joined = viewerIsAuthor ? "own|" : "other|"
        joined += "n=\(visible.count)|"
        for entry in visible {
            let pub: String
            switch entry.isPublic {
            case true: pub = "1"
            case false: pub = "0"
            case nil: pub = "?"
            }
            joined += (entry.id ?? "")
                + "\u{1}" + (entry.title ?? "")
                + "\u{1}" + (entry.content ?? "")
                + "\u{1}" + (entry.locationName ?? "")
                + "\u{1}" + (entry.locationDistrict ?? "")
                + "\u{1}" + pub
                + "\u{1}" + (entry.visibility ?? "")
                + "\u{1}" + String(entry.ephemeralUntil ?? -1)
                + "\u{1}" + String(entry.createdAt ?? -1)
                + "\u{1}" + (entry.images ?? []).joined(separator: ",")
                + "\u{1}" + (entry.quoteId ?? "")
                + "\u{1}" + (entry.placeholder == true ? "1" : "0")
                + "\u{1}" + (entry.tags ?? []).sorted().joined(separator: ",")
                + "\u{1}" + String(entry.pinned ?? 0)
                + "\u{2}"
        }
        return String(format: "%016llx", fnv1a(joined))
    }

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

    /// 锚点半径 pt：固定 15（预览锚点 r=15，约 30pt 直径；光晕另见渲染层 28pt）。
    static let anchorRadius: CGFloat = 15

    /// 标签节点半径 pt：8 + 挂载篇数，上限 18（1 篇 → 9，10 篇及以上 → 18；
    /// 预览标签固定 12，本支按任务口径改为随篇数长大）。
    static func radius(forTagCount count: Int) -> CGFloat {
        8 + min(10, CGFloat(max(0, count)))
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
    /// 力导向布局的初值（见 relaxedPositions），不再直接作最终星位。
    static func position(forEntryId id: String) -> (x: Double, y: Double) {
        let x = Double(fnv1a(id) % 1000) / 1000.0
        let y = Double(fnv1a(id + "|star-y") % 1000) / 1000.0
        return (x, y)
    }

    // MARK: - 力导向布局（2.5D 第 1 支；纯逻辑，可进测试 target）

    /// 力导向松弛：以 id 哈希位为初值，在 0...1 归一化平面上做确定性松弛。
    /// - 步进在 recompute 的后台队列（userInitiated）里整段跑完，主线程只渲染
    ///   终态，不逐帧重绘、不逐帧回主线程。
    /// - 收敛即停：一步内全部星的最大位移 < 0.5pt（按 360pt 画布折算，
    ///   归一化 ≈ 0.0014）即停模拟、停重绘；上限 80 步。
    /// - 力：全部星对互斥（Fruchterman-Reingold，k = sqrt(1/n)）；连线边作
    ///   弹簧（强度为互斥的一半，簇内聚而不塌）；另有弱中心引力防飘出；
    ///   步长带温度冷却（0.05 起、每步 ×0.95）。
    /// - 迭代顺序按 id 排序固定，无随机数：同输入同输出。星位是同一批
    ///   建模输入（id、连线）的纯函数，指纹（diaryVersion）不变即输出不变，
    ///   故本次布局改动不升 algorithmVersion（缓存只在内存、不落盘，
    ///   不跨版本复用；2→3 留给第 2 支的指纹＋节点模型改动）。
    /// - 距离为 0 的星对按下标奇偶给确定性微扰，不除零、不随机。
    static func relaxedPositions(
        for entries: [Entry],
        edges: [StarMapEdge],
        viewerIsAuthor: Bool
    ) -> [String: (x: Double, y: Double)] {
        let visible = visibleEntries(entries, viewerIsAuthor: viewerIsAuthor)
        let ids = visible.compactMap { $0.id }.sorted()
        guard ids.count > 1 else {
            var single: [String: (x: Double, y: Double)] = [:]
            for id in ids { single[id] = position(forEntryId: id) }
            return single
        }
        let n = Double(ids.count)
        let k = (1.0 / n).squareRoot()
        let stopThreshold = 0.5 / 360.0
        let maxIterations = 80
        var pos: [String: (x: Double, y: Double)] = [:]
        for id in ids { pos[id] = position(forEntryId: id) }
        var temperature = 0.05
        for _ in 0..<maxIterations {
            var disp: [String: (x: Double, y: Double)] = [:]
            for id in ids { disp[id] = (x: 0, y: 0) }
            // 互斥：全部星对（O(n²)，n ≤ 500 拉取上限）。
            for i in ids.indices {
                for j in ids.indices where j > i {
                    let a = ids[i]
                    let b = ids[j]
                    guard let pa = pos[a], let pb = pos[b] else { continue }
                    var dx = pa.x - pb.x
                    var dy = pa.y - pb.y
                    var dist2 = dx * dx + dy * dy
                    if dist2 < 1e-12 {
                        dx = (i % 2 == 0) ? 0.001 : -0.001
                        dy = (j % 2 == 0) ? 0.0007 : -0.0007
                        dist2 = dx * dx + dy * dy
                    }
                    let dist = dist2.squareRoot()
                    let force = (k * k) / dist
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    disp[a] = (x: (disp[a]?.x ?? 0) + fx, y: (disp[a]?.y ?? 0) + fy)
                    disp[b] = (x: (disp[b]?.x ?? 0) - fx, y: (disp[b]?.y ?? 0) - fy)
                }
            }
            // 弹簧：连线边相吸（强度减半），同簇收拢。
            for edge in edges {
                guard let pa = pos[edge.firstId], let pb = pos[edge.secondId] else { continue }
                let dx = pa.x - pb.x
                let dy = pa.y - pb.y
                let dist = (dx * dx + dy * dy).squareRoot()
                guard dist > 1e-9 else { continue }
                let force = (dist * dist) / k * 0.5
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                disp[edge.firstId] = (x: (disp[edge.firstId]?.x ?? 0) - fx, y: (disp[edge.firstId]?.y ?? 0) - fy)
                disp[edge.secondId] = (x: (disp[edge.secondId]?.x ?? 0) + fx, y: (disp[edge.secondId]?.y ?? 0) + fy)
            }
            // 弱中心引力 + 步长封顶（温度）+  clamp 到画布边距内。
            var maxMove = 0.0
            for id in ids {
                guard var p = pos[id] else { continue }
                var dx = (disp[id]?.x ?? 0) + (0.5 - p.x) * 0.02
                var dy = (disp[id]?.y ?? 0) + (0.5 - p.y) * 0.02
                let len = (dx * dx + dy * dy).squareRoot()
                if len > temperature {
                    dx = dx / len * temperature
                    dy = dy / len * temperature
                }
                p.x = max(0.02, min(0.98, p.x + dx))
                p.y = max(0.02, min(0.98, p.y + dy))
                pos[id] = p
                maxMove = max(maxMove, (dx * dx + dy * dy).squareRoot())
            }
            if maxMove < stopThreshold { break }
            temperature *= 0.95
        }
        return pos
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
        // 文档频率：词 → 含该词的篇数（只在过滤后集合上算）。
        var docFreq: [String: Int] = [:]
        var keywordsById: [String: Set<String>] = [:]
        for entry in visible {
            guard let id = entry.id else { continue }
            let keys = keywords(entry)
            keywordsById[id] = keys
            for key in keys { docFreq[key, default: 0] += 1 }
        }
        // 地点键：逐对循环内只做查表，不再每对重复 trim 与 placeKey
        //（r18 ㊳；关键词的 keywordsById / docFreq 早已预计算，不动）。
        var placeKeyById: [String: String] = [:]
        for entry in visible {
            guard let id = entry.id else { continue }
            if let place = placeKey(entry, viewerIsAuthor: viewerIsAuthor) {
                placeKeyById[id] = place
            }
        }
        let freqCap = max(2, visible.count / 2)
        var edges: [StarMapEdge] = []
        for i in visible.indices {
            for j in visible.indices where j > i {
                guard let a = visible[i].id, let b = visible[j].id else { continue }
                var reasons: [StarMapEdgeReason] = []
                if let placeA = placeKeyById[a],
                   let placeB = placeKeyById[b],
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
        // 力导向布局（2.5D 第 1 支）：星位不再是纯哈希定点——以哈希位为初值、
        // 以连线为弹簧做确定性松弛（后台队列内整段跑完，主线程只渲染终态）。
        // 星位仍由 id 与连线决定、不随机飘；同输入同输出（见 relaxedPositions）。
        // 松弛只用日记–日记边：标签节点尚未定位，不进弹簧。
        let relaxed = relaxedPositions(for: visible, edges: edges, viewerIsAuthor: viewerIsAuthor)
        // 标签节点（2.5D 第 2 支）：一标签一节点，位置取挂载篇的星位质心，
        // 大小按挂载篇数；无标签的篇不产生节点，空标签（0 篇）不进模型。
        var tagMembers: [String: [String]] = [:]
        for entry in visible {
            guard let id = entry.id else { continue }
            // 同篇内重复标签只记一次（服务端 tags 正常不重复，此处防脏数据）。
            var seenNames = Set<String>()
            for tag in entry.tags ?? [] {
                let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seenNames.insert(name).inserted else { continue }
                tagMembers[name, default: []].append(id)
            }
        }
        var tagNodes: [StarMapTagNode] = []
        for name in tagMembers.keys.sorted() {
            guard let memberIds = tagMembers[name], !memberIds.isEmpty else { continue }
            var sumX = 0.0
            var sumY = 0.0
            var counted = 0
            for id in memberIds {
                guard let p = relaxed[id] else { continue }
                sumX += p.x
                sumY += p.y
                counted += 1
            }
            guard counted > 0 else { continue }
            tagNodes.append(StarMapTagNode(
                name: name,
                count: memberIds.count,
                x: sumX / Double(counted),
                y: sumY / Double(counted),
                radius: radius(forTagCount: memberIds.count)
            ))
        }
        // 日记–标签连线（2.5D 第 2 支）：每篇连向自己的每个标签节点；
        // 端点字典序（firstId < secondId），与日记–日记边同一 id 口径。
        for entry in visible {
            guard let id = entry.id else { continue }
            var seenNames = Set<String>()
            for tag in entry.tags ?? [] {
                let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, tagMembers[name] != nil, seenNames.insert(name).inserted else { continue }
                let tagId = "tag:" + name
                let (first, second) = id < tagId ? (id, tagId) : (tagId, id)
                edges.append(StarMapEdge(
                    firstId: first,
                    secondId: second,
                    reasons: [StarMapEdgeReason(kind: .tag, detail: name, tokens: [])]
                ))
            }
        }
        // 锚点（2.5D 第 2 支；与预览同口径）：置顶篇（单槽位，取首篇）＋
        // 连接数前 3（不含置顶）；无置顶退纯 top 3。度数算全部边（地点／
        // 同词／标签边）的日记端点，同度数按 id 排序，稳定。只在可见篇里取。
        let visibleIds = Set(visible.compactMap { $0.id })
        var degree: [String: Int] = [:]
        for edge in edges {
            for endpoint in [edge.firstId, edge.secondId] where visibleIds.contains(endpoint) {
                degree[endpoint, default: 0] += 1
            }
        }
        let pinnedId = visible.first(where: { $0.isPinned })?.id
        let ranked = visible.compactMap { $0.id }.sorted { a, b in
            let da = degree[a] ?? 0
            let db = degree[b] ?? 0
            if da != db { return da > db }
            return a < b
        }
        var anchorIds: [String] = []
        if let pinnedId = pinnedId, !anchorIds.contains(pinnedId) { anchorIds.append(pinnedId) }
        for id in ranked where anchorIds.count < 4 && id != pinnedId {
            anchorIds.append(id)
        }
        let anchorSet = Set(anchorIds)
        var stars: [StarMapStar] = []
        for entry in visible {
            guard let id = entry.id else { continue }
            let count = wordCount(entry)
            let pos = relaxed[id] ?? position(forEntryId: id)
            let isAnchor = anchorSet.contains(id)
            stars.append(StarMapStar(
                entry: entry,
                x: pos.x,
                y: pos.y,
                radius: isAnchor ? anchorRadius : radius(forWordCount: count),
                brightness: 0.70,
                wordCount: count,
                kind: isAnchor ? .anchor : .diary
            ))
            entryById[id] = entry
        }
        return StarMapModel(stars: stars, edges: edges, entryById: entryById, tagNodes: tagNodes)
    }

    // MARK: - 差分（r17 M2；纯逻辑，可进测试 target）

    /// 两次模型间的差分：按星 id、边 id（firstId + "|" + secondId，字典序，
    /// 跨缓存复用仍稳定）比对。星位由 id 确定性哈希，旧星在两次模型里同位，
    /// 差分只决定“谁是新的、谁消失了”，不移动旧星。
    static func diff(old: StarMapModel?, new: StarMapModel) -> StarMapDiff {
        let oldStarIds = Set((old?.stars ?? []).compactMap { $0.entry.id })
        let newStarIds = Set(new.stars.compactMap { $0.entry.id })
        let oldEdgesById: [String: StarMapEdge] = (old?.edges ?? []).reduce(into: [:]) { $0[$1.id] = $1 }
        let newEdgesById: [String: StarMapEdge] = new.edges.reduce(into: [:]) { $0[$1.id] = $1 }
        let oldEdgeIds = Set(oldEdgesById.keys)
        let newEdgeIds = Set(newEdgesById.keys)
        // 同一条边只改理由（id 不变、reasons 变）：不算新线，调用方只更新
        // 底部理由文案，不重播入场。
        let changedEdgeIds = oldEdgeIds.intersection(newEdgeIds).filter {
            oldEdgesById[$0]?.reasons != newEdgesById[$0]?.reasons
        }.sorted()
        return StarMapDiff(
            newStarIds: newStarIds.subtracting(oldStarIds).sorted(),
            removedStarIds: oldStarIds.subtracting(newStarIds).sorted(),
            newEdgeIds: newEdgeIds.subtracting(oldEdgeIds).sorted(),
            removedEdgeIds: oldEdgeIds.subtracting(newEdgeIds).sorted(),
            changedEdgeIds: changedEdgeIds)
    }
}

/// 两次星图模型间的差分结果（r17 M2）。id 列表均已排序，调用方按序
/// 排入场节奏时顺序稳定；old 为 nil（首次建图）时全部星与边都是新的。
struct StarMapDiff {
    /// 新出现的星 id（按 id 排序，入场按此序错峰）。
    let newStarIds: [String]
    let removedStarIds: [String]
    /// 新出现的边 id（按 id 排序）。
    let newEdgeIds: [String]
    let removedEdgeIds: [String]
    /// id 不变、理由变了的边 id：只更新底部理由，不重播入场。
    let changedEdgeIds: [String]
}

// MARK: - 建图结果内存缓存（r17 C5；纯逻辑，Foundation only，可进测试 target）
//
// 只缓存近期访问过的范围（内存，不落盘）：
// - 键 = 账号桶 + 作者 + 角色 + 分片 + 日记版本 + 算法版本；任一分量变了
//   即 miss 重建。指纹不含天气、互动数等轻量字段，命中时 VC 按 id 从
//   最新日记重绑 Entry（见 rebindCachedModelEntries），不直接用旧副本。
//   切连线类型不走这里——
//   didTapFilterPill 只改 edgeFilter 后调 applyModelToSky，在已有
//   model.edges 上按 kind 过滤，模型本身不重建（见 VC）。
// - 冷开落盘未做：是否值得落盘（存星点与边的 ID、关系类型）待真机实测
//   建图耗时后再定；内存缓存已覆盖「本月 → 去年 → 本月」直接复用。
// - 退出 / 401 清理：SessionManager.purgeLocalSnapshotsForCurrentAccount
//   调 purge(viewerBucket:) 按账号桶清掉该账号的全部槽位；切账号不走
//   清理，旧桶保留、桶隔离防串号（与 BearyFeedCache 同口径）。
// - 容量：最近 4 个键，超了逐出最久未用；单模型 ≤ 500 星、边数有界，
//   内存占用可控。读写只在主线程发生（VC recompute / 建图回包），
//   仍加一把 NSLock，防以后有后台调用方。
enum BearyStarMapCache {
    static let maxEntries = 4

    private static let lock = NSLock()
    private static var memory: [String: StarMapModel] = [:]
    /// 最近使用顺序（队尾最新）；命中时移到队尾，超容时逐队首。
    private static var order: [String] = []

    /// 账号桶：当前查看者 id；游客为 "guest"。作者 id 与角色另拼进键，
    /// 同一查看者看不同作者的星图不撞键。
    static func accountKey(viewerId: Int?, authorId: Int, viewerIsAuthor: Bool) -> String {
        let viewerBucket = viewerId.map { "\($0)" } ?? "guest"
        return "\(viewerBucket)|\(authorId)|\(viewerIsAuthor ? "own" : "other")"
    }

    static func key(account: String, slice: StarMapSlice, diaryVersion: String, algorithmVersion: Int = BearyStarMap.algorithmVersion) -> String {
        "\(account)|\(slice.cacheKey)|\(diaryVersion)|v\(algorithmVersion)"
    }

    static func lookup(key: String) -> StarMapModel? {
        lock.lock()
        defer { lock.unlock() }
        guard let model = memory[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return model
    }

    static func store(key: String, model: StarMapModel) {
        lock.lock()
        defer { lock.unlock() }
        memory[key] = model
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }

    /// 按账号桶清：键以 "\(viewerBucket)|" 开头（accountKey 的第一段），
    /// 该查看者看过的所有作者星图一并清掉。
    static func purge(viewerBucket: String) {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(viewerBucket)|"
        for key in memory.keys where key.hasPrefix(prefix) {
            memory.removeValue(forKey: key)
        }
        order.removeAll { $0.hasPrefix(prefix) }
    }

    static func purgeAll() {
        lock.lock()
        defer { lock.unlock() }
        memory.removeAll()
        order.removeAll()
    }
}

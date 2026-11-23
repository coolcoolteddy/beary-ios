import UIKit

// ===== 广场顶部轮播（第一页是盲盒交换，其余页为精选与历史上的今天）=====
// 卡片同宽（表宽 - 32），一次一张，可左右滑，4 秒自动换一张，
// 下方小圆点可点切页；页面不可见时停表，手动滑动时不抢。
// 卡片主体点按：精选卡进那篇日记详情，历史卡进历史上的今天页，盲盒页进盲盒流程页；
// 点按不切换下一条。盲盒页标题与计数走盲盒当日态（BlindBoxState），计数变化时
// 宿主重建轮播（见 BearyFeedViewController.rebuildCarouselItems）。
// 精选挑法（客户端就地实现，未新开后端接口）：复用广场首屏已加载数据
// （BearyFeedViewController.plazaRaw，首屏 fetchEntries scope=plaza，
// 已按有效公开过滤），按赞数 + 回应数 + 新近加权挑 3 篇，见 BearyPlazaFeaturedPicker。
// 身份隔离（identity_aware_caching / identity_safe_async_data）：
// 精选只存“当日选中 id 顺序”在 UserDefaults，键按身份 + 当日分桶
// （登录用 user id，未登录用 guest），登录态绝不读 guest 桶；切号即换桶，
// 旧桶内容不再渲染；缓存里只有 id，不存正文——渲染永远取当前内存里的
// 广场条目，id 对不上就地重挑，不把旧内容当新鲜的展示。历史上的今天是
// 公开静态内容，不按身份缓存（当日一桶）；历史页列当天事件
// （服务端给几条列几条；未部署新字段时用老 events 兜底），不拉日记、不写入口。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 历史上的今天（GET /api/history-today；每天 3 条＋小熊评论）

/// 服务端回包：{ date: "yyyy-MM-dd", events: [3 条], comments: [3 条] }。
/// comments 在兜底路径下可能缺省；events 为空或解码失败一律按未加载处理。
/// 事件文案是陈述句（服务端已按“不超过 25 字”成句），直接展示、不再加工。
/// 服务端新字段（历史上的今天改版）：农历、节日、带年份的事件明细、生日。
/// 一律可选——老端点回包没有这些字段时照常解码，展示层用老 events 兜底，
/// 绝不空白页。
struct BearyHistoryTodayEventDetail: Codable {
    var year: Int?
    var text: String
    var comment: String?
}

struct BearyHistoryTodayBirth: Codable {
    var year: Int?
    var name: String
    var intro: String?
}

struct BearyHistoryToday: Codable {
    var date: String
    var events: [String]
    var comments: [String]?

    var lunar: String?
    var lunarYear: String?
    var festival: String?
    var eventsDetail: [BearyHistoryTodayEventDetail]?
    var births: [BearyHistoryTodayBirth]?

    var firstEvent: String? { events.first }

    /// 第 i 条事件的小熊评论（与 events 同下标；缺省、越界或空白回 nil）。
    func comment(at index: Int) -> String? {
        guard let comments = comments, index >= 0, index < comments.count else { return nil }
        let text = comments[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 展示用事件行：新字段 eventsDetail 优先；缺省或全空时用老 events＋
    /// 同下标评论合成，绝不空白页。
    var displayEvents: [BearyHistoryTodayEventDetail] {
        if let detail = eventsDetail {
            let cleaned = detail.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !cleaned.isEmpty { return cleaned }
        }
        return events.enumerated().map { BearyHistoryTodayEventDetail(year: nil, text: $0.element, comment: comment(at: $0.offset)) }
    }

    /// 展示用生日：最多 4 人（服务端多给也只取前 4）。
    var displayBirths: [BearyHistoryTodayBirth] {
        return Array((births ?? []).prefix(4))
    }

    /// 农历日期（"十月十五"），空白当缺省。
    var lunarDay: String? {
        guard let lunar = lunar?.trimmingCharacters(in: .whitespacesAndNewlines), !lunar.isEmpty else { return nil }
        return lunar
    }

    /// 农历年份（"丙午年"），空白当缺省。
    var lunarYearText: String? {
        guard let lunarYear = lunarYear?.trimmingCharacters(in: .whitespacesAndNewlines), !lunarYear.isEmpty else { return nil }
        return lunarYear
    }

    /// 节日，空白当缺省；没有就不显示节日行。
    var festivalText: String? {
        guard let festival = festival?.trimmingCharacters(in: .whitespacesAndNewlines), !festival.isEmpty else { return nil }
        return festival
    }

    /// 当日日期文案（"11月18日"）。
    var dateLabel: String {
        return Self.dateLabel(for: date)
    }

    /// 日期键（"yyyy-MM-dd"）转日期文案；解析失败回退原串。
    static func dateLabel(for dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else { return dateKey }
        return "\(month)月\(day)日"
    }
}

enum BearyHistoryTodayLoader {
    /// 当日缓存（公开静态内容，不按身份分桶；键含日期，隔天自动失效）。
    private static func cacheKey(for dateKey: String) -> String {
        return "beary.historyToday.\(dateKey)"
    }

    /// 同步读当日缓存（date 对得上才认；旧日期残留直接丢弃）。
    static func cached() -> BearyHistoryToday? {
        let key = BlindBoxDate.todayKey()
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: key)) else { return nil }
        guard let payload = try? JSONDecoder().decode(BearyHistoryToday.self, from: data) else { return nil }
        guard payload.date == key, !payload.events.isEmpty else { return nil }
        return payload
    }

    private static func save(_ payload: BearyHistoryToday) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: payload.date))
    }

    /// 在途去重：多次调用只发一条请求，回包分发给所有等在途者。
    /// 调用方在主线程调（回包数组的读写都在主线程）。
    private static var inFlightCompletions: [(BearyHistoryToday?) -> Void]?

    /// 拉取当日 3 条：缓存命中直接回包（不发请求）；未命中发 GET 请求，
    /// 成功写缓存后回包；失败回 nil（调用方保留旧卡、不谎报）。
    /// 回调一律主线程。
    static func load(completion: @escaping (BearyHistoryToday?) -> Void) {
        if let payload = cached() {
            DispatchQueue.main.async { completion(payload) }
            return
        }
        if inFlightCompletions != nil {
            inFlightCompletions?.append(completion)
            return
        }
        inFlightCompletions = [completion]
        let finish: (BearyHistoryToday?) -> Void = { payload in
            DispatchQueue.main.async {
                let waiting = inFlightCompletions ?? []
                inFlightCompletions = nil
                waiting.forEach { $0(payload) }
            }
        }
        _ = BearyAPI.shared.request("/api/history-today", suppressUnauthorized: true) { (result: Result<BearyHistoryToday, APIError>) in
            switch result {
            case .success(let payload):
                guard !payload.events.isEmpty else {
                    finish(nil)
                    return
                }
                save(payload)
                finish(payload)
            case .failure:
                finish(nil)
            }
        }
    }
}

// MARK: - 精选挑法（复用广场首屏数据，不新开接口）

enum BearyPlazaFeaturedPicker {
    static let pickCount = 3

    /// 挑法：有效公开篇里按赞加权（赞 ×10 + 回应数 + 新近加分：24 小时内 +30、
    /// 7 天内 +10），分高在前，同分按发布时间倒序、id 升序兜底，全天同一批。
    /// 当日选中 id 顺序按身份 + 日期缓存（只存 id，不存正文）；缓存 id 若
    /// 不全在当前列表里（删篇/翻私密），就地按分数重挑，不渲染旧内容。
    /// count 由轮播配置下发（缺省 pickCount）；缓存比 count 少时就地重挑。
    static func pick(from entries: [Entry], count: Int = pickCount) -> [Entry] {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let candidates = entries.filter { entry in
            guard let id = entry.id, !id.isEmpty else { return false }
            guard BearyEphemeral.isEffectivelyPublic(entry) else { return false }
            return true
        }
        guard !candidates.isEmpty else { return [] }
        if let cached = cachedPickIds(), !cached.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: candidates.compactMap { entry -> (String, Entry)? in
                guard let id = entry.id else { return nil }
                return (id, entry)
            })
            let restored = cached.compactMap { byId[$0] }
            if restored.count == cached.count && restored.count >= count {
                return Array(restored.prefix(count))
            }
        }
        let ranked = candidates.sorted { a, b in
            let sa = score(a, nowMs: nowMs)
            let sb = score(b, nowMs: nowMs)
            if sa != sb { return sa > sb }
            let pa = a.publishedAt ?? a.createdAt ?? 0
            let pb = b.publishedAt ?? b.createdAt ?? 0
            if pa != pb { return pa > pb }
            return (a.id ?? "") < (b.id ?? "")
        }
        let picks = Array(ranked.prefix(max(0, count)))
        savePickIds(picks.compactMap { $0.id })
        return picks
    }

    private static func score(_ entry: Entry, nowMs: Int) -> Int {
        var value = (entry.likeCount ?? 0) * 10
        value += (entry.emotes ?? []).reduce(0) { $0 + ($1.count ?? 0) }
        if let published = entry.publishedAt ?? entry.createdAt {
            let ageHours = (nowMs - published) / 3_600_000
            if ageHours < 24 {
                value += 30
            } else if ageHours < 168 {
                value += 10
            }
        }
        return value
    }

    /// 身份 + 当日分桶（与盲盒桶、广场快照桶同口径：登录用 user id，未登录用 guest）。
    private static func cacheKey() -> String {
        let account: String
        if let id = SessionManager.shared.currentUser?.id {
            account = "\(id)"
        } else {
            account = "guest"
        }
        return "beary.carousel.featured.\(account).\(BlindBoxDate.todayKey())"
    }

    private static func cachedPickIds() -> [String]? {
        let ids = UserDefaults.standard.stringArray(forKey: cacheKey() + ".ids")
        guard let ids = ids, !ids.isEmpty else { return nil }
        return ids
    }

    private static func savePickIds(_ ids: [String]) {
        let key = cacheKey()
        UserDefaults.standard.set(ids, forKey: key + ".ids")
        // 新鲜度时间戳：当日桶天然过期（键含日期），写下它只为排查找证。
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: key + ".savedAt")
    }

    /// 显式退出时清该号当日精选桶（与 BlindBoxState.clearAccount 同口径；
    /// 切号不调——旧号桶保留、切回可复用，读时只认当前身份的桶）。
    static func clearAccount(accountId: Int) {
        let prefix = "beary.carousel.featured.\(accountId)."
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - 卡片文案

enum BearyPlazaCarouselItem {
    case featured(Entry)
    case historyToday(BearyHistoryToday?)
    case blindBox
    /// 公告页（服务端配置下发；取最新一条有效公告，无公告时不建页）。
    case announcement(BearyAnnouncement)
}

enum BearyPlazaCarouselText {
    /// 标题：服务端标题优先，无标题取正文首行（截 30 字），都没有给中性占位。
    static func displayTitle(for entry: Entry) -> String {
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let content = entry.content {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(30))
                }
            }
        }
        return "一篇日记"
    }

    /// 标题的 attributed 版（今日推荐卡）：先全文渲染再取前 30 字——
    /// 记号已是单个附件格，不会在记号中间截断。标题原样全量渲染（卡片
    /// 单行尾部截断）；无标题取正文首行；都没有给中性占位。
    static func displayTitleAttributed(for entry: Entry, font: UIFont, dark: Bool) -> NSAttributedString {
        if let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return BearyText.inlineAttributedText(from: title, font: font, color: BearyColors.ink, paragraphStyle: nil, dark: dark, gifImageKeys: entry.images)
        }
        if let content = entry.content {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let rendered = BearyText.inlineAttributedText(from: trimmed, font: font, color: BearyColors.ink, paragraphStyle: nil, dark: dark, gifImageKeys: entry.images)
                    guard rendered.string.count > 30 else { return rendered }
                    let prefixLength = rendered.string.prefix(30).utf16.count
                    return rendered.attributedSubstring(from: NSRange(location: 0, length: prefixLength))
                }
            }
        }
        return NSAttributedString(string: "一篇日记", attributes: [.font: font, .foregroundColor: BearyColors.ink])
    }

    /// 副行：作者名 · 赞数（无作者名时只显赞数）。
    static func metaText(for entry: Entry) -> String {
        var parts: [String] = []
        if let name = entry.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        parts.append("\(entry.likeCount ?? 0) 赞")
        return parts.joined(separator: " · ")
    }

    /// 盲盒页副行：今日计数（与原下方小卡同一 BlindBoxState 口径）；
    /// 已换完追加原小卡已换态文案，未登录追加登录提示；文案走 catalog，不自编。
    static func blindBoxMetaText() -> String {
        let count = BlindBoxState.shared.countText()
        if SessionManager.shared.isLoggedIn == false {
            return "\(count) · \(NSLocalizedString("blindbox.exchange.login_hint", comment: ""))"
        }
        if BlindBoxState.shared.usedToday {
            return "\(count) · \(NSLocalizedString("blindbox.exchange.used_hint", comment: ""))"
        }
        return count
    }

    /// 公告页眉（String Catalog：carousel.announcement.eyebrow）。
    static func announcementEyebrow() -> String {
        return NSLocalizedString("carousel.announcement.eyebrow", comment: "")
    }

    /// 公告页副行：发布日期（跟 App 语言走的本地化日期，不写死格式）。
    static func dateText(ms: Int) -> String {
        return announcementDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private static let announcementDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// 历史卡日期行："11月23日 · 农历十月十五"；农历缺省时只显公历日期。
    static func historyDateLine(for payload: BearyHistoryToday) -> String {
        guard let lunar = payload.lunarDay else { return payload.dateLabel }
        return String(format: NSLocalizedString("historyToday.carousel_date_lunar", comment: ""), payload.dateLabel, lunar)
    }
}

// MARK: - 轮播视图

final class BearyPlazaCarouselView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {

    // 卡高 76 → 112：历史卡现为 5 行（日期行＋3 条事件速览＋第一句小熊评论），
    // 76 放不下；精选／盲盒卡内部结构不动，文字栈仍居中，只是卡变高了。
    static let cardHeight: CGFloat = 112
    static let preferredHeight: CGFloat = 136

    /// 自动换页间隔（方案定 3–5 秒，取中间 4 秒）。
    private static let autoAdvanceInterval: TimeInterval = 4

    var onSelectFeatured: ((Entry) -> Void)?
    var onSelectHistory: (() -> Void)?
    var onSelectBlindBox: (() -> Void)?
    var onSelectAnnouncement: ((BearyAnnouncement) -> Void)?

    private var items: [BearyPlazaCarouselItem] = []
    private var pageVisible = false
    private var userDragging = false
    private var autoTimer: Timer?

    private lazy var flowLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.dataSource = self
        view.delegate = self
        view.register(BearyPlazaCarouselCell.self, forCellWithReuseIdentifier: "BearyPlazaCarouselCell")
        return view
    }()

    private let pageControl: UIPageControl = {
        let control = UIPageControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        // 小圆点可点切页（点哪颗去哪页）；自动轮播与左右滑不变。
        control.hidesForSinglePage = true
        control.pageIndicatorTintColor = BearyColors.alpha(BearyColors.gray, 0.4)
        control.currentPageIndicatorTintColor = BearyColors.orange
        return control
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(collectionView)
        addSubview(pageControl)
        pageControl.addTarget(self, action: #selector(pageControlTapped), for: .valueChanged)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: BearyPlazaCarouselView.cardHeight),
            pageControl.topAnchor.constraint(equalTo: collectionView.bottomAnchor, constant: 6),
            pageControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            pageControl.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        autoTimer?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopAutoAdvance()
        } else if pageVisible {
            startAutoAdvanceIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width, height: BearyPlazaCarouselView.cardHeight)
        if flowLayout.itemSize != size {
            flowLayout.itemSize = size
            flowLayout.invalidateLayout()
        }
    }

    /// 换 items：内容不变时不动滚动位（首拉重拍不把用户正在看的卡顶回第一张）；
    /// 变了才回第一张。
    func setItems(_ newItems: [BearyPlazaCarouselItem]) {
        if itemsSignature(items) == itemsSignature(newItems) {
            return
        }
        items = newItems
        pageControl.numberOfPages = items.count
        pageControl.currentPage = 0
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
        startAutoAdvanceIfNeeded()
    }

    private func itemsSignature(_ list: [BearyPlazaCarouselItem]) -> String {
        return list.map { item in
            switch item {
            case .featured(let entry): return "f:\(entry.id ?? "")"
            case .historyToday(let payload): return "h:\(payload?.date ?? ""):\(payload?.firstEvent ?? "")"
            case .blindBox: return "b:\(SessionManager.shared.isLoggedIn):\(BlindBoxState.shared.countText())"
            case .announcement(let ann): return "a:\(ann.id)"
            }
        }.joined(separator: ",")
    }

    /// 页面可见性（容器切 tab / modal 盖住时由宿主调）：不可见即停表。
    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        if visible {
            startAutoAdvanceIfNeeded()
        } else {
            stopAutoAdvance()
        }
    }

    private func startAutoAdvanceIfNeeded() {
        stopAutoAdvance()
        guard pageVisible, !userDragging, items.count > 1, window != nil else { return }
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        let timer = Timer(timeInterval: BearyPlazaCarouselView.autoAdvanceInterval, repeats: true) { [weak self] _ in
            self?.advanceOnePage()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    private func stopAutoAdvance() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    private func advanceOnePage() {
        guard pageVisible, !userDragging, items.count > 1, window != nil else { return }
        let next = (currentPage() + 1) % items.count
        collectionView.scrollToItem(at: IndexPath(item: next, section: 0), at: .centeredHorizontally, animated: BearyMotion.animated(true))
        pageControl.currentPage = next
    }

    /// 点小圆点切页：停表、跳到该页、再起表（与手动滑动同一口径）。
    @objc private func pageControlTapped() {
        let page = pageControl.currentPage
        guard page >= 0, page < items.count else { return }
        stopAutoAdvance()
        collectionView.scrollToItem(at: IndexPath(item: page, section: 0), at: .centeredHorizontally, animated: BearyMotion.animated(true))
        startAutoAdvanceIfNeeded()
    }

    private func currentPage() -> Int {
        guard collectionView.bounds.width > 0, !items.isEmpty else { return 0 }
        let page = Int(round(collectionView.contentOffset.x / collectionView.bounds.width))
        return max(0, min(items.count - 1, page))
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "BearyPlazaCarouselCell", for: indexPath) as! BearyPlazaCarouselCell
        let item = items[indexPath.item]
        cell.configure(item: item)
        cell.onSelect = { [weak self] in
            guard let self = self else { return }
            switch item {
            case .featured(let entry): self.onSelectFeatured?(entry)
            case .historyToday: self.onSelectHistory?()
            case .blindBox: self.onSelectBlindBox?()
            case .announcement(let ann): self.onSelectAnnouncement?(ann)
            }
        }
        return cell
    }

    // MARK: - UIScrollViewDelegate（手动滑动时不抢）

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userDragging = true
        stopAutoAdvance()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            userDragging = false
            pageControl.currentPage = currentPage()
            startAutoAdvanceIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userDragging = false
        pageControl.currentPage = currentPage()
        startAutoAdvanceIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pageControl.currentPage = currentPage()
    }
}

// MARK: - 轮播卡片

final class BearyPlazaCarouselCell: UICollectionViewCell {

    var onSelect: (() -> Void)?

    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let bodyButton = BearyHit44Button(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = BearyColors.surface1
        contentView.layer.cornerRadius = BearyCorners.single
        contentView.clipsToBounds = true

        eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
        eyebrowLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11, weight: .semibold))
        eyebrowLabel.adjustsFontForContentSizeCategory = true
        eyebrowLabel.textColor = BearyColors.deepOrangeText
        eyebrowLabel.numberOfLines = 1

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail

        let textStack = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, metaLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        textStack.isUserInteractionEnabled = false

        // 卡片主体点按（整张卡）。
        bodyButton.translatesAutoresizingMaskIntoConstraints = false
        bodyButton.addTarget(self, action: #selector(bodyTapped), for: .touchUpInside)
        bodyButton.bearyAddPressFeedback()
        contentView.addSubview(bodyButton)
        contentView.sendSubviewToBack(bodyButton)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            bodyButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            bodyButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bodyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bodyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        eyebrowLabel.isHidden = false
        // 历史卡改了标题行数／字重／副行显隐，复用前一律复位（精选／盲盒卡是单行）。
        titleLabel.numberOfLines = 1
        titleLabel.font = BearyDynamicType.smallSemiboldFont()
        metaLabel.isHidden = false
        onSelect = nil
    }

    func configure(item: BearyPlazaCarouselItem) {
        switch item {
        case .featured(let entry):
            eyebrowLabel.isHidden = false
            eyebrowLabel.text = "今日推荐"
            titleLabel.attributedText = BearyPlazaCarouselText.displayTitleAttributed(for: entry, font: titleLabel.font, dark: traitCollection.userInterfaceStyle == .dark)
            metaLabel.text = BearyPlazaCarouselText.metaText(for: entry)
            bodyButton.accessibilityLabel = "今日推荐：\(BearyPlazaCarouselText.displayTitle(for: entry))"
        case .historyToday(let payload):
            eyebrowLabel.isHidden = false
            if let payload = payload {
                // 日期行：公历＋农历（农历缺省只显公历）。
                eyebrowLabel.text = BearyPlazaCarouselText.historyDateLine(for: payload)
                // 3 条事件速览：前 3 条各一行；副行是第一句小熊评论（没有不显示）。
                titleLabel.numberOfLines = 3
                titleLabel.font = BearyDynamicType.smallBodyFont()
                let previewEvents = payload.displayEvents.prefix(3)
                let previewText = previewEvents.map { $0.text }.joined(separator: "\n")
                titleLabel.text = previewText.isEmpty ? payload.dateLabel : previewText
                let firstComment: String? = previewEvents.first.flatMap { $0.comment }
                metaLabel.text = firstComment
                metaLabel.isHidden = firstComment == nil
            } else {
                // 还在加载：眉标给标题、标题给日期、副行明说正在加载，不编一条假事件。
                eyebrowLabel.text = NSLocalizedString("historyToday.title", comment: "")
                titleLabel.text = BearyHistoryToday.dateLabel(for: BlindBoxDate.todayKey())
                metaLabel.text = "正在加载…"
            }
            bodyButton.accessibilityLabel = String(format: NSLocalizedString("historyToday.carousel_a11y", comment: ""), NSLocalizedString("historyToday.title", comment: ""), titleLabel.text ?? "")
        case .blindBox:
            // 盲盒页不用眉标行（标题本身就是“盲盒交换”）；副行是今日计数，
            // 已换完追加原小卡已换态文案，未登录追加登录提示。
            eyebrowLabel.isHidden = true
            titleLabel.text = NSLocalizedString("blindbox.exchange.title", comment: "")
            metaLabel.text = BearyPlazaCarouselText.blindBoxMetaText()
            bodyButton.accessibilityLabel = (titleLabel.text ?? "") + " " + (metaLabel.text ?? "")
        case .announcement(let ann):
            // 盲盒页隐藏了眉标行；cell 复用时须显式恢复，否则公告页眉标被藏。
            eyebrowLabel.isHidden = false
            eyebrowLabel.text = BearyPlazaCarouselText.announcementEyebrow()
            titleLabel.text = ann.title
            metaLabel.text = BearyPlazaCarouselText.dateText(ms: ann.createdAt)
            bodyButton.accessibilityLabel = BearyPlazaCarouselText.announcementEyebrow() + "：" + ann.title
        }
    }

    @objc private func bodyTapped() {
        onSelect?()
    }
}

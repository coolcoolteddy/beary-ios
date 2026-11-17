import UIKit

// ===== 广场顶部轮播（取代顶部盲盒卡；盲盒改收轮播下方一行小卡）=====
// 卡片与旧盲盒卡同宽（表宽 - 32），一次一张，可左右滑，4 秒自动换一张，
// 下方小圆点只作指示（点圆点不切页）；页面不可见时停表，手动滑动时不抢。
// 卡片主体点按：精选卡进那篇日记详情，话题卡进话题页；点按不切换下一条。
// 角落小熊是独立点按区（44pt 热区）：只播一个戳一下的小反应，不跳页、
// 不写数据；给日记加小熊回应进详情页走原有入口。
// 吉祥物：官方资产 side_beary_icon（一笔画抱信封小熊，深色变体由 imageset 自带），不自绘。
// 精选挑法（客户端就地实现，未新开后端接口）：复用广场首屏已加载数据
// （BearyFeedViewController.plazaRaw，首屏 fetchEntries scope=plaza，
// 已按有效公开过滤），按赞数 + 回应数 + 新近加权挑 3 篇，见 BearyPlazaFeaturedPicker。
// 身份隔离（identity_aware_caching / identity_safe_async_data）：
// 精选只存“当日选中 id 顺序”在 UserDefaults，键按身份 + 当日分桶
// （登录用 user id，未登录用 guest），登录态绝不读 guest 桶；切号即换桶，
// 旧桶内容不再渲染；缓存里只有 id，不存正文——渲染永远取当前内存里的
// 广场条目，id 对不上就地重挑，不把旧内容当新鲜的展示。话题本身是公开
// 静态内容，不按身份缓存；话题页的相关日记与写入口另按身份处理
// （见 BearyPlazaTopicViewController）。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 话题（固定题库，一天一条自动轮换；新闻自动挑已否决）

struct BearyPlazaCarouselTopic {
    var title: String
    var question: String
    /// 话题页搜相关公开日记用的关键词（按顺序取第一个有结果的）。
    var keywords: [String]

    /// 当日话题：按 Asia/Shanghai 日期键哈希取题库下标，全天同一条，各端一致。
    static func today() -> BearyPlazaCarouselTopic {
        return topic(forDayKey: BlindBoxDate.todayKey())
    }

    static func topic(forDayKey dayKey: String) -> BearyPlazaCarouselTopic {
        var hash: UInt64 = 5381
        for scalar in dayKey.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return bank[Int(hash % UInt64(bank.count))]
    }

    /// 固定题库（32 条；国内用户有感觉的轻松话题——电竞、影视、音乐、梗、
    /// 纪念日；涉法、劣迹艺人、政治类不进题库）。完整清单见 PR 正文。
    static let bank: [BearyPlazaCarouselTopic] = [
        BearyPlazaCarouselTopic(title: "昨晚那场电竞决赛", question: "说说让你熬夜看完的那场比赛", keywords: ["电竞", "比赛", "决赛"]),
        BearyPlazaCarouselTopic(title: "第一次打排位那天", question: "你还记得第一次上分的那个晚上吗", keywords: ["游戏", "排位", "上分"]),
        BearyPlazaCarouselTopic(title: "我的本命英雄", question: "玩了这么久，你最舍不得换下谁", keywords: ["英雄", "游戏"]),
        BearyPlazaCarouselTopic(title: "看了三遍以上的电影", question: "重刷的时候，你在看什么", keywords: ["电影", "重刷"]),
        BearyPlazaCarouselTopic(title: "今年院线最好看的一部", question: "散场之后，你第一个想聊的人是谁", keywords: ["电影", "影院"]),
        BearyPlazaCarouselTopic(title: "追到半夜三点的那部剧", question: "追完那天，你是什么心情", keywords: ["追剧", "电视剧"]),
        BearyPlazaCarouselTopic(title: "一响起就想起某人的那首歌", question: "循环播放的那首歌，背后是什么故事", keywords: ["歌", "音乐"]),
        BearyPlazaCarouselTopic(title: "歌单里藏着的心情", question: "最近单曲循环的是哪一首", keywords: ["歌单", "音乐"]),
        BearyPlazaCarouselTopic(title: "演唱会现场最难忘的一瞬间", question: "大合唱响起的时候，你在想什么", keywords: ["演唱会"]),
        BearyPlazaCarouselTopic(title: "现在看到还会笑的梗", question: "说说那个让你笑出声的梗", keywords: ["梗"]),
        BearyPlazaCarouselTopic(title: "手机里存的表情包", question: "最常用的一张，讲的是什么心情", keywords: ["表情包"]),
        BearyPlazaCarouselTopic(title: "今年最火的那个热梗", question: "你第一次看到它是在哪儿", keywords: ["热梗"]),
        BearyPlazaCarouselTopic(title: "十年前的今天", question: "翻翻十年前的照片，想起什么", keywords: ["十年", "回忆"]),
        BearyPlazaCarouselTopic(title: "毕业那天", question: "毕业季的最后一顿饭，你和谁吃的", keywords: ["毕业"]),
        BearyPlazaCarouselTopic(title: "第一次发工资买的东西", question: "那笔钱花在哪儿，你还记得吗", keywords: ["工资"]),
        BearyPlazaCarouselTopic(title: "童年暑假最想念的一件事", question: "那个夏天，你最常去的地方是哪里", keywords: ["暑假", "童年"]),
        BearyPlazaCarouselTopic(title: "过年回家最期待的一道菜", question: "谁做的菜，是你心里年味的味道", keywords: ["过年", "年夜饭"]),
        BearyPlazaCarouselTopic(title: "城市下雪的那天", question: "下雪天，你最想和谁一起出门", keywords: ["下雪", "雪"]),
        BearyPlazaCarouselTopic(title: "一场说走就走的旅行", question: "最冲动的一次出发，去了哪里", keywords: ["旅行"]),
        BearyPlazaCarouselTopic(title: "深夜食堂最拿手的一道菜", question: "做给谁吃的时候，最有成就感", keywords: ["做饭", "美食"]),
        BearyPlazaCarouselTopic(title: "奶茶自由和快乐自由", question: "你最常点的那一杯，是什么口味", keywords: ["奶茶"]),
        BearyPlazaCarouselTopic(title: "改变了我一点点的那本书", question: "合上书的那一刻，你在想什么", keywords: ["书", "阅读"]),
        BearyPlazaCarouselTopic(title: "房间里最有故事的东西", question: "它是怎么来到你身边的", keywords: ["房间"]),
        BearyPlazaCarouselTopic(title: "运动之后最爽的一刻", question: "跑完步、打完球，你第一件事做什么", keywords: ["运动", "跑步"]),
        BearyPlazaCarouselTopic(title: "养过最难忘的一只小动物", question: "它教会了你什么", keywords: ["猫", "狗", "宠物"]),
        BearyPlazaCarouselTopic(title: "雨天最适合做的事", question: "听雨声的时候，你在想什么", keywords: ["下雨", "雨天"]),
        BearyPlazaCarouselTopic(title: "明天不用上班、不用上学", question: "你会怎么安排这一天", keywords: ["休息", "放假"]),
        BearyPlazaCarouselTopic(title: "小时候的梦想", question: "现在回头看，那个梦想去哪儿了", keywords: ["梦想"]),
        BearyPlazaCarouselTopic(title: "一直记到现在的那句台词", question: "那句话是在什么场景下说的", keywords: ["台词", "电影"]),
        BearyPlazaCarouselTopic(title: "手机相册里最近一张照片", question: "按下快门的时候，你在看什么", keywords: ["照片", "相册"]),
        BearyPlazaCarouselTopic(title: "周末的正确打开方式", question: "这个周末，你打算怎么过", keywords: ["周末"]),
        BearyPlazaCarouselTopic(title: "一件等了很久的事", question: "终于等到的那天，你做了什么", keywords: ["等待"]),
    ]
}

// MARK: - 精选挑法（复用广场首屏数据，不新开接口）

enum BearyPlazaFeaturedPicker {
    static let pickCount = 3

    /// 挑法：有效公开篇里按赞加权（赞 ×10 + 回应数 + 新近加分：24 小时内 +30、
    /// 7 天内 +10），分高在前，同分按发布时间倒序、id 升序兜底，全天同一批。
    /// 当日选中 id 顺序按身份 + 日期缓存（只存 id，不存正文）；缓存 id 若
    /// 不全在当前列表里（删篇/翻私密），就地按分数重挑，不渲染旧内容。
    static func pick(from entries: [Entry]) -> [Entry] {
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
            if restored.count == cached.count {
                return restored
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
        let picks = Array(ranked.prefix(pickCount))
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
    case topic(BearyPlazaCarouselTopic)
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

    /// 副行：作者名 · 赞数（无作者名时只显赞数）。
    static func metaText(for entry: Entry) -> String {
        var parts: [String] = []
        if let name = entry.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        parts.append("\(entry.likeCount ?? 0) 赞")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 轮播视图

final class BearyPlazaCarouselView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate {

    static let cardHeight: CGFloat = 76
    static let preferredHeight: CGFloat = 100

    /// 自动换页间隔（方案定 3–5 秒，取中间 4 秒）。
    private static let autoAdvanceInterval: TimeInterval = 4

    var onSelectFeatured: ((Entry) -> Void)?
    var onSelectTopic: ((BearyPlazaCarouselTopic) -> Void)?

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
        // 小圆点只作指示，不可点——切换下一条只靠左右滑和自动轮播。
        control.isUserInteractionEnabled = false
        control.hidesForSinglePage = true
        control.pageIndicatorTintColor = BearyColors.alpha(BearyColors.gray, 0.4)
        control.currentPageIndicatorTintColor = BearyColors.orange
        return control
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(collectionView)
        addSubview(pageControl)
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
            case .topic(let topic): return "t:\(topic.title)"
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
            case .topic(let topic): self.onSelectTopic?(topic)
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
    private let bearButton = BearyHit44Button(type: .custom)
    private let bearImageView = UIImageView()

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

        // 卡片主体点按（整张卡；熊按钮盖在它上面，先截获熊的点按）。
        bodyButton.translatesAutoresizingMaskIntoConstraints = false
        bodyButton.addTarget(self, action: #selector(bodyTapped), for: .touchUpInside)
        bodyButton.bearyAddPressFeedback()
        contentView.addSubview(bodyButton)
        contentView.sendSubviewToBack(bodyButton)

        bearImageView.translatesAutoresizingMaskIntoConstraints = false
        bearImageView.contentMode = .scaleAspectFit
        // 官方一笔画熊（深色变体 imageset 自带）；缺失时直接无图，不走暂代。
        bearImageView.image = UIImage(named: "side_beary_icon")
        bearImageView.isUserInteractionEnabled = false
        contentView.addSubview(bearImageView)

        // 熊独立点按区：视觉 30pt，热区 44pt；只播戳动效，不跳页、不写数据。
        bearButton.translatesAutoresizingMaskIntoConstraints = false
        bearButton.addTarget(self, action: #selector(bearTapped), for: .touchUpInside)
        bearButton.accessibilityLabel = "贝瑞"
        bearButton.accessibilityHint = "点按戳一下"
        contentView.addSubview(bearButton)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: bearButton.leadingAnchor, constant: -8),
            bearImageView.widthAnchor.constraint(equalToConstant: 30),
            bearImageView.heightAnchor.constraint(equalToConstant: 30),
            bearImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            bearImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            bearButton.widthAnchor.constraint(equalToConstant: 44),
            bearButton.heightAnchor.constraint(equalToConstant: 44),
            bearButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            bearButton.centerXAnchor.constraint(equalTo: bearImageView.centerXAnchor),
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
        bearImageView.transform = .identity
        onSelect = nil
    }

    func configure(item: BearyPlazaCarouselItem) {
        switch item {
        case .featured(let entry):
            eyebrowLabel.text = "今日推荐"
            titleLabel.text = BearyPlazaCarouselText.displayTitle(for: entry)
            metaLabel.text = BearyPlazaCarouselText.metaText(for: entry)
            bodyButton.accessibilityLabel = "今日推荐：\(titleLabel.text ?? "")"
        case .topic(let topic):
            eyebrowLabel.text = "今日话题"
            titleLabel.text = topic.title
            metaLabel.text = topic.question
            bodyButton.accessibilityLabel = "今日话题：\(topic.title)"
        }
    }

    @objc private func bodyTapped() {
        onSelect?()
    }

    /// 戳一下：小幅放大 + 轻转后弹簧回位（跟主站戳熊一个意思），不跳页、不写数据。
    @objc private func bearTapped() {
        bearImageView.layer.removeAllAnimations()
        UIView.animate(withDuration: BearyMotion.micro, animations: {
            self.bearImageView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18).rotated(by: -0.10)
        }) { _ in
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, usingSpringWithDamping: BearyMotion.springDamping, initialSpringVelocity: 0.5, options: [], animations: {
                self.bearImageView.transform = .identity
            }, completion: nil)
        }
    }
}

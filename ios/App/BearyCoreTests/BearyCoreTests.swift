import XCTest

// ===== 第一阶段单测：路由解析 + 模型解码 + Scope =====
// 注意：测试 target 不带宿主 App，直接把 BearyAPI.swift 与 BearyNavigator.swift 编进测试包，
// 因此这里不 import App、不走 @testable；跑法见 workflow 的 test 任务。

private func bearyDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

final class BearyRouteTests: XCTestCase {
    func testParsePages() {
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary")!), .home)
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/")!), .home)
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/notifications")!), .notifications)
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/timeline")!), .timeline)
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/profile")!), .profile)
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/search")!), .search)
    }

    func testParseDeepLinks() {
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/d/b_abc123")!), .entry("b_abc123"))
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/@lele")!), .userByHandle("lele"))
        XCTAssertEqual(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/u/27")!), .userById(27))
    }

    func testParseRejects() {
        XCTAssertNil(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/d/")!))
        XCTAssertNil(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/@")!))
        XCTAssertNil(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/u/abc")!))
        XCTAssertNil(BearyRoute.parse(url: URL(string: "https://teddyhn.com/beary/unknown")!))
        XCTAssertNil(BearyRoute.parse(url: URL(string: "https://example.com/beary")!))
    }

    func testWebURLs() {
        XCTAssertEqual(BearyRoute.entry("b_x").webURL?.absoluteString, "https://teddyhn.com/beary/d/b_x")
        XCTAssertEqual(BearyRoute.userByHandle("lele").webURL?.absoluteString, "https://teddyhn.com/beary/@lele")
        XCTAssertEqual(BearyRoute.userById(27).webURL?.absoluteString, "https://teddyhn.com/beary/u/27")
    }
}

final class BearyDecodingTests: XCTestCase {
    func testFullEntry() throws {
        let json = """
        {"id":"b_test1","author_id":27,"author_name":"乐乐","author_avatar":"/beary/api/users/27/avatar?v=3",
        "author_cover":null,"author_badge":"beta","author_plus":1,"content":"今天写的第一篇",
        "images":["img1.jpg"],"img_dims":{"img1.jpg":[1200,900]},"mood":"love","weather":"sunny",
        "quote_id":null,"quote":null,"created_at":1761000000000,"publish_at":1761604800000,
        "edit_deadline":1761000900000,"is_public":true,"is_locked":true,"is_mine":false,
        "like_count":5,"liked_by_me":true,"bookmarked_by_me":false,"recipient_id":null,
        "recipient_name":null,"emotes":[{"emote":"love","count":2,"mine":true}]}
        """
        let e = try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(e.id, "b_test1")
        XCTAssertEqual(e.authorId, 27)
        XCTAssertEqual(e.authorBadge, "beta")
        XCTAssertEqual(e.images, ["img1.jpg"])
        XCTAssertEqual(e.imgDims?["img1.jpg"], [1200, 900])
        XCTAssertEqual(e.likeCount, 5)
        XCTAssertEqual(e.likedByMe, true)
        XCTAssertEqual(e.emotes?.first?.emote, "love")
        XCTAssertEqual(e.emotes?.first?.mine, true)
    }

    func testSlimSearchEntry() throws {
        // 搜索返回的瘦条目只有 9 个字段，解码不能因为缺字段而失败
        let json = """
        {"id":"b_s1","content":"带猫的一天","images":[],"created_at":1761000000000,
        "author_id":1,"author_name":"Teddy","author_avatar":null,"author_badge":null,"like_count":3}
        """
        let e = try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(e.id, "b_s1")
        XCTAssertEqual(e.likeCount, 3)
        XCTAssertNil(e.mood)
        XCTAssertNil(e.publishAt)
    }

    func testEntryListAndNotifications() throws {
        let listJSON = """
        {"entries":[],"mailbox_count":2,"trash_count":0,"tl_counts":{"total":10,"priv":1,"pub":9,"next_pub":1762000000000},"delivered_total":null}
        """
        let list = try bearyDecoder().decode(EntryList.self, from: Data(listJSON.utf8))
        XCTAssertEqual(list.entries?.count, 0)
        XCTAssertEqual(list.mailboxCount, 2)
        XCTAssertEqual(list.tlCounts?.pub, 9)
        XCTAssertEqual(list.tlCounts?.nextPub, 1762000000000)

        let ntJSON = """
        {"items":[{"id":11,"type":"like","entry_id":"b_x","created_at":1761000000000,"read":false,
        "actor_id":27,"actor_name":"乐乐","actor_avatar":null,"excerpt":"今天写的第一篇"},
        {"id":12,"type":"system","entry_id":"","created_at":1761000001000,"read":true,
        "title":"你的 Plus 即将到期","body":"你的 Plus 将在 2026 年 11 月 1 日到期。","excerpt":"你的 Plus 将在 2026 年 11 月 1 日到期。"}],
        "unread":1,"sysUnread":0,"total":2}
        """
        let nt = try bearyDecoder().decode(NotificationList.self, from: Data(ntJSON.utf8))
        XCTAssertEqual(nt.items?.count, 2)
        XCTAssertEqual(nt.unread, 1)
        XCTAssertEqual(nt.items?.first?.type, "like")
        XCTAssertEqual(nt.items?.last?.read, true)
    }

    func testSearchAndMe() throws {
        let sJSON = """
        {"users":[{"id":27,"display_name":"乐乐","handle":"lele","avatar_url":"/beary/api/users/27/avatar?v=3","cover_url":null}],
        "entries":[],"mine":null}
        """
        let s = try bearyDecoder().decode(SearchResult.self, from: Data(sJSON.utf8))
        XCTAssertEqual(s.users?.first?.handle, "lele")
        XCTAssertNil(s.mine)

        let meJSON = """
        {"user":{"id":1,"email":"hi@teddyhn.com","display_name":"Teddy","handle":"teddy",
        "avatar":null,"cover_ver":0,"created_at":1759000000000,"plus":true,
        "plus_until":1801324799000,"plus_free":false,"is_admin":true}}
        """
        let me = try bearyDecoder().decode(MeResponse.self, from: Data(meJSON.utf8))
        XCTAssertEqual(me.user?.handle, "teddy")
        XCTAssertEqual(me.user?.isAdmin, true)
        XCTAssertEqual(me.user?.plusUntil, 1801324799000)
    }
}

final class BearyScopeTests: XCTestCase {
    func testScopeValues() {
        XCTAssertEqual(BearyAPI.Scope.plaza.rawValue, "plaza")
        XCTAssertEqual(BearyAPI.Scope.delivered.rawValue, "delivered")
        XCTAssertEqual(BearyAPI.Scope.timeline.rawValue, "timeline")
        XCTAssertEqual(BearyAPI.Scope.authorLiked(27).rawValue, "author_liked")
        XCTAssertEqual(BearyAPI.Scope.author(27).authorId, 27)
        XCTAssertEqual(BearyAPI.Scope.authorLiked(27).authorId, 27)
        XCTAssertNil(BearyAPI.Scope.plaza.authorId)
    }
}

// ===== 批 E 日记位置：模型解码（只验服务端透传字段的解码；展示脱敏与地图聚合
// 在 BearyLocation.swift，不编进本测试包，见 BearyLocationDisplay / BearyLocationMap）=====
final class BearyLocationDecodingTests: XCTestCase {
    func testEntryLocationFields() throws {
        let json = """
        {"id":"b_loc1","author_id":1,"content":"今天在这家店坐了一下午。",
        "location_name":"某某路 123 号 · 示例咖啡馆","location_district":"鄞州区",
        "created_at":1761000000000,"is_public":true}
        """
        let e = try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(e.locationName, "某某路 123 号 · 示例咖啡馆")
        XCTAssertEqual(e.locationDistrict, "鄞州区")
    }

    func testEntryLocationFieldsMissing() throws {
        // 老日记/服务端未透传时两字段缺省为 nil，展示层按无位置处理，不崩解码。
        let json = """
        {"id":"b_loc2","author_id":1,"content":"没有位置的日记。",
        "created_at":1761000000000,"is_public":false}
        """
        let e = try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertNil(e.locationName)
        XCTAssertNil(e.locationDistrict)
    }
}

// ===== 日记星图：纯逻辑单测（BearyStarMap.swift 同编进测试 target；
// 不依赖 UIKit / BearyNativeCommon / BearyLocation / SessionManager）=====
final class BearyStarMapTests: XCTestCase {
    private func entry(_ json: String) throws -> Entry {
        try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
    }

    private func ms(year: Int, month: Int, day: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        let date = Calendar.current.date(from: comps)!
        return Int(date.timeIntervalSince1970 * 1000)
    }

    func testPositionIsDeterministicAndBounded() {
        let a = BearyStarMap.position(forEntryId: "b_star1")
        let b = BearyStarMap.position(forEntryId: "b_star1")
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, b.y)
        XCTAssertTrue(a.x >= 0 && a.x < 1 && a.y >= 0 && a.y < 1)
        // 两 id 不同位（FNV-1a 碰撞概率可忽略；若此断言抖动，先查哈希实现而非放宽）。
        let c = BearyStarMap.position(forEntryId: "b_star2")
        XCTAssertTrue(a.x != c.x || a.y != c.y)
    }

    func testFilterFailClosedForOther() throws {
        let pub = try entry("{\"id\":\"b_pub\",\"content\":\"公开篇。\",\"is_public\":true}")
        let priv = try entry("{\"id\":\"b_priv\",\"content\":\"私密篇。\",\"is_public\":false}")
        let missing = try entry("{\"id\":\"b_missing\",\"content\":\"未标公开态。\"}")
        let placeholder = try entry("{\"id\":\"b_ph\",\"content\":\"占位壳。\",\"is_public\":true,\"placeholder\":true}")
        let expired = try entry("{\"id\":\"b_exp\",\"content\":\"限时过期。\",\"is_public\":true,\"ephemeral_until\":1000}")
        let noId = try entry("{\"content\":\"无 id。\",\"is_public\":true}")
        let all = [pub, priv, missing, placeholder, expired, noId]
        let otherIds = Set(BearyStarMap.visibleEntries(all, viewerIsAuthor: false).compactMap { $0.id })
        XCTAssertEqual(otherIds, ["b_pub"])
        let ownIds = Set(BearyStarMap.visibleEntries(all, viewerIsAuthor: true).compactMap { $0.id })
        XCTAssertEqual(ownIds, ["b_pub", "b_priv", "b_missing", "b_exp"])
    }

    func testPlaceEdgeDistrictOnlyForOther() throws {
        // 同精确名、不同区级：他人视角不成同地点边（精确名不作键）。
        let a = try entry("{\"id\":\"b_pa\",\"content\":\"甲篇内容甲。\",\"is_public\":true,\"location_name\":\"示例咖啡馆\",\"location_district\":\"甲区\"}")
        let b = try entry("{\"id\":\"b_pb\",\"content\":\"乙篇内容乙。\",\"is_public\":true,\"location_name\":\"示例咖啡馆\",\"location_district\":\"乙区\"}")
        let otherModel = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: false)
        XCTAssertTrue(otherModel.edges.allSatisfy { !$0.reasons.contains(where: { $0.kind == .place }) })
        // 同区级、不同精确名：他人视角成边且原因只带区级；本人视角成边带精确名。
        let c = try entry("{\"id\":\"b_pc\",\"content\":\"丙篇内容丙。\",\"is_public\":true,\"location_name\":\"甲店\",\"location_district\":\"同区\"}")
        let d = try entry("{\"id\":\"b_pd\",\"content\":\"丁篇内容丁。\",\"is_public\":true,\"location_name\":\"乙店\",\"location_district\":\"同区\"}")
        let otherModel2 = BearyStarMap.buildModel(entries: [c, d], viewerIsAuthor: false)
        XCTAssertEqual(otherModel2.edges.count, 1)
        XCTAssertEqual(otherModel2.edges[0].reasons.filter { $0.kind == .place }.map { $0.detail }, ["同区"])
        let ownModel = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        XCTAssertEqual(ownModel.edges.count, 1)
        XCTAssertEqual(ownModel.edges[0].reasons.filter { $0.kind == .place }.map { $0.detail }, ["示例咖啡馆"])
    }

    func testMoodAndWordEdges() throws {
        let a = try entry("{\"id\":\"b_ma\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let b = try entry("{\"id\":\"b_mb\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":true}")
        let model = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        XCTAssertEqual(model.edges.count, 1)
        XCTAssertTrue(model.edges[0].reasons.contains(where: { $0.kind == .mood && $0.detail == "happy" }))
        let wordReasons = model.edges[0].reasons.filter { $0.kind == .word }
        XCTAssertEqual(wordReasons.count, 1)
        XCTAssertTrue(wordReasons[0].tokens.contains("桂花"))
    }

    func testHighFrequencyWordDoesNotConnect() throws {
        // 4 篇都含“今天”：文档频率 4 > 上限 max(2, 4/2)=2，高频词不连线；
        // 且各篇心情不同、无地点，避免其他原因成边。
        let jsons = [
            "{\"id\":\"b_hf1\",\"content\":\"今天。\",\"mood\":\"happy\",\"is_public\":true}",
            "{\"id\":\"b_hf2\",\"content\":\"今天好。\",\"mood\":\"cry\",\"is_public\":true}",
            "{\"id\":\"b_hf3\",\"content\":\"今天呀。\",\"mood\":\"angry\",\"is_public\":true}",
            "{\"id\":\"b_hf4\",\"content\":\"今天呢。\",\"mood\":\"lonely\",\"is_public\":true}",
        ]
        let entries = try jsons.map { try entry($0) }
        let model = BearyStarMap.buildModel(entries: entries, viewerIsAuthor: true)
        XCTAssertTrue(model.edges.isEmpty)
    }

    func testPrivateEntryTakesItsEdgesWithIt() throws {
        let pub = try entry("{\"id\":\"b_ea\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let priv = try entry("{\"id\":\"b_eb\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":false}")
        let model = BearyStarMap.buildModel(entries: [pub, priv], viewerIsAuthor: false)
        XCTAssertEqual(model.stars.map { $0.entry.id }, ["b_ea"])
        XCTAssertTrue(model.edges.isEmpty)
    }

    func testWordCountRadiusBrightness() throws {
        let e = try entry("{\"id\":\"b_wc\",\"title\":\"标题\",\"content\":\"正文 四字。\",\"mood\":\"happy\",\"is_public\":true}")
        // 标题 2 + 正文去空白 5 = 7。
        XCTAssertEqual(BearyStarMap.wordCount(e), 7)
        XCTAssertTrue(BearyStarMap.radius(forWordCount: 700) > BearyStarMap.radius(forWordCount: 7))
        XCTAssertEqual(BearyStarMap.radius(forWordCount: 0), 6)
        XCTAssertEqual(BearyStarMap.brightness(forMoodKey: "happy"), 1.0)
        XCTAssertEqual(BearyStarMap.brightness(forMoodKey: "cry"), 0.40)
        XCTAssertEqual(BearyStarMap.brightness(forMoodKey: "some_future_key"), 0.75)
        XCTAssertEqual(BearyStarMap.brightness(forMoodKey: nil), 0.70)
    }

    func testSlicingAndDefaultSlice() throws {
        let oct = try entry("{\"id\":\"b_oct\",\"content\":\"十月篇。\",\"is_public\":true,\"created_at\":\(ms(year: 2026, month: 10, day: 3))}")
        let nov = try entry("{\"id\":\"b_nov\",\"content\":\"十一月篇。\",\"is_public\":true,\"created_at\":\(ms(year: 2026, month: 11, day: 5))}")
        let undated = try entry("{\"id\":\"b_und\",\"content\":\"无日期篇。\",\"is_public\":true}")
        let entries = [oct, nov, undated]
        XCTAssertEqual(BearyStarMap.years(in: entries), [2026])
        XCTAssertEqual(BearyStarMap.months(in: entries, year: 2026), [11, 10])
        XCTAssertTrue(BearyStarMap.hasUndated(in: entries))
        XCTAssertEqual(BearyStarMap.entries(in: entries, slice: .month(year: 2026, month: 10)).map { $0.id }, ["b_oct"])
        XCTAssertEqual(BearyStarMap.entries(in: entries, slice: .undated).map { $0.id }, ["b_und"])
        XCTAssertEqual(BearyStarMap.defaultSlice(for: entries), .all)
        // 81 篇（> 阈值 80）默认最新年最新月，不铺全量。
        var many: [Entry] = []
        for i in 0..<81 {
            many.append(try entry("{\"id\":\"b_many\(i)\",\"content\":\"第\(i)篇。\",\"is_public\":true,\"created_at\":\(ms(year: 2026, month: 11, day: 5))}"))
        }
        XCTAssertEqual(BearyStarMap.defaultSlice(for: many), .month(year: 2026, month: 11))
// ===== 与过去的自己对话：日期 / 串状态 / 可见性 / 存储（纯逻辑；UI 在 ProfileVC）=====
final class BearyPastSelfTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func ms(year: Int, month: Int, day: Int) -> Int {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Int(date.timeIntervalSince1970 * 1000)
    }

    private func message(id: String, chain: String, createdMs: Int, deliverOn: String, revokedMs: Int? = nil) -> PastSelfMessage {
        PastSelfMessage(id: id, originEntryId: chain, chainId: chain, authorId: 1, body: "留话 \(id)",
                        createdAtMs: createdMs, deliverOn: deliverOn, revokedAtMs: revokedMs,
                        replyToMessageId: nil, localOnly: false)
    }

    func testNextYearNormalAndLeapDay() {
        XCTAssertEqual(PastSelfLogic.nextYearDateString(fromMs: ms(year: 2025, month: 10, day: 30), calendar: calendar), "2026-10-30")
        // 2 月 29 日不跳 3 月 1 日、不丢推送，退到 2 月 28 日。
        XCTAssertEqual(PastSelfLogic.nextYearDateString(fromMs: ms(year: 2024, month: 2, day: 29), calendar: calendar), "2025-02-28")
    }

    func testThreadStateTransitions() {
        let first = message(id: "m1", chain: "b_1", createdMs: ms(year: 2025, month: 10, day: 30), deliverOn: "2026-10-30")
        // 未到送达日：等待态（那年今日卡内「已留话 · 明年见」，不进送达卡）。
        if case .waiting(let waiting) = PastSelfLogic.threadState([first], chainId: "b_1", today: "2026-10-29") {
            XCTAssertEqual(waiting.id, "m1")
        } else {
            XCTFail("expected waiting before deliver day")
        }
        // 送达日当天及之后：送达态一直保留，直到再回一句（不只推一天）。
        if case .due(_, let latest) = PastSelfLogic.threadState([first], chainId: "b_1", today: "2026-11-05") {
            XCTAssertEqual(latest.id, "m1")
        } else {
            XCTFail("expected due after deliver day")
        }
        // 再回一句后：最新行等明年，此前有已送达行 → 已回态（不再出「再回一句」）。
        let second = message(id: "m2", chain: "b_1", createdMs: ms(year: 2026, month: 10, day: 30), deliverOn: "2027-10-30")
        if case .answered(let waiting, let chain) = PastSelfLogic.threadState([first, second], chainId: "b_1", today: "2026-11-05") {
            XCTAssertEqual(waiting.id, "m2")
            XCTAssertEqual(chain.count, 2)
        } else {
            XCTFail("expected answered after reply")
        }
        // 撤回行不计入链。
        let revoked = message(id: "m3", chain: "b_1", createdMs: ms(year: 2026, month: 10, day: 31), deliverOn: "2027-10-31", revokedMs: 1)
        XCTAssertEqual(PastSelfLogic.liveChainMessages([first, second, revoked], chainId: "b_1").map { $0.id }, ["m1", "m2"])
    }

    func testVisibilityFailClosed() throws {
        // 语料未到齐不猜：返回 nil，调用方不渲染。
        XCTAssertNil(PastSelfVisibility.viewerVisibility(origin: nil, viewerIsAuthor: true, corpusComplete: false))
        // 到齐仍无原篇 = 已删（作者与他人都只见占位，内容不渲染）。
        XCTAssertEqual(PastSelfVisibility.viewerVisibility(origin: nil, viewerIsAuthor: true, corpusComplete: true), .deleted)
        // 他人永远只见占位，即使原篇公开（对话只推本人）。
        var publicEntry = try bearyDecoder().decode(Entry.self, from: Data("{\"id\":\"b_1\",\"is_public\":true}".utf8))
        XCTAssertEqual(PastSelfVisibility.viewerVisibility(origin: publicEntry, viewerIsAuthor: false, corpusComplete: true), .authorOnly)
        XCTAssertEqual(PastSelfVisibility.viewerVisibility(origin: publicEntry, viewerIsAuthor: true, corpusComplete: true), .full)
        // 作者看自己的私密原篇：全文 + 私密提示。
        publicEntry.isPublic = false
        XCTAssertEqual(PastSelfVisibility.viewerVisibility(origin: publicEntry, viewerIsAuthor: true, corpusComplete: true), .privateNote)
        // iCity 私密占位同样按私密处理。
        publicEntry.placeholder = true
        XCTAssertEqual(PastSelfVisibility.viewerVisibility(origin: publicEntry, viewerIsAuthor: true, corpusComplete: true), .privateNote)
    }

    func testStoreDuplicateWaitingAndRevoke() throws {
        let suite = UserDefaults(suiteName: "beary.pastself.tests")!
        suite.removePersistentDomain(forName: "beary.pastself.tests")
        let store = PastSelfStore(userId: 99, defaults: suite)
        let created = ms(year: 2025, month: 10, day: 30)
        let first = store.add(originEntryId: "b_9", body: "第一句", createdAtMs: created, calendar: calendar)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.deliverOn, "2026-10-30")
        // 同一链已有等待中的留话时，第二句被拒（防同一天堆两条同日送达）。
        XCTAssertNil(store.add(originEntryId: "b_9", body: "第二句", createdAtMs: created, calendar: calendar))
        // 撤回等待中的最新行成功；已送达行不可撤回。
        XCTAssertTrue(store.revoke(messageId: first!.id, nowMs: created, today: "2026-01-01"))
        XCTAssertFalse(store.revoke(messageId: first.id, nowMs: created, today: "2026-01-01"))
        let delivered = store.add(originEntryId: "b_8", body: "旧句", createdAtMs: created, calendar: calendar)!
        XCTAssertFalse(store.revoke(messageId: delivered.id, nowMs: created, today: "2026-10-30"))
        // 按用户隔离：另一用户看不到本用户的留话。
        XCTAssertTrue(PastSelfStore(userId: 100, defaults: suite).loadAll().isEmpty)
        suite.removePersistentDomain(forName: "beary.pastself.tests")
    }

    func testMergePreservesLocalRevoke() throws {
        let suite = UserDefaults(suiteName: "beary.pastself.tests")!
        suite.removePersistentDomain(forName: "beary.pastself.tests")
        let store = PastSelfStore(userId: 98, defaults: suite)
        let created = ms(year: 2025, month: 10, day: 30)
        let local = store.add(originEntryId: "b_7", body: "待同步句", createdAtMs: created, calendar: calendar)!
        XCTAssertTrue(store.revoke(messageId: local.id, nowMs: created, today: "2026-01-01"))
        // 服务端回包仍是未撤回旧态时，本地撤回标记不被冲掉。
        var serverRow = local
        serverRow.revokedAtMs = nil
        serverRow.localOnly = false
        store.mergeServerRows([serverRow])
        XCTAssertEqual(store.loadAll().first?.revokedAtMs, created)
        suite.removePersistentDomain(forName: "beary.pastself.tests")
    }

    func testMessageDecoding() throws {
        let json = """
        {"id":"ps_1","origin_entry_id":"b_1","chain_id":"b_1","author_id":1,"body":"少熬一点夜",
        "created_at":1761780000000,"deliver_on":"2026-10-30","revoked_at":null,"reply_to_message_id":null}
        """
        let decoded = try bearyDecoder().decode(PastSelfMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.originEntryId, "b_1")
        XCTAssertEqual(decoded.body, "少熬一点夜")
        XCTAssertEqual(decoded.createdAtMs, 1761780000000)
        XCTAssertEqual(decoded.deliverOn, "2026-10-30")
        XCTAssertFalse(decoded.localOnly)
    }
}

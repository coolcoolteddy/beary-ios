import XCTest
import UIKit

// ===== 第一阶段单测：路由解析 + 模型解码 + Scope =====
// 注意：测试 target 不带宿主 App，直接把 BearyAPI.swift 与 BearyNavigator.swift 编进测试包，
// 因此这里不 import App、不走 @testable；跑法见 workflow 的 test 任务。
// 审计三轮第 18 项另把 BearyDraftFiles.swift、BearyEntrySync.swift、BearyDiaryPin.swift
// 编进测试包（pbxproj 同款做法），替身说明见文件末尾“第 18 项”一节。

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
        "author_cover":null,"author_plus":1,"content":"今天写的第一篇",
        "images":["img1.jpg"],"img_dims":{"img1.jpg":[1200,900]},"mood":"love","weather":"sunny",
        "quote_id":null,"quote":null,"created_at":1761000000000,"publish_at":1761604800000,
        "edit_deadline":1761000900000,"is_public":true,"is_locked":true,"is_mine":false,
        "like_count":5,"liked_by_me":true,"bookmarked_by_me":false,"recipient_id":null,
        "recipient_name":null,"emotes":[{"emote":"love","count":2,"mine":true}]}
        """
        let e = try bearyDecoder().decode(Entry.self, from: Data(json.utf8))
        XCTAssertEqual(e.id, "b_test1")
        XCTAssertEqual(e.authorId, 27)
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
        "author_id":1,"author_name":"Teddy","author_avatar":null,"like_count":3}
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

// ===== 第十轮 03：TrashItem 编码—解码往返 =====
// saveAll 经 convertToSnakeCase 编码写 trash.json，loadAll 经
// convertFromSnakeCase 解码读回；旧版 encode 漏了 title 与 imageKeys，
// 往返即丢——回收站标题退化、彻底删除后图片缓存精确逐出失效。
final class BearyTrashItemTests: XCTestCase {
    func testRoundTripKeepsTitleAndImageKeys() throws {
        let json = """
        {"id":"b_trash1","content":"今天写的第一篇","title":"带猫的一天",
        "images":["1/abc.jpg","1/def.jpg"],"created_at":1761000000000,
        "publish_at":1761604800000,"published":1,"visibility":"public",
        "deleted_at":1761700000000,"days_left":29}
        """
        let decoded = try bearyDecoder().decode(TrashItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.title, "带猫的一天")
        XCTAssertEqual(decoded.imageKeys, ["1/abc.jpg", "1/def.jpg"])

        // 与 BearyTrashSyncStore.makeEncoder 同口径：convertToSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(decoded)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"title\""))
        XCTAssertTrue(raw.contains("\"images\""))

        let roundTripped = try bearyDecoder().decode(TrashItem.self, from: data)
        XCTAssertEqual(roundTripped.id, "b_trash1")
        XCTAssertEqual(roundTripped.title, "带猫的一天")
        XCTAssertEqual(roundTripped.imageKeys, ["1/abc.jpg", "1/def.jpg"])
        XCTAssertEqual(roundTripped.content, "今天写的第一篇")
        XCTAssertEqual(roundTripped.daysLeft, 29)
    }

    func testOldCacheWithoutTitleAndImagesStillDecodes() throws {
        // 旧版 trash.json 缺 title 与 images 两键，仍须能解码（按 nil 读）
        let json = """
        {"id":"b_old1","content":"旧缓存的一篇","created_at":1761000000000,
        "deleted_at":1761700000000,"days_left":12}
        """
        let decoded = try bearyDecoder().decode(TrashItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, "b_old1")
        XCTAssertNil(decoded.title)
        XCTAssertNil(decoded.imageKeys)
        XCTAssertEqual(decoded.daysLeft, 12)
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
    }

    // MARK: - r17 C5：日记版本指纹 + 建图内存缓存

    func testDiaryVersionStableAcrossReorderAndSensitiveToEdits() throws {
        let a = try entry("{\"id\":\"b_v1\",\"title\":\"甲\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true,\"created_at\":\(ms(year: 2026, month: 11, day: 5))}")
        let b = try entry("{\"id\":\"b_v2\",\"title\":\"乙\",\"content\":\"桂花香满路。\",\"mood\":\"cry\",\"is_public\":true,\"created_at\":\(ms(year: 2026, month: 11, day: 4))}")
        let base = BearyStarMap.diaryVersion(entries: [a, b], viewerIsAuthor: true)
        // 同一集合换顺序，指纹不变（fetch 顺序不触发重建）。
        XCTAssertEqual(BearyStarMap.diaryVersion(entries: [b, a], viewerIsAuthor: true), base)
        // 改正文：整片词频都可能变，指纹必须变。
        var edited = b
        edited.content = "桂花落了一地。"
        XCTAssertNotEqual(BearyStarMap.diaryVersion(entries: [a, edited], viewerIsAuthor: true), base)
        // 改心情：亮度与同心情边都变，指纹必须变。
        var moodEdited = b
        moodEdited.mood = "happy"
        XCTAssertNotEqual(BearyStarMap.diaryVersion(entries: [a, moodEdited], viewerIsAuthor: true), base)
        // 改公开态：过滤集合变，指纹必须变。
        var visEdited = b
        visEdited.isPublic = false
        XCTAssertNotEqual(BearyStarMap.diaryVersion(entries: [a, visEdited], viewerIsAuthor: true), base)
    }

    func testDiaryVersionDiffersByViewerRole() throws {
        let a = try entry("{\"id\":\"b_vr1\",\"content\":\"甲篇内容甲。\",\"is_public\":true,\"location_name\":\"示例咖啡馆\",\"location_district\":\"甲区\"}")
        let b = try entry("{\"id\":\"b_vr2\",\"content\":\"乙篇内容乙。\",\"is_public\":true,\"location_name\":\"示例咖啡馆\",\"location_district\":\"甲区\"}")
        // 同一片、本人与他人地点键不同（精确名 vs 区级），指纹必须区分。
        XCTAssertNotEqual(
            BearyStarMap.diaryVersion(entries: [a, b], viewerIsAuthor: true),
            BearyStarMap.diaryVersion(entries: [a, b], viewerIsAuthor: false))
    }

    func testModelCacheHitMissPurgeAndEviction() throws {
        BearyStarMapCache.purgeAll()
        let a = try entry("{\"id\":\"b_c1\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let b = try entry("{\"id\":\"b_c2\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":true}")
        let model = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        let account = BearyStarMapCache.accountKey(viewerId: 7, authorId: 7, viewerIsAuthor: true)
        let version = BearyStarMap.diaryVersion(entries: [a, b], viewerIsAuthor: true)
        let key = BearyStarMapCache.key(account: account, slice: .all, diaryVersion: version)
        XCTAssertNil(BearyStarMapCache.lookup(key: key))
        BearyStarMapCache.store(key: key, model: model)
        // 命中：同一键取回同一模型（星数与边数一致）。
        let hit = BearyStarMapCache.lookup(key: key)
        XCTAssertEqual(hit?.stars.count, 2)
        XCTAssertEqual(hit?.edges.count, 1)
        // 改一篇正文 → 版本变 → miss，不取回旧模型。
        var edited = b
        edited.content = "换了内容。"
        let newVersion = BearyStarMap.diaryVersion(entries: [a, edited], viewerIsAuthor: true)
        XCTAssertNil(BearyStarMapCache.lookup(key: BearyStarMapCache.key(account: account, slice: .all, diaryVersion: newVersion)))
        // 切分片 → 另一键 → miss。
        XCTAssertNil(BearyStarMapCache.lookup(key: BearyStarMapCache.key(account: account, slice: .month(year: 2026, month: 11), diaryVersion: version)))
        // 算法版本变 → 旧键失效（key 默认取当前算法版本；显式旧版本查不到）。
        XCTAssertNil(BearyStarMapCache.lookup(key: BearyStarMapCache.key(account: account, slice: .all, diaryVersion: version, algorithmVersion: BearyStarMap.algorithmVersion + 1)))
        // 退出 / 401 按账号桶清：该账号的槽位全清，别人的不动。
        let otherAccount = BearyStarMapCache.accountKey(viewerId: 8, authorId: 8, viewerIsAuthor: true)
        let otherKey = BearyStarMapCache.key(account: otherAccount, slice: .all, diaryVersion: version)
        BearyStarMapCache.store(key: otherKey, model: model)
        BearyStarMapCache.purge(viewerBucket: "7")
        XCTAssertNil(BearyStarMapCache.lookup(key: key))
        XCTAssertNotNil(BearyStarMapCache.lookup(key: otherKey))
        // 超容逐出最久未用：再存 4 个新键（上限 4），最早的 otherKey 被逐出。
        for i in 0..<4 {
            let k = BearyStarMapCache.key(account: otherAccount, slice: .year(2020 + i), diaryVersion: version)
            BearyStarMapCache.store(key: k, model: model)
        }
        XCTAssertNil(BearyStarMapCache.lookup(key: otherKey))
        BearyStarMapCache.purgeAll()
    }

    // MARK: - r17 M2：新旧模型差分（星 id / 边 id）

    func testDiffFindsNewStarsAndEdges() throws {
        let a = try entry("{\"id\":\"b_d1\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let b = try entry("{\"id\":\"b_d2\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":true}")
        let old = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        XCTAssertEqual(old.edges.count, 1)
        // 新增一篇：同心情 + 同词，与旧两篇各连一条新线。
        let c = try entry("{\"id\":\"b_d3\",\"content\":\"桂花落在湖边。\",\"mood\":\"happy\",\"is_public\":true}")
        let new = BearyStarMap.buildModel(entries: [a, b, c], viewerIsAuthor: true)
        let diff = BearyStarMap.diff(old: old, new: new)
        XCTAssertEqual(diff.newStarIds, ["b_d3"])
        XCTAssertTrue(diff.removedStarIds.isEmpty)
        XCTAssertEqual(diff.newEdgeIds.count, 2)
        XCTAssertTrue(diff.newEdgeIds.allSatisfy { $0.contains("b_d3") })
        XCTAssertTrue(diff.removedEdgeIds.isEmpty)
        // 旧 a–b 边仍在，但“桂花”文档频率升到 3、超上限 max(2, 3/2)=2，
        // 同词理由被抑制，只剩同心情——算理由变，不算新线。
        XCTAssertEqual(diff.changedEdgeIds, [old.edges[0].id])
    }

    func testDiffChangedEdgeReasonsOnly() throws {
        // 两篇同心情 + 同词：边带 mood 与 word 两条理由。
        let a = try entry("{\"id\":\"b_r1\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let b = try entry("{\"id\":\"b_r2\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":true}")
        let old = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        XCTAssertEqual(old.edges.count, 1)
        XCTAssertEqual(old.edges[0].reasons.count, 2)
        // 只改一篇心情：边还在（同词），理由少一条 mood——只算理由变，
        // 不算新线、不算新星。
        var moodEdited = b
        moodEdited.mood = "cry"
        let new = BearyStarMap.buildModel(entries: [a, moodEdited], viewerIsAuthor: true)
        let diff = BearyStarMap.diff(old: old, new: new)
        XCTAssertEqual(diff.newStarIds, [])
        XCTAssertEqual(diff.newEdgeIds, [])
        XCTAssertEqual(diff.changedEdgeIds, [old.edges[0].id])
        XCTAssertEqual(new.edges[0].reasons.count, 1)
        XCTAssertEqual(new.edges[0].reasons[0].kind, .word)
    }

    func testDiffRemovedStarsAndFirstLoad() throws {
        let a = try entry("{\"id\":\"b_x1\",\"content\":\"湖边桂花开了。\",\"mood\":\"happy\",\"is_public\":true}")
        let b = try entry("{\"id\":\"b_x2\",\"content\":\"桂花香满路。\",\"mood\":\"happy\",\"is_public\":true}")
        let old = BearyStarMap.buildModel(entries: [a, b], viewerIsAuthor: true)
        // 删一篇：星与边一起消失。
        let new = BearyStarMap.buildModel(entries: [a], viewerIsAuthor: true)
        let diff = BearyStarMap.diff(old: old, new: new)
        XCTAssertEqual(diff.removedStarIds, ["b_x2"])
        XCTAssertEqual(diff.removedEdgeIds, [old.edges[0].id])
        XCTAssertTrue(diff.newStarIds.isEmpty && diff.newEdgeIds.isEmpty)
        // 首次建图（old 为 nil）：全部星与边都是新的。
        let first = BearyStarMap.diff(old: nil, new: old)
        XCTAssertEqual(first.newStarIds, ["b_x1", "b_x2"])
        XCTAssertEqual(first.newEdgeIds, [old.edges[0].id])
    }
}

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
        XCTAssertFalse(store.revoke(messageId: first!.id, nowMs: created, today: "2026-01-01"))
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

    func testCorruptStoreBlocksAllWrites() throws {
        // 审计新一轮 05：存储损坏后，add / revoke / merge / replace / remove
        // 全都不覆盖，原始数据原样保留。
        let suite = UserDefaults(suiteName: "beary.pastself.tests")!
        suite.removePersistentDomain(forName: "beary.pastself.tests")
        let store = PastSelfStore(userId: 97, defaults: suite)
        let created = ms(year: 2025, month: 10, day: 30)
        let first = store.add(originEntryId: "b_6", body: "别丢我", createdAtMs: created, calendar: calendar)!
        let mainKey = "beary.pastSelf.v1.97"
        // 模拟损坏：主 key 写进解不出的字节。
        suite.set(Data("坏了".utf8), forKey: mainKey)
        if case .corrupt = store.loadOutcome() {} else {
            XCTFail("损坏的存储应判为 corrupt")
        }
        XCTAssertTrue(store.isStoreCorrupt)
        // 新增被拒，且原因可区分（不是“已有等待中”也不是“已满”）。
        XCTAssertNil(store.add(originEntryId: "b_5", body: "新一句", createdAtMs: created, calendar: calendar))
        XCTAssertEqual(store.lastRejection, .storeCorrupt)
        // 其余写路径同样不覆盖：原始坏字节原样保留。
        XCTAssertFalse(store.revoke(messageId: first.id, nowMs: created, today: "2026-01-01"))
        store.mergeServerRows([first])
        store.replaceLocalRow(localId: first.id, with: first)
        store.removeLocalRow(id: first.id)
        XCTAssertEqual(suite.data(forKey: mainKey), Data("坏了".utf8))
        suite.removePersistentDomain(forName: "beary.pastself.tests")
    }

    func testMergeIntoEmptyStoreImportsServerRows() throws {
        // 回炉：空库（.empty）与损坏（.corrupt）走不同路——空库时服务端
        // 行能正常合进来（新设备首次同步从服务端拉回留话），损坏时才拦。
        let suite = UserDefaults(suiteName: "beary.pastself.tests")!
        suite.removePersistentDomain(forName: "beary.pastself.tests")
        let store = PastSelfStore(userId: 94, defaults: suite)
        let created = ms(year: 2025, month: 10, day: 30)
        if case .empty = store.loadOutcome() {} else {
            XCTFail("空库应判为 empty")
        }
        var serverRow = message(id: "ps_s1", chain: "b_2", createdMs: created, deliverOn: "2026-10-30")
        serverRow.authorId = 94
        store.mergeServerRows([serverRow])
        XCTAssertEqual(store.loadAll().map { $0.id }, ["ps_s1"])
        suite.removePersistentDomain(forName: "beary.pastself.tests")
    }

    func testBackupKeepsLastGoodAndRestores() throws {
        // 审计新一轮 05：每次成功写入前，上一份好数据进独立备份 key；
        // 主 key 损坏后可从备份恢复，无备份时恢复失败、主 key 不动。
        let suite = UserDefaults(suiteName: "beary.pastself.tests")!
        suite.removePersistentDomain(forName: "beary.pastself.tests")
        let store = PastSelfStore(userId: 96, defaults: suite)
        let created = ms(year: 2025, month: 10, day: 30)
        let first = store.add(originEntryId: "b_4", body: "第一句", createdAtMs: created, calendar: calendar)!
        // 首写无旧数据，备份 key 还是空的。
        XCTAssertNil(suite.data(forKey: "beary.pastSelf.v1.96.bak"))
        XCTAssertNotNil(store.add(originEntryId: "b_3", body: "第二句", createdAtMs: created, calendar: calendar))
        // 第二次写入前，上一份好数据（只有第一句）已进备份 key。
        let backup = try JSONDecoder().decode([PastSelfMessage].self, from: suite.data(forKey: "beary.pastSelf.v1.96.bak")!)
        XCTAssertEqual(backup.map { $0.id }, [first.id])
        // 主 key 损坏 → 从备份恢复，回到上一份好数据；损坏后新写被拒，备份不被坏数据污染。
        suite.set(Data("坏了".utf8), forKey: "beary.pastSelf.v1.96")
        XCTAssertNil(store.add(originEntryId: "b_2", body: "第三句", createdAtMs: created, calendar: calendar))
        XCTAssertTrue(store.restoreFromBackup())
        XCTAssertEqual(store.loadAll().map { $0.id }, [first.id])
        // 无备份时恢复失败，主 key 原样不动。
        suite.set(Data("坏了".utf8), forKey: "beary.pastSelf.v1.95")
        XCTAssertFalse(PastSelfStore(userId: 95, defaults: suite).restoreFromBackup())
        XCTAssertEqual(suite.data(forKey: "beary.pastSelf.v1.95"), Data("坏了".utf8))
        suite.removePersistentDomain(forName: "beary.pastself.tests")
    }

    func testMessageDecoding() throws {
        let json = """
        {"id":"ps_1","origin_entry_id":"b_1","chain_id":"b_1","author_id":1,"body":"少熬一点夜",
        "created_at":1761780000000,"deliver_on":"2026-10-30","revoked_at":null,"reply_to_message_id":null}
        """
        // PastSelfMessage 用显式 snake_case CodingKeys，与 convertFromSnakeCase
        // 叠加会 keyNotFound；产品侧 PastSelf 三个端点同样走 plain 解码器
        // （BearyAPI.pastSelfDecoder），此处与产品口径一致。共享的
        // bearyDecoder() 本身不动（其余类型依赖 convert 策略）。
        let decoded = try JSONDecoder().decode(PastSelfMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.originEntryId, "b_1")
        XCTAssertEqual(decoded.body, "少熬一点夜")
        XCTAssertEqual(decoded.createdAtMs, 1761780000000)
        XCTAssertEqual(decoded.deliverOn, "2026-10-30")
        XCTAssertFalse(decoded.localOnly)
    }
}

// ===== 秒开-网络层：API 专用会话配置 =====
// 只断言配置本身（连接复用口径 + 账号无关缓存关闭 + 共享 cookie 桶），
// 不发真实网络；BearyAPI.swift 本就编进测试包，BearyNetwork 配置
// 不依赖 NativeCommon，故测试目标无需新增文件。
final class BearyNetworkTests: XCTestCase {
    func testDedicatedSessionConfig() {
        let session = BearyAPI.makeDedicatedSession()
        XCTAssertEqual(session.configuration.httpMaximumConnectionsPerHost, 6)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertTrue(session.configuration.httpCookieStorage === HTTPCookieStorage.shared)
        XCTAssertTrue(session.configuration.httpShouldSetCookies)
    }
}

// ===== 第 7 轮 #7：会话列表 A→B→A 快切，旧请求回包过期判定 =====
// 只比账号 ID 的旧口径下，A→B→A 后旧 A 请求回包时账号 ID 再次相等，
// 会通过校验、把过期会话写回新列表；本测试用可控的代次推进复现：
// 不发真实网络，只推进 (账号 ID, authEpoch) 这一对判定输入——
// 旧请求发起时捕获 (A, 5)，切到 B 再切回 A 后当前为 (A, 7)，
// 账号 ID 相同但代次已变，判定必须为过期。
final class BearyAccountLoadStalenessTests: XCTestCase {
    func testSameAccountSameEpochIsFresh() {
        XCTAssertFalse(BearyAPI.isStaleAccountLoad(requestAccountId: 1, requestEpoch: 5, currentAccountId: 1, currentEpoch: 5))
    }

    func testAccountChangedIsStale() {
        XCTAssertTrue(BearyAPI.isStaleAccountLoad(requestAccountId: 1, requestEpoch: 5, currentAccountId: 2, currentEpoch: 6))
    }

    func testABABackToAWithAdvancedEpochIsStale() {
        // 复现：A 发起加载 (A, epoch 5) 后切到 B (epoch 6)，再切回 A (epoch 7)；
        // 旧 A 请求此时回包——账号 ID 再次相等（旧口径会放行），代次不等必须丢弃。
        let requestAccountId = 1
        let requestEpoch = 5
        let currentAccountId = 1
        let currentEpoch = 7
        XCTAssertEqual(currentAccountId, requestAccountId, "旧口径只比账号 ID：此时相等，会误放行旧回包")
        XCTAssertTrue(BearyAPI.isStaleAccountLoad(requestAccountId: requestAccountId, requestEpoch: requestEpoch, currentAccountId: currentAccountId, currentEpoch: currentEpoch))
    }

    func testLoggedOutIsStale() {
        XCTAssertTrue(BearyAPI.isStaleAccountLoad(requestAccountId: 1, requestEpoch: 5, currentAccountId: nil, currentEpoch: 6))
    }
}

// ===== 第七轮 #4：私信持久化后台化回归 =====
// BearyDMStore 的磁盘读写只走专用串行后台队列；调用方只拿回调结果，
// 不再同步返回值。测试用随机账号 id（内存索引按账号隔离、互不干扰），
// 每个用例结束删掉自己账号的本地文件，不碰真实账号数据。
// 类名与 BearyDMStoreTests.swift 的损坏保护测试类区分（同名会重复定义）。
final class BearyDMStoreBackgroundTests: XCTestCase {
    private var accountId: Int = 0

    override func setUp() {
        super.setUp()
        accountId = Int.random(in: 1_000_000...9_999_999)
    }

    override func tearDown() {
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("beary_dm_\(accountId).json"))
        }
        super.tearDown()
    }

    private func peer(_ id: Int) -> BearyAPI.FriendUser {
        BearyAPI.FriendUser(id: id, displayName: "对方\(id)", handle: "peer\(id)", avatarUrl: nil, createdAt: nil)
    }

    private func msg(_ id: Int, sender: Int = 7, body: String? = nil) -> BearyAPI.DMMessage {
        BearyAPI.DMMessage(id: id, senderId: sender, body: body ?? "消息\(id)", createdAt: id * 1000)
    }

    /// 同步等 save 完成并返回回调里的排序结果（回调必在主线程派发）。
    private func save(_ messages: [BearyAPI.DMMessage], peerId: Int) -> [BearyAPI.DMMessage] {
        let exp = expectation(description: "saveMessages")
        var saved: [BearyAPI.DMMessage] = []
        BearyDMStore.saveMessages(accountId: accountId, peer: peer(peerId), messages: messages) { result in
            saved = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        return saved
    }

    private func load(peerId: Int) -> [BearyAPI.DMMessage] {
        let exp = expectation(description: "messages")
        var loaded: [BearyAPI.DMMessage] = []
        BearyDMStore.messages(accountId: accountId, peerId: peerId) { result in
            loaded = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        return loaded
    }

    func testSaveThenLoadRoundTripSorted() {
        let saved = save([msg(3), msg(1), msg(2)], peerId: 11)
        XCTAssertEqual(saved.map { $0.id ?? -1 }, [1, 2, 3])
        XCTAssertEqual(load(peerId: 11).map { $0.id ?? -1 }, [1, 2, 3])
        XCTAssertEqual(load(peerId: 11).map { $0.body ?? "" }, ["消息1", "消息2", "消息3"])
    }

    /// 历史保留：两批重叠写入后旧批不丢、同 id 服务端（后一批）为准。
    func testOverlappingBatchesRetainHistoryServerWins() {
        _ = save((1...5).map { msg($0, body: "旧\($0)") }, peerId: 12)
        let saved = save((4...8).map { msg($0, body: "新\($0)") }, peerId: 12)
        XCTAssertEqual(saved.map { $0.id ?? -1 }, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(saved.filter { $0.id == 4 || $0.id == 5 }.map { $0.body ?? "" }, ["新4", "新5"])
        XCTAssertEqual(saved.filter { $0.id == 1 }.map { $0.body ?? "" }, ["旧1"])
        XCTAssertEqual(load(peerId: 12).map { $0.id ?? -1 }, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    /// 调用线程不被挡：save 只入队即返回，回调必异步到达（不在调用栈内同步触发）。
    func testSaveReturnsImmediatelyAndCompletesAsync() {
        let batch = (1...2000).map { msg($0) }
        var completed = false
        let exp = expectation(description: "save-async")
        let start = CFAbsoluteTimeGetCurrent()
        BearyDMStore.saveMessages(accountId: accountId, peer: peer(13), messages: batch) { result in
            completed = true
            XCTAssertEqual(result.count, 2000)
            exp.fulfill()
        }
        let enqueueElapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertFalse(completed, "saveMessages 回调不得同步触发：整库编码写盘必须已离队到后台")
        XCTAssertLessThan(enqueueElapsed, 0.5, "2000 条入队只应是微秒级：调用线程不得做整库编码写盘")
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(completed)
        XCTAssertEqual(load(peerId: 13).count, 2000)
    }

    /// 并发读写：多路并发 save 不丢批、不串号；串行队列排队后结果为全集。
    func testConcurrentSavesDoNotLoseMessages() {
        let exp = expectation(description: "concurrent-saves")
        exp.expectedFulfillmentCount = 10
        for i in 0..<10 {
            DispatchQueue.global(qos: .userInitiated).async {
                // 同一对方 5 路（id 段不重叠）＋ 5 个不同对方各 1 路。
                let peerId = i < 5 ? 14 : 100 + i
                let base = i < 5 ? i * 20 : 0
                let batch = (1...20).map { self.msg(base + $0) }
                BearyDMStore.saveMessages(accountId: self.accountId, peer: self.peer(peerId), messages: batch) { _ in
                    exp.fulfill()
                }
            }
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(load(peerId: 14).map { $0.id ?? -1 }, Array(1...100))
        for i in 5..<10 {
            XCTAssertEqual(load(peerId: 100 + i).count, 20)
        }
    }

    /// 不同大小本地文件：调用线程耗时只与入队有关，与文件大小无关；
    /// 大文件同样完整读回（滚动帧率的真机部分见 PR 真机验点）。
    func testEnqueueCostIndependentOfStoreSize() {
        for (peerId, count) in [(15, 100), (16, 5000)] {
            let batch = (1...count).map { msg($0, body: String(repeating: "x", count: 80)) }
            XCTAssertEqual(save(batch, peerId: peerId).count, count)
            let start = CFAbsoluteTimeGetCurrent()
            let exp = expectation(description: "messages-\(count)")
            var loaded: [BearyAPI.DMMessage] = []
            BearyDMStore.messages(accountId: accountId, peerId: peerId) { result in
                loaded = result
                exp.fulfill()
            }
            let enqueueElapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertLessThan(enqueueElapsed, 0.5, "本地文件 \(count) 条时调用线程仍只应入队")
            wait(for: [exp], timeout: 10)
            XCTAssertEqual(loaded.count, count)
        }
    }

    /// 会话列表合并：仅本地有的对方追加、服务端为准、未读数不由本地推断。
    func testMergedConversationsKeepsLocalOnlyPeer() {
        _ = save([msg(1, body: "本地话")], peerId: 17)
        let serverPeer = BearyAPI.FriendUser(id: 18, displayName: "服务端方", handle: "srv", avatarUrl: nil, createdAt: nil)
        let server = [BearyAPI.DMConversation(peer: serverPeer, lastBody: "服务端话", lastAt: 9000, unreadCount: 3)]
        let exp = expectation(description: "merged")
        var merged: [BearyAPI.DMConversation] = []
        BearyDMStore.mergedConversations(server: server, accountId: accountId) { result in
            merged = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(merged.map { $0.peer?.id ?? -1 }, [18, 17])
        XCTAssertEqual(merged.first?.unreadCount, 3)
        XCTAssertNil(merged.last?.unreadCount)
        XCTAssertEqual(merged.last?.lastBody, "本地话")
    }

    /// 游客/无账号：不读写任何文件，回调空结果、不崩。
    func testNilAccountIsNoop() {
        let exp1 = expectation(description: "nil-messages")
        BearyDMStore.messages(accountId: nil, peerId: 19) { result in
            XCTAssertTrue(result.isEmpty)
            exp1.fulfill()
        }
        let exp2 = expectation(description: "nil-save")
        BearyDMStore.saveMessages(accountId: nil, peer: peer(19), messages: [msg(1)]) { result in
            XCTAssertTrue(result.isEmpty)
            exp2.fulfill()
        }
        wait(for: [exp1, exp2], timeout: 10)
    }
}

// ===== 审计三轮第 18 项：损坏与恢复路径回归测试（PR #1037 / #1034 / #1039 / #1043 / #1045）=====
// 覆盖：草稿损坏保护（#1037）、回收站编解码往返（#1034）、离线同步写盘失败
// （#1039）、导出缺失游标（#1043）、切号后置顶状态（#1045）。
// 测试 target 不带宿主 App：为编进被测生产文件，本 PR 把 BearyDraftFiles.swift、
// BearyEntrySync.swift、BearyDiaryPin.swift 加进 BearyCoreTests target（与
// BearyAPI.swift 同款做法，见 project.pbxproj）；其余生产文件不动。
// 上述三文件在 App target 内依赖的 SessionManager / DiagFile /
// BearyConfirmSheet 不进测试 target，原因：SessionManager 是登录中枢
// （signOut 时清十余个缓存与页面类型），整文件编进测试包会把近全 App 拖进来；
// DiagFile 在 SceneDelegate.swift 内，BearyConfirmSheet 依赖底 sheet 容器与
// 按钮工厂，同样整文件进包即近全 App。故本节给这三个符号各立一个最小测试替身，
// 只镜像被测文件实际用到的 API 口径：
//   - SessionManager.shared.currentUser（MeUser?，可写；生产侧为 private(set)，
//     测试直接赋值模拟切号——替身口径与生产不一致时，被测文件随替身一起
//     编译失败，不会静默通过）；
//   - DiagFile.mark(_:)（空实现；被测路径只在有残留旧图时记诊断日志）；
//   - BearyConfirmSheet.show(from:title:message:actions:)（空实现；只被不测的
//     confirmReplacement 用，替身须与生产 API 同签名，否则被测文件编不过）。
// BearyBeijingDay 已是独立文件且已编进测试包（第四轮审计 17），不用替身。
// 2026-11-10 变基适配（主线已变，被测口径以现行主线为准）：#933 把 saveDay /
// commitFullSync / TrashSyncStore.saveAll 由 Result 改成 Bool；#941 起回收站
// 写盘代际先记后写（失败也 +1）；#1069 全量提交改 staging 换盘，旧日文件留
// 空数组不删除；#1079 备份失败不再落回 corruptStore，改走 partialSaveFailed；
// #1046 置顶替换确认改走 BearyConfirmSheet.show。原注 #1037 / #1039 / #1045
// 未合入（分别被 #1079、#941、#975 覆盖），此处测的是现行主线的同款行为。
// 替身行为不参与任何断言；生产侧改了这些 API 的签名，被测文件在测试包内
// 编译即失败（大声失败，非静默通过）。
// 未覆盖（诚实说明）：
//   - #1043 的 fetchScopePage 是 BearySettingsViewController 的 private 方法，
//     整页编进测试包不现实；此处只 pin 住它两道 guard 依赖的模型契约
//     （缺 entries 键解成 nil、末条缺 createdAt 解成 nil），保证 guard
//     不被未来的解码改动悄悄架空；
//   - #1039 的 syncedAccountIdThisLaunch / trashSyncedAccountIdThisLaunch
//     只在联网全量同步的成功分支里置位，无网测不到；此处测作为其门控的
//     store 层 Bool 契约（失败即 false、旧快照保留；回收站代际先记后写，
//     失败也 +1，见 #941）。
// 所有落盘测试都用测试专用账号 id（987xxx），只读写测试运行器自己沙箱的
// Application Support，不碰用户真实数据目录；用完即删。

// MARK: - 第 18 项测试替身（test doubles，见节首说明）

/// 生产 SessionManager（SessionManager.swift，不进测试 target）的最小口径：
/// 只含 BearyEntrySync / BearyDiaryPin 用到的 shared + currentUser。
/// 登录/切号/持久化等行为不在此替身内；测试直接置 currentUser 模拟切号。
final class SessionManager {
    static let shared = SessionManager()
    var currentUser: MeUser?
}

/// 生产 DiagFile.mark（SceneDelegate.swift，不进测试 target）：被测路径只在
/// 有残留旧图时记一条诊断日志；替身空实现，不参与断言。
enum DiagFile {
    static func mark(_ stage: String) {}
}

/// 生产 BearyConfirmSheet（BearyConfirmSheet.swift，不进测试 target）的最小口径：
/// 只含 BearyDiaryPin.confirmReplacement 用到的 show + Action；空实现，不弹 sheet。
/// 签名须与生产一致（含 onDismissWithoutAction 可选参数，#1046），否则被测文件编不过。
enum BearyConfirmSheet {
    struct Action {
        enum Style { case `default`, cancel, destructive }
        let title: String
        let style: Style
        let handler: (() -> Void)?
        init(title: String, style: Style = .default, handler: (() -> Void)? = nil) {
            self.title = title
            self.style = style
            self.handler = handler
        }
    }
    static func show(from presenter: UIViewController, title: String, message: String?, actions: [Action], onDismissWithoutAction: (() -> Void)? = nil) {}
}

// MARK: - 第 18 项测试辅助

private func bearyTestEntry(id: String, createdAt: Int?, title: String? = nil, images: [String]? = nil, visibility: String? = nil, pinned: Int? = nil) throws -> Entry {
    var dict: [String: Any] = ["id": id, "content": "正文 \(id)", "is_public": true]
    if let created = createdAt { dict["created_at"] = created }
    if let t = title { dict["title"] = t }
    if let imgs = images { dict["images"] = imgs }
    if let v = visibility { dict["visibility"] = v }
    if let p = pinned { dict["pinned"] = p }
    return try bearyDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: dict))
}

private func bearyTestUser(id: Int) throws -> MeUser {
    let me = try bearyDecoder().decode(MeResponse.self, from: Data("{\"user\":{\"id\":\(id)}}".utf8))
    return try XCTUnwrap(me.user)
}

// MARK: - 第 18 项用例 1：草稿损坏保护（#1037）

final class BearyDraftBackupTests: XCTestCase {
    private let draftTestUid = 987001

    private var baseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private var storeURL: URL {
        baseURL.appendingPathComponent("beary_draft_v3_\(draftTestUid).json")
    }

    private var backupURLs: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix("beary_draft_v3_\(draftTestUid).json.corrupt-") }
    }

    private func cleanupDraftTestFiles() {
        // 先恢复目录权限（失败测试里改过），再删文件——删目录内文件要写权限。
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: baseURL.path)
        try? FileManager.default.removeItem(at: storeURL)
        for url in backupURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func writeCorruptDraftStore() throws -> Data {
        // 用生产类型本身编码“好草稿”（与 saveAll 同款 JSONEncoder），再混一条
        // 坏数据拼成损坏库——文件里的好草稿保证是 BearyDraft 能解出的形状；
        // 写完当场自检：首条必须解出 BearyDraft，否则测试搭的库本身就不触发
        // “逐条恢复”分支（自检失败会在此报错，而不是在 loadAllResult 处误报）。
        let goodDraft = BearyDraft(draftId: "d_good", content: "好草稿正文", images: [], clientReq: "req-1", updatedAt: 1762000000, notifyRecipient: false, quoteImages: [], quoteDeleted: false)
        let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(goodDraft))
        let bad: [String: Any] = ["__notADraft": true]
        let data = try JSONSerialization.data(withJSONObject: [goodObject, bad])
        try data.write(to: storeURL, options: .atomic)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [Any])
        XCTAssertEqual(raw.count, 2)
        let goodData = try JSONSerialization.data(withJSONObject: raw[0])
        let probe = try JSONDecoder().decode(BearyDraft.self, from: goodData)
        XCTAssertEqual(probe.draftId, "d_good")
        return data
    }

    func testPartialRecoveryAbortsWhenBackupFails() throws {
        let previousAccount = BearyDraftStore.currentAccountId
        defer { cleanupDraftTestFiles(); _ = BearyDraftStore.setAccount(previousAccount) }
        cleanupDraftTestFiles()
        _ = BearyDraftStore.setAccount(draftTestUid)
        let original = try writeCorruptDraftStore()
        // 备份写不进目录：备份失败（读权限还在，读库本身不受影响）。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: baseURL.path)
        let result = BearyDraftStore.loadAllResult()
        guard case .failure(let error) = result else {
            XCTFail("expected failure when backup fails, got \(result)")
            return
        }
        // #1079（r19-A1）：备份失败不再落回 corruptStore，改走 partialSaveFailed，
        // 好草稿随失败带回（backupURL 为 nil，备份没建成）。
        guard case .partialSaveFailed(let drafts, let kept, let skipped, let backupURL) = error else {
            XCTFail("expected partialSaveFailed, got \(error)")
            return
        }
        XCTAssertNil(backupURL)
        XCTAssertEqual(kept, 1)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.draftId, "d_good")
        XCTAssertNotNil(BearyDraftStore.lastLoadError)
        // 原文件不动：好草稿没被回写丢掉，坏条目仍在原文件里等下次恢复。
        XCTAssertEqual(try Data(contentsOf: storeURL), original)
        XCTAssertTrue(backupURLs.isEmpty)
        // 兼容口径：失败时 loadAll() 返回 []，但 lastLoadError 置标记。
        XCTAssertTrue(BearyDraftStore.loadAll().isEmpty)
        XCTAssertNotNil(BearyDraftStore.lastLoadError)
    }

    func testPartialRecoverySucceedsWhenBackupWorks() throws {
        let previousAccount = BearyDraftStore.currentAccountId
        defer { cleanupDraftTestFiles(); _ = BearyDraftStore.setAccount(previousAccount) }
        cleanupDraftTestFiles()
        _ = BearyDraftStore.setAccount(draftTestUid)
        let original = try writeCorruptDraftStore()
        let result = BearyDraftStore.loadAllResult()
        guard case .success(let drafts) = result else {
            XCTFail("expected success when backup works, got \(result)")
            return
        }
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.draftId, "d_good")
        XCTAssertEqual(drafts.first?.content, "好草稿正文")
        XCTAssertNil(BearyDraftStore.lastLoadError)
        // 好数据已回写（坏条目出库），原损坏内容只留在备份里。
        guard let backup = backupURLs.first else {
            XCTFail("expected one backup file after recovery")
            return
        }
        XCTAssertEqual(backupURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let rewritten = try JSONDecoder().decode([BearyDraft].self, from: Data(contentsOf: storeURL))
        XCTAssertEqual(rewritten.count, 1)
        XCTAssertEqual(rewritten.first?.draftId, "d_good")
    }
}

// MARK: - 第 18 项用例 2：回收站编解码往返（#1034）

final class BearyTrashRoundtripTests: XCTestCase {
    private func trashRoundtrip(_ item: TrashItem) throws -> TrashItem {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TrashItem.self, from: encoder.encode(item))
    }

    func testTrashItemRoundtripKeepsTitleAndImageKeys() throws {
        let item = TrashItem(id: "b_t1", content: "正文", createdAt: 1761000000000, publishAt: nil, deletedAt: 1762000000000, daysLeft: 30, published: nil, visibility: "public", title: "标题", imageKeys: ["k1", "k2"])
        let back = try trashRoundtrip(item)
        XCTAssertEqual(back.id, "b_t1")
        XCTAssertEqual(back.content, "正文")
        XCTAssertEqual(back.visibility, "public")
        XCTAssertEqual(back.title, "标题")
        XCTAssertEqual(back.imageKeys, ["k1", "k2"])
        XCTAssertEqual(back.daysLeft, 30)
    }

    func testTrashItemDecodesServerShape() throws {
        // 服务端 trash 行：图片 keys 在 "images" 键下（CodingKeys 配对）。
        let json = """
        {"id":"b_t2","content":"正文","created_at":1761000000000,"deleted_at":1762000000000,
        "days_left":30,"visibility":"friends","title":"标题","images":["k1","k2","k3"]}
        """
        let item = try bearyDecoder().decode(TrashItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.title, "标题")
        XCTAssertEqual(item.imageKeys, ["k1", "k2", "k3"])
        XCTAssertEqual(item.visibility, "friends")
    }

    func testTrashItemNilFieldsStayNil() throws {
        // 旧缓存行无标题/图片：编解码不凭空补值。
        let item = TrashItem(id: "b_t3", content: nil, createdAt: nil, publishAt: nil, deletedAt: 1, daysLeft: 30)
        let back = try trashRoundtrip(item)
        XCTAssertNil(back.title)
        XCTAssertNil(back.imageKeys)
        XCTAssertNil(back.visibility)
    }

    func testPrependDeletedCarriesTitleImageKeysVisibility() throws {
        // #1034 全链路：删帖进桶 → 落盘 → 重读，标题/图片 keys/可见性都在。
        let uid = 987003
        let dir = try XCTUnwrap(BearyTrashSyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let oldItem = TrashItem(id: "b_old", content: "旧篇", createdAt: 1761000000000, publishAt: nil, deletedAt: 1761000001000, daysLeft: 29, published: nil, visibility: "private", title: "旧标题", imageKeys: ["k0"])
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: uid, items: [oldItem]), "seed bucket")
        let entry = try bearyTestEntry(id: "b_pre1", createdAt: 1761000000000, title: "待删标题", images: ["k1", "k2"], visibility: "friends")
        BearyTrashSyncStore.prependDeleted(accountId: uid, entry: entry)
        let items = try XCTUnwrap(BearyTrashSyncStore.loadAll(accountId: uid))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.id, "b_pre1")
        XCTAssertEqual(items.first?.title, "待删标题")
        XCTAssertEqual(items.first?.imageKeys, ["k1", "k2"])
        XCTAssertEqual(items.first?.visibility, "friends")
        XCTAssertEqual(items.first?.daysLeft, 30)
        XCTAssertNotNil(items.first?.deletedAt)
        XCTAssertEqual(items.last?.id, "b_old")
    }
}

// MARK: - 第 18 项用例 3：离线同步写盘失败（#1039）

final class BearySyncWriteResultTests: XCTestCase {
    func testSaveDaySuccessRoundtrip() throws {
        let uid = 987002
        let dir = try XCTUnwrap(BearyEntrySyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let entry = try bearyTestEntry(id: "b_day1", createdAt: 1761000000000)
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: uid, dayKey: "2026-10-21", entries: [entry]), "saveDay")
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: uid, dayKey: "2026-10-21")?.map { $0.id }, ["b_day1"])
    }

    func testSaveDayFailureWhenDirectoryBlocked() throws {
        let uid = 987012
        let dir = try XCTUnwrap(BearyEntrySyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        // 用普通文件占住目录位：建目录失败 → saveDay 回 failure，不写盘。
        _ = FileManager.default.createFile(atPath: dir.path, contents: Data("block".utf8))
        let entry = try bearyTestEntry(id: "b_day2", createdAt: 1761000000000)
        XCTAssertFalse(BearyEntrySyncStore.saveDay(accountId: uid, dayKey: "2026-10-21", entries: [entry]), "directory blocked by file")
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: uid, dayKey: "2026-10-21"))
    }

    func testSaveDayFailureKeepsOldSnapshot() throws {
        let uid = 987042
        let dir = try XCTUnwrap(BearyEntrySyncStore.accountDir(accountId: uid))
        let dayURL = try XCTUnwrap(BearyEntrySyncStore.dayFileURL(accountId: uid, dayKey: "2026-10-21"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let oldEntry = try bearyTestEntry(id: "b_old", createdAt: 1761000000000)
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: uid, dayKey: "2026-10-21", entries: [oldEntry]), "seed old day file")
        let oldData = try Data(contentsOf: dayURL)
        // 目录只读：原子写建不出临时文件 → failure，旧日文件原样保留。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let newEntry = try bearyTestEntry(id: "b_new", createdAt: 1761000000000)
        XCTAssertFalse(BearyEntrySyncStore.saveDay(accountId: uid, dayKey: "2026-10-21", entries: [newEntry]), "read-only directory")
        XCTAssertEqual(try Data(contentsOf: dayURL), oldData)
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: uid, dayKey: "2026-10-21")?.map { $0.id }, ["b_old"])
    }

    func testCommitFullSyncSuccessEmptiesStaleDays() throws {
        let uid = 987022
        let dir = try XCTUnwrap(BearyEntrySyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let staleURL = dir.appendingPathComponent("2026-10-20.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: staleURL)
        let entry = try bearyTestEntry(id: "b_c1", createdAt: 1761000000000)
        XCTAssertTrue(BearyEntrySyncStore.commitFullSync(accountId: uid, grouped: ["2026-10-21": [entry]]), "commit")
        // #1069 staging 换盘：旧日文件不删除，留空数组占位（loadDay 读到 []）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: uid, dayKey: "2026-10-20")?.count, 0)
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: uid, dayKey: "2026-10-21")?.map { $0.id }, ["b_c1"])
    }

    func testCommitFullSyncFailureWhenDirectoryBlocked() throws {
        let uid = 987032
        let dir = try XCTUnwrap(BearyEntrySyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        _ = FileManager.default.createFile(atPath: dir.path, contents: Data("block".utf8))
        let entry = try bearyTestEntry(id: "b_c2", createdAt: 1761000000000)
        XCTAssertFalse(BearyEntrySyncStore.commitFullSync(accountId: uid, grouped: ["2026-10-21": [entry]]), "directory blocked by file")
    }

    func testTrashSaveAllFailureKeepsOldSnapshotAndBumpsGeneration() throws {
        let uid = 987013
        let dir = try XCTUnwrap(BearyTrashSyncStore.accountDir(accountId: uid))
        let fileURL = try XCTUnwrap(BearyTrashSyncStore.fileURL(accountId: uid))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let oldItem = TrashItem(id: "b_old", content: "旧快照", createdAt: 1761000000000, publishAt: nil, deletedAt: 1762000000000, daysLeft: 30, published: nil, visibility: "public", title: "旧标题", imageKeys: ["k9"])
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: uid, items: [oldItem]), "seed old snapshot")
        let oldData = try Data(contentsOf: fileURL)
        let generationBefore = BearyTrashSyncStore.currentWriteSequence()
        // 目录只读：写失败、旧 trash.json 原样保留；写盘代际先记后写（#941），失败也 +1。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertFalse(BearyTrashSyncStore.saveAll(accountId: uid, items: []), "read-only directory")
        XCTAssertEqual(try Data(contentsOf: fileURL), oldData)
        XCTAssertEqual(BearyTrashSyncStore.currentWriteSequence(), generationBefore + 1)
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: uid)?.map { $0.id }, ["b_old"])
    }

    func testTrashSaveAllSuccessBumpsGeneration() throws {
        let uid = 987023
        let dir = try XCTUnwrap(BearyTrashSyncStore.accountDir(accountId: uid))
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.removeItem(at: dir)
        let generationBefore = BearyTrashSyncStore.currentWriteSequence()
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: uid, items: []), "save empty bucket")
        XCTAssertEqual(BearyTrashSyncStore.currentWriteSequence(), generationBefore + 1)
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: uid)?.count, 0)
    }
}

// MARK: - 第 18 项用例 4：导出缺失游标（#1043，模型契约层）

final class BearyExportCursorTests: XCTestCase {
    func testEntryListWithoutEntriesKeyDecodesToNilNotEmpty() throws {
        // #1043 第一道 guard 认的是“键缺失”：缺 entries 键必须解成 nil，
        // 不能默认成 []——否则“空页”与“回包结构异常”无法区分，guard 恒不触发。
        let list = try bearyDecoder().decode(EntryList.self, from: Data("{\"mailbox_count\":0,\"trash_count\":0}".utf8))
        XCTAssertNil(list.entries)
    }

    func testEntryListWithEmptyEntriesIsEmptyPage() throws {
        // 对照：entries 键在、数组为空，是合法空页（与缺失不同）。
        let list = try bearyDecoder().decode(EntryList.self, from: Data("{\"entries\":[]}".utf8))
        XCTAssertEqual(list.entries?.count, 0)
    }

    func testEntryWithoutCreatedAtDecodesToNil() throws {
        let entry = try bearyTestEntry(id: "b_nocursor", createdAt: nil)
        XCTAssertNil(entry.createdAt)
    }

    func testFullPageWithLastEntryMissingCreatedAt() throws {
        // 满 50 条且末条缺 createdAt：正是 #1043 第二道 guard 匹配的形状——
        // 末条无游标，无法续翻，不得按完整页收尾。
        var dicts: [[String: Any]] = []
        for i in 0..<50 {
            var d: [String: Any] = ["id": "b_p\(i)", "content": "第\(i)篇", "created_at": 1761000000000 + i * 1000, "is_public": true]
            if i == 49 { d.removeValue(forKey: "created_at") }
            dicts.append(d)
        }
        let entries = try bearyDecoder().decode([Entry].self, from: JSONSerialization.data(withJSONObject: dicts))
        XCTAssertEqual(entries.count, 50)
        XCTAssertNotNil(entries.first?.createdAt)
        XCTAssertNil(entries.last?.createdAt)
    }
}

// MARK: - 第 18 项用例 5：切号后置顶状态（#1045）

final class BearyDiaryPinAccountTests: XCTestCase {
    private func setUser(_ id: Int?) throws {
        SessionManager.shared.currentUser = try id.map { try bearyTestUser(id: $0) }
    }

    private func clearPin(for userId: Int) throws {
        try setUser(userId)
        BearyDiaryPin.currentPinnedEntryId = nil
    }

    func testPinnedMemoryIsIsolatedPerAccount() throws {
        defer { try? clearPin(for: 1); try? clearPin(for: 27); SessionManager.shared.currentUser = nil }
        try setUser(1)
        BearyDiaryPin.currentPinnedEntryId = "b_pinA"
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
        // 切到 B：读不到 A 的记忆，不弹 A 的替换确认。
        try setUser(27)
        XCTAssertNil(BearyDiaryPin.currentPinnedEntryId)
        XCTAssertNil(BearyDiaryPin.existingPinnedId(excluding: "b_other", in: []))
        BearyDiaryPin.currentPinnedEntryId = "b_pinB"
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinB")
        // 切回 A：A 的记忆还在。
        try setUser(1)
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
        XCTAssertEqual(BearyDiaryPin.existingPinnedId(excluding: "b_other", in: []), "b_pinA")
        try setUser(27)
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinB")
    }

    func testNoteEntriesOnlyAffectsCurrentAccount() throws {
        defer { try? clearPin(for: 1); try? clearPin(for: 27); SessionManager.shared.currentUser = nil }
        try setUser(1)
        BearyDiaryPin.noteEntries([try bearyTestEntry(id: "b_pinA", createdAt: 1761000000000, pinned: 1)])
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
        try setUser(27)
        XCTAssertNil(BearyDiaryPin.currentPinnedEntryId)
        BearyDiaryPin.noteEntries([try bearyTestEntry(id: "b_pinB", createdAt: 1761000000000, pinned: 1)])
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinB")
        try setUser(1)
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
    }

    func testPinMemoryNotReadOrWrittenWhileLoggedOut() throws {
        defer { try? clearPin(for: 1); SessionManager.shared.currentUser = nil }
        try setUser(1)
        BearyDiaryPin.currentPinnedEntryId = "b_pinA"
        SessionManager.shared.currentUser = nil
        XCTAssertNil(BearyDiaryPin.currentPinnedEntryId)
        BearyDiaryPin.currentPinnedEntryId = "b_nope"
        try setUser(1)
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
    }

    func testUnpinClearsOnlyCurrentAccount() throws {
        defer { try? clearPin(for: 1); try? clearPin(for: 27); SessionManager.shared.currentUser = nil }
        try setUser(1)
        BearyDiaryPin.currentPinnedEntryId = "b_pinA"
        try setUser(27)
        BearyDiaryPin.currentPinnedEntryId = "b_pinB"
        BearyDiaryPin.notePinResult(entryId: "b_pinB", pinned: false)
        XCTAssertNil(BearyDiaryPin.currentPinnedEntryId)
        try setUser(1)
        XCTAssertEqual(BearyDiaryPin.currentPinnedEntryId, "b_pinA")
    }
}

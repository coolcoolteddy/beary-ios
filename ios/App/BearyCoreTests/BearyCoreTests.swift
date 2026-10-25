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

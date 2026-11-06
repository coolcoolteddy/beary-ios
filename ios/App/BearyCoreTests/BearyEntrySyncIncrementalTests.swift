import XCTest

// ===== 第四轮增量同步批 01/04/11：分批持久化与纯逻辑单测 =====
//
// 覆盖 BearyEntrySyncStore 新增的分批契约与 BearySyncTaskIdentity：
//   - 01 上限分批：多页合并落盘（不攒全量进内存）、重复合并幂等、
//     合并永不删旧数据（只做 additive 合并，删旧只在收尾 finalize 时做）；
//   - 04 跳过拦截：groupByDay 计跳过数（缺 createdAt / 缺 id），合并
//     本身不删任何条目——跳过发生时编排层不调 finalize、不清缓存；
//   - 04 nil entries 不清缓存：收尾清理只删“未见日”，且只认 YYYY-MM-DD.json
//     文件名，进度文件不动；nil entries 的拦截在编排层 fetchDiaryPage
//     的回包守卫（依赖网络），按 #933 惯例由代码审查 + PR CI 覆盖；
//   - 11 旧代次回包丢弃：任务身份（epoch + 代次）匹配逻辑；分页回调与
//     收尾的双重校验在编排层（依赖网络与 SessionManager），同上由审查 + CI 覆盖。
// 测试桶用固定大号测试账号，setUp / tearDown 各清一次，不碰真实账号桶。

final class BearyEntrySyncIncrementalTests: XCTestCase {
    private let testAccountId = 987654321

    private func makeEntry(id: String, createdAtMs: Int) -> Entry {
        let json = """
        {"id": "\(id)", "created_at": \(createdAtMs), "content": "test \(id)"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Entry.self, from: Data(json.utf8))
    }

    private func makeTrashItem(id: String, deletedAtMs: Int) -> TrashItem {
        TrashItem(id: id, content: "trash \(id)", createdAt: nil, publishAt: nil,
                  deletedAt: deletedAtMs, daysLeft: 30)
    }

    override func setUp() {
        super.setUp()
        BearyEntrySyncStore.purgeAccount(accountId: testAccountId)
        BearyTrashSyncStore.purgeAccount(accountId: testAccountId)
    }

    override func tearDown() {
        BearyEntrySyncStore.purgeAccount(accountId: testAccountId)
        BearyTrashSyncStore.purgeAccount(accountId: testAccountId)
        super.tearDown()
    }

    // MARK: - 04 分组跳过计数

    func testGroupByDayCountsSkippedEntries() {
        // 缺 createdAt 一条、缺 id 一条，均丢弃并计数；其余正常归日。
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let noDate = try! decoder.decode(Entry.self, from: Data("{\"id\": \"no-date\", \"content\": \"x\"}".utf8))
        let noId = try! decoder.decode(Entry.self, from: Data("{\"created_at\": 1735689600000, \"content\": \"x\"}".utf8))
        let result = BearyEntrySyncStore.groupByDay([
            makeEntry(id: "e1", createdAtMs: 1735689600000),
            noDate,
            noId,
        ])
        XCTAssertEqual(result.grouped["2025-01-01"]?.map({ $0.id }), ["e1"])
        XCTAssertEqual(result.skippedCount, 2)
    }

    // MARK: - 01 日记分批持久化

    func testMergeDayPageAcrossPagesWithoutFullAccumulation() {
        // 模拟 3 页 × 50 篇（150 篇、跨 2 个北京日）：逐页合并，不攒全量。
        // 北京 2025-01-02 00:00 = 1735747200000；北京 2025-01-01 00:00 = 1735660800000。
        let day2Base = 1735747200000
        let day1Base = 1735660800000
        let page1 = (0..<50).map { makeEntry(id: "p1-e\($0)", createdAtMs: day2Base + $0 * 60000) }
        let page2 = (0..<25).map { makeEntry(id: "p2-a\($0)", createdAtMs: day2Base + 3600000 + $0 * 60000) }
            + (0..<25).map { makeEntry(id: "p2-b\($0)", createdAtMs: day1Base + $0 * 60000) }
        let page3 = (0..<50).map { makeEntry(id: "p3-e\($0)", createdAtMs: day1Base + 3600000 + $0 * 60000) }
        for page in [page1, page2, page3] {
            let grouped = BearyEntrySyncStore.groupByDay(page)
            XCTAssertEqual(grouped.skippedCount, 0)
            XCTAssertTrue(BearyEntrySyncStore.mergeDayPage(accountId: testAccountId, grouped: grouped.grouped))
        }
        let day2 = BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-02")
        let day1 = BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")
        XCTAssertEqual(day2?.count, 75)
        XCTAssertEqual(day1?.count, 75)
        XCTAssertEqual(Set(day2?.compactMap({ $0.id }) ?? []),
                       Set((0..<50).map { "p1-e\($0)" } + (0..<25).map { "p2-a\($0)" }))
        XCTAssertEqual(Set(day1?.compactMap({ $0.id }) ?? []),
                       Set((0..<25).map { "p2-b\($0)" } + (0..<50).map { "p3-e\($0)" }))
        // 重复合并同一页幂等：不翻倍、不丢篇。
        let grouped1 = BearyEntrySyncStore.groupByDay(page1)
        XCTAssertTrue(BearyEntrySyncStore.mergeDayPage(accountId: testAccountId, grouped: grouped1.grouped))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-02")?.count, 75)
    }

    func testMergeDayPageNeverDeletesStaleEntries() {
        // 合并是 additive 的：旧日文件、旧条目在合并后仍在——删旧只在收尾做。
        // 若某页有条目无法归日（跳过），编排层不调收尾，旧缓存就靠这一条保住。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31",
                                                 entries: [makeEntry(id: "stale-day", createdAtMs: 1735657200000)]))
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01",
                                                 entries: [makeEntry(id: "stale-entry", createdAtMs: 1735689600000)]))
        let grouped = BearyEntrySyncStore.groupByDay([makeEntry(id: "fresh", createdAtMs: 1735689660000)])
        XCTAssertTrue(BearyEntrySyncStore.mergeDayPage(accountId: testAccountId, grouped: grouped.grouped))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31")?.first?.id, "stale-day")
        XCTAssertEqual(Set(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")?.compactMap({ $0.id }) ?? []),
                       ["stale-entry", "fresh"])
    }

    func testFinalizeDayDropsUnfetchedEntries() {
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [
            makeEntry(id: "e1", createdAtMs: 1735689600000),
            makeEntry(id: "e2", createdAtMs: 1735689660000),
            makeEntry(id: "e3", createdAtMs: 1735689720000),
        ]))
        XCTAssertTrue(BearyEntrySyncStore.finalizeDay(accountId: testAccountId, dayKey: "2025-01-01", entryIds: ["e1", "e3"]))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")?.compactMap({ $0.id }), ["e1", "e3"])
        // 精确集合为空时删掉该日文件。
        XCTAssertTrue(BearyEntrySyncStore.finalizeDay(accountId: testAccountId, dayKey: "2025-01-01", entryIds: []))
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01"))
    }

    func testCleanupDaysNotInKeepsSeenDaysAndProgressFile() {
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01",
                                                 entries: [makeEntry(id: "e1", createdAtMs: 1735689600000)]))
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31",
                                                 entries: [makeEntry(id: "old", createdAtMs: 1735657200000)]))
        let progress = DiarySyncProgress(epoch: 7, writeSequence: 3, before: nil, beforeId: nil,
                                         pageCount: 1, totalFetched: 1,
                                         seenDayKeys: ["2025-01-01"], entryIdsByDay: ["2025-01-01": ["e1"]])
        XCTAssertTrue(BearyEntrySyncStore.saveDiaryProgress(accountId: testAccountId, progress: progress))
        XCTAssertTrue(BearyEntrySyncStore.cleanupDaysNotIn(accountId: testAccountId, seenDayKeys: ["2025-01-01"]))
        XCTAssertNotNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01"))
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31"))
        // 进度文件不是日文件，不被清理（续跑游标还在）。
        XCTAssertNotNil(BearyEntrySyncStore.loadDiaryProgress(accountId: testAccountId))
    }

    func testCleanupDaysNotInWithNoBucketReturnsTrue() {
        // 本轮零日记、桶都不存在：无可清理即返回 true，不谎报失败。
        XCTAssertTrue(BearyEntrySyncStore.cleanupDaysNotIn(accountId: testAccountId, seenDayKeys: []))
    }

    // MARK: - 01 日记分批进度往返

    func testDiaryProgressRoundTripAndClear() {
        XCTAssertNil(BearyEntrySyncStore.loadDiaryProgress(accountId: testAccountId))
        let progress = DiarySyncProgress(epoch: 7, writeSequence: 3, before: 1735689600000, beforeId: "e1",
                                         pageCount: 2, totalFetched: 100,
                                         seenDayKeys: ["2025-01-01"],
                                         entryIdsByDay: ["2025-01-01": ["e1", "e2"]])
        XCTAssertTrue(BearyEntrySyncStore.saveDiaryProgress(accountId: testAccountId, progress: progress))
        let loaded = BearyEntrySyncStore.loadDiaryProgress(accountId: testAccountId)
        XCTAssertEqual(loaded?.epoch, 7)
        XCTAssertEqual(loaded?.writeSequence, 3)
        XCTAssertEqual(loaded?.before, 1735689600000)
        XCTAssertEqual(loaded?.beforeId, "e1")
        XCTAssertEqual(loaded?.pageCount, 2)
        XCTAssertEqual(loaded?.totalFetched, 100)
        XCTAssertEqual(loaded?.seenDayKeys, ["2025-01-01"])
        XCTAssertEqual(loaded?.entryIdsByDay, ["2025-01-01": ["e1", "e2"]])
        BearyEntrySyncStore.clearDiaryProgress(accountId: testAccountId)
        XCTAssertNil(BearyEntrySyncStore.loadDiaryProgress(accountId: testAccountId))
    }

    // MARK: - 11 任务身份匹配

    func testTaskIdentityRejectsStaleEpochAndGeneration() {
        let identity = BearySyncTaskIdentity(epoch: 5, generation: 2)
        XCTAssertTrue(identity.matches(epoch: 5, generation: 2))
        // 重登/切号（epoch 变）——旧任务回包丢弃。
        XCTAssertFalse(identity.matches(epoch: 6, generation: 2))
        // 新一轮 kick（代次变）——旧任务回包丢弃。
        XCTAssertFalse(identity.matches(epoch: 5, generation: 3))
        XCTAssertFalse(identity.matches(epoch: 6, generation: 3))
    }

    // MARK: - 01 回收站分批持久化

    func testMergeTrashPageAcrossPages() {
        let page1 = [makeTrashItem(id: "t1", deletedAtMs: 1735689600000),
                     makeTrashItem(id: "t2", deletedAtMs: 1735689500000)]
        let page2 = [makeTrashItem(id: "t3", deletedAtMs: 1735689400000)]
        XCTAssertTrue(BearyTrashSyncStore.mergeTrashPage(accountId: testAccountId, items: page1))
        XCTAssertTrue(BearyTrashSyncStore.mergeTrashPage(accountId: testAccountId, items: page2))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.map({ $0.id }), ["t1", "t2", "t3"])
        // 重复合并同一页幂等。
        XCTAssertTrue(BearyTrashSyncStore.mergeTrashPage(accountId: testAccountId, items: page1))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.count, 3)
    }

    func testMergeTrashPageNeverDeletesStaleItems() {
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [makeTrashItem(id: "stale", deletedAtMs: 1735689600000)]))
        XCTAssertTrue(BearyTrashSyncStore.mergeTrashPage(accountId: testAccountId, items: [makeTrashItem(id: "fresh", deletedAtMs: 1735689700000)]))
        XCTAssertEqual(Set(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.map({ $0.id }) ?? []), ["stale", "fresh"])
    }

    func testFinalizeTrashDropsUnseenItems() {
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [
            makeTrashItem(id: "t1", deletedAtMs: 1735689600000),
            makeTrashItem(id: "t2", deletedAtMs: 1735689500000),
            makeTrashItem(id: "t3", deletedAtMs: 1735689400000),
        ]))
        XCTAssertTrue(BearyTrashSyncStore.finalizeTrash(accountId: testAccountId, seenIds: ["t1", "t3"]))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.map({ $0.id }), ["t1", "t3"])
        // 精确集合为空时写空数组文件（“已同步、回收站为空”），不删文件。
        XCTAssertTrue(BearyTrashSyncStore.finalizeTrash(accountId: testAccountId, seenIds: []))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.count, 0)
    }

    func testTrashProgressRoundTripAndClear() {
        XCTAssertNil(BearyTrashSyncStore.loadTrashProgress(accountId: testAccountId))
        let progress = TrashSyncProgress(epoch: 7, writeSequence: 3, before: "1735689600000", beforeId: "t1",
                                         pageCount: 1, totalFetched: 50, seenIds: ["t1", "t2"])
        XCTAssertTrue(BearyTrashSyncStore.saveTrashProgress(accountId: testAccountId, progress: progress))
        let loaded = BearyTrashSyncStore.loadTrashProgress(accountId: testAccountId)
        XCTAssertEqual(loaded?.epoch, 7)
        XCTAssertEqual(loaded?.writeSequence, 3)
        XCTAssertEqual(loaded?.before, "1735689600000")
        XCTAssertEqual(loaded?.beforeId, "t1")
        XCTAssertEqual(loaded?.seenIds, ["t1", "t2"])
        BearyTrashSyncStore.clearTrashProgress(accountId: testAccountId)
        XCTAssertNil(BearyTrashSyncStore.loadTrashProgress(accountId: testAccountId))
    }
}

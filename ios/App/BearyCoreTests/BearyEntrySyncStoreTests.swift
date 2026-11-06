import XCTest

// ===== 第四轮审计 02 / 17：同步存储核单测 =====
//
// 覆盖 BearyEntrySyncStore / BearyTrashSyncStore 的磁盘行为：
//   - 写盘失败时 commitFullSync / saveAll 返回 false（不谎报成功）；
//   - r17-C2 全有或全无：commitFullSync 任一日写盘失败时好日期也不发布
//     （活盘原样不动），而不是“好日期照常落盘”；旧日文件变空数组文件
//     （= 已同步、该日为空），不再删文件；
//   - 回读校验：写完 id 序列对不上即判失败。
//
// 口径说明：已同步标记（syncedAccountIdThisLaunch）由编排层 finishDiaryRun /
// finishTrashRun 在 finalizeDay / finalizeTrash 与完整性校验都通过时才置——
// 本文件测的是它所依赖的存储核契约（false = 不可记已同步），编排层的
// 三行门控由代码审查 + PR CI 覆盖，不在此用网络与 SessionManager 搭台测。
// 测试桶用固定大号测试账号，setUp / tearDown 各清一次，不碰真实账号桶。

final class BearyEntrySyncStoreTests: XCTestCase {
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

    // MARK: - 日文件写盘

    func testSaveDayRoundTripReturnsTrue() {
        let entry = makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [entry]))
        let loaded = BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?.first?.id, "e1")
    }

    func testSaveDayFailsWhenAccountDirectoryBlocked() {
        // 账号目录位置被一个普通文件占住：建目录与写盘都失败，须报 false。
        let dir = BearyEntrySyncStore.accountDir(accountId: testAccountId)!
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))
        let entry = makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertFalse(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [entry]))
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01"))
    }

    // MARK: - 全量提交

    func testCommitFullSyncSuccessEmptiesStaleDays() {
        // 先留一个不在新集合里的旧日文件，提交成功后该日应变空数组文件
        // （= 已同步、该日为空），而不是被删掉（r17-C2 空日约定：文件缺失
        // 只代表从未同步/写盘失败，与确认空可区分）。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [makeEntry(id: "old", createdAtMs: 1735657200000)]))
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [makeEntry(id: "e1", createdAtMs: 1735689600000)],
        ])
        XCTAssertTrue(committed)
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31")?.count, 0)
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")?.first?.id, "e1")
        // 换盘成功后完整性标记在位（总数 = 本批总篇数）。
        XCTAssertTrue(BearyEntrySyncStore.isArchiveComplete(accountId: testAccountId))
        XCTAssertEqual(BearyEntrySyncStore.loadCompletion(accountId: testAccountId)?.entryCount, 1)
    }

    func testCommitFullSyncPartialFailurePublishesNothing() {
        // 旧日文件（不在新集合里）先落盘。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [makeEntry(id: "old", createdAtMs: 1735657200000)]))
        // 非法日键（带 /）让 staging 写盘失败：全有或全无——整体报 false，
        // 好日期也不发布，活盘原样不动（旧日文件仍读得到旧内容），不写标记。
        // 注：直接堵活盘日文件路径测不到失败——staging 是全新目录，换盘会把
        // 堵路的目录整个搬进 .bak；故用非法日键做 staging 写盘失败的故障注入。
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [makeEntry(id: "e1", createdAtMs: 1735689600000)],
            "bad/key": [makeEntry(id: "e2", createdAtMs: 1735776000000)],
        ])
        XCTAssertFalse(committed)
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01"))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31")?.first?.id, "old")
        XCTAssertFalse(BearyEntrySyncStore.isArchiveComplete(accountId: testAccountId))
    }

    func testGroupByDayUsesBeijingDayBoundary() {
        // 2025-01-01 00:00 UTC = 北京 2025-01-01 08:00 → 归 2025-01-01；
        // 2024-12-31 15:00 UTC = 北京 2024-12-31 23:00 → 归 2024-12-31；
        // 无 createdAt 的条目丢弃。
        let noDateDecoder = JSONDecoder()
        noDateDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let noDate = try! noDateDecoder.decode(Entry.self, from: Data("{\"id\": \"no-date\", \"content\": \"x\"}".utf8))
        let result = BearyEntrySyncStore.groupByDay([
            makeEntry(id: "new-year", createdAtMs: 1735689600000),
            makeEntry(id: "eve", createdAtMs: 1735657200000),
            noDate,
        ])
        XCTAssertEqual(result.grouped["2025-01-01"]?.map({ $0.id }), ["new-year"])
        XCTAssertEqual(result.grouped["2024-12-31"]?.map({ $0.id }), ["eve"])
        XCTAssertEqual(result.grouped.keys.count, 2)
        // 无 createdAt 的条目丢弃并计数（第四轮增量 04：跳过数供编排层拦截提交）。
        XCTAssertEqual(result.skippedCount, 1)
    }

    // MARK: - 回收站整桶写盘

    func testTrashSaveAllRoundTripReturnsTrue() {
        let item = makeTrashItem(id: "t1", deletedAtMs: 1735689600000)
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [item]))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.first?.id, "t1")
    }

    func testTrashSaveAllFailsWhenAccountDirectoryBlocked() {
        let dir = BearyTrashSyncStore.accountDir(accountId: testAccountId)!
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))
        XCTAssertFalse(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [makeTrashItem(id: "t1", deletedAtMs: 1735689600000)]))
        XCTAssertNil(BearyTrashSyncStore.loadAll(accountId: testAccountId))
    }
}

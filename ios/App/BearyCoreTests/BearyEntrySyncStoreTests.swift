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

    override func setUp() {
        super.setUp()
        BearySyncTestHelpers.purgeSyncStores(accountId: testAccountId)
    }

    override func tearDown() {
        BearySyncTestHelpers.purgeSyncStores(accountId: testAccountId)
        super.tearDown()
    }

    // MARK: - 日文件写盘

    func testSaveDayRoundTripReturnsTrue() {
        let entry = BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [entry]))
        let loaded = BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?.first?.id, "e1")
    }

    func testSaveDayFailsWhenAccountDirectoryBlocked() {
        // 账号目录位置被一个普通文件占住：建目录与写盘都失败，须报 false。
        let dir = BearyEntrySyncStore.accountDir(accountId: testAccountId)!
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))
        let entry = BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertFalse(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [entry]))
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01"))
    }

    // MARK: - 全量提交

    func testCommitFullSyncSuccessEmptiesStaleDays() {
        // 先留一个不在新集合里的旧日文件，提交成功后该日应变空数组文件
        // （= 已同步、该日为空），而不是被删掉（r17-C2 空日约定：文件缺失
        // 只代表从未同步/写盘失败，与确认空可区分）。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [BearySyncTestHelpers.makeEntry(id: "old", createdAtMs: 1735657200000)]))
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)],
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
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [BearySyncTestHelpers.makeEntry(id: "old", createdAtMs: 1735657200000)]))
        // 非法日键（带 /）让 staging 写盘失败：全有或全无——整体报 false，
        // 好日期也不发布，活盘原样不动（旧日文件仍读得到旧内容），不写标记。
        // 注：直接堵活盘日文件路径测不到失败——staging 是全新目录，换盘会把
        // 堵路的目录整个搬进 .bak；故用非法日键做 staging 写盘失败的故障注入。
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)],
            "bad/key": [BearySyncTestHelpers.makeEntry(id: "e2", createdAtMs: 1735776000000)],
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
            BearySyncTestHelpers.makeEntry(id: "new-year", createdAtMs: 1735689600000),
            BearySyncTestHelpers.makeEntry(id: "eve", createdAtMs: 1735657200000),
            noDate,
        ])
        XCTAssertEqual(result.grouped["2025-01-01"]?.map({ $0.id }), ["new-year"])
        XCTAssertEqual(result.grouped["2024-12-31"]?.map({ $0.id }), ["eve"])
        XCTAssertEqual(result.grouped.keys.count, 2)
        // 无 createdAt 的条目丢弃并计数（第四轮增量 04：跳过数供编排层拦截提交）。
        XCTAssertEqual(result.skippedCount, 1)
    }

    // MARK: - 部分归档可读（离线搜索部分态）

    /// 帮手：不经 saveDay 直接写一日文件（绕开标记计数维护，专造
    /// “总数对不上标记”的部分态；编码口径与落盘一致）。
    private func writeDayFileRaw(dayKey: String, entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try! encoder.encode(entries)
        let url = BearyEntrySyncStore.dayFileURL(accountId: testAccountId, dayKey: dayKey)!
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url, options: .atomic)
    }

    func testLoadReadableEntriesSkipsUnrecoverableDay() {
        // 两日全量提交（标记总数 2）；随后把其中一日活盘文件写坏
        // （本支是全新账号、无 .bak 可回落，该日不可恢复）。
        XCTAssertTrue(BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)],
            "2025-01-02": [BearySyncTestHelpers.makeEntry(id: "e2", createdAtMs: 1735776000000)],
        ]))
        XCTAssertTrue(BearyEntrySyncStore.isArchiveComplete(accountId: testAccountId))
        let badURL = BearyEntrySyncStore.dayFileURL(accountId: testAccountId, dayKey: "2025-01-02")!
        try! Data("not json".utf8).write(to: badURL, options: .atomic)
        // 全量读盘整体 nil（任一日不可恢复即不认）；部分读盘只返回可读日。
        XCTAssertNil(BearyEntrySyncStore.loadAllEntries(accountId: testAccountId))
        XCTAssertEqual(BearyEntrySyncStore.loadReadableEntries(accountId: testAccountId)?.map({ $0.id }), ["e1"])
        // 按 id 取回（部分态）：坏日里的 id 取不到，好日里的能取到，不判 nil。
        XCTAssertEqual(BearyEntrySyncStore.loadReadableEntries(accountId: testAccountId, byIds: ["e1", "e2"])?.map({ $0.id }), ["e1"])
        // 对照：严格取回任一日坏即整体 nil。
        XCTAssertNil(BearyEntrySyncStore.loadEntries(accountId: testAccountId, byIds: ["e1", "e2"]))
    }

    func testLoadReadableEntriesIgnoresCountMismatch() {
        // 一日全量提交（标记总数 1）；再直接落第二日（不维护标记计数），
        // 标记总数对不上实际篇数。
        XCTAssertTrue(BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)],
        ]))
        writeDayFileRaw(dayKey: "2025-01-02", entries: [BearySyncTestHelpers.makeEntry(id: "e2", createdAtMs: 1735776000000)])
        // 全量读盘整体 nil（总数对不上）；部分读盘返回全部可读日，不判 nil。
        XCTAssertNil(BearyEntrySyncStore.loadAllEntries(accountId: testAccountId))
        XCTAssertEqual(BearyEntrySyncStore.loadReadableEntries(accountId: testAccountId)?.map({ $0.id }), ["e2", "e1"])
    }

    func testLoadReadableEntriesNilWithoutMarker() {
        // 只有落盘日、无完整性标记：不认部分态（fail-closed），调用方走服务端。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2025-01-01", entries: [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)]))
        XCTAssertFalse(BearyEntrySyncStore.isArchiveComplete(accountId: testAccountId))
        XCTAssertNil(BearyEntrySyncStore.loadAllEntries(accountId: testAccountId))
        XCTAssertNil(BearyEntrySyncStore.loadReadableEntries(accountId: testAccountId))
    }

    func testLoadReadableEntriesNilWhenNoDayReadable() {
        // 归档损坏：唯一一日不可恢复——部分读盘同样 nil，维持 fail-closed。
        XCTAssertTrue(BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [BearySyncTestHelpers.makeEntry(id: "e1", createdAtMs: 1735689600000)],
        ]))
        let badURL = BearyEntrySyncStore.dayFileURL(accountId: testAccountId, dayKey: "2025-01-01")!
        try! Data("not json".utf8).write(to: badURL, options: .atomic)
        XCTAssertNil(BearyEntrySyncStore.loadAllEntries(accountId: testAccountId))
        XCTAssertNil(BearyEntrySyncStore.loadReadableEntries(accountId: testAccountId))
    }

    // MARK: - 回收站整桶写盘

    func testTrashSaveAllRoundTripReturnsTrue() {
        let item = BearySyncTestHelpers.makeTrashItem(id: "t1", deletedAtMs: 1735689600000)
        XCTAssertTrue(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [item]))
        XCTAssertEqual(BearyTrashSyncStore.loadAll(accountId: testAccountId)?.first?.id, "t1")
    }

    func testTrashSaveAllFailsWhenAccountDirectoryBlocked() {
        let dir = BearyTrashSyncStore.accountDir(accountId: testAccountId)!
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))
        XCTAssertFalse(BearyTrashSyncStore.saveAll(accountId: testAccountId, items: [BearySyncTestHelpers.makeTrashItem(id: "t1", deletedAtMs: 1735689600000)]))
        XCTAssertNil(BearyTrashSyncStore.loadAll(accountId: testAccountId))
    }

    // MARK: - 发布后补拉待办（第三批体验检查第 1 项）

    func testPendingPublishRefetchAddLoadRemoveRoundTrip() {
        XCTAssertEqual(BearyEntrySyncStore.loadPendingPublishRefetch(accountId: testAccountId).count, 0)
        XCTAssertTrue(BearyEntrySyncStore.addPendingPublishRefetch(accountId: testAccountId, entryId: "e1", dayKey: "2026-11-17"))
        XCTAssertTrue(BearyEntrySyncStore.addPendingPublishRefetch(accountId: testAccountId, entryId: "e2", dayKey: "2026-11-17"))
        // 同 id 重复入队不重复记。
        XCTAssertTrue(BearyEntrySyncStore.addPendingPublishRefetch(accountId: testAccountId, entryId: "e1", dayKey: "2026-11-17"))
        let loaded = BearyEntrySyncStore.loadPendingPublishRefetch(accountId: testAccountId)
        XCTAssertEqual(loaded.map({ $0.entryId }), ["e1", "e2"])
        XCTAssertEqual(loaded.first?.dayKey, "2026-11-17")
        XCTAssertEqual(loaded.first?.attempts, 0)
        // 摘队只摘指定 id，不在队里的 id 也返回 true。
        XCTAssertTrue(BearyEntrySyncStore.removePendingPublishRefetch(accountId: testAccountId, entryId: "e1"))
        XCTAssertTrue(BearyEntrySyncStore.removePendingPublishRefetch(accountId: testAccountId, entryId: "missing"))
        XCTAssertEqual(BearyEntrySyncStore.loadPendingPublishRefetch(accountId: testAccountId).map({ $0.entryId }), ["e2"])
        // 清空即无待办。
        XCTAssertTrue(BearyEntrySyncStore.savePendingPublishRefetch(accountId: testAccountId, items: []))
        XCTAssertEqual(BearyEntrySyncStore.loadPendingPublishRefetch(accountId: testAccountId).count, 0)
    }

    func testPendingPublishRefetchCorruptFileReadsAsEmpty() {
        // 待办文件损坏按无待办处理（下次全量同步仍会拉回，不拦同步）。
        XCTAssertTrue(BearyEntrySyncStore.addPendingPublishRefetch(accountId: testAccountId, entryId: "e1", dayKey: "2026-11-17"))
        let dir = BearyEntrySyncStore.accountDir(accountId: testAccountId)!
        let url = dir.appendingPathComponent("beary_publish_refetch.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("not-json".utf8)))
        XCTAssertEqual(BearyEntrySyncStore.loadPendingPublishRefetch(accountId: testAccountId).count, 0)
    }
}

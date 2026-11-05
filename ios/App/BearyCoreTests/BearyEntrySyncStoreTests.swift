import XCTest

// ===== 第四轮审计 02 / 17：同步存储核单测 =====
//
// 覆盖 BearyEntrySyncStore / BearyTrashSyncStore 的磁盘行为：
//   - 写盘失败时 commitFullSync / saveAll 返回 false（不谎报成功）；
//   - 部分日期写失败时好日期照常落盘、旧日文件不被清理，下次重跑仍能对齐；
//   - 回读校验：写完 id 序列对不上即判失败。
//
// 口径说明：已同步标记（syncedAccountIdThisLaunch）由编排层 finishSync /
// finishTrashSync 在 commitFullSync / saveAll 返回 true 时才置——
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
                  published: nil, visibility: nil, deletedAt: deletedAtMs, daysLeft: 30)
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

    func testCommitFullSyncSuccessCleansStaleFiles() {
        // 先留一个不在新集合里的旧日文件，提交成功后应被清理。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [makeEntry(id: "old", createdAtMs: 1735657200000)]))
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [makeEntry(id: "e1", createdAtMs: 1735689600000)],
        ])
        XCTAssertTrue(committed)
        XCTAssertNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31"))
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-01")?.first?.id, "e1")
    }

    func testCommitFullSyncPartialFailureKeepsStaleFilesAndGoodDays() {
        // 旧日文件（不在新集合里）先落盘。
        XCTAssertTrue(BearyEntrySyncStore.saveDay(accountId: testAccountId, dayKey: "2024-12-31", entries: [makeEntry(id: "old", createdAtMs: 1735657200000)]))
        // 其中一个目标日路径被目录堵住：该日写盘失败，其余日应照常写。
        let blockedURL = BearyEntrySyncStore.dayFileURL(accountId: testAccountId, dayKey: "2025-01-01")!
        try! FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)
        let committed = BearyEntrySyncStore.commitFullSync(accountId: testAccountId, grouped: [
            "2025-01-01": [makeEntry(id: "e1", createdAtMs: 1735689600000)],
            "2025-01-02": [makeEntry(id: "e2", createdAtMs: 1735776000000)],
        ])
        // 部分失败：整体报 false（编排层据此不记已同步标记，下次 kick 重跑）；
        // 好日期已写，旧日文件未被清理（不因一次失败丢旧缓存）。
        XCTAssertFalse(committed)
        XCTAssertEqual(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2025-01-02")?.first?.id, "e2")
        XCTAssertNotNil(BearyEntrySyncStore.loadDay(accountId: testAccountId, dayKey: "2024-12-31"))
    }

    func testGroupByDayUsesBeijingDayBoundary() {
        // 2025-01-01 00:00 UTC = 北京 2025-01-01 08:00 → 归 2025-01-01；
        // 2024-12-31 15:00 UTC = 北京 2024-12-31 23:00 → 归 2024-12-31；
        // 无 createdAt 的条目丢弃。
        let noDateDecoder = JSONDecoder()
        noDateDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let noDate = try! noDateDecoder.decode(Entry.self, from: Data("{\"id\": \"no-date\", \"content\": \"x\"}".utf8))
        let grouped = BearyEntrySyncStore.groupByDay([
            makeEntry(id: "new-year", createdAtMs: 1735689600000),
            makeEntry(id: "eve", createdAtMs: 1735657200000),
            noDate,
        ])
        XCTAssertEqual(grouped["2025-01-01"]?.map({ $0.id }), ["new-year"])
        XCTAssertEqual(grouped["2024-12-31"]?.map({ $0.id }), ["eve"])
        XCTAssertEqual(grouped.keys.count, 2)
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

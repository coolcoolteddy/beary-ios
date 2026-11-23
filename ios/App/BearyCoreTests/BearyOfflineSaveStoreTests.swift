import XCTest

// ===== 第二批体验检查第 6 项：离线保存存储核单测 =====
//
// 覆盖 BearyOfflineSaveStore 的磁盘行为：
//   - 文字 JSON 写盘往返（与同步层同款蛇形编解码）；
//   - 图片原字节按 key 落盘、按 key 取回、不同 key 不互通；
//   - 清单记录 upsert 去重、逐篇状态（complete/partial/pending）原样存取；
//   - 占用统计（字节 + 篇数）与单篇/整桶删除；
//   - 账号隔离：A 号桶的保存不进 B 号桶的占用与清单。
//
// 口径说明：本文件只测存储核契约。编排层（本人门控、取图、批量）
// 依赖 SessionManager 与网络，由代码审查 + PR CI 覆盖，不在此搭台测。
// 测试桶用固定大号测试账号，setUp / tearDown 各清一次，不碰真实账号桶。

final class BearyOfflineSaveStoreTests: XCTestCase {
    private let testAccountId = 987654322
    private let otherAccountId = 987654323

    private func makeEntry(id: String, createdAtMs: Int, images: [String]? = nil) -> Entry {
        let imagesJSON = images.map { "\"" + $0.joined(separator: "\", \"") + "\"" } ?? ""
        let json = """
        {"id": "\(id)", "created_at": \(createdAtMs), "content": "test \(id)", "images": [\(imagesJSON)]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Entry.self, from: Data(json.utf8))
    }

    override func setUp() {
        super.setUp()
        BearyOfflineSaveStore.purgeAccount(accountId: testAccountId)
        BearyOfflineSaveStore.purgeAccount(accountId: otherAccountId)
    }

    override func tearDown() {
        BearyOfflineSaveStore.purgeAccount(accountId: testAccountId)
        BearyOfflineSaveStore.purgeAccount(accountId: otherAccountId)
        super.tearDown()
    }

    // MARK: - 文字 JSON

    func testSaveEntryJSONRoundTrip() {
        let entry = makeEntry(id: "e1", createdAtMs: 1735689600000, images: ["a/b.jpg"])
        XCTAssertTrue(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: entry))
        let loaded = BearyOfflineSaveStore.loadEntry(accountId: testAccountId, entryId: "e1")
        XCTAssertEqual(loaded?.id, "e1")
        XCTAssertEqual(loaded?.content, "test e1")
        XCTAssertEqual(loaded?.images, ["a/b.jpg"])
    }

    func testSaveEntryJSONFailsWithoutId() {
        var entry = makeEntry(id: "e1", createdAtMs: 1735689600000)
        entry.id = nil
        XCTAssertFalse(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: entry))
    }

    func testSaveEntryJSONFailsWhenAccountDirectoryBlocked() {
        // 账号目录位置被一个普通文件占住：建目录与写盘都失败，须报 false。
        let dir = BearyOfflineSaveStore.accountDir(accountId: testAccountId)!
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.path, contents: Data("x".utf8)))
        XCTAssertFalse(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: makeEntry(id: "e1", createdAtMs: 1735689600000)))
        XCTAssertNil(BearyOfflineSaveStore.loadEntry(accountId: testAccountId, entryId: "e1"))
    }

    // MARK: - 图片原字节

    func testSaveImageDataRoundTripByKey() {
        let bytes = Data("fake-jpeg-bytes".utf8)
        XCTAssertTrue(BearyOfflineSaveStore.saveImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg", data: bytes))
        XCTAssertEqual(BearyOfflineSaveStore.imageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg"), bytes)
        XCTAssertTrue(BearyOfflineSaveStore.hasImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg"))
        // 不同 key 不互通，不同篇不互通。
        XCTAssertNil(BearyOfflineSaveStore.imageData(accountId: testAccountId, entryId: "e1", key: "a/c.jpg"))
        XCTAssertNil(BearyOfflineSaveStore.imageData(accountId: testAccountId, entryId: "e2", key: "a/b.jpg"))
    }

    func testSaveImageDataRejectsEmptyData() {
        XCTAssertFalse(BearyOfflineSaveStore.saveImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg", data: Data()))
        XCTAssertFalse(BearyOfflineSaveStore.hasImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg"))
    }

    // MARK: - 清单与占用

    func testManifestUpsertDeduplicatesByEntryId() {
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 2, downloadedCount: 1, failedKeys: ["a/c.jpg"], totalBytes: 100, status: "partial")
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        XCTAssertEqual(BearyOfflineSaveStore.savedRecords(accountId: testAccountId).count, 1)
        XCTAssertEqual(BearyOfflineSaveStore.record(accountId: testAccountId, entryId: "e1")?.status, "partial")
        XCTAssertEqual(BearyOfflineSaveStore.record(accountId: testAccountId, entryId: "e1")?.failedKeys, ["a/c.jpg"])
    }

    // MARK: - A2：清单内存缓存＋批量落盘

    /// 批量内 upsert 只改内存缓存、不写盘（磁盘清单仍是旧的），
    /// 但 record/savedRecords 已能读到新记录；end 后一次落盘。
    func testManifestBatchDefersDiskWriteUntilEnd() {
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 1, downloadedCount: 1, failedKeys: [], totalBytes: 100, status: "complete")
        BearyOfflineSaveStore.beginManifestBatch(accountId: testAccountId)
        defer { _ = BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId) }
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        // 缓存已可见，磁盘仍是旧的。
        XCTAssertEqual(BearyOfflineSaveStore.record(accountId: testAccountId, entryId: "e1")?.status, "complete")
        XCTAssertEqual(diskManifestEntryCount(accountId: testAccountId), 0)
        XCTAssertTrue(BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId))
        // 落盘后磁盘与缓存一致。
        XCTAssertEqual(diskManifestEntryCount(accountId: testAccountId), 1)
        XCTAssertEqual(BearyOfflineSaveStore.savedRecords(accountId: testAccountId).count, 1)
    }

    /// 嵌套 begin/end：只 end 一次仍不落盘，两次都 end 后才落盘。
    func testManifestBatchNestedDepth() {
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 0, downloadedCount: 0, failedKeys: [], totalBytes: 100, status: "complete")
        BearyOfflineSaveStore.beginManifestBatch(accountId: testAccountId)
        BearyOfflineSaveStore.beginManifestBatch(accountId: testAccountId)
        defer {
            _ = BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId)
            _ = BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId)
        }
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        XCTAssertTrue(BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId))
        XCTAssertEqual(diskManifestEntryCount(accountId: testAccountId), 0)
        XCTAssertTrue(BearyOfflineSaveStore.endManifestBatch(accountId: testAccountId))
        XCTAssertEqual(diskManifestEntryCount(accountId: testAccountId), 1)
    }

    /// 直读磁盘上的 manifest.json，不走内存缓存；文件不存在即 0 篇。
    private func diskManifestEntryCount(accountId: Int) -> Int {
        guard let url = BearyOfflineSaveStore.manifestURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(BearyOfflineSaveManifest.self, from: data) else {
            return 0
        }
        return manifest.entries.count
    }

    func testUsageCountsBytesAndEntries() {
        let entry = makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertTrue(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: entry))
        let imageBytes = Data(repeating: 7, count: 1024)
        XCTAssertTrue(BearyOfflineSaveStore.saveImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg", data: imageBytes))
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 1, downloadedCount: 1, failedKeys: [], totalBytes: 0, status: "complete")
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        let usage = BearyOfflineSaveStore.usage(accountId: testAccountId)
        XCTAssertEqual(usage.entryCount, 1)
        // 占用至少含 1KB 图片字节（另有文字 JSON 与清单字节）。
        XCTAssertGreaterThanOrEqual(usage.bytes, 1024)
    }

    func testUsageIsZeroWithoutAnySave() {
        let usage = BearyOfflineSaveStore.usage(accountId: testAccountId)
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertEqual(usage.entryCount, 0)
    }

    // MARK: - 删除与账号隔离

    func testRemoveEntryDeletesFilesAndRecord() {
        let entry = makeEntry(id: "e1", createdAtMs: 1735689600000)
        XCTAssertTrue(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: entry))
        XCTAssertTrue(BearyOfflineSaveStore.saveImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg", data: Data("x".utf8)))
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 1, downloadedCount: 1, failedKeys: [], totalBytes: 1, status: "complete")
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        XCTAssertTrue(BearyOfflineSaveStore.removeEntry(accountId: testAccountId, entryId: "e1"))
        XCTAssertNil(BearyOfflineSaveStore.loadEntry(accountId: testAccountId, entryId: "e1"))
        XCTAssertFalse(BearyOfflineSaveStore.hasImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg"))
        XCTAssertNil(BearyOfflineSaveStore.record(accountId: testAccountId, entryId: "e1"))
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: testAccountId).entryCount, 0)
    }

    func testRemoveAllClearsWholeBucket() {
        XCTAssertTrue(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: makeEntry(id: "e1", createdAtMs: 1735689600000)))
        XCTAssertTrue(BearyOfflineSaveStore.removeAll(accountId: testAccountId))
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: testAccountId).bytes, 0)
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: testAccountId).entryCount, 0)
    }

    func testAccountIsolation() {
        XCTAssertTrue(BearyOfflineSaveStore.saveEntryJSON(accountId: testAccountId, entry: makeEntry(id: "e1", createdAtMs: 1735689600000)))
        XCTAssertTrue(BearyOfflineSaveStore.saveImageData(accountId: testAccountId, entryId: "e1", key: "a/b.jpg", data: Data("x".utf8)))
        let record = BearyOfflineSaveRecord(entryId: "e1", title: "t", createdAtMs: 1735689600000, savedAt: 1735689600, imageCount: 1, downloadedCount: 1, failedKeys: [], totalBytes: 1, status: "complete")
        XCTAssertTrue(BearyOfflineSaveStore.upsertRecord(accountId: testAccountId, record: record))
        // 另一账号桶看不到本账号的保存。
        XCTAssertNil(BearyOfflineSaveStore.loadEntry(accountId: otherAccountId, entryId: "e1"))
        XCTAssertNil(BearyOfflineSaveStore.record(accountId: otherAccountId, entryId: "e1"))
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: otherAccountId).entryCount, 0)
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: otherAccountId).bytes, 0)
        // 删 A 桶不影响 B 桶（B 桶本就为空，删后仍为空；A 桶删后归零）。
        XCTAssertTrue(BearyOfflineSaveStore.removeAll(accountId: testAccountId))
        XCTAssertEqual(BearyOfflineSaveStore.usage(accountId: testAccountId).entryCount, 0)
    }
}

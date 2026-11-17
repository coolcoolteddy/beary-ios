import XCTest

// 审计四轮 01/17：DMStore 纯存储核心＋真实文件故障路径。
// 测试 target 无宿主 App，直接把 BearyDMStore.swift 与 BearyAPI.swift 编进来；
// BearyDMStore.testBaseDirectory 指到临时目录，跑真实文件的损坏/写盘失败/切号路径。
final class BearyDMStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("beary-dmstore-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)
        BearyDMStore.testBaseDirectory = tmpDir
    }

    override func tearDown() {
        BearyDMStore.testBaseDirectory = nil
        if let tmpDir = tmpDir {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        super.tearDown()
    }

    private func peer(id: Int) -> BearyAPI.FriendUser {
        BearyAPI.FriendUser(id: id, displayName: "对方", handle: "peer", avatarUrl: nil, createdAt: nil)
    }

    private func message(id: Int, senderId: Int = 99, body: String) -> BearyAPI.DMMessage {
        BearyAPI.DMMessage(id: id, senderId: senderId, body: body, createdAt: 1793000000000)
    }

    private func storeFile(accountId: Int) -> URL {
        tmpDir.appendingPathComponent("beary_dm_\(accountId).json")
    }

    private func backupFiles(accountId: Int) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        return names.filter { $0.hasPrefix("beary_dm_\(accountId).json.corrupt-") && $0.hasSuffix(".bak") }
            .sorted().map { tmpDir.appendingPathComponent($0) }
    }

    private func saveMessages(accountId: Int, peer peerId: Int, messages: [BearyAPI.DMMessage]) -> [BearyAPI.DMMessage] {
        let exp = expectation(description: "saveMessages")
        var merged: [BearyAPI.DMMessage] = []
        BearyDMStore.saveMessages(accountId: accountId, peer: peer(id: peerId), messages: messages) { result, _ in
            merged = result
            exp.fulfill()
        }
        waitForExpectations(timeout: 30)
        return merged
    }

    // MARK: - 纯核心：编解码与合并

    func testCoreDecodeDistinguishesMissingCorruptLoaded() {
        if case .missing = BearyDMStoreCore.decode(nil) {} else { XCTFail("nil 应为 missing") }
        if case .corrupt = BearyDMStoreCore.decode(Data("不是 json".utf8)) {} else { XCTFail("垃圾应为 corrupt") }
        if case .corrupt = BearyDMStoreCore.decode(Data()) {} else { XCTFail("空数据应为 corrupt") }
        let store: [String: BearyDMStore.StoredConversation] = [
            "5": BearyDMStore.StoredConversation(
                peer: BearyDMStore.StoredPeer(id: 5, displayName: "对方", handle: "peer", avatarUrl: nil),
                messages: [BearyDMStore.StoredMessage(id: 1, senderId: 99, body: "你好", createdAt: 1793000000000)])
        ]
        guard let data = BearyDMStoreCore.encode(store) else { XCTFail("编码不应失败"); return }
        if case .loaded(let decoded) = BearyDMStoreCore.decode(data) {
            XCTAssertEqual(decoded["5"]?.messages.first?.body, "你好")
        } else {
            XCTFail("合法 JSON 应为 loaded")
        }
    }

    func testCoreMergeServerWinsOnSameId() {
        let local: [String: BearyDMStore.StoredConversation] = [
            "5": BearyDMStore.StoredConversation(
                peer: BearyDMStore.StoredPeer(id: 5, displayName: "旧名", handle: "peer", avatarUrl: nil),
                messages: [
                    BearyDMStore.StoredMessage(id: 1, senderId: 99, body: "旧正文", createdAt: 1793000000000),
                    BearyDMStore.StoredMessage(id: 2, senderId: 5, body: "本地独有", createdAt: 1793000001000)
                ])
        ]
        let merged = BearyDMStoreCore.merge(local, peer: peer(id: 5), messages: [message(id: 1, body: "新正文")])
        let rows = merged["5"]?.messages ?? []
        XCTAssertEqual(rows.map { $0.id }, [1, 2])
        XCTAssertEqual(rows.first?.body, "新正文")
        XCTAssertEqual(rows.last?.body, "本地独有")
        XCTAssertEqual(merged["5"]?.peer.displayName, "对方")
    }

    // MARK: - 真实文件：损坏不覆盖

    func testCorruptFileIsNotOverwritten() {
        let accountId = 9001
        let garbage = Data("这不是 JSON，文件已损坏".utf8)
        try? garbage.write(to: storeFile(accountId: accountId))
        let merged = saveMessages(accountId: accountId, peer: 5, messages: [message(id: 10, body: "新消息")])
        // 损坏时只回本次服务端新消息，不写盘。
        XCTAssertEqual(merged.map { $0.id }, [10])
        // 原文件一字未动。
        let after = try? Data(contentsOf: storeFile(accountId: accountId))
        XCTAssertEqual(after, garbage)
        // 备份已留一份，内容与原文件一致（先守住再取下标，免得断言失败后直接崩溃）。
        let backups = backupFiles(accountId: accountId)
        XCTAssertEqual(backups.count, 1)
        guard let backup = backups.first else { XCTFail("应留一份损坏备份"); return }
        let backupData = try? Data(contentsOf: backup)
        XCTAssertEqual(backupData, garbage)
        XCTAssertTrue(BearyDMStore.isStoreCorrupt(accountId: accountId))
        // 再存一次：备份不重复刷，原文件仍不动。
        _ = saveMessages(accountId: accountId, peer: 5, messages: [message(id: 11, body: "又一条")])
        XCTAssertEqual(backupFiles(accountId: accountId).count, 1)
        let afterSecond = try? Data(contentsOf: storeFile(accountId: accountId))
        XCTAssertEqual(afterSecond, garbage)
    }

    // MARK: - 第 17 轮 #9：persistMessages（损坏检查＋合并＋写盘合一）

    func testPersistMessagesMergesTwoPagesOnHealthyStore() {
        let accountId = 9030
        // 第一页 5 条，第二页（更早）另 5 条：两页合并无丢、按 id 升序。
        let exp1 = expectation(description: "persist page 1")
        var first: [BearyAPI.DMMessage] = []
        var firstSaved = false
        BearyDMStore.persistMessages(accountId: accountId, peer: peer(id: 5), messages: (1...5).map { message(id: $0, body: "新 \($0)") }) { outcome in
            if case .merged(let merged, let saved) = outcome { first = merged; firstSaved = saved }
            exp1.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(firstSaved)
        XCTAssertEqual(first.map { $0.id }, [1, 2, 3, 4, 5])
        let exp2 = expectation(description: "persist page 2")
        var second: [BearyAPI.DMMessage] = []
        var secondSaved = false
        BearyDMStore.persistMessages(accountId: accountId, peer: peer(id: 5), messages: (6...10).map { message(id: $0, body: "旧 \($0)") }) { outcome in
            if case .merged(let merged, let saved) = outcome { second = merged; secondSaved = saved }
            exp2.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(secondSaved)
        XCTAssertEqual(second.map { $0.id }, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        // 磁盘上的库同样是两页合并后的 10 条。
        if case .loaded(let all) = BearyDMStore.loadAll(accountId: accountId) {
            XCTAssertEqual(all["5"]?.messages.map { $0.id }, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        } else {
            XCTFail("健康库应能读出两页合并结果")
        }
    }

    func testPersistMessagesCorruptStoreReturnsFreshOnly() {
        let accountId = 9031
        let garbage = Data("这不是 JSON，文件已损坏".utf8)
        try? garbage.write(to: storeFile(accountId: accountId))
        let exp = expectation(description: "persist corrupt")
        var gotCorrupt = false
        var fresh: [BearyAPI.DMMessage] = []
        BearyDMStore.persistMessages(accountId: accountId, peer: peer(id: 5), messages: [message(id: 10, body: "新消息")]) { outcome in
            if case .corrupt(let rows) = outcome { gotCorrupt = true; fresh = rows }
            exp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(gotCorrupt)
        // 损坏时只回本次新消息，不写盘。
        XCTAssertEqual(fresh.map { $0.id }, [10])
        let after = try? Data(contentsOf: storeFile(accountId: accountId))
        XCTAssertEqual(after, garbage)
        // 恰一份备份，损坏态已登记。
        XCTAssertEqual(backupFiles(accountId: accountId).count, 1)
        XCTAssertTrue(BearyDMStore.isStoreCorrupt(accountId: accountId))
    }

    // MARK: - 第十轮 V-Data：异步版 isCorrupt（读盘只在 ioQueue 上做）

    func testAsyncIsCorruptDetectsCorruptFileAndRegisters() {
        let accountId = 9011
        let garbage = Data("这不是 JSON，文件已损坏".utf8)
        try? garbage.write(to: storeFile(accountId: accountId))
        let exp = expectation(description: "async isCorrupt corrupt")
        var corrupt = false
        BearyDMStore.isCorrupt(accountId: accountId) { value in
            corrupt = value
            exp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(corrupt)
        // 异步检查同样登记损坏态：空态判断经 isStoreCorrupt 读到同一结论，
        // 且只留一份损坏备份、原文件一字未动。
        XCTAssertTrue(BearyDMStore.isStoreCorrupt(accountId: accountId))
        XCTAssertEqual(backupFiles(accountId: accountId).count, 1)
        XCTAssertEqual(try? Data(contentsOf: storeFile(accountId: accountId)), garbage)
    }

    func testAsyncIsCorruptReturnsFalseForHealthyOrMissingFile() {
        let healthyId = 9012
        _ = saveMessages(accountId: healthyId, peer: 5, messages: [message(id: 10, body: "你好")])
        let expHealthy = expectation(description: "async isCorrupt healthy")
        var healthyCorrupt = true
        BearyDMStore.isCorrupt(accountId: healthyId) { value in
            healthyCorrupt = value
            expHealthy.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertFalse(healthyCorrupt)
        XCTAssertFalse(BearyDMStore.isStoreCorrupt(accountId: healthyId))
        // 无文件（新库）同样不算损坏。
        let expMissing = expectation(description: "async isCorrupt missing")
        var missingCorrupt = true
        BearyDMStore.isCorrupt(accountId: 9013) { value in
            missingCorrupt = value
            expMissing.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertFalse(missingCorrupt)
    }

    func testWriteFailureReturnsFalse() {
        // 根目录本身是个普通文件：建目录失败，写盘必然失败。
        let blocker = tmpDir.appendingPathComponent("blocker")
        try? Data("占位".utf8).write(to: blocker)
        BearyDMStore.testBaseDirectory = blocker
        XCTAssertFalse(BearyDMStore.saveAll([:], accountId: 9002))
        if case .missing = BearyDMStore.loadAll(accountId: 9002) {} else {
            XCTFail("写不进盘的文件应按 missing 处理，不当成损坏")
        }
        // 写盘失败也不得把账号记成损坏。
        XCTAssertFalse(BearyDMStore.isStoreCorrupt(accountId: 9002))
        // 写盘失败不影响界面：本次服务端消息照常返回，只是没落盘。
        let merged = saveMessages(accountId: 9002, peer: 5, messages: [message(id: 10, body: "新消息")])
        XCTAssertEqual(merged.map { $0.id }, [10])
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocker.appendingPathComponent("beary_dm_9002.json").path))
    }

    // MARK: - 真实文件：切号隔离

    func testAccountSwitchDoesNotCrossContaminate() {
        let first = 9003
        let second = 9004
        // 两号交错写入（模拟切号中先后回包），串行队列内按到达顺序落盘。
        let exp1 = expectation(description: "save first")
        let exp2 = expectation(description: "save second")
        BearyDMStore.saveMessages(accountId: first, peer: peer(id: 5), messages: [message(id: 10, body: "一号的消息")]) { _, _ in exp1.fulfill() }
        BearyDMStore.saveMessages(accountId: second, peer: peer(id: 6), messages: [message(id: 20, body: "二号的消息")]) { _, _ in exp2.fulfill() }
        waitForExpectations(timeout: 30)
        // 各号只读到自己的文件。
        if case .loaded(let allFirst) = BearyDMStore.loadAll(accountId: first) {
            XCTAssertEqual(allFirst.keys.sorted(), ["5"])
        } else {
            XCTFail("一号应读到自己的会话")
        }
        if case .loaded(let allSecond) = BearyDMStore.loadAll(accountId: second) {
            XCTAssertEqual(allSecond.keys.sorted(), ["6"])
        } else {
            XCTFail("二号应读到自己的会话")
        }
        // 会话列表合并也不串号：二号看不到一号仅本地有的对方。
        let merged = BearyDMStore.mergedConversations(server: [], accountId: second)
        XCTAssertEqual(merged.compactMap { $0.peer?.id }, [6])
    }

    // MARK: - 真实文件：恢复与丢弃

    func testRestoreCorruptBackup() {
        let accountId = 9005
        // 先存一份好的，再把主文件写坏、把好备份放到“最新”位置。
        _ = saveMessages(accountId: accountId, peer: 5, messages: [message(id: 10, body: "好消息")])
        guard let goodData = try? Data(contentsOf: storeFile(accountId: accountId)) else {
            XCTFail("应先有合法文件"); return
        }
        let futureBak = tmpDir.appendingPathComponent("beary_dm_\(accountId).json.corrupt-9999999999.bak")
        try? goodData.write(to: futureBak)
        try? Data("坏了".utf8).write(to: storeFile(accountId: accountId))
        // 触发一次读取，确认损坏态、原文件不动。
        if case .corrupt = BearyDMStore.loadAll(accountId: accountId) {} else {
            XCTFail("写坏后应为 corrupt")
        }
        XCTAssertTrue(BearyDMStore.isStoreCorrupt(accountId: accountId))
        // 恢复：用好备份覆盖坏文件。
        let exp = expectation(description: "restore")
        var restored = false
        BearyDMStore.restoreCorruptBackup(accountId: accountId) { ok in
            restored = ok
            exp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(restored)
        XCTAssertFalse(BearyDMStore.isStoreCorrupt(accountId: accountId))
        if case .loaded(let all) = BearyDMStore.loadAll(accountId: accountId) {
            XCTAssertEqual(all["5"]?.messages.first?.body, "好消息")
        } else {
            XCTFail("恢复后应能读出好消息")
        }
    }

    func testDiscardCorruptStore() {
        let accountId = 9006
        try? Data("坏了".utf8).write(to: storeFile(accountId: accountId))
        if case .corrupt = BearyDMStore.loadAll(accountId: accountId) {} else {
            XCTFail("应为 corrupt")
        }
        XCTAssertEqual(backupFiles(accountId: accountId).count, 1)
        let exp = expectation(description: "discard")
        var discarded = false
        BearyDMStore.discardCorruptStore(accountId: accountId) { ok in
            discarded = ok
            exp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertTrue(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeFile(accountId: accountId).path))
        XCTAssertFalse(BearyDMStore.isStoreCorrupt(accountId: accountId))
        // 丢弃后重新同步即重建：再存一条就写出新文件。
        let merged = saveMessages(accountId: accountId, peer: 5, messages: [message(id: 10, body: "重建后")])
        XCTAssertEqual(merged.map { $0.id }, [10])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFile(accountId: accountId).path))
        // 没有损坏态时丢弃返回 false。
        let exp2 = expectation(description: "discard again")
        var discardedAgain = true
        BearyDMStore.discardCorruptStore(accountId: accountId) { ok in
            discardedAgain = ok
            exp2.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertFalse(discardedAgain)
    }

    // MARK: - 待发存储（审计四轮增量 12）

    private func pendingFile(accountId: Int) -> URL {
        tmpDir.appendingPathComponent("beary_dm_pending_\(accountId).json")
    }

    private func pendingBackupFiles(accountId: Int) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        return names.filter { $0.hasPrefix("beary_dm_pending_\(accountId).json.corrupt-") && $0.hasSuffix(".bak") }
            .sorted().map { tmpDir.appendingPathComponent($0) }
    }

    /// 同一 ioQueue 串行执行：先排队的 savePending 一定先于本次 loadPendings 落盘。
    private func loadPendings(accountId: Int, peerId: Int) -> [BearyDMStore.PendingSend] {
        let exp = expectation(description: "loadPendings")
        var result: [BearyDMStore.PendingSend] = []
        BearyDMStore.loadPendings(accountId: accountId, peerId: peerId) { list in
            result = list
            exp.fulfill()
        }
        // 审计四轮增量 12：超时 30 秒——#935 教训：CI 冷启动下纯同步用例也跑过 4.5 秒，5 秒太贴边。
        waitForExpectations(timeout: 30)
        return result
    }

    func testPendingCoreRoundTrip() {
        let p1 = BearyDMStore.PendingSend(localKey: "k1", peerId: 5, body: "你好", createdAt: 1000, status: .sending)
        let p2 = BearyDMStore.PendingSend(localKey: "k2", peerId: 5, body: "在吗", createdAt: 2000, status: .failed)
        guard let data = BearyDMStoreCore.encodePendings([p1, p2]),
              let decoded = BearyDMStoreCore.decodePendings(data) else {
            XCTFail("待发编解码应成功")
            return
        }
        XCTAssertEqual(decoded.map { $0.localKey }, ["k1", "k2"])
        // 同 localKey 覆盖（改状态不增行）。
        let p1Failed = BearyDMStore.PendingSend(localKey: "k1", peerId: 5, body: "你好", createdAt: 1000, status: .failed)
        let upserted = BearyDMStoreCore.upsertPending(decoded, p1Failed)
        XCTAssertEqual(upserted.count, 2)
        XCTAssertEqual(upserted.first(where: { $0.localKey == "k1" })?.status, .failed)
        // 删指定 key，不动其他。
        let kept = BearyDMStoreCore.removePending(upserted, localKey: "k1")
        XCTAssertEqual(kept.map { $0.localKey }, ["k2"])
        // 坏 JSON → nil（调用方复制备份保留原文件）。
        XCTAssertNil(BearyDMStoreCore.decodePendings(Data("不是 json".utf8)))
    }

    func testPendingFileSurvivesMainStoreCorruption() {
        let accountId = 9010
        // 主库先写坏：待发是独立文件，仍可读写、不被损坏保护锁住。
        try? Data("坏了".utf8).write(to: storeFile(accountId: accountId))
        if case .corrupt = BearyDMStore.loadAll(accountId: accountId) {} else {
            XCTFail("主库应为 corrupt")
        }
        BearyDMStore.savePending(.init(localKey: "k1", peerId: 5, body: "待发", createdAt: 1000, status: .sending), accountId: accountId)
        let list = loadPendings(accountId: accountId, peerId: 5)
        XCTAssertEqual(list.map { $0.body }, ["待发"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFile(accountId: accountId).path))
    }

    func testPendingFileCorruptIsPreservedAsBak() {
        let accountId = 9011
        try? Data("坏了".utf8).write(to: pendingFile(accountId: accountId))
        // 损坏待发文件 → 读回空，原文件不动、另存一份 .bak（不丢记录、不阻塞）。
        XCTAssertEqual(loadPendings(accountId: accountId, peerId: 5).count, 0)
        XCTAssertEqual(pendingBackupFiles(accountId: accountId).count, 1)
        XCTAssertEqual(try? Data(contentsOf: pendingBackupFiles(accountId: accountId)[0]), Data("坏了".utf8))
        XCTAssertEqual(try? Data(contentsOf: pendingFile(accountId: accountId)), Data("坏了".utf8))
        // 损坏后写盘禁：新待发不落盘，原文件与 .bak 都不动（审计第二轮 6）。
        BearyDMStore.savePending(.init(localKey: "k1", peerId: 5, body: "新待发", createdAt: 1000, status: .sending), accountId: accountId)
        XCTAssertEqual(loadPendings(accountId: accountId, peerId: 5).count, 0)
        XCTAssertEqual(try? Data(contentsOf: pendingFile(accountId: accountId)), Data("坏了".utf8))
        XCTAssertEqual(pendingBackupFiles(accountId: accountId).count, 1)
        // 改状态／删行同样不动原文件。
        BearyDMStore.updatePendingStatus(localKey: "k1", status: .failed, accountId: accountId)
        BearyDMStore.removePending(localKey: "k1", accountId: accountId)
        XCTAssertEqual(try? Data(contentsOf: pendingFile(accountId: accountId)), Data("坏了".utf8))
    }

    // 审计第 18 轮 #12：改状态／删行的写盘结果经 completion 回传。
    func testPendingStatusAndRemoveReportWriteResult() {
        // 损坏态：改状态与删行都回 false，且原文件不动。
        let corruptAccount = 9013
        try? Data("坏了".utf8).write(to: pendingFile(accountId: corruptAccount))
        let corruptStatus = expectation(description: "corrupt update returns false")
        BearyDMStore.updatePendingStatus(localKey: "k1", status: .failed, accountId: corruptAccount) { saved in
            XCTAssertFalse(saved)
            corruptStatus.fulfill()
        }
        let corruptRemove = expectation(description: "corrupt remove returns false")
        BearyDMStore.removePending(localKey: "k1", accountId: corruptAccount) { saved in
            XCTAssertFalse(saved)
            corruptRemove.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertEqual(try? Data(contentsOf: pendingFile(accountId: corruptAccount)), Data("坏了".utf8))
        // 正常态：改状态成功回 true，落盘后的状态读回一致。
        let accountId = 9014
        BearyDMStore.savePending(.init(localKey: "k1", peerId: 5, body: "待发", createdAt: 1000, status: .sending), accountId: accountId)
        let statusExp = expectation(description: "update returns true")
        BearyDMStore.updatePendingStatus(localKey: "k1", status: .failed, accountId: accountId) { saved in
            XCTAssertTrue(saved)
            statusExp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertEqual(loadPendings(accountId: accountId, peerId: 5).first?.status, .failed)
        // 删行成功回 true，行已不在；再删不存在的行回 true（目标态已达成）。
        let removeExp = expectation(description: "remove returns true")
        BearyDMStore.removePending(localKey: "k1", accountId: accountId) { saved in
            XCTAssertTrue(saved)
            removeExp.fulfill()
        }
        waitForExpectations(timeout: 30)
        XCTAssertEqual(loadPendings(accountId: accountId, peerId: 5).count, 0)
        let removeMissingExp = expectation(description: "remove missing returns true")
        BearyDMStore.removePending(localKey: "k1", accountId: accountId) { saved in
            XCTAssertTrue(saved)
            removeMissingExp.fulfill()
        }
        waitForExpectations(timeout: 30)
        // 改不存在的行回 false（未落盘）。
        let missingStatusExp = expectation(description: "update missing returns false")
        BearyDMStore.updatePendingStatus(localKey: "k1", status: .failed, accountId: accountId) { saved in
            XCTAssertFalse(saved)
            missingStatusExp.fulfill()
        }
        waitForExpectations(timeout: 30)
    }

    func testPendingCorruptBackupURLIsUnique() {
        // 同秒内多次损坏也不撞名（审计第二轮 6：秒级时间戳会撞，须加 UUID）。
        let url = pendingFile(accountId: 9012)
        XCTAssertNotEqual(
            BearyDMStoreCore.pendingCorruptBackupURL(for: url),
            BearyDMStoreCore.pendingCorruptBackupURL(for: url)
        )
    }

    func testPendingAccountIsolation() {
        BearyDMStore.savePending(.init(localKey: "k1", peerId: 5, body: "A 的", createdAt: 1000, status: .sending), accountId: 9020)
        BearyDMStore.savePending(.init(localKey: "k2", peerId: 5, body: "B 的", createdAt: 1000, status: .sending), accountId: 9021)
        XCTAssertEqual(loadPendings(accountId: 9020, peerId: 5).map { $0.body }, ["A 的"])
        XCTAssertEqual(loadPendings(accountId: 9021, peerId: 5).map { $0.body }, ["B 的"])
        // 同账号不同对方也互不干扰。
        BearyDMStore.savePending(.init(localKey: "k3", peerId: 7, body: "另一人", createdAt: 1000, status: .sending), accountId: 9020)
        XCTAssertEqual(loadPendings(accountId: 9020, peerId: 5).map { $0.localKey }, ["k1"])
        XCTAssertEqual(loadPendings(accountId: 9020, peerId: 7).map { $0.localKey }, ["k3"])
    }

    // MARK: - 测量：整库写回性能（measure/dm-store-write-perf，测完删支）
    //
    // 只测不改：不改产品代码、不迁移存储，仅在测试侧计时并打印 [DM-PERF] 行供 CI 日志读取。
    // 消息正文约 30 字，与真实私信同量级。结论只保证“耗时随库增长”，不保证真机体感。

    private func perfFileBytes(accountId: Int) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: storeFile(accountId: accountId).path)[.size] as? Int) ?? -1
    }

    private func perfFileMtime(accountId: Int) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: storeFile(accountId: accountId).path)[.modificationDate] as? Date
    }

    /// 一次 persistMessages 的端到端耗时（调用 → completion 回主线程），含排队＋合并＋整库编码＋原子写。
    private func perfPersist(accountId: Int, peer peerId: Int, messages: [BearyAPI.DMMessage]) -> (ms: Double, saved: Bool, mergedCount: Int) {
        let exp = expectation(description: "perfPersist")
        let start = CFAbsoluteTimeGetCurrent()
        var ms = -1.0
        var saved = false
        var mergedCount = -1
        BearyDMStore.persistMessages(accountId: accountId, peer: peer(id: peerId), messages: messages) { outcome in
            ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if case .merged(let merged, let s) = outcome { saved = s; mergedCount = merged.count }
            exp.fulfill()
        }
        waitForExpectations(timeout: 120)
        return (ms, saved, mergedCount)
    }

    /// 种子：totalMessages 条分 peerCount 个会话、id 全局连续，每会话一次整批 persist 写入。
    private func perfSeed(accountId: Int, peerCount: Int, totalMessages: Int) {
        let perPeer = totalMessages / peerCount
        var nextId = 1
        for p in 1...peerCount {
            let batch = (0..<perPeer).map { i in
                message(id: nextId + i, body: "测量正文第 \(nextId + i) 条，约三十字长度的私信内容。")
            }
            nextId += perPeer
            let r = perfPersist(accountId: accountId, peer: p, messages: batch)
            XCTAssertTrue(r.saved, "种子写入应成功 peer=\(p)")
            XCTAssertEqual(r.mergedCount, perPeer)
        }
    }

    /// ① persist 单次耗时 vs 该账号总消息数（1k / 10k / 50k）× 会话数（1 / 20 / 100）。
    func testPerfPersistIncrementalVsTotal() {
        let scales: [(total: Int, peers: Int)] = [
            (1_000, 1), (1_000, 20),
            (10_000, 1), (10_000, 20), (10_000, 100),
            (50_000, 1), (50_000, 20), (50_000, 100),
        ]
        for (index, scale) in scales.enumerated() {
            let accountId = 9100 + index
            perfSeed(accountId: accountId, peerCount: scale.peers, totalMessages: scale.total)
            let bytes = perfFileBytes(accountId: accountId)
            XCTAssertGreaterThan(bytes, 0, "种子文件应存在")
            // 10 条新消息（模拟一拍轮询拉到的新消息）。
            let fresh = (1...10).map { message(id: scale.total + $0, body: "测量新增第 \($0) 条，约三十字长度的私信内容。") }
            let incr = perfPersist(accountId: accountId, peer: 1, messages: fresh)
            XCTAssertTrue(incr.saved)
            print("[DM-PERF] persist total=\(scale.total) peers=\(scale.peers) bytes=\(bytes) incr10ms=\(String(format: "%.2f", incr.ms)) saved=\(incr.saved)")
            // 同批重复（已在库里，合并去重后无新行）——轮询回包无新消息的等价场景。
            let mtimeBeforeDup = perfFileMtime(accountId: accountId)
            let dup = perfPersist(accountId: accountId, peer: 1, messages: fresh)
            let mtimeAfterDup = perfFileMtime(accountId: accountId)
            print("[DM-PERF] persist-dup total=\(scale.total) peers=\(scale.peers) dup10ms=\(String(format: "%.2f", dup.ms)) saved=\(dup.saved) mtimeChanged=\(mtimeBeforeDup != mtimeAfterDup) bytesAfter=\(perfFileBytes(accountId: accountId))")
            // 空批——loadLatest 空回包直接透传 persistMessages 的场景。
            let mtimeBeforeEmpty = perfFileMtime(accountId: accountId)
            let empty = perfPersist(accountId: accountId, peer: 1, messages: [])
            let mtimeAfterEmpty = perfFileMtime(accountId: accountId)
            print("[DM-PERF] persist-empty total=\(scale.total) peers=\(scale.peers) emptyMs=\(String(format: "%.2f", empty.ms)) saved=\(empty.saved) mtimeChanged=\(mtimeBeforeEmpty != mtimeAfterEmpty) bytesAfter=\(perfFileBytes(accountId: accountId))")
        }
    }

    /// ② 首次打开聊天页的整库解码耗时（丢内存索引 → loadAll 读盘＋解码；另拆纯编码耗时）。
    func testPerfFirstOpenDecode() {
        let scales: [(total: Int, peers: Int)] = [(1_000, 1), (10_000, 1), (10_000, 20), (50_000, 1)]
        for (index, scale) in scales.enumerated() {
            let accountId = 9200 + index
            perfSeed(accountId: accountId, peerCount: scale.peers, totalMessages: scale.total)
            let bytes = perfFileBytes(accountId: accountId)
            // 丢内存索引，模拟首次打开：下一次访问重新整库读盘＋解码。
            BearyDMStore.testBaseDirectory = tmpDir
            let t0 = CFAbsoluteTimeGetCurrent()
            let outcome = BearyDMStore.loadAll(accountId: accountId)
            let loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard case .loaded(let all) = outcome else { XCTFail("种子库应可读"); return }
            // 纯编码：整库字典 → Data（不含写盘）。
            let t1 = CFAbsoluteTimeGetCurrent()
            let encoded = BearyDMStoreCore.encode(all)
            let encodeMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
            XCTAssertNotNil(encoded)
            print("[DM-PERF] decode total=\(scale.total) peers=\(scale.peers) bytes=\(bytes) loadAllMs=\(String(format: "%.2f", loadMs)) encodeMs=\(String(format: "%.2f", encodeMs))")
            // 异步 messages()：首次访问走 cachedAll → loadAll，含主线程回切。
            BearyDMStore.testBaseDirectory = tmpDir
            let exp = expectation(description: "perfMessages")
            let t2 = CFAbsoluteTimeGetCurrent()
            var rows = -1
            BearyDMStore.messages(accountId: accountId, peerId: 1) { list in
                rows = list.count
                exp.fulfill()
            }
            waitForExpectations(timeout: 120)
            let msgMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000
            print("[DM-PERF] messages total=\(scale.total) peers=\(scale.peers) messagesMs=\(String(format: "%.2f", msgMs)) rows=\(rows)")
        }
    }

    /// ③ 会话列表同步入口 localConversations 在写盘进行时的主线程等待时间。
    func testPerfSyncEntryBlockedDuringWrite() {
        let accountId = 9300
        perfSeed(accountId: accountId, peerCount: 1, totalMessages: 50_000)
        // 三轮：每轮先发一笔 5000 条新消息的写盘（不等待），紧接着在测试线程调同步入口；
        // syncOnIO 会等到在途写盘完成——测到的就是主线程同款等待（最坏情况：调用撞上在途写盘）。
        for round in 1...3 {
            let batch = (1...5_000).map { message(id: 50_000 + (round - 1) * 5_000 + $0, body: "测量大批量第 \($0) 条，约三十字长度的私信内容。") }
            let exp = expectation(description: "perfBigPersist r\(round)")
            let t0 = CFAbsoluteTimeGetCurrent()
            var persistMs = -1.0
            BearyDMStore.persistMessages(accountId: accountId, peer: peer(id: 2), messages: batch) { _ in
                persistMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                exp.fulfill()
            }
            let s0 = CFAbsoluteTimeGetCurrent()
            let convs = BearyDMStore.localConversations(accountId: accountId)
            let blockedMs = (CFAbsoluteTimeGetCurrent() - s0) * 1000
            waitForExpectations(timeout: 120)
            XCTAssertEqual(convs.count, 2)
            print("[DM-PERF] sync-blocked round=\(round) totalBefore=50000 bigBatch=5000 blockedMs=\(String(format: "%.2f", blockedMs)) persistMs=\(String(format: "%.2f", persistMs)) bytes=\(perfFileBytes(accountId: accountId))")
        }
    }
}

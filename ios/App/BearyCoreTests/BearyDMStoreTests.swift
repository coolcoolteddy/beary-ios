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
        BearyDMStore.saveMessages(accountId: accountId, peer: peer(id: peerId), messages: messages) { result in
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
        BearyDMStore.saveMessages(accountId: first, peer: peer(id: 5), messages: [message(id: 10, body: "一号的消息")]) { _ in exp1.fulfill() }
        BearyDMStore.saveMessages(accountId: second, peer: peer(id: 6), messages: [message(id: 20, body: "二号的消息")]) { _ in exp2.fulfill() }
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
}

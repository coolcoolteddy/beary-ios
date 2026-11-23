import Foundation

// ===== 本人主动离线保存：编排层 =====
//
// 存储核见 BearyOfflineSaveStore.swift。本文件只做编排：
//   - 本人门控：只保存作者是当前账号的日记（isMine 或 authorId == 当前用户 id），
//     他人篇一律拒绝（调用方详情页 ⋯ 菜单只在 isAuthor 时才露出入口，这里是第二道门）；
//   - 取图：原图字节走 BearyImageLoader.fetchRawData（磁盘命中即复用、不重复下载，
//     未命中走一次网络下载并按图片口径验 HTTP 2xx + image/* MIME + 可解码探针）；
//   - 续传：已在盘上的图片不再下载，只补缺失的；中途退出残留 pending 记录，
//     下次保存续传；
//   - 批量：以本地已同步的日记归档（BearyEntrySyncStore.loadAllEntries）为源，
//     只取本人篇、跳过已 complete 的篇，逐篇顺序保存并报进度。
//
// 实况视频（liveVideos）本批不存：只存文字 JSON 与静态原图字节；
// 离线打开实况篇时静态帧仍在，视频需联网。后续要补时走 BearyLivePhotoLoader
// 的 mov 原字节，同一目录结构可扩展，不改存储核口径。

enum BearyOfflineSaveError: Error {
    case notLoggedIn
    case notMine
    case missingId
    case entryWriteFailed
}

struct BearyOfflineSaveOutcome {
    var savedImages: Int
    var failedKeys: [String]
    var totalBytes: Int64
    /// complete = 全部图片在盘；partial = 部分图片缺失。
    var status: String
}

struct BearyOfflineSaveBatchResult {
    var saved: Int
    var partial: Int
    var failed: Int
    var skipped: Int
}

final class BearyOfflineSaveManager {
    static let shared = BearyOfflineSaveManager()

    /// 清单与写盘只走这条串行队列；网络取图回调回本队列再写盘，不跨线程碰清单。
    private let queue = DispatchQueue(label: "com.beary.offline-save")

    private init() {}

    var currentAccountId: Int? {
        SessionManager.shared.currentUser?.id ?? BearyImageLoader.shared.currentAccountId
    }

    func isOwnEntry(_ entry: Entry) -> Bool {
        guard let accountId = currentAccountId else { return false }
        return entry.isMine == true || entry.authorId == accountId
    }

    func record(for entryId: String) -> BearyOfflineSaveRecord? {
        guard let accountId = currentAccountId else { return nil }
        return BearyOfflineSaveStore.record(accountId: accountId, entryId: entryId)
    }

    /// 同步读清单：只在后台队列（写盘路径）或测试里调；主线程走下面的异步版。
    func isSaved(entryId: String) -> Bool {
        record(for: entryId)?.isComplete == true
    }

    /// 同步读清单：只在后台队列或测试里调；主线程走下面的异步版。
    func savedRecords() -> [BearyOfflineSaveRecord] {
        guard let accountId = currentAccountId else { return [] }
        return BearyOfflineSaveStore.savedRecords(accountId: accountId)
    }

    /// 同步算占用（递归枚举整桶字节＋读清单）：只在后台队列或测试里调；
    /// 主线程走下面的异步版。
    func usage() -> (bytes: Int64, entryCount: Int) {
        guard let accountId = currentAccountId else { return (0, 0) }
        return BearyOfflineSaveStore.usage(accountId: accountId)
    }

    // MARK: - 清单异步读（第三轮 B 项：后台读＋标脏后异步重载）

    /// 预热清单缓存（详情页／设置页进页时调）：后台读盘进缓存，主线程读清单
    /// 时只命中内存；未登录时不读盘。
    func warmManifestCache() {
        guard let accountId = currentAccountId else { return }
        BearyOfflineSaveStore.refreshManifestCache(accountId: accountId)
    }

    /// 内存里的保存态（缓存已加载且未标脏时才有值；nil = 未读到，调用方走
    /// 异步版等回包，不以 false 冒充未保存）。
    func cachedIsSaved(entryId: String) -> Bool? {
        guard let accountId = currentAccountId else { return nil }
        return BearyOfflineSaveStore.cachedManifest(accountId: accountId)?.record(for: entryId)?.isComplete
    }

    /// 异步版 isSaved：清单在后台读，结果回主线程；未登录回 false。
    func isSaved(entryId: String, completion: @escaping (Bool) -> Void) {
        guard let accountId = currentAccountId else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        BearyOfflineSaveStore.loadManifestAsync(accountId: accountId) { manifest in
            completion(manifest.record(for: entryId)?.isComplete == true)
        }
    }

    /// 异步版 savedRecords：清单在后台读，结果回主线程；未登录回 []。
    func savedRecords(completion: @escaping ([BearyOfflineSaveRecord]) -> Void) {
        guard let accountId = currentAccountId else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        BearyOfflineSaveStore.loadManifestAsync(accountId: accountId) { manifest in
            completion(manifest.entries)
        }
    }

    /// 异步版 usage：整桶字节枚举＋清单读都在本队列（后台）做，结果回主线程；
    /// 读到之前调用方留旧文案，不先写“未保存”。未登录回 (0, 0)。
    func usage(completion: @escaping ((bytes: Int64, entryCount: Int)) -> Void) {
        guard let accountId = currentAccountId else {
            DispatchQueue.main.async { completion((0, 0)) }
            return
        }
        queue.async {
            let result = BearyOfflineSaveStore.usage(accountId: accountId)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 单篇保存

    /// 逐篇标记离线保存：先写文字 JSON（失败即整体失败），再逐张补图片原字节。
    /// 完成回调一律回主线程；成功也可能带 failedKeys（partial，文字已存、部分图缺失）。
    func save(entry: Entry, completion: @escaping (Result<BearyOfflineSaveOutcome, BearyOfflineSaveError>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let accountId = self.currentAccountId else {
                self.completeOnMain(.failure(.notLoggedIn), completion: completion)
                return
            }
            guard self.isOwnEntry(entry) else {
                self.completeOnMain(.failure(.notMine), completion: completion)
                return
            }
            guard let entryId = entry.id, !entryId.isEmpty else {
                self.completeOnMain(.failure(.missingId), completion: completion)
                return
            }
            guard BearyOfflineSaveStore.saveEntryJSON(accountId: accountId, entry: entry) else {
                self.completeOnMain(.failure(.entryWriteFailed), completion: completion)
                return
            }
            let keys = entry.images ?? []
            let title = BearyOfflineSaveStore.displayTitle(for: entry)
            // 先记 pending：中途退出/崩溃后残留，下次保存凭它续传未下载的图片。
            let pending = BearyOfflineSaveRecord(
                entryId: entryId, title: title, createdAtMs: entry.createdAt,
                savedAt: Date().timeIntervalSince1970,
                imageCount: keys.count, downloadedCount: 0, failedKeys: [],
                totalBytes: BearyOfflineSaveStore.entryJSONByteCount(accountId: accountId, entryId: entryId),
                status: "pending")
            _ = BearyOfflineSaveStore.upsertRecord(accountId: accountId, record: pending)
            if keys.isEmpty {
                let outcome = self.finalize(accountId: accountId, entry: entry, downloadedKeys: [], failedKeys: [])
                self.completeOnMain(.success(outcome), completion: completion)
                return
            }
            // 已在盘上的图不再下载；只对缺失的发取图，全部回齐后一次性结算。
            var downloadedKeys: [String] = []
            var failedKeys: [String] = []
            let group = DispatchGroup()
            for key in keys {
                if BearyOfflineSaveStore.hasImageData(accountId: accountId, entryId: entryId, key: key) {
                    downloadedKeys.append(key)
                    continue
                }
                guard let url = BearyImageURLs.imageURL(key: key, thumb: false) else {
                    failedKeys.append(key)
                    continue
                }
                group.enter()
                BearyImageLoader.shared.fetchRawData(url: url) { [weak self] data in
                    guard let self = self else { group.leave(); return }
                    self.queue.async {
                        if let data = data, BearyOfflineSaveStore.saveImageData(accountId: accountId, entryId: entryId, key: key, data: data) {
                            downloadedKeys.append(key)
                        } else {
                            failedKeys.append(key)
                        }
                        group.leave()
                    }
                }
            }
            group.notify(queue: self.queue) { [weak self] in
                guard let self = self else { return }
                let outcome = self.finalize(accountId: accountId, entry: entry, downloadedKeys: downloadedKeys, failedKeys: failedKeys)
                self.completeOnMain(.success(outcome), completion: completion)
            }
        }
    }

    /// 结算：按实际落盘情况写回清单记录（complete/partial）并算本篇总字节。
    private func finalize(accountId: Int, entry: Entry, downloadedKeys: [String], failedKeys: [String]) -> BearyOfflineSaveOutcome {
        guard let entryId = entry.id else {
            return BearyOfflineSaveOutcome(savedImages: 0, failedKeys: failedKeys, totalBytes: 0, status: "partial")
        }
        let keys = entry.images ?? []
        var totalBytes = BearyOfflineSaveStore.entryJSONByteCount(accountId: accountId, entryId: entryId)
        for key in downloadedKeys {
            totalBytes += BearyOfflineSaveStore.imageByteCount(accountId: accountId, entryId: entryId, key: key)
        }
        let status = failedKeys.isEmpty ? "complete" : "partial"
        let previous = BearyOfflineSaveStore.record(accountId: accountId, entryId: entryId)
        let record = BearyOfflineSaveRecord(
            entryId: entryId,
            title: BearyOfflineSaveStore.displayTitle(for: entry),
            createdAtMs: entry.createdAt,
            savedAt: previous?.savedAt ?? Date().timeIntervalSince1970,
            imageCount: keys.count,
            downloadedCount: downloadedKeys.count,
            failedKeys: failedKeys,
            totalBytes: totalBytes,
            status: status)
        _ = BearyOfflineSaveStore.upsertRecord(accountId: accountId, record: record)
        return BearyOfflineSaveOutcome(savedImages: downloadedKeys.count, failedKeys: failedKeys, totalBytes: totalBytes, status: status)
    }

    private func completeOnMain(_ result: Result<BearyOfflineSaveOutcome, BearyOfflineSaveError>, completion: @escaping (Result<BearyOfflineSaveOutcome, BearyOfflineSaveError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - 批量保存

    /// 批量：以本地已同步归档为源，只取本人篇、跳过已 complete 的篇，逐篇顺序保存。
    /// progress(done,total) 与 completion 一律回主线程；单篇失败只计 failed，不中断整批。
    func saveAllOwnEntries(progress: ((Int, Int) -> Void)? = nil, completion: @escaping (BearyOfflineSaveBatchResult) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let accountId = self.currentAccountId else {
                DispatchQueue.main.async { completion(BearyOfflineSaveBatchResult(saved: 0, partial: 0, failed: 0, skipped: 0)) }
                return
            }
            let all = BearyEntrySyncStore.loadAllEntries(accountId: accountId) ?? []
            let own = all.filter { $0.isMine == true || $0.authorId == accountId }
            let total = own.count
            var result = BearyOfflineSaveBatchResult(saved: 0, partial: 0, failed: 0, skipped: 0)
            var done = 0
            let group = DispatchGroup()
            // 顺序链：一次只跑一篇，清单写盘不交错；progress 在每篇结算后报。
            func saveNext(index: Int) {
                guard index < own.count else {
                    DispatchQueue.main.async { completion(result) }
                    return
                }
                let entry = own[index]
                if let entryId = entry.id,
                   BearyOfflineSaveStore.record(accountId: accountId, entryId: entryId)?.isComplete == true {
                    result.skipped += 1
                    done += 1
                    DispatchQueue.main.async { progress?(done, total) }
                    saveNext(index: index + 1)
                    return
                }
                group.enter()
                self.save(entry: entry) { single in
                    switch single {
                    case .success(let outcome):
                        if outcome.status == "complete" { result.saved += 1 } else { result.partial += 1 }
                    case .failure:
                        result.failed += 1
                    }
                    done += 1
                    DispatchQueue.main.async { progress?(done, total) }
                    group.leave()
                }
                // save 的完成回调在主线程：等它回来再继续下一篇，避免并发写清单。
                group.notify(queue: self.queue) {
                    saveNext(index: index + 1)
                }
            }
            saveNext(index: 0)
        }
    }

    // MARK: - 删除

    /// 删单篇离线副本（文字 + 图片 + 清单记录）；已同步的日记与 Caches 缓存不受影响。
    /// 同步版：只在后台队列或测试里调；主线程走下面的异步版。
    @discardableResult
    func remove(entryId: String) -> Bool {
        guard let accountId = currentAccountId else { return false }
        return BearyOfflineSaveStore.removeEntry(accountId: accountId, entryId: entryId)
    }

    /// 异步版 remove：删盘在本队列（后台）做，成败回主线程；未登录回 false。
    /// 清单写盘成功后 Store 标脏并后台重载缓存，调用方重读即新值。
    func remove(entryId: String, completion: @escaping (Bool) -> Void) {
        guard let accountId = currentAccountId else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        queue.async {
            let removed = BearyOfflineSaveStore.removeEntry(accountId: accountId, entryId: entryId)
            DispatchQueue.main.async { completion(removed) }
        }
    }

    /// 清除本账号全部离线保存；其他账号的桶不动，已同步的日记不受影响。
    /// 同步版：只在后台队列或测试里调；主线程走下面的异步版。
    @discardableResult
    func removeAll() -> Bool {
        guard let accountId = currentAccountId else { return false }
        return BearyOfflineSaveStore.removeAll(accountId: accountId)
    }

    /// 异步版 removeAll：删盘在本队列（后台）做，成败回主线程；未登录回 false。
    func removeAll(completion: @escaping (Bool) -> Void) {
        guard let accountId = currentAccountId else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        queue.async {
            let cleared = BearyOfflineSaveStore.removeAll(accountId: accountId)
            DispatchQueue.main.async { completion(cleared) }
        }
    }
}

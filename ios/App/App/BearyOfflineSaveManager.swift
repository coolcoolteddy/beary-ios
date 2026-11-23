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

    func isSaved(entryId: String) -> Bool {
        record(for: entryId)?.isComplete == true
    }

    func savedRecords() -> [BearyOfflineSaveRecord] {
        guard let accountId = currentAccountId else { return [] }
        return BearyOfflineSaveStore.savedRecords(accountId: accountId)
    }

    func usage() -> (bytes: Int64, entryCount: Int) {
        guard let accountId = currentAccountId else { return (0, 0) }
        return BearyOfflineSaveStore.usage(accountId: accountId)
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
            // A2：单篇保存的两次清单写（pending 与 finalize 各一次 upsert）
            // 并作一批：其间只改内存缓存，finalize 结算后一次落盘。
            // 批量时外层 saveAllOwnEntries 另开一批，整批 N 篇只落盘一次。
            BearyOfflineSaveStore.beginManifestBatch(accountId: accountId)
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
                guard let self = self else {
                    // Manager 已释放、finalize 跑不到：把本篇开的批量合上，
                    // 脏缓存落盘一次，别让 depth 卡住、后续 upsert 一直不写盘。
                    BearyOfflineSaveStore.endManifestBatch(accountId: accountId)
                    return
                }
                let outcome = self.finalize(accountId: accountId, entry: entry, downloadedKeys: downloadedKeys, failedKeys: failedKeys)
                self.completeOnMain(.success(outcome), completion: completion)
            }
        }
    }

    /// 结算：按实际落盘情况写回清单记录（complete/partial）并算本篇总字节。
    /// 写完合上本篇开的批量（单篇保存时 depth 回 0、一次落盘；批量时
    /// 外层仍在批内，不写盘，等整批结束再落盘）。
    private func finalize(accountId: Int, entry: Entry, downloadedKeys: [String], failedKeys: [String]) -> BearyOfflineSaveOutcome {
        guard let entryId = entry.id else {
            _ = BearyOfflineSaveStore.endManifestBatch(accountId: accountId)
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
        _ = BearyOfflineSaveStore.endManifestBatch(accountId: accountId)
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
            // A2：整批只落盘一次——其间每篇的 pending/finalize 两次 upsert
            // 只改内存缓存，末篇结算后 endManifestBatch 一次写盘。
            BearyOfflineSaveStore.beginManifestBatch(accountId: accountId)
            let all = BearyEntrySyncStore.loadAllEntries(accountId: accountId) ?? []
            let own = all.filter { $0.isMine == true || $0.authorId == accountId }
            let total = own.count
            var result = BearyOfflineSaveBatchResult(saved: 0, partial: 0, failed: 0, skipped: 0)
            var done = 0
            let group = DispatchGroup()
            // 顺序链：一次只跑一篇，清单写盘不交错；progress 在每篇结算后报。
            func saveNext(index: Int) {
                guard index < own.count else {
                    _ = BearyOfflineSaveStore.endManifestBatch(accountId: accountId)
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
    @discardableResult
    func remove(entryId: String) -> Bool {
        guard let accountId = currentAccountId else { return false }
        return BearyOfflineSaveStore.removeEntry(accountId: accountId, entryId: entryId)
    }

    /// 清除本账号全部离线保存；其他账号的桶不动，已同步的日记不受影响。
    @discardableResult
    func removeAll() -> Bool {
        guard let accountId = currentAccountId else { return false }
        return BearyOfflineSaveStore.removeAll(accountId: accountId)
    }
}

import Foundation

// ===== 同步存储三份单测的共享 helper =====
//
// 原先 BearyEntrySyncStoreTests / BearyEntrySyncIncrementalTests /
// BearyOfflineSaveStoreTests 各写一份的 makeEntry / makeTrashItem /
// setUp-tearDown 清桶逻辑逐字相同，只差两处变体，用参数化收掉：
//   - OfflineSave 的 makeEntry 多一个 images 参数（传了就写进 JSON）；
//   - OfflineSave 的 setUp-tearDown 清的是 BearyOfflineSaveStore、双账号。
// 只引用测试 target 已编的符号（Entry / TrashItem / 三个 Store），
// 不引测试 target 清单外的符号（见 #938 教训：新文件须进测试 target
// 文件清单，见 project.pbxproj 的 BearyCoreTests Sources）。

enum BearySyncTestHelpers {

    /// 造一篇测试日记：与三文件原先的 JSON 口径一致
    ///（snake_case 解码；content 固定为 "test \(id)"）。
    /// images 为 nil 时不写 images 键（EntrySync 两份原样）；
    /// 传了就写进 JSON（OfflineSave 原样，如 ["a/b.jpg"]）。
    static func makeEntry(id: String, createdAtMs: Int, images: [String]? = nil) -> Entry {
        let imagesJSON: String
        if let images {
            imagesJSON = ", \"images\": [" + images.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        } else {
            imagesJSON = ""
        }
        let json = """
        {"id": "\(id)", "created_at": \(createdAtMs), "content": "test \(id)"\(imagesJSON)}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Entry.self, from: Data(json.utf8))
    }

    /// 造一个回收站测试项：与 EntrySync 两份原先的构造一致。
    static func makeTrashItem(id: String, deletedAtMs: Int) -> TrashItem {
        TrashItem(id: id, content: "trash \(id)", createdAt: nil, publishAt: nil,
                  deletedAt: deletedAtMs, daysLeft: 30)
    }

    /// 清一个账号的日记同步桶与回收站同步桶（EntrySync 两份的 setUp-tearDown 原样）。
    static func purgeSyncStores(accountId: Int) {
        BearyEntrySyncStore.purgeAccount(accountId: accountId)
        BearyTrashSyncStore.purgeAccount(accountId: accountId)
    }

    /// 清一个或多个账号的离线保存桶（OfflineSave 的 setUp-tearDown 原样，双账号）。
    static func purgeOfflineSaveStore(accountIds: [Int]) {
        for accountId in accountIds {
            BearyOfflineSaveStore.purgeAccount(accountId: accountId)
        }
    }
}

import UIKit

// ===== 个人 GIF 库（微信表情包模式）：服务端按账号存，App 端按账号缓存 =====
// 上传/添加过的 GIF 存进自己的库，在哪都能用；库里只存 key、不复制文件。
// 上限 100 个，满了先删再加（add 满时服务端 409 'library full'）。
// 心情选择器打开时 refresh 一次（失败静默用缓存）；增删后发通知，
// 选择器在前台时跟帧刷新“我的 GIF”组。服务端接口与表见
// ~/workspace/beary-gif-upload-server.diff（GET /beary/api/gif-library、
// POST /beary/api/gif-library/add|remove；表 beary_gif_library）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyGIFLibrary {

    static let maxCount = 100
    static let libraryDidChangeNotification = Notification.Name("BearyGIFLibraryDidChange")

    private static func cacheKey(accountId: Int?) -> String {
        "beary.gifLibrary.\(accountId.map(String.init) ?? "guest")"
    }

    static func cachedKeys(accountId: Int? = BearyDraftStore.currentAccountId) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(accountId: accountId)),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys.filter { $0.hasSuffix(".gif") }
    }

    private static func saveCache(_ keys: [String], accountId: Int?) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(accountId: accountId))
    }

    static func contains(_ key: String, accountId: Int? = BearyDraftStore.currentAccountId) -> Bool {
        cachedKeys(accountId: accountId).contains(key)
    }

    /// 拉服务端列表刷新本地缓存（心情选择器打开时调；失败静默用缓存）。
    static func refresh(completion: (([String]) -> Void)? = nil) {
        let accountId = BearyDraftStore.currentAccountId
        BearyAPI.shared.gifLibraryList { result in
            DispatchQueue.main.async {
                guard BearyDraftStore.currentAccountId == accountId else { return }
                switch result {
                case .success(let resp):
                    let keys = (resp.keys ?? []).filter { $0.hasSuffix(".gif") }
                    saveCache(keys, accountId: accountId)
                    NotificationCenter.default.post(name: libraryDidChangeNotification, object: nil)
                    completion?(keys)
                case .failure:
                    completion?(cachedKeys(accountId: accountId))
                }
            }
        }
    }

    enum AddResult { case added, alreadyAdded, full, notViewable, failed }

    /// 加进我的库（按 key 去重；服务端是权威——缓存未命中但服务端已有
    /// 时回 added:false，仍把 key 补进缓存）。
    static func add(key: String, completion: @escaping (AddResult) -> Void) {
        let accountId = BearyDraftStore.currentAccountId
        if contains(key, accountId: accountId) { completion(.alreadyAdded); return }
        BearyAPI.shared.gifLibraryAdd(key: key) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    var keys = cachedKeys(accountId: accountId)
                    if keys.contains(key) == false { keys.insert(key, at: 0) }
                    saveCache(Array(keys.prefix(maxCount)), accountId: accountId)
                    NotificationCenter.default.post(name: libraryDidChangeNotification, object: nil)
                    completion(resp.added == false ? .alreadyAdded : .added)
                case .failure(let error):
                    if case .server(let code, _) = error, code == "library full" { completion(.full); return }
                    if case .server(let code, _) = error, code == "not viewable" { completion(.notViewable); return }
                    completion(.failed)
                }
            }
        }
    }

    /// 从我的库删掉（只删行，不删文件、不影响已发日记里的引用）。
    static func remove(key: String, completion: ((Bool) -> Void)? = nil) {
        let accountId = BearyDraftStore.currentAccountId
        BearyAPI.shared.gifLibraryRemove(key: key) { _ in
            DispatchQueue.main.async {
                var keys = cachedKeys(accountId: accountId)
                keys.removeAll { $0 == key }
                saveCache(keys, accountId: accountId)
                NotificationCenter.default.post(name: libraryDidChangeNotification, object: nil)
                completion?(true)
            }
        }
    }
}

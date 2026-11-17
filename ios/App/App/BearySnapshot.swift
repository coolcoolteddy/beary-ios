import Foundation

// 日记快照（2026-11-11 产品冲突清单第 4 条定版）：旧文字版，只含文字、不含照片。
// 服务端 GET /beary/api/entries/:id/snapshots 只返回最近 7 天内产生的版本，
// 星标版长期保留；恢复前服务端先自动存一遍当前版本（不自动加星标）。

struct BearyEntrySnapshot: Decodable {
    var id: Int?
    var entryId: String?
    var content: String?
    var title: String?
    var createdAt: Int?
    var starred: Int?
    /// 星标判定：只认显式 1（与 Entry.isPinned 同款 fail-closed 口径）。
    var isStarred: Bool { starred == 1 }

    /// 展示时间：yyyy-MM-dd HH:mm:ss（设备本地时区）；列表首行与预览副行同款。
    /// 服务端 created_at 是毫秒，相对时间（feedTimeString）不进快照展示。
    var displayDateString: String {
        guard let ms = createdAt else { return "" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    /// 固定格式走 en_US_POSIX，时区跟设备（与截图 23:42:35 同款本地时间）。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

struct BearySnapshotListResponse: Decodable {
    var snapshots: [BearyEntrySnapshot]?
}

struct BearySnapshotStarResponse: Decodable {
    var starred: Int?
}

// MARK: - 快照接口（端点均已在 teddy_beary/worker.js 后端核实）

extension BearyAPI {
    /// 快照列表：GET /beary/api/entries/:id/snapshots，仅作者本人可读。
    func fetchSnapshots(entryId: String, completion: @escaping (Result<[BearyEntrySnapshot], APIError>) -> Void) {
        let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        request("/beary/api/entries/\(safe)/snapshots") { (result: Result<BearySnapshotListResponse, APIError>) in
            switch result {
            case .success(let resp):
                completion(.success(resp.snapshots ?? []))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 手动星标开关：POST /beary/api/entries/:id/snapshots/:snapId/star，取反；
    /// 响应带取反后的 starred，调用方以它覆盖本地值。
    func toggleSnapshotStar(entryId: String, snapshotId: Int, completion: @escaping (Result<BearySnapshotStarResponse, APIError>) -> Void) {
        let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        request("/beary/api/entries/\(safe)/snapshots/\(snapshotId)/star", method: "POST", completion: completion)
    }

    /// 一键恢复：POST /beary/api/entries/:id/snapshots/:snapId/restore。
    /// 服务端先自动存当前文字版为快照，再写回旧文字；只恢复文字，不动照片。
    func restoreSnapshot(entryId: String, snapshotId: Int, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        requestVoid("/beary/api/entries/\(safe)/snapshots/\(snapshotId)/restore", method: "POST", completion: completion)
    }

    /// 清空全部快照：DELETE /beary/api/entries/:id/snapshots，仅作者本人。
    /// 删掉该篇全部快照（含已加星标的长期保留版），不可撤销；服务端点位见
    /// beary-snapshot-clear-server.diff，部署前调用会 404、按失败处理。
    func clearSnapshots(entryId: String, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId
        requestVoid("/beary/api/entries/\(safe)/snapshots", method: "DELETE", completion: completion)
    }
}

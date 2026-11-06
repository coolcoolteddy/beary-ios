import Foundation

/// 第四轮增量同步批 01/11：一次同步的任务身份与分批进度（只依赖 Foundation，
/// 不碰 SessionManager 与网络，可进测试 target）。
///
/// 任务身份（11）：kick 时捕获 authEpoch 与任务代次；分页回调与最终提交前
/// 双重校验——epoch 或代次任一不符即旧任务回包（退出/重登/切号/新一轮 kick
/// 后到达），一律丢弃，不提交、不记已同步。
struct BearySyncTaskIdentity: Equatable {
    var epoch: Int
    var generation: Int

    /// 该身份是否仍是当前任务（回包接纳判定）。
    func matches(epoch: Int, generation: Int) -> Bool {
        self.epoch == epoch && self.generation == generation
    }
}

/// 分批同步进度（01：可恢复分页游标）——只含游标与元数据（日键集合与每页
/// 拉到的 id 集合），不含正文等条目内容；完成或丢弃时删除。
/// epoch 与 writeSequence 是续跑的前提：重登/切号（epoch 变）或其间有过
/// 本地写盘（writeSequence 变），旧进度作废、从头重跑。
struct DiarySyncProgress: Codable {
    /// 发起时的 authEpoch。
    var epoch: Int
    /// 发起时的日记写盘代际。
    var writeSequence: Int
    var before: Int?
    var beforeId: String?
    var pageCount: Int
    var totalFetched: Int
    var seenDayKeys: [String]
    var entryIdsByDay: [String: [String]]
}

/// 回收站分批同步进度（同日记腿）。
struct TrashSyncProgress: Codable {
    /// 发起时的 authEpoch。
    var epoch: Int
    /// 发起时的回收站写盘代际。
    var writeSequence: Int
    var before: String?
    var beforeId: String?
    var pageCount: Int
    var totalFetched: Int
    var seenIds: [String]
}

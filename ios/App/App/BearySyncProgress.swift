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

/// 进程启动标识：每次 App 启动生成一个新值，只存内存、永不落盘。
/// 分批进度落盘时盖上本启动的标识；恢复时只认同启动的进度——跨重启的
/// 旧进度一律作废、从第一页重核。单凭 epoch 与 writeSequence 无法区分
/// “同启动续跑”与“重启后旧进度”：两个计数都是内存态，重启后归零重取，
/// 与上一进程保存的旧进度可能取到相同数值（审计新一轮 P1-1）。
enum BearySyncLaunchIdentity {
    static let token = UUID().uuidString
}

/// 分批同步进度（01：可恢复分页游标）——只含游标与元数据（日键集合与每页
/// 拉到的 id 集合），不含正文等条目内容；完成或丢弃时删除。
/// epoch、writeSequence 与 launchToken 是续跑的前提：重登/切号（epoch 变）、
/// 其间有过本地写盘（writeSequence 变）或跨进程重启（launchToken 变），
/// 旧进度作废、从头重跑。旧版落盘文件无 launchToken 键，解码为 nil，
/// 与本启动标识比对不上，同样作废（正好清掉修法前可能已误认的旧进度）。
struct DiarySyncProgress: Codable {
    /// 发起时的 authEpoch。
    var epoch: Int
    /// 发起时的日记写盘代际。
    var writeSequence: Int
    /// 发起时的进程启动标识（同启动才续跑；缺省 nil 即旧版文件）。
    var launchToken: String? = nil
    var before: Int?
    var beforeId: String?
    var pageCount: Int
    var totalFetched: Int
    var seenDayKeys: [String]
    var entryIdsByDay: [String: [String]]
}

/// 回收站分批同步进度（同日记腿；launchToken 口径同 DiarySyncProgress）。
struct TrashSyncProgress: Codable {
    /// 发起时的 authEpoch。
    var epoch: Int
    /// 发起时的回收站写盘代际。
    var writeSequence: Int
    /// 发起时的进程启动标识（同启动才续跑；缺省 nil 即旧版文件）。
    var launchToken: String? = nil
    var before: String?
    var beforeId: String?
    var pageCount: Int
    var totalFetched: Int
    var seenIds: [String]
}

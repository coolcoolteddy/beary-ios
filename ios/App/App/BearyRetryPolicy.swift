import Foundation

/// 三层重试口径表（可复用资源第十四批第 2 项收口）。
///
/// 三套重试分属不同层，分层、触发与持久性都不同，不合成一个重试引擎；
/// 这里只收「重试次数＋退避」口径与「失败即摘」判定，各层仍留自己的队列与触发器。
///
/// 请求层 BearyAPI.requestAttempt：自动，随请求；内存（当次请求内）。
///   发布 3 次，1s→2s→4s（封顶 4s）；GET 1 次、仅网络错误、立即重发；
///   上传 0 次。失败即摘：次数耗尽／不可重试／epoch 或账号已变即停，原失败原样返回。
/// 发布任务层 BearyPublishCenter.retryPublish：手动，用户点按才重试；
///   失败记录内存（上限 10 条）＋草稿持久标记。手动重试不限次数，每次重跑都
///   重新走请求层 3 次退避重试。失败即摘：记录超 10 条丢最旧；草稿被改过／
///   草稿已不在，不原样重跑、走编辑器。
/// 同步补拉层 BearyEntrySync.drainPendingRefetch：自动，kick 驱动
///   （启动／回前台／下拉刷新）；磁盘队列。单条最多 10 次，无退避——
///   attempts 每 kick 最多 +1，不存在紧循环；待办是幂等 GET 单条重拉，
///   kick 本身已是节流，10 次是防无限重发的兜底上限，不是重试时刻表。
///   失败即摘：落盘成功／404／attempts 触顶即摘，下次全量同步仍会拉回。
enum BearyRetryPolicy {
    /// 请求层：发布（POST /beary/api/entries）最多重试次数。
    static let publishMaxRetries = 3
    /// 请求层：发布重试首延。
    static let publishBackoffInitialDelay: TimeInterval = 1
    /// 请求层：发布重试每次延迟倍数。
    static let publishBackoffMultiplier: TimeInterval = 2
    /// 请求层：发布重试退避封顶（序列 1s→2s→4s）。
    static let publishBackoffMaxDelay: TimeInterval = 4
    /// 请求层：GET 最多重试次数（仅网络错误、立即重发，无退避）。
    static let readMaxRetries = 1
    /// 请求层：上传（POST /beary/api/images/upload）不重试——重发会重复落图。
    static let uploadMaxRetries = 0
    /// 同步补拉层：单条待办最多重拉次数（跨 kick 累计），触顶即摘。
    static let refetchMaxAttempts = 10
    /// 发布任务层：内存失败记录上限（超了丢最旧一条）。这是内存 bound，
    /// 不是重试次数——手动重试本身不限次数。
    static let publishFailureRecordLimit = 10
}

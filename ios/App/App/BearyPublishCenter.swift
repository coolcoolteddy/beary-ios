import UIKit

/// 第一次点按时拍下的不可变完整发布快照（quote-freeze）：正文、心情、
/// 天气、气温、引用、可见性、@、标题、限时、位置、clientReq 全在点按瞬间
/// 定格；门禁与 setVisibility 在途期间用户改什么都不再进提交载荷，
/// 发布中心只读本快照。
/// （从 BearyComposerViewController 移出：发布中心持有它跑后台发布，
/// 编辑器退出后快照仍在。imageKeys/liveVideos 不在此：新模型下图片
/// 发布时才上传，keys 由发布中心按交接的图片清单顺序算出。）
struct PublishSnapshot {
    let content: String
    let mood: String?
    let weather: String?
    let temperature: Int?
    var quoteId: String?
    var published: Int
    /// 好友第一期：新建三档（private/friends/public；限时恒 public）。
    /// 快照拍定后 publishEntry 按它发，published 同步作旧版兼容（friends→0）。
    var visibility: String
    let mentionedUserId: Int?
    let title: String?
    /// 标签完整版（2026-11-18）：新建时选中的标签列；空组不发 tags 键。
    let tags: [String]?
    var ephemeral: Int?
    let locationName: String?
    let locationDistrict: String?
    /// 发布快照里的地点经纬度（2026-11-14 Li 定改存经纬度，随文本一起发）。
    let locationLatitude: Double?
    let locationLongitude: Double?
    /// 2026-11-19 七组版：定位地址精度分级字段（随地点一起发，取自 placemark）。
    let locationCountry: String?
    let locationRegion: String?
    let locationCity: String?
    let locationStreet: String?
    /// 日记时区（2026-11-21 v21 §二，17:02 Li 改）：创建草稿时的设备时区 IANA 标识
    /// （草稿创建时取一次，之后编辑/发布都不改；无记录的旧草稿回落发布时设备时区）。
    /// 快照不做 Codable 持久化，只经 saveDraftNow 落草稿，加字段安全。
    /// 编辑不改时区：updateEntry 不发本键。
    let tzName: String?
    let clientReq: String
    /// 快照拍定时的发起账号：发布中心起飞前再校验一次，防门禁/
    /// setVisibility 在途期间账号已变仍把旧篇以新账号发出。
    let originAccountId: Int?
    /// P0-2：提交时记录的草稿 id 与账号：成功回包只清理这一篇。
    /// 回包时 currentDraftId 可能已切到另一篇，绝不能按现值删。
    let draftId: String?
    let accountId: Int?
    /// P0-2：提交时本篇图片的本地文件名：成功后只删这些文件，
    /// 不碰切篇后新篇的图片。
    let imageLocalFiles: [String]
    /// #43：点按时刻的图片清单（按编辑器图片条顺序）：交接时直接用它，
    /// 不再从当前 imageItems 现场组装——写盘窗口内新增/删除的图片
    /// 不得混进本次发布；成功后删图仍只用上方的 imageLocalFiles。
    let images: [BearyPublishImage]
}

/// 交接给发布中心的图片（按编辑器图片条顺序）：已有服务端 key 的
/// 不再上传；只有本地文件的发布时上传；实况视频按现有路径走——
/// 内存里有 liveVideoData 即用它，没有则按 liveVideoFile 读盘。
struct BearyPublishImage {
    let localFile: String?
    let serverKey: String?
    let liveVideoKey: String?
    let liveVideoFile: String?
    let liveVideoData: Data?
    /// 原图上传方式（#46）：编辑器交接时传入；.original 且 .orig 在盘时
    /// 中心按原图上传，否则回落压缩。默认 nil＝压缩（旧调用方兼容，
    /// 默认值在下方显式 init 参数上；let 属性带默认值时 init 内再赋值
    /// 会报 may only be initialized once，故此处不写 = nil）。
    let uploadMode: BearyUploadMode?
    /// 原图本地文件名（与静图同 stem 的 <uuid>.orig）；nil=无原图。
    let originalFile: String?

    /// 与 memberwise init 同语义的显式 init：后两个参数保留默认值，
    /// 旧 5 参数调用方（如详情页恢复发布）无需改动。显式写出是因
    /// CI 曾报 7 参数调用 extra arguments（#1927），不再依赖合成 init。
    init(localFile: String?, serverKey: String?, liveVideoKey: String?, liveVideoFile: String?, liveVideoData: Data?, uploadMode: BearyUploadMode? = nil, originalFile: String? = nil) {
        self.localFile = localFile
        self.serverKey = serverKey
        self.liveVideoKey = liveVideoKey
        self.liveVideoFile = liveVideoFile
        self.liveVideoData = liveVideoData
        self.uploadMode = uploadMode
        self.originalFile = originalFile
    }
}

/// 一次后台发布任务：快照＋图片清单＋门禁出路＋宿主视图＋回包闭包。
/// hostView 只弱持有（Chrome 的 view，编辑器退出后 pill 挂在它上面）；
/// onPublished/onRequireLogin 是编辑器交接来的容器闭包值（不持有编辑器
/// 本身），编辑器已退场时照常执行。onPublished 回传本次发布的代次
/// （publishToken），容器只在代次仍是最新且顶层无其他 modal 时才
/// dismiss＋切时间线；否则只刷新列表——旧发布的成功回调不得关掉用户
/// 后来打开的页面（如下一篇编辑器）。
struct BearyPublishJob {
    let snapshot: PublishSnapshot
    let images: [BearyPublishImage]
    /// 门禁选了「一并公开」：先 setVisibility 公开原日记，再发新篇。
    let publishTogether: Bool
    /// 本次发布的代次（容器每次开编辑器发一个）：成功时原样回传给
    /// onPublished，供容器侧比对——旧代次的成功回调不得 dismiss／切页。
    let publishToken: UUID
    /// 原日记在本次发布前已公开（编辑器读草稿持久标记所得，或中心
    /// 一键重试沿用上次部分成功态）：只发新篇，不再走门禁与 setVisibility；
    /// start() 内同样守卫，publishTogether 与本标记同真时以后者为准。
    /// 须是 var：let 带默认值不进成员逐项构造器（SE-0242 只认 var），
    /// 写 let 会让两处构造点报 extra argument（2026-11-17 本支 CI 实证）。
    var sourceAlreadyPublished: Bool = false
    weak var hostView: UIView?
    /// 成功回调：新日记 id＋本次发布的代次。
    let onPublished: ((String, UUID) -> Void)?
    let onRequireLogin: (() -> Void)?
    /// 第 25 轮 18 项：实况失败等“打开草稿重试”入口——编辑器已退场时由容器
    /// 打开草稿箱；nil 时失败只按 pill／toast 展示，不提供入口。
    let onOpenDraft: (() -> Void)?
}

/// 发布进度：单调、不回退。按步骤（图片 0..<n、POST 为第 n 步）记账：
/// 每步先按估计字节（base64 体量）立预算；任务首个 didSendBodyData
/// 回调带回 authoritative totalBytesExpectedToSend，此时把该步预算
/// 修正为实测值；任务完成即按预算计满。进度 = 已发 / 总预算，
/// 每次取 max（旧值，新值），重试任务从 0 重报也不回退。
/// 展示侧再封顶 0.95（见 BearyPublishCenter.reportProgress），
/// 只有成功瞬间才走满 1.0。
private final class BearyPublishProgress {
    private var budgets: [Int: Int64] = [:]
    private var sent: [Int: Int64] = [:]
    private var completedSteps: Set<Int> = []
    private var lastProgress: Double = 0
    private let lock = NSLock()

    func setEstimate(step: Int, bytes: Int64) {
        lock.lock()
        budgets[step] = max(budgets[step] ?? 0, bytes)
        lock.unlock()
    }

    func update(step: Int, sent newSent: Int64, expected: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if expected > 0 {
            budgets[step] = max(budgets[step] ?? 0, expected)
        }
        sent[step] = max(sent[step] ?? 0, newSent)
        return currentLocked()
    }

    func complete(step: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        completedSteps.insert(step)
        sent[step] = budgets[step] ?? sent[step] ?? 0
        return currentLocked()
    }

    private func currentLocked() -> Double {
        var total: Int64 = 0
        var done: Int64 = 0
        for (step, budget) in budgets {
            total += budget
            if completedSteps.contains(step) {
                done += budget
            } else {
                done += min(sent[step] ?? 0, budget)
            }
        }
        guard total > 0 else { return lastProgress }
        let value = Double(done) / Double(total)
        lastProgress = max(lastProgress, value)
        return lastProgress
    }
}

/// 后台发布中心：编辑器点发布即退场后，发布流程在此继续跑——持有
/// 快照、图片清单与回包闭包，编辑器析构不影响它。单例，活得比任何
/// 一页编辑器都久；同一 draftId 同时只跑一支任务（重入即拒收，
/// 调用方留页并 toast「发布中…」）。
/// 流程：起飞前账号校验 →（一并公开时）setVisibility → 本地图片并行
/// 上传（拿到 keys，按原序组装）→ publishEntry。任一步失败即停，草稿
/// 保留（交接前已落盘），失败文案走 pill（本任务的 pill 仍在时）或 toast
/// （pill 已被新任务接管时，带重试入口），并留失败记录＋草稿持久标记
/// （pill 点开的状态表与草稿箱重试入口共用；原日记已公开时只重试新篇）；
/// 成功清草稿与本地图片、pill 对勾「已发布」、走 onPublished。
/// 杀 App／切后台时发布即停、草稿可重试（不加后台任务）；单张上传
/// 成功即把 key 写回草稿，失败重试只重传未成功的图（见 persistUploadedKey）。
final class BearyPublishCenter {

    static let shared = BearyPublishCenter()

    /// 图片并行上传上限（2026-11-14）：3 路——API 会话每 host 6 并发，
    /// 留一半给时间线等其他请求；9 张图时约 3 倍于串行。
    private static let maxConcurrentUploads = 3

    /// 图片准备（读盘＋base64）走本队列，不占主线程；与编辑器
    /// imagePrepQueue 同款分工。
    private let ioQueue = DispatchQueue(label: "beary.publishCenter", qos: .userInitiated)

    private var running: [String: RunningJob] = [:]
    /// 当前可见的 pill（同一时刻只一块；新任务接管时旧 pill 被 show 移除）。
    /// 多篇并行时 pill 报篇数（「正在发布 N 篇」）、点开列各篇状态；
    /// 被接管任务的失败不再走 pill，改走 toast＋失败记录＋草稿箱重试入口。
    private weak var currentPill: BearyPublishPillView?
    /// 发布失败记录（key = draftId ?? clientReq）：原任务＋失败文案＋
    /// 失败时原日记是否已公开＋失败时草稿原样（重试指纹）。供 pill 状态表
    /// 与一键重试用；重试开始／新一轮发布开始即失效（另见 start()）；
    /// 超 10 条时丢最旧一条。草稿删除不另行通知——重试前按指纹核对，
    /// 草稿不在即失效、改走编辑器。
    private var failedJobs: [String: FailedPublish] = [:]

    private init() {}

    /// 同一草稿是否正在后台发布（草稿箱打开／删除的守卫）。
    func isPublishing(draftId: String?) -> Bool {
        guard let key = draftId else { return false }
        return running[key] != nil
    }

    /// 一键重试的结果：started = 已开始重跑；alreadyRunning = 该篇已在发布中；
    /// needsEditor = 中心无原任务／草稿已变／草稿不在，请从草稿箱打开再发布
    /// （编辑器读草稿持久标记后仍跳过门禁与 setVisibility，只发新篇）。
    enum PublishRetryResult {
        case started
        case alreadyRunning
        case needsEditor
    }

    /// 一次失败的发布：原任务（快照＋图片＋回调）＋失败文案＋失败时原日记
    /// 是否已公开＋失败时草稿原样（重试指纹）。草稿为 nil = 失败时草稿已不在，
    /// 重试一律走编辑器。
    private struct FailedPublish {
        let job: BearyPublishJob
        let message: String
        let sourcePublished: Bool
        let failedAt: Date
        let draft: BearyDraft?

        /// 草稿仍与失败时一致（正文／标题／心情／天气／引用／@／位置／
        /// 可见性／图片清单逐项比对；updatedAt 每次保存都刷新，不能当改过依据）。
        func matches(draft: BearyDraft) -> Bool {
            guard let base = self.draft else { return false }
            guard draft.content == base.content,
                  draft.title == base.title,
                  draft.mood == base.mood,
                  draft.weather == base.weather,
                  draft.temperature == base.temperature,
                  draft.quoteId == base.quoteId,
                  draft.recipientId == base.recipientId,
                  draft.locationName == base.locationName,
                  draft.locationDistrict == base.locationDistrict,
                  draft.locationLatitude == base.locationLatitude,
                  draft.locationLongitude == base.locationLongitude,
                  draft.visibilitySegmentIndex == base.visibilitySegmentIndex,
                  draft.ephemeralEnabled == base.ephemeralEnabled,
                  draft.images.count == base.images.count else { return false }
            for (current, old) in zip(draft.images, base.images) {
                guard current.localFile == old.localFile, current.serverKey == old.serverKey else { return false }
            }
            return true
        }
    }

    /// 交接一支发布任务。返回 false = 同一草稿已有在途任务，本次拒收，
    /// 调用方不得退出编辑器。调用方须在主线程调（后台线程调时自动 hop）。
    @discardableResult
    func start(job: BearyPublishJob) -> Bool {
        if !Thread.isMainThread {
            var result = false
            DispatchQueue.main.sync { result = start(job: job) }
            return result
        }
        let key = job.snapshot.draftId ?? job.snapshot.clientReq
        guard running[key] == nil else { return false }
        let runningJob = RunningJob(job: job)
        running[key] = runningJob
        // 新一轮发布开始即清旧失败记录与草稿持久标记（失败行与重试入口
        // 随之消失；本轮再失败由 fail() 重写）。只在有记录时写盘，
        // 不给首次发布多一次写盘。
        if failedJobs[key] != nil {
            failedJobs.removeValue(forKey: key)
            clearPublishFailureMark(draftId: job.snapshot.draftId, accountId: job.snapshot.accountId)
        }
        // 第 25 轮 17 项：发布前一次性估算全部步骤的总预算（图片＋POST），
        // 再开始第一步——进度分母从一开始就是总量，首图传完不再冲到 0.95。
        seedTotalEstimate(for: job, into: runningJob.progress)
        if let host = job.hostView {
            let pill = BearyPublishPill.show(in: host)
            currentPill = pill
            runningJob.pill = pill
            pill.setTapHandler { [weak self] in self?.presentStatusSheet() }
            refreshPillTitle()
        }
        // 起飞前账号校验：快照发起账号与当前账号失配即中止、不发请求，
        // 草稿保留（交接前已落盘），pill 用现有账号失配文案。
        // 原日记已公开的重试（sourceAlreadyPublished）同样可能在此失配，
        // 文案认 RunningJob 的部分成功态，不再一律按未公开写。
        if let expected = job.snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            fail(runningJob, message: accountMismatchMessage(sourceAlreadyPublished: runningJob.sourcePublished))
            return true
        }
        // 原日记已公开（编辑器持久标记／一键重试沿用）时跳过 setVisibility，
        // 只发新篇；publishTogether 与本标记同真时以后者为准。
        if job.publishTogether && !job.sourceAlreadyPublished {
            runSetVisibility(runningJob)
        } else {
            uploadNext(runningJob)
        }
        return true
    }

    // MARK: - 步骤

    private func runSetVisibility(_ runningJob: RunningJob) {
        guard let sourceId = runningJob.job.snapshot.quoteId, !sourceId.isEmpty else {
            uploadNext(runningJob)
            return
        }
        BearyAPI.shared.setVisibility(id: sourceId, published: 1) { [weak self, weak runningJob] result in
            DispatchQueue.main.async {
                guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
                switch result {
                case .success:
                    runningJob.sourcePublished = true
                    self.uploadNext(runningJob)
                case .failure(let error):
                    // 第 25 轮 20 项：网络失败结果未知（超时也可能服务端已公开）——
                    // 先查原篇当前状态再定文案：已公开即继续发新篇；仍私密即原口径
                    // 失败；查询本身也失败时明说结果未知，不谎称未公开。非网络失败
                    // 是服务端已明确拒绝，结果已知，直接按原口径失败。
                    if case .network = error {
                        BearyAPI.shared.fetchEntry(id: sourceId) { [weak self, weak runningJob] fetchResult in
                            DispatchQueue.main.async {
                                guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
                                switch fetchResult {
                                case .success(let entry):
                                    if entry.isPublic == true || entry.visibility == "public" {
                                        runningJob.sourcePublished = true
                                        self.uploadNext(runningJob)
                                    } else {
                                        self.fail(runningJob, message: "原日记公开失败，请重试")
                                    }
                                case .failure:
                                    self.fail(runningJob, message: "网络不稳定，原日记是否已公开未知，请打开草稿查看后重试")
                                }
                            }
                        }
                    } else {
                        self.fail(runningJob, message: "原日记公开失败，请重试")
                    }
                }
            }
        }
    }

    /// 图片上传入口（主线程）：已有 key 的图直接记结果、不再上传；
    /// 其余图最多 3 路并行上传（见 pumpUploads），keys 按原序组装后转 POST。
    /// 2026-11-14（132 真机）：旧版逐张串行传，9 张图要等 9 个往返，
    /// 发布钮放开后用户点发布即交接、中心一次接多张未传图时串行太慢；
    /// 并行上限 3——API 会话每 host 6 并发，留一半给时间线等其他请求。
    /// 进度仍按步记账（BearyPublishProgress 各步独立预算，乱序完成不回退）。
    private func uploadNext(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        let job = runningJob.job
        // 起飞前账号校验（旧 uploadPrepared 令牌门控与 performPublish 入口
        // 同款）：切号后不再用新账号 cookie 传旧账号的图片或发帖，草稿保留；
        // 部分成功态（原日记已公开）用部分成功口径。
        if let expected = job.snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            fail(runningJob, message: accountMismatchMessage(sourceAlreadyPublished: runningJob.sourcePublished))
            return
        }
        // 已有服务端 key 的图不再上传（旧草稿、旧版已传完的图），直接记结果。
        for (index, image) in job.images.enumerated() {
            if let key = image.serverKey {
                runningJob.uploadResults[index] = key
                if let liveKey = image.liveVideoKey {
                    runningJob.uploadLiveResults[index] = liveKey
                }
                runningJob.uploadFinished += 1
            }
        }
        if runningJob.uploadFinished >= job.images.count {
            finishUploadsAndPost(runningJob)
            return
        }
        pumpUploads(runningJob)
    }

    /// 并行泵：同时在途不超过 3 路；每路完成时补起下一张（见 uploadOne
    /// 完成分支）。无本地文件又无 key 的项是交接时已守卫的程序错误，
    /// 按图片失效处理，不编新文案（与旧串行版同款）。
    private func pumpUploads(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        let job = runningJob.job
        while runningJob.uploadInFlight < Self.maxConcurrentUploads,
              runningJob.uploadStarted < job.images.count {
            let index = runningJob.uploadStarted
            runningJob.uploadStarted += 1
            let image = job.images[index]
            if image.serverKey != nil { continue }
            guard image.localFile != nil else {
                fail(runningJob, message: partialFailureMessage(Self.message(forPublishError: .server("image unavailable", nil)), runningJob: runningJob))
                return
            }
            runningJob.uploadInFlight += 1
            uploadOne(runningJob, index: index, image: image)
        }
    }

    /// 单张上传：ioQueue 上读盘＋base64，网络任务建好后回主线程记账。
    /// 完成分支在主线程跑：成功记结果、补起下一路、全部落袋后按序组装
    /// 转 POST；失败即停整单（草稿保留，旧串行版同款）。
    private func uploadOne(_ runningJob: RunningJob, index: Int, image: BearyPublishImage) {
        let job = runningJob.job
        guard let localFile = image.localFile else { return }
        let step = index
        let accountId = job.snapshot.accountId
        ioQueue.async { [weak self, weak runningJob] in
            guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
            guard let prepared = BearyDraftImageStore.existingPreparedJPEG(fullName: localFile, accountId: accountId) else {
                DispatchQueue.main.async {
                    self.fail(runningJob, message: self.partialFailureMessage(Self.message(forPublishError: .server("image unavailable", nil)), runningJob: runningJob))
                }
                return
            }
            // #46 原图竞态：选原图后立即发布、编辑器侧原图上传仍在途时被
            // 交接取消，中心此前只读压缩 JPEG。模式为原图且 .orig 在盘时
            // 读原图（剥 GPS、按实测格式发，共享格式集），任一步失败回落压缩，
            // 绝不发带 GPS 或格式不明的原图（与编辑器 startOriginalUpload 同口径）。
            var fullData = prepared.full.data
            var fullWidth = prepared.full.w
            var fullHeight = prepared.full.h
            var fullMimeType = "image/jpeg"
            if image.uploadMode == .original, let originalFile = image.originalFile,
               let rawData = BearyDraftImageStore.originalData(for: originalFile),
               rawData.count <= 5 * 1024 * 1024,
               let strippedData = BearyImagePrep.strippedGPSData(rawData),
               let detectedMime = BearyImagePrep.mimeType(of: strippedData),
               BearyImagePrep.originalUploadMimeTypes.contains(detectedMime),
               let pixelSize = BearyImagePrep.pixelSize(of: strippedData),
               pixelSize.width > 0, pixelSize.height > 0 {
                fullData = strippedData
                fullWidth = pixelSize.width
                fullHeight = pixelSize.height
                fullMimeType = detectedMime
            }
            var videoData = image.liveVideoData
            if videoData == nil, let videoFile = image.liveVideoFile {
                videoData = BearyDraftImageStore.videoData(for: videoFile)
                if videoData == nil {
                    DispatchQueue.main.async {
                        // 实况视频已丢：与编辑器恢复态同口径，不静默降级为静态。
                        self.fail(runningJob, message: self.partialFailureMessage("有实况视频已丢失，重新选择该图片后再发布", runningJob: runningJob))
                    }
                    return
                }
            }
            let dataUrl = BearyImagePrep.dataURL(fullData, mimeType: fullMimeType)
            let thumbDataUrl = BearyImagePrep.dataURL(prepared.thumb)
            let videoDataUrl = videoData.map { BearyLivePhoto.videoDataURL($0) }
            let estimate = Self.base64Length(fullData.count) + 23
                + Self.base64Length(prepared.thumb.count) + 23
                + (videoData.map { Self.base64Length($0.count) + 27 } ?? 0) + 100
            runningJob.progress.setEstimate(step: step, bytes: Int64(estimate))
            let progressHandler: (Int64, Int64) -> Void = { [weak self, weak runningJob] sent, expected in
                guard let self = self, let runningJob = runningJob else { return }
                let value = runningJob.progress.update(step: step, sent: sent, expected: expected)
                DispatchQueue.main.async {
                    self.reportProgress(runningJob, value: value)
                }
            }
            BearyAPI.shared.uploadImage(dataUrl: dataUrl, width: fullWidth, height: fullHeight, thumbDataUrl: thumbDataUrl, videoDataUrl: videoDataUrl, uploadProgress: progressHandler) { [weak self, weak runningJob] result in
                DispatchQueue.main.async {
                    guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
                    runningJob.uploadInFlight -= 1
                    let value = runningJob.progress.complete(step: step)
                    self.reportProgress(runningJob, value: value)
                    switch result {
                    case .success(let resp):
                        guard let key = resp.key else {
                            self.fail(runningJob, message: "发布失败，请重试")
                            return
                        }
                        // 实况回包缺 live_key = 视频没落下：按失败处理，
                        // 不把实况当静态图发出（与编辑器 uploadPrepared 同口径）。
                        if videoData != nil, resp.liveKey == nil || resp.liveKey?.isEmpty == true {
                            // 第 25 轮 18 项：编辑器已退场、pill 不可点，“请点图重试”
                            // 无处可点——改提示打开草稿重试，并经 fail() 的草稿入口
                            // 呈现（见 openDraftOnFailure）。
                            runningJob.openDraftOnFailure = true
                            self.fail(runningJob, message: "实况视频上传失败，已保存为草稿，请打开草稿重试")
                            return
                        }
                        runningJob.uploadResults[index] = key
                        if let liveKey = resp.liveKey {
                            runningJob.uploadLiveResults[index] = liveKey
                        }
                        runningJob.uploadFinished += 1
                        // #52：成功即把 key 写回草稿（见 persistUploadedKey），
                        // 失败重试从草稿重建任务时这张图直接跳过，不再重传。
                        self.persistUploadedKey(runningJob, index: index, image: image, key: key, liveKey: resp.liveKey)
                        self.pumpUploads(runningJob)
                        if runningJob.uploadFinished >= runningJob.job.images.count {
                            self.finishUploadsAndPost(runningJob)
                        }
                    case .failure(let error):
                        self.fail(runningJob, error: error)
                    }
                }
            }
        }
    }

    /// #52：单张上传成功即把 key／liveKey 写回草稿，失败重试不再重传这张图。
    /// 只更新对应草稿图项的 serverKey／liveVideoKey／state（.uploaded），
    /// 本地文件与 liveVideoFile 不动；成功清草稿时整篇随之删除，无残留表。
    /// 主线程同步写：成功回包都在主线程排队，并行 3 路的写回互不交错；
    /// 写盘失败只丢本次写回（重试时最多重传这一张），不阻塞发布流程。
    private func persistUploadedKey(_ runningJob: RunningJob, index: Int, image: BearyPublishImage, key: String, liveKey: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let draftId = runningJob.job.snapshot.draftId,
              let localFile = image.localFile else { return }
        let accountId = runningJob.job.snapshot.accountId
        guard var draft = BearyDraftStore.loadAll(forAccount: accountId).first(where: { $0.draftId == draftId }) else { return }
        // 按本地文件名定位（交接清单与草稿图片同序同源，localFile 唯一）；
        // 找不到时按同下标兜底（仅当该项尚未有 key）。
        var target = draft.images.firstIndex(where: { $0.localFile == localFile })
        if target == nil, index < draft.images.count, draft.images[index].serverKey == nil {
            target = index
        }
        guard let target = target else { return }
        draft.images[target].serverKey = key
        if let liveKey = liveKey {
            draft.images[target].liveVideoKey = liveKey
        }
        draft.images[target].state = .uploaded
        _ = BearyDraftStore.save(draft, forAccount: accountId)
    }

    /// 全部图片落袋后按原序组装 keys／liveVideos，再进 POST。
    private func finishUploadsAndPost(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        var keys: [String] = []
        var liveVideos: [String: String] = [:]
        for index in runningJob.job.images.indices {
            guard let key = runningJob.uploadResults[index] else {
                fail(runningJob, message: Self.message(forPublishError: .server("image unavailable", nil)))
                return
            }
            keys.append(key)
            if let liveKey = runningJob.uploadLiveResults[index] {
                liveVideos[key] = liveKey
            }
        }
        runningJob.imageKeys = keys
        runningJob.liveVideos = liveVideos
        runPost(runningJob)
    }

    private func runPost(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        // POST 前再校验发起账号（旧串行版在 uploadNext 递归末尾校验，
        // 并行版的组装入口在此补同一道校验）：切号后不发帖，草稿保留。
        if let expected = runningJob.job.snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            fail(runningJob, message: accountMismatchMessage(sourceAlreadyPublished: runningJob.sourcePublished))
            return
        }
        let job = runningJob.job
        let snapshot = job.snapshot
        let step = job.images.count
        // POST 体很小（正文＋keys＋小字段），估计 = 正文 UTF-8 字节＋1KB；
        // 首个 didSendBodyData 回调带回实测值修正。
        let estimate = snapshot.content.utf8.count + 1024
        runningJob.progress.setEstimate(step: step, bytes: Int64(estimate))
        let progressHandler: (Int64, Int64) -> Void = { [weak self, weak runningJob] sent, expected in
            guard let self = self, let runningJob = runningJob else { return }
            let value = runningJob.progress.update(step: step, sent: sent, expected: expected)
            DispatchQueue.main.async {
                self.reportProgress(runningJob, value: value)
            }
        }
        BearyAPI.shared.publishEntry(
            content: snapshot.content, images: runningJob.imageKeys, mood: snapshot.mood,
            weather: snapshot.weather, quoteId: snapshot.quoteId, published: snapshot.published,
            mentionedUserId: snapshot.mentionedUserId, title: snapshot.title, ephemeral: snapshot.ephemeral,
            clientReq: snapshot.clientReq, locationName: snapshot.locationName,
            locationDistrict: snapshot.locationDistrict, locationLatitude: snapshot.locationLatitude,
            locationLongitude: snapshot.locationLongitude, locationCountry: snapshot.locationCountry,
            locationRegion: snapshot.locationRegion, locationCity: snapshot.locationCity,
            locationStreet: snapshot.locationStreet, temperature: snapshot.temperature,
            liveVideos: runningJob.liveVideos.isEmpty ? nil : runningJob.liveVideos,
            visibility: snapshot.visibility,
            tags: snapshot.tags,
            timeZoneName: snapshot.tzName,
            uploadProgress: progressHandler
        ) { [weak self, weak runningJob] result in
            DispatchQueue.main.async {
                guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
                let value = runningJob.progress.complete(step: step)
                self.reportProgress(runningJob, value: value)
                switch result {
                case .success(let resp):
                    if let entryId = resp.id {
                        self.succeed(runningJob, entryId: entryId)
                    } else {
                        // 成功回包无 id：按旧口径发布失败，草稿保留。
                        self.fail(runningJob, message: self.partialFailureMessage("发布失败，请重试", runningJob: runningJob))
                    }
                case .failure(let error):
                    self.fail(runningJob, error: error)
                }
            }
        }
    }

    // MARK: - 终态

    /// 成功：清草稿与本地图片、pill 对勾「已发布」、音效震动、走 onPublished。
    private func succeed(_ runningJob: RunningJob, entryId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        runningJob.finished = true
        running.removeValue(forKey: runningJob.key)
        let snapshot = runningJob.job.snapshot
        // 只有拿到 entry id 才清草稿与本地图片（与旧 clearPublishedDraft 同款，
        // 只是编辑器已退场，不再清内存槽位与刷新草稿 pill；删图显式传快照账号，
        // 不跟当前账号——成功回包时账号可能已变，默认桶会删错地方）。
        // 审计 26-3：先删草稿记录，确认成功后再清图（与编辑器
        // clearDraftAndFiles 同款顺序）。旧顺序先清图后删记录，删记录
        // 写盘失败时会留下指向已清附件的草稿记录；删记录失败时附件
        // 保留，残留草稿仍在草稿箱可见、可手动删。
        if let draftIdValue = snapshot.draftId {
            BearyDraftStore.deleteAsyncReporting(draftId: draftIdValue, forAccount: snapshot.accountId) { deleted in
                guard deleted else { return }
                BearyDraftImageStore.deletePairsIfUnreferencedAsync(snapshot.imageLocalFiles, excludingDraftId: nil, forAccount: snapshot.accountId)
            }
        } else {
            // 无草稿记录：只有未落盘的本地图，直接清掉。
            BearyDraftImageStore.deletePairsIfUnreferencedAsync(snapshot.imageLocalFiles, excludingDraftId: nil, forAccount: snapshot.accountId)
        }
        BearyHaptics.publishSuccess()
        BearySoundPlayer.play(.publishSuccess)
        if let pill = runningJob.pill, pill === currentPill {
            pill.finishSuccess()
            currentPill = nil
        } else {
            // 本任务的 pill 已被新任务接管（或本任务无 pill）：成功不另弹
            // 反馈，onPublished 的切页即反馈；只把当前 pill 的篇数刷下来。
            refreshPillTitle()
            if let container = terminalToastContainer(for: runningJob) {
                // 第 25 轮 16 项：pill 已被新任务接管时，成功结果同样以 toast 留档。
                BearyToast.show(in: container, message: "已发布")
            }
        }
        // 第 25 轮 15 项：最终成功回包再次核对发起账号——uploadNext 只在每步前
        // 校验，POST 回包前切号仍可能让旧账号结果走到新账号容器；失配时不走
        // onPublished（容器按当前账号刷新与 upsert 都不属于旧账号）。草稿清理
        // 仍按快照账号做（服务端已落盘），pill 照常显示已发布。
        if let expected = snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            return
        }
        runningJob.job.onPublished?(entryId, runningJob.job.publishToken)
    }

    /// 失败：停掉任务、草稿保留（交接前已落盘，不再重存）、拒绝震动＋拒绝音、
    /// 失败留档（内存记录＋草稿持久标记，见 recordFailure）。pill 是本任务的
    /// 才走 pill 显示失败文案；pill 已被新任务接管（或本任务无 pill）时改走
    /// 与 pill 无关的 toast 补一条（带重试入口），否则旧任务失败全程不可见；
    /// 401 另走登录入口（见 fail(error:)）。
    private func fail(_ runningJob: RunningJob, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        runningJob.finished = true
        running.removeValue(forKey: runningJob.key)
        // 拒绝反馈：震动＋拒绝音成对（成功侧 publishSuccess 震动＋回应音同款）；
        // 旧版只有震动没有音，失败与成功不对称。401 路径另见 fail(error:)，
        // 其反馈是登录入口本身，不另补音。
        BearyHaptics.rejectionWarning()
        BearySoundPlayer.play(.refuseBonk)
        recordFailure(runningJob, message: message)
        if runningJob.openDraftOnFailure, let openDraft = runningJob.job.onOpenDraft,
           let container = terminalToastContainer(for: runningJob) {
            // 第 25 轮 18 项：实况视频上传失败——编辑器已退场、pill 不可点，
            // 故本次失败不走 pill，改以带“打开草稿”入口的 toast 呈现；
            // pill 与 toast 同落点，叠加会互挡，只留 toast。
            if runningJob.pill === currentPill {
                runningJob.pill?.dismiss()
                currentPill = nil
            }
            BearyToast.show(in: container, message: message, actionTitle: "打开草稿", action: openDraft)
            return
        }
        if let pill = runningJob.pill, pill === currentPill {
            pill.finishFailure(message: message)
            currentPill = nil
        } else {
            // pill 已被新任务接管时不把失败文案写进新 pill（旧注释亦如此），
            // 但不再静默：toast 2–4 秒自撤、只短暂盖住新 pill，进度不受影响，
            // 失败文案与重试入口仍有文字可查。
            showFailureToast(runningJob: runningJob, message: message)
            refreshPillTitle()
        }
    }

    /// 失败（带原始错误）：按旧 performPublish 分流——部分成功先行，
    /// 网络给明确文案，401 走登录入口，其余走 message(forPublishError:)。
    private func fail(_ runningJob: RunningJob, error: APIError) {
        dispatchPrecondition(condition: .onQueue(.main))
        if runningJob.sourcePublished {
            // 部分成功：原日记已公开，不回滚、不走通用“发布失败”文案。
            if case .unauthorized = error {
                fail(runningJob, message: "原日记已公开，新篇发布失败，登录已失效，请重新登录后只重试新篇")
                runningJob.job.onRequireLogin?()
            } else if case .network = error {
                fail(runningJob, message: "原日记已公开，新篇发布失败，网络不可用，已保存为草稿，联网后可只重试新篇")
            } else {
                fail(runningJob, message: "原日记已公开，新篇发布失败，请只重试新篇")
            }
            return
        }
        if case .network = error {
            // 草稿交接前已确认落盘成功，故直接称已保存（旧口径按落盘成败分文案，
            // 本处落盘已是交接前提，不再分支）。
            fail(runningJob, message: "网络不可用，已保存为草稿，联网后可重试")
            return
        }
        if case .unauthorized = error {
            // 401：pill 静默撤掉、直接走登录入口（旧口径无文案、只弹登录）。
            guard !runningJob.finished else { return }
            runningJob.finished = true
            running.removeValue(forKey: runningJob.key)
            if runningJob.pill === currentPill {
                runningJob.pill?.dismiss()
                currentPill = nil
            }
            runningJob.job.onRequireLogin?()
            return
        }
        fail(runningJob, message: Self.message(forPublishError: error))
    }

    // MARK: - 失败可见与一键重试

    /// 一键重试：用失败时保留的原任务重跑；原日记已公开时只重试新篇
    /// （跳过 setVisibility，见 start() 内守卫），其余原样重跑
    /// （图片重传、同一 clientReq 幂等）。调用方在主线程调（后台线程调时自动 hop，
    /// 与 start() 同款）。
    @discardableResult
    func retryPublish(draftId: String) -> PublishRetryResult {
        if !Thread.isMainThread {
            var result: PublishRetryResult = .needsEditor
            DispatchQueue.main.sync { result = retryPublish(draftId: draftId) }
            return result
        }
        guard let failed = failedJobs[draftId] else { return .needsEditor }
        let key = failed.job.snapshot.draftId ?? failed.job.snapshot.clientReq
        guard running[key] == nil else { return .alreadyRunning }
        // 草稿指纹：失败后被改过（正文／标题／图片等任一动过）即不原样重跑，
        // 改走编辑器——编辑器读草稿持久标记后仍跳过门禁与 setVisibility，
        // 只发新篇。草稿已不在同样走编辑器。
        if let draftIdValue = failed.job.snapshot.draftId {
            guard let draft = BearyDraftStore.loadAll(forAccount: failed.job.snapshot.accountId)
                    .first(where: { $0.draftId == draftIdValue }),
                  failed.matches(draft: draft) else { return .needsEditor }
        }
        let retryJob = BearyPublishJob(
            snapshot: failed.job.snapshot,
            images: failed.job.images,
            publishTogether: failed.job.publishTogether,
            publishToken: failed.job.publishToken,
            sourceAlreadyPublished: failed.sourcePublished || failed.job.sourceAlreadyPublished,
            hostView: failed.job.hostView ?? Self.keyWindowRootView(),
            onPublished: failed.job.onPublished,
            onRequireLogin: failed.job.onRequireLogin,
            onOpenDraft: failed.job.onOpenDraft)
        failedJobs.removeValue(forKey: draftId)
        clearPublishFailureMark(draftId: failed.job.snapshot.draftId, accountId: failed.job.snapshot.accountId)
        guard start(job: retryJob) else { return .alreadyRunning }
        return .started
    }

    /// 失败留档：内存记录供 pill 状态表与一键重试；持久标记写草稿，
    /// 草稿箱据此出失败行与重试入口（重启后仍在）。写盘走 ioQueue 串行，
    /// 与清标记按调用顺序落盘。记录超 10 条时丢最旧一条。
    private func recordFailure(_ runningJob: RunningJob, message: String) {
        let snapshot = runningJob.job.snapshot
        let sourcePublished = runningJob.sourcePublished
        let record = FailedPublish(
            job: runningJob.job,
            message: message,
            sourcePublished: sourcePublished,
            failedAt: Date(),
            draft: snapshot.draftId.flatMap { draftId in
                BearyDraftStore.loadAll(forAccount: snapshot.accountId).first(where: { $0.draftId == draftId })
            }
        )
        failedJobs[runningJob.key] = record
        if failedJobs.count > 10,
           let oldestKey = failedJobs.min(by: { $0.value.failedAt < $1.value.failedAt })?.key {
            failedJobs.removeValue(forKey: oldestKey)
        }
        guard let draftId = snapshot.draftId else { return }
        let accountId = snapshot.accountId
        BearyDraftStore.ioQueue.async {
            guard var draft = BearyDraftStore.loadAll(forAccount: accountId).first(where: { $0.draftId == draftId }) else { return }
            draft.lastPublishFailure = message
            draft.sourcePublished = sourcePublished
            _ = BearyDraftStore.save(draft, forAccount: accountId)
        }
    }

    /// 新一轮发布开始即清旧失败标记（失败行与重试入口随之消失；本轮再失败
    /// 由 fail() 重写）。只在内存里有失败记录时调（见 start()／retryPublish），
    /// 不给首次发布多一次写盘；与记标记同走 ioQueue 串行，清与写按调用顺序落盘。
    private func clearPublishFailureMark(draftId: String?, accountId: Int?) {
        guard let draftId = draftId else { return }
        BearyDraftStore.ioQueue.async {
            guard var draft = BearyDraftStore.loadAll(forAccount: accountId).first(where: { $0.draftId == draftId }),
                  draft.lastPublishFailure != nil || draft.sourcePublished else { return }
            draft.lastPublishFailure = nil
            draft.sourcePublished = false
            _ = BearyDraftStore.save(draft, forAccount: accountId)
        }
    }

    /// 被接管任务的失败 toast：与 pill 无关的通道，带重试入口；容器优先用
    /// 本任务的 hostView（Chrome 视图），没有时退回 key window 根视图，
    /// 仍没有则不弹（不崩、不补假反馈）。重试走一键重试；中心无原任务时
    /// （如重启后）改提示从草稿箱打开再发布。
    private func showFailureToast(runningJob: RunningJob, message: String) {
        guard let container = runningJob.job.hostView ?? Self.keyWindowRootView() else { return }
        let retryTitle = runningJob.sourcePublished ? "只重试新篇" : "重试"
        let key = runningJob.key
        BearyToast.show(in: container, message: message, actionTitle: retryTitle) { [weak self] in
            guard let self = self else { return }
            if self.retryPublish(draftId: key) == .needsEditor,
               let fallbackContainer = self.currentPill?.superview ?? Self.keyWindowRootView() {
                BearyToast.show(in: fallbackContainer, message: "请从草稿箱打开这篇再发布")
            }
        }
    }

    /// 胶囊标题：单篇沿用「正在发布…」，多篇并行时报篇数；失败／成功后篇数
    /// 回落，剩一篇即回单篇文案。只写当前 pill（被接管的旧 pill 已不在容器里）。
    private func refreshPillTitle() {
        guard let pill = currentPill else { return }
        let count = running.count
        pill.setTitle(count > 1 ? "正在发布 \(count) 篇" : "正在发布…")
    }

    /// 胶囊点按：列出各篇状态（在途＋最近失败），失败项各带重试入口。
    /// 草稿已不在的失败记录先清掉，不列已删的篇。无在途也无失败记录时不弹。
    private func presentStatusSheet() {
        guard let container = currentPill?.superview ?? Self.keyWindowRootView(),
              let presenter = Self.topViewController(from: container) else { return }
        // 草稿已不在的失败记录先清掉，不列已删的篇；只当记录账号就是当前
        // 账号时才按缺失判过期（切号后旧号草稿不在当前桶里，不算已删）。
        // 先算 key 再删，不在 filter 闭包里改字典（遍历中修改会 crash）。
        // 读库失败时不判过期：loadAll 失败回 [] 不代表无草稿（见 loadAll 注释），
        // 此时直接列出现有记录，不删。
        if case .success(let allDrafts) = BearyDraftStore.loadAllResult() {
            let draftIds = Set(allDrafts.map { $0.draftId })
            let currentAccountId = BearyDraftStore.currentAccountId
            let staleKeys = failedJobs.values
                .filter { record in
                    guard let draftId = record.job.snapshot.draftId,
                          record.job.snapshot.accountId == currentAccountId else { return false }
                    return !draftIds.contains(draftId)
                }
                .map { $0.job.snapshot.draftId ?? $0.job.snapshot.clientReq }
            for key in staleKeys { failedJobs.removeValue(forKey: key) }
        }
        let failedList = failedJobs.values.sorted(by: { $0.failedAt > $1.failedAt })
        let runningList = running.values.sorted(by: { $0.startedAt < $1.startedAt })
        guard !runningList.isEmpty || !failedList.isEmpty else { return }
        var lines: [String] = []
        for job in runningList {
            lines.append("“\(Self.previewText(for: job.job.snapshot))” 发布中 \(Int((job.lastProgress * 100).rounded()))%")
        }
        for record in failedList {
            lines.append("“\(Self.previewText(for: record.job.snapshot))” 发布失败：\(record.message)")
        }
        let alert = UIAlertController(title: "发布状态", message: lines.joined(separator: "\n"), preferredStyle: .alert)
        for record in failedList {
            let preview = Self.previewText(for: record.job.snapshot)
            let title = record.sourcePublished ? "只重试新篇“\(preview)”" : "重试“\(preview)”"
            let key = record.job.snapshot.draftId ?? record.job.snapshot.clientReq
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                if self.retryPublish(draftId: key) == .needsEditor,
                   let fallbackContainer = self.currentPill?.superview ?? Self.keyWindowRootView() {
                    BearyToast.show(in: fallbackContainer, message: "请从草稿箱打开这篇再发布")
                }
            })
        }
        alert.addAction(UIAlertAction(title: "关闭", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// 状态表里的篇目短名：标题优先，无标题取正文前 10 字（去空白换行），再无取“这篇日记”。
    private static func previewText(for snapshot: PublishSnapshot) -> String {
        let title = (snapshot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(12)) }
        let body = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "这篇日记" }
        let prefix = String(body.prefix(10))
        return body.count > 10 ? prefix + "…" : prefix
    }

    /// key window 根视图（toast／重试 pill 无 hostView 时的落点；后台／无窗口时 nil）。
    private static func keyWindowRootView() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window.rootViewController?.view
            }
        }
        return scenes.first?.windows.first?.rootViewController?.view
    }

    /// 容器所属 VC（响应链往上找），有 presented 时认顶层，供状态表 present 用。
    private static func topViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController {
                var top = vc
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }

    // MARK: - 文案与进度口径

    /// 失败文案（从 BearyComposerViewController 原样移入）：服务端业务码
    /// 各分支原样，默认「发布失败，请重试」。共用三分支走
    /// BearyServerErrorMessages 共享码表，这里只留专属分支。
    static func message(forPublishError error: APIError) -> String {
        if case .server(let code, _) = error {
            if let shared = BearyServerErrorMessages.sharedMessage(forServerCode: code) {
                return shared
            }
            switch code {
            case "create_gap":
                return "发布太频繁，请稍后再试"
            case "create_day_limit":
                return "今日发布次数已达上限，请明天再试"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "recipient_invalid", "mentioned_user_invalid":
                return "无法提到这位用户，请重新选择"
            default:
                return "发布失败，请重试"
            }
        }
        return "发布失败，请重试"
    }

    /// 账号失配文案（编辑器 showPublishAccountMismatchAlert 原句）：
    /// 部分成功态（原日记已公开）另加一句。
    private func accountMismatchMessage(sourceAlreadyPublished: Bool) -> String {
        if sourceAlreadyPublished {
            return "原日记已公开，新篇未发布。账号已变化，请回到原账号后再发布，或丢弃本篇重新开始。"
        }
        return "账号已变化，本篇未发布。请回到原账号后再发布，或丢弃本篇重新开始。"
    }

    /// 部分成功失败文案：第 25 轮 13（收窄）：原日记已公开时，按 #2464 口径
    /// 先说失败——“发布失败，引用的日记已公开，…”；未公开时原样返回。
    /// 通用“发布失败，请重试”只改成“发布失败，引用的日记已公开，请只重试新篇”，
    /// 其余 base 前加“发布失败，引用的日记已公开。”前缀。
    /// 仅供上述四条分支用；fail(error:) 与账号失配
    /// 分支已有部分成功口径，不走这里。
    private func partialFailureMessage(_ base: String, runningJob: RunningJob) -> String {
        guard runningJob.sourcePublished else { return base }
        if base == "发布失败，请重试" {
            return NSLocalizedString("publish.partial_failure_retry_new_only", comment: "")
        }
        return NSLocalizedString("publish.partial_failure_prefix", comment: "") + base
    }

    private func reportProgress(_ runningJob: RunningJob, value: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 最新进度先记在任务上（pill 状态表读它；pill 本身只认当前任务）。
        runningJob.lastProgress = value
        guard runningJob.pill === currentPill else { return }
        // 展示封顶 0.95：上传字节发完、等服务端回包期间不先满格；
        // 成功瞬间才走满 1.0（见 finishSuccess）。
        runningJob.pill?.setProgress(min(value, 0.95), animated: false)
    }

    /// 第 25 轮 16／18 项：终态结果被接管时的 toast 落点——宿主容器优先
    /// （编辑器已退场也还在），没有宿主时退回当前 pill 的容器。
    private func terminalToastContainer(for runningJob: RunningJob) -> UIView? {
        runningJob.job.hostView ?? currentPill?.superview
    }

    /// 第 25 轮 17 项：发布前按全部图片＋POST 一次性立总预算（口径与各步
    /// 起传时的 setEstimate 一致：base64 体量＋固定开销；原图模式按原图
    /// 文件计，不按压缩 JPEG 计）。文件已缺失的步先不立预算（起传时按
    /// 失败处理，不虚增分母）；已有服务端 key 的图不上传，不占预算。
    /// 只读文件大小，不读文件内容；fileURL 用当前账号解析——起飞前账号
    /// 校验随后即拦失配，失配任务不展示进度，误算无害。
    private func seedTotalEstimate(for job: BearyPublishJob, into progress: BearyPublishProgress) {
        for (index, image) in job.images.enumerated() {
            if image.serverKey != nil { continue }
            guard let localFile = image.localFile else { continue }
            var bytes: Int64 = 0
            if image.uploadMode == .original,
               let originalFile = image.originalFile,
               let size = fileSize(BearyDraftImageStore.fileURL(for: originalFile)) {
                bytes += Int64(Self.base64Length(size)) + 23
            } else if let size = fileSize(BearyDraftImageStore.fileURL(for: localFile)) {
                bytes += Int64(Self.base64Length(size)) + 23
            } else {
                continue
            }
            if let thumbSize = fileSize(BearyDraftImageStore.fileURL(for: BearyDraftImageStore.thumbFileName(for: localFile))) {
                bytes += Int64(Self.base64Length(thumbSize)) + 23
            }
            if let videoFile = image.liveVideoFile,
               let videoSize = fileSize(BearyDraftImageStore.fileURL(for: videoFile)) {
                bytes += Int64(Self.base64Length(videoSize)) + 27
            } else if let videoData = image.liveVideoData {
                bytes += Int64(Self.base64Length(videoData.count)) + 27
            }
            bytes += 100
            progress.setEstimate(step: index, bytes: bytes)
        }
        progress.setEstimate(step: job.images.count, bytes: Int64(job.snapshot.content.utf8.count + 1024))
    }

    private func fileSize(_ url: URL?) -> Int? {
        guard let url = url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// base64 体量：4 * ceil(n / 3)，不物化字符串。
    private static func base64Length(_ byteCount: Int) -> Int {
        return 4 * ((byteCount + 2) / 3)
    }

    /// 在途任务（强持有到终态；终态后从 running 摘除即释放）。
    /// 并行上传记账：uploadResults／uploadLiveResults 按原下标收结果，
    /// uploadStarted 是下一个待起传的下标，uploadInFlight 是当前在途
    /// 路数，uploadFinished 是已落袋张数（含已有 key 不用传的）；
    /// imageKeys／liveVideos 在全部落袋后按序组装（见 finishUploadsAndPost）。
    private final class RunningJob {
        let job: BearyPublishJob
        let key: String
        var imageKeys: [String] = []
        var liveVideos: [String: String] = [:]
        var uploadResults: [Int: String] = [:]
        var uploadLiveResults: [Int: String] = [:]
        var uploadStarted = 0
        var uploadInFlight = 0
        var uploadFinished = 0
        var sourcePublished: Bool
        /// 第 25 轮 18 项：本次失败是否走“打开草稿重试”入口（实况回包缺
        /// live_key 时置位，见 uploadNext；fail() 据此改走带入口的 toast）。
        var openDraftOnFailure = false
        var progress = BearyPublishProgress()
        /// 最新上报进度（0...1，展示封顶前的值；pill 状态表读它）。
        var lastProgress: Double = 0
        /// 任务开始时刻（pill 状态表里在途任务按它排序）。
        let startedAt = Date()
        var pill: BearyPublishPillView?
        var finished = false

        init(job: BearyPublishJob) {
            self.job = job
            self.key = job.snapshot.draftId ?? job.snapshot.clientReq
            // 原日记已公开可能是本次 setVisibility 的结果，也可能是重试带入的
            // 已有态（编辑器持久标记／一键重试沿用），后者起跑即为 true。
            self.sourcePublished = job.sourceAlreadyPublished
        }
    }
}

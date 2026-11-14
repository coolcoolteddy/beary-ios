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
    /// 时间胶囊 v1：埋了才有值（解锁毫秒戳＋区级）；不埋两者皆 nil，
    /// 发布中心按它发 is_capsule 三键（变基衔接：main 侧胶囊字段，
    /// #1451 基线后才进 main，快照从编辑器移到中心时须一并带上，
    /// 否则埋胶囊的日记会静默发成普通篇）。
    let capsuleUnlockAt: Int?
    let capsuleDistrict: String?
    let mentionedUserId: Int?
    let title: String?
    var ephemeral: Int?
    let locationName: String?
    let locationDistrict: String?
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
    /// 第 25 轮 19 项：已保存的原图上传方式与原图文件（与草稿
    /// BearyDraftImageItem 同款字段；nil = 压缩／无原图）。发布时按它
    /// 读原图，不静默改传压缩 JPEG。
    let uploadMode: BearyUploadMode?
    let originalFile: String?
}

/// 一次后台发布任务：快照＋图片清单＋门禁出路＋宿主视图＋回包闭包。
/// hostView 只弱持有（Chrome 的 view，编辑器退出后 pill 挂在它上面）；
/// onPublished/onRequireLogin 是编辑器交接来的容器闭包值（不持有编辑器
/// 本身），编辑器已退场时照常执行（SceneDelegate.onPublished 的 dismiss
/// 在无 presented 页时为空操作、后续切时间线照常）。
struct BearyPublishJob {
    let snapshot: PublishSnapshot
    let images: [BearyPublishImage]
    /// 门禁选了「一并公开」：先 setVisibility 公开原日记，再发新篇。
    let publishTogether: Bool
    weak var hostView: UIView?
    let onPublished: ((String) -> Void)?
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
/// 流程：起飞前账号校验 →（一并公开时）setVisibility → 按顺序逐张
/// 上传本地图片（拿到 keys）→ publishEntry。任一步失败即停，草稿
/// 保留（交接前已落盘），pill 显示现有失败文案；成功清草稿与本地
/// 图片、pill 对勾「已发布」、走 onPublished。
/// 杀 App／切后台时发布即停、草稿可重试（不加后台任务）；失败重试
/// 重传全部图片（不做中途 keys 落盘）。
final class BearyPublishCenter {

    static let shared = BearyPublishCenter()

    /// 图片准备（读盘＋base64）走本队列，不占主线程；与编辑器
    /// imagePrepQueue 同款分工。
    private let ioQueue = DispatchQueue(label: "beary.publishCenter", qos: .userInitiated)

    private var running: [String: RunningJob] = [:]
    /// 当前可见的 pill（同一时刻只一块；新任务接管时旧 pill 被 show 移除，
    /// 旧任务的终态结果改以 toast 落在宿主容器上（第 25 轮 16 项），
    /// 草稿仍保留在草稿箱、可重发）。
    private weak var currentPill: BearyPublishPillView?

    private init() {}

    /// 同一草稿是否正在后台发布（草稿箱打开／删除的守卫）。
    func isPublishing(draftId: String?) -> Bool {
        guard let key = draftId else { return false }
        return running[key] != nil
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
        // 第 25 轮 17 项：发布前一次性估算全部步骤的总预算（图片＋POST），
        // 再开始第一步——进度分母从一开始就是总量，首图传完不再冲到 0.95。
        seedTotalEstimate(for: job, into: runningJob.progress)
        if let host = job.hostView {
            let pill = BearyPublishPill.show(in: host)
            currentPill = pill
            runningJob.pill = pill
        }
        // 起飞前账号校验：快照发起账号与当前账号失配即中止、不发请求，
        // 草稿保留（交接前已落盘），pill 用现有账号失配文案。
        // 此时原日记尚未公开，用 plain 文案（部分成功文案见 runPost 前校验）。
        if let expected = job.snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            fail(runningJob, message: accountMismatchMessage(sourceAlreadyPublished: false))
            return true
        }
        if job.publishTogether {
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

    private func uploadNext(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        let job = runningJob.job
        // 每步（图片上传／转 POST）前再校验发起账号（旧 uploadPrepared
        // 令牌门控与 performPublish 入口同款）：切号后不再用新账号
        // cookie 传旧账号的图片或发帖，草稿保留；部分成功态（原日记
        // 已公开）用部分成功口径。
        if let expected = job.snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            fail(runningJob, message: accountMismatchMessage(sourceAlreadyPublished: runningJob.sourcePublished))
            return
        }
        if runningJob.imageIndex >= job.images.count {
            runPost(runningJob)
            return
        }
        let image = job.images[runningJob.imageIndex]
        // 已有服务端 key 的图不再上传（旧草稿、旧版已传完的图）。
        if let key = image.serverKey {
            runningJob.imageKeys.append(key)
            if let liveKey = image.liveVideoKey {
                runningJob.liveVideos[key] = liveKey
            }
            runningJob.imageIndex += 1
            uploadNext(runningJob)
            return
        }
        guard let localFile = image.localFile else {
            // 交接时已守卫（无 key 又无本地文件拦截不发），到这里即程序错误；
            // 按图片失效处理，不编新文案。
            fail(runningJob, message: Self.message(forPublishError: .server("image unavailable", nil)))
            return
        }
        let step = runningJob.imageIndex
        let accountId = job.snapshot.accountId
        ioQueue.async { [weak self, weak runningJob] in
            guard let self = self, let runningJob = runningJob, !runningJob.finished else { return }
            guard let prepared = BearyDraftImageStore.existingPreparedJPEG(fullName: localFile, accountId: accountId) else {
                DispatchQueue.main.async {
                    self.fail(runningJob, message: Self.message(forPublishError: .server("image unavailable", nil)))
                }
                return
            }
            var videoData = image.liveVideoData
            if videoData == nil, let videoFile = image.liveVideoFile {
                videoData = BearyDraftImageStore.videoData(for: videoFile)
                if videoData == nil {
                    DispatchQueue.main.async {
                        // 实况视频已丢：与编辑器恢复态同口径，不静默降级为静态。
                        self.fail(runningJob, message: "有实况视频已丢失，重新选择该图片后再发布")
                    }
                    return
                }
            }
            // 第 25 轮 19 项：按已保存的原图模式读原图——原图模式且 .orig 在时，
            // 发剥 GPS 后的原图（仅 HEIC/JPEG、5MB 以内，与编辑器起传同口径）；
            // 取不到、格式不明或剥 GPS 失败时回落压缩，不静默丢图。
            var fullData = prepared.full.data
            var fullWidth = prepared.full.w
            var fullHeight = prepared.full.h
            var mimeType = "image/jpeg"
            if image.uploadMode == .original, let originalFile = image.originalFile,
               let rawData = BearyDraftImageStore.originalData(for: originalFile),
               rawData.count <= 5 * 1024 * 1024,
               let strippedData = BearyImagePrep.strippedGPSData(rawData),
               let detectedMime = BearyImagePrep.mimeType(of: strippedData),
               detectedMime == "image/heic" || detectedMime == "image/jpeg",
               let pixelSize = BearyImagePrep.pixelSize(of: strippedData),
               pixelSize.width > 0, pixelSize.height > 0 {
                fullData = strippedData
                fullWidth = pixelSize.width
                fullHeight = pixelSize.height
                mimeType = detectedMime
            }
            let dataUrl = BearyImagePrep.dataURL(fullData, mimeType: mimeType)
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
                        runningJob.imageKeys.append(key)
                        if let liveKey = resp.liveKey {
                            runningJob.liveVideos[key] = liveKey
                        }
                        runningJob.imageIndex += 1
                        self.uploadNext(runningJob)
                    case .failure(let error):
                        self.fail(runningJob, error: error)
                    }
                }
            }
        }
    }

    private func runPost(_ runningJob: RunningJob) {
        dispatchPrecondition(condition: .onQueue(.main))
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
            locationDistrict: snapshot.locationDistrict, temperature: snapshot.temperature,
            liveVideos: runningJob.liveVideos.isEmpty ? nil : runningJob.liveVideos,
            visibility: snapshot.visibility,
            isCapsule: snapshot.capsuleUnlockAt == nil ? nil : 1,
            capsuleUnlockAt: snapshot.capsuleUnlockAt, capsuleDistrict: snapshot.capsuleDistrict,
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
                        self.fail(runningJob, message: "发布失败，请重试")
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
        BearyDraftImageStore.deletePairsIfUnreferencedAsync(snapshot.imageLocalFiles, excludingDraftId: snapshot.draftId, forAccount: snapshot.accountId)
        if let draftIdValue = snapshot.draftId {
            BearyDraftStore.deleteAsync(draftId: draftIdValue, forAccount: snapshot.accountId)
        }
        BearyHaptics.publishSuccess()
        BearySoundPlayer.play(.publishSuccess)
        if runningJob.pill === currentPill {
            runningJob.pill?.finishSuccess()
            currentPill = nil
        } else if let container = terminalToastContainer(for: runningJob) {
            // 第 25 轮 16 项：pill 已被新任务接管时，成功结果同样以 toast 留档。
            BearyToast.show(in: container, message: "已发布")
        }
        // 第 25 轮 15 项：最终成功回包再次核对发起账号——uploadNext 只在每步前
        // 校验，POST 回包前切号仍可能让旧账号结果走到新账号容器；失配时不走
        // onPublished（容器按当前账号刷新与 upsert 都不属于旧账号）。草稿清理
        // 仍按快照账号做（服务端已落盘），pill 照常显示已发布。
        if let expected = snapshot.originAccountId,
           BearyAPI.shared.authAccountId != expected {
            return
        }
        runningJob.job.onPublished?(entryId)
    }

    /// 失败：停掉任务、草稿保留（交接前已落盘，不再重存）、拒绝震动、
    /// pill 显示现有失败文案。401 另走登录入口（见 fail(error:)）。
    private func fail(_ runningJob: RunningJob, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !runningJob.finished else { return }
        runningJob.finished = true
        running.removeValue(forKey: runningJob.key)
        BearyHaptics.rejectionWarning()
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
        if runningJob.pill === currentPill {
            runningJob.pill?.finishFailure(message: message)
            currentPill = nil
        } else if let container = terminalToastContainer(for: runningJob) {
            // 第 25 轮 16 项：pill 已被新任务接管时，旧任务失败仍须有可查看的
            // 结果，改以 toast 形式落在宿主容器上；草稿仍在草稿箱可重发。
            BearyToast.show(in: container, message: message)
        }
        // pill 仍是本任务时按旧口径走 pill，不再另弹 toast；
        // 无宿主容器时无处可落 toast，失败只剩草稿（与旧口径一致）。
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

    // MARK: - 文案与进度口径

    /// 失败文案（从 BearyComposerViewController 原样移入）：服务端业务码
    /// 各分支原样，默认「发布失败，请重试」。
    static func message(forPublishError error: APIError) -> String {
        if case .server(let code, _) = error {
            switch code {
            case "create_gap":
                return "发布太频繁，请稍后再试"
            case "create_day_limit":
                return "今日发布次数已达上限，请明天再试"
            case "create_dup":
                return "这篇和你写过的一篇一模一样"
            case "content too long":
                return "正文最多 2000 字"
            case "title too long":
                return "标题最多 30 字"
            case "image unavailable":
                return "图片已失效，请重新添加"
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

    private func reportProgress(_ runningJob: RunningJob, value: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
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
    private final class RunningJob {
        let job: BearyPublishJob
        let key: String
        var imageKeys: [String] = []
        var liveVideos: [String: String] = [:]
        var imageIndex = 0
        var sourcePublished: Bool
        /// 第 25 轮 18 项：本次失败是否走“打开草稿重试”入口（实况回包缺
        /// live_key 时置位，见 uploadNext；fail() 据此改走带入口的 toast）。
        var openDraftOnFailure = false
        var progress = BearyPublishProgress()
        var pill: BearyPublishPillView?
        var finished = false

        init(job: BearyPublishJob) {
            self.job = job
            self.key = job.snapshot.draftId ?? job.snapshot.clientReq
            self.sourcePublished = false
        }
    }
}
